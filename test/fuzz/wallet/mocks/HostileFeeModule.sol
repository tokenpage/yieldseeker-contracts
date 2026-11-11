// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IYieldSeekerFeeModule} from "../../../../src/fees/IYieldSeekerFeeModule.sol";

contract HostileFeeModule is IYieldSeekerFeeModule {
    enum Behavior {
        None,
        Revert,
        BurnGas,
        Overcharge
    }

    address public immutable override FEE_TRACKER;
    bytes32 public immutable override FEE_TYPE;
    Behavior public immutable behavior;
    uint256 public immutable owed;

    error HostileFeeModuleReverted();

    constructor(address tracker, bytes32 feeType, Behavior behavior_, uint256 owed_) {
        FEE_TRACKER = tracker;
        FEE_TYPE = feeType;
        behavior = behavior_;
        owed = owed_;
    }

    function isValidPlan(bytes calldata) external pure override returns (bool) {
        return true;
    }

    function onAction(address, bytes32, bytes calldata, uint256 maxPayment) external view override returns (uint256) {
        if (behavior == Behavior.Revert) revert HostileFeeModuleReverted();
        if (behavior == Behavior.BurnGas) {
            while (true) {}
        }
        if (behavior == Behavior.Overcharge) return maxPayment + 1;
        return 0;
    }

    function isAccountedToken(address, address) external pure override returns (bool) {
        return false;
    }

    function feesOwedInBaseAsset(address) external view override returns (uint256) {
        return owed;
    }
}
