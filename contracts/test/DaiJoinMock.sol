// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

contract DaiJoinMock {
    event Join(address usr, uint256 wad);

    function join(address usr, uint256 wad) external {
        emit Join(usr, wad);
    }
}
