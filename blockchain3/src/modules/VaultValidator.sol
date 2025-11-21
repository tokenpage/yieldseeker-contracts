// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IPolicyValidator.sol";

contract VaultValidator is IPolicyValidator {

    address public immutable allowedAsset;
    uint256 public immutable maxAmount;

    constructor(address _allowedAsset, uint256 _maxAmount) {
        allowedAsset = _allowedAsset;
        maxAmount = _maxAmount;
    }

    function validateAction(
        address, // wallet
        address, // target
        bytes4 selector,
        bytes calldata data
    ) external view override returns (bool) {
        // Selector for deposit(address,uint256) is usually something like 0x47e7ef24
        // But we assume the caller (Executor) already matched the selector to this validator

        // Decode params: deposit(address asset, uint256 amount)
        // Skip selector (4 bytes)
        if (data.length < 4 + 64) return false;

        (address asset, uint256 amount) = abi.decode(data[4:], (address, uint256));

        if (asset != allowedAsset) return false;
        if (amount > maxAmount) return false;

        return true;
    }
}
