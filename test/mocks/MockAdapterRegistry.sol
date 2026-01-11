// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title MockAdapterRegistry
/// @notice Simple adapter registry mock for testing
contract MockAdapterRegistry {
    mapping(address => address) private _targetAdapters;

    function setTargetAdapter(address target, address adapter) external {
        _targetAdapters[target] = adapter;
    }

    function getTargetAdapter(address target) external view returns (address) {
        return _targetAdapters[target];
    }
}
