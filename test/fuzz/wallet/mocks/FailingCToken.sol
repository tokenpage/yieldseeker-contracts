// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

contract FailingCToken {
    uint256 private constant ERROR_CODE = 1;
    address public immutable underlying;

    constructor(address underlying_) {
        underlying = underlying_;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1e18;
    }

    function mint(uint256) external pure returns (uint256) {
        return ERROR_CODE;
    }

    function redeem(uint256) external pure returns (uint256) {
        return ERROR_CODE;
    }
}
