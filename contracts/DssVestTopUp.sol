// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@uniswap/v3-periphery/contracts/libraries/TransferHelper.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "./interfaces/IUpkeepRefunder.sol";

interface DssVestLike {
    function vest(uint256 _id) external;

    function unpaid(uint256 _id) external view returns (uint256 amt);
}

interface DaiJoinLike {
    function join(address usr, uint256 wad) external;
}

interface KeeperRegistryLike {
    function getUpkeep(uint256 id)
        external
        view
        returns (
            address target,
            uint32 executeGas,
            bytes memory checkData,
            uint96 balance,
            address lastKeeper,
            address admin,
            uint64 maxValidBlocknumber
        );

    function addFunds(uint256 id, uint96 amount) external;
}

/**
 * @title DssVestTopUp
 * @notice Replenishes upkeep balance on demand
 * @dev Withdraws vested tokens or uses transferred tokens from Maker protocol and
 * funds an upkeep after swapping the payment tokens for LINK
 */
contract DssVestTopUp is IUpkeepRefunder, Ownable {
    DssVestLike public immutable dssVest;
    DaiJoinLike public immutable daiJoin;
    ISwapRouter public immutable swapRouter;
    address public immutable vow;
    address public immutable paymentToken;
    address public immutable linkToken;
    address public immutable paymentUsdPriceFeed;
    address public immutable linkUsdPriceFeed;
    KeeperRegistryLike public keeperRegistry;
    uint24 public uniswapPoolFee = 3000;
    uint24 public uniswapSlippageTolerancePercent = 2;
    uint256 public vestId;
    uint256 public upkeepId;
    uint256 public minWithdrawAmt;
    uint256 public maxDepositAmt;
    uint256 public threshold;

    event VestIdUpdated(uint256 newVestId);
    event UpkeepIdUpdated(uint256 newUpkeepId);
    event MinWithdrawAmtUpdated(uint256 newMinWithdrawAmt);
    event MaxDepositAmtUpdated(uint256 newMaxDepositAmt);
    event ThresholdUpdated(uint256 newThreshold);
    event VestedTokensWithdrawn(uint256 amount);
    event ExcessPaymentReturned(uint256 amount);
    event SwappedPaymentTokenForLink(uint256 amountIn, uint256 amountOut);
    event UpkeepRefunded(uint256 amount);
    event FundsRecovered(address token, uint256 amount);

    constructor(
        address _dssVest,
        address _daiJoin,
        address _vow,
        address _paymentToken,
        address _keeperRegistry,
        address _swapRouter,
        address _linkToken,
        address _paymentUsdPriceFeed,
        address _linkUsdPriceFeed,
        uint256 _minWithdrawAmt,
        uint256 _maxDepositAmt,
        uint256 _threshold
    ) {
        require(_dssVest != address(0), "invalid dssVest address");
        require(_daiJoin != address(0), "invalid daiJoin address");
        require(_vow != address(0), "invalid vow address");
        require(_paymentToken != address(0), "invalid paymentToken address");
        require(_keeperRegistry != address(0), "invalid keeperRegistry address");
        require(_swapRouter != address(0), "invalid swapRouter address");
        require(_linkToken != address(0), "invalid linkToken address");
        require(_paymentUsdPriceFeed != address(0), "invalid paymentUsdPriceFeed address");
        require(_linkUsdPriceFeed != address(0), "invalid linkUsdPriceFeed address");
        require(_minWithdrawAmt > 0, "invalid minWithdrawAmt");
        require(_maxDepositAmt > 0, "invalid maxDepositAmt");
        require(_threshold > 0, "invalid threshold");

        dssVest = DssVestLike(_dssVest);
        daiJoin = DaiJoinLike(_daiJoin);
        vow = _vow;
        paymentToken = _paymentToken;
        keeperRegistry = KeeperRegistryLike(_keeperRegistry);
        swapRouter = ISwapRouter(_swapRouter);
        linkToken = _linkToken;
        paymentUsdPriceFeed = _paymentUsdPriceFeed;
        linkUsdPriceFeed = _linkUsdPriceFeed;
        setMinWithdrawAmt(_minWithdrawAmt);
        setMaxDepositAmt(_maxDepositAmt);
        setThreshold(_threshold);
    }

    modifier initialized() {
        require(vestId > 0, "vestId not set");
        require(upkeepId > 0, "upkeepId not set");
        _;
    }

    // ACTIONS

    /**
     * @notice Top up upkeep balance with LINK
     * @dev Called by the DssCronKeeper contract when check returns true
     */
    function refundUpkeep() public initialized {
        require(shouldRefundUpkeep(), "refund not needed");
        uint256 amt;
        uint256 preBalance = getPaymentBalance();
        if (preBalance >= minWithdrawAmt) {
            // Emergency topup
            amt = preBalance;
        } else {
            // Withdraw vested tokens
            dssVest.vest(vestId);
            amt = getPaymentBalance();
            emit VestedTokensWithdrawn(amt);
            if (amt > maxDepositAmt) {
                // Return excess amount to surplus buffer
                uint256 excessAmt = amt - maxDepositAmt;
                daiJoin.join(vow, excessAmt);
                amt = maxDepositAmt;
                emit ExcessPaymentReturned(excessAmt);
            }
        }
        uint256 amtOut = _swapPaymentToLink(amt);
        _fundUpkeep(amtOut);
    }

    /**
     * @notice Check whether top up is needed
     * @dev Called by the keeper
     * @return result indicating if topping up the upkeep balance is needed and
     * if there's enough unpaid vested tokens or tokens in the contract balance
     */
    function shouldRefundUpkeep() public view initialized returns (bool) {
        (, , , uint96 balance, , , ) = keeperRegistry.getUpkeep(upkeepId);
        if (
            threshold < balance ||
            (dssVest.unpaid(vestId) < minWithdrawAmt &&
                getPaymentBalance() < minWithdrawAmt)
        ) {
            return false;
        }
        return true;
    }

    // HELPERS

    function _swapPaymentToLink(uint256 amount)
        internal
        returns (uint256 amountOut)
    {
        TransferHelper.safeApprove(paymentToken, address(swapRouter), amount);
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter
            .ExactInputSingleParams({
                tokenIn: paymentToken,
                tokenOut: linkToken,
                fee: uniswapPoolFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amount,
                amountOutMinimum: _getPaymentLinkSwapOutMin(amount),
                sqrtPriceLimitX96: 0
            });
        amountOut = swapRouter.exactInputSingle(params);
        emit SwappedPaymentTokenForLink(amount, amountOut);
    }

    function _fundUpkeep(uint256 amount) internal {
        TransferHelper.safeApprove(linkToken, address(keeperRegistry), amount);
        keeperRegistry.addFunds(upkeepId, uint96(amount));
        emit UpkeepRefunded(amount);
    }

    function _getPaymentLinkSwapOutMin(uint256 amountIn) internal view returns (uint256) {
        uint256 linkDecimals = IERC20Metadata(linkToken).decimals();
        uint256 paymentLinkPrice = uint256(_getDerivedPrice(paymentUsdPriceFeed, linkUsdPriceFeed, uint8(linkDecimals)));

        uint256 paymentDecimals = IERC20Metadata(paymentToken).decimals();
        uint256 paymentAmt = uint256(_scalePrice(int256(amountIn), uint8(paymentDecimals), uint8(linkDecimals)));

        uint256 linkAmt = (paymentAmt * paymentLinkPrice) / 10 ** linkDecimals;
        uint256 slippageTolerance = (linkAmt * uniswapSlippageTolerancePercent) / 100;

        return linkAmt - slippageTolerance;
    }

    function _getDerivedPrice(address _base, address _quote, uint8 _decimals)
        internal
        view
        returns (int256)
    {
        require(_decimals > uint8(0) && _decimals <= uint8(18), "invalid decimals");
        int256 decimals = int256(10 ** uint256(_decimals));
        ( , int256 basePrice, , , ) = AggregatorV3Interface(_base).latestRoundData();
        uint8 baseDecimals = AggregatorV3Interface(_base).decimals();
        basePrice = _scalePrice(basePrice, baseDecimals, _decimals);

        ( , int256 quotePrice, , , ) = AggregatorV3Interface(_quote).latestRoundData();
        uint8 quoteDecimals = AggregatorV3Interface(_quote).decimals();
        quotePrice = _scalePrice(quotePrice, quoteDecimals, _decimals);

        return basePrice * decimals / quotePrice;
    }

    function _scalePrice(int256 _price, uint8 _priceDecimals, uint8 _decimals)
        internal
        pure
        returns (int256)
    {
        if (_priceDecimals < _decimals) {
            return _price * int256(10 ** uint256(_decimals - _priceDecimals));
        } else if (_priceDecimals > _decimals) {
            return _price / int256(10 ** uint256(_priceDecimals - _decimals));
        }
        return _price;
    }

    /**
     * @dev Rescues random funds stuck
     * @param token address of the token to rescue
     */
    function recoverFunds(IERC20 token) external onlyOwner {
        uint256 tokenBalance = token.balanceOf(address(this));
        token.transfer(msg.sender, tokenBalance);
        emit FundsRecovered(address(token), tokenBalance);
    }

    // GETTERS

    /**
     * @notice Retrieve the vest payment token balance of this contract
     * @return balance
     */
    function getPaymentBalance() public view returns (uint256) {
        return IERC20(paymentToken).balanceOf(address(this));
    }

    // SETTERS

    function setVestId(uint256 _vestId) external onlyOwner {
        require(_vestId > 0, "invalid vestId");
        vestId = _vestId;
        emit VestIdUpdated(_vestId);
    }

    function setUpkeepId(uint256 _upkeepId) external onlyOwner {
        require(_upkeepId > 0, "invalid upkeepId");
        upkeepId = _upkeepId;
        emit UpkeepIdUpdated(_upkeepId);
    }

    function setMinWithdrawAmt(uint256 _minWithdrawAmt) public onlyOwner {
        require(_minWithdrawAmt > 0, "invalid minWithdrawAmt");
        minWithdrawAmt = _minWithdrawAmt;
        emit MinWithdrawAmtUpdated(_minWithdrawAmt);
    }

    function setMaxDepositAmt(uint256 _maxDepositAmt) public onlyOwner {
        require(_maxDepositAmt > 0, "invalid maxDepositAmt");
        maxDepositAmt = _maxDepositAmt;
        emit MaxDepositAmtUpdated(_maxDepositAmt);
    }

    function setThreshold(uint256 _threshold) public onlyOwner {
        require(_threshold > 0, "invalid threshold");
        threshold = _threshold;
        emit ThresholdUpdated(_threshold);
    }
    
     function setUniswapPoolFee(uint24 _uniSwapPoolFee) public onlyOwner {
        uniswapPoolFee = _uniSwapPoolFee;
    }

    function setSlippageTolerancePercent(
        uint24 _uniswapSlippageTolerancePercent
    ) public onlyOwner {
        uniswapSlippageTolerancePercent = _uniswapSlippageTolerancePercent;
    }

    function setKeeperRegistry(address _keeperRegistry) public onlyOwner {
        keeperRegistry = KeeperRegistryLike(_keeperRegistry);
    }
}
