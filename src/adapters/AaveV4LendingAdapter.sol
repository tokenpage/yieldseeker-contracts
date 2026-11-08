// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AWKAaveV4LendingAdapter} from "../agentwalletkit/adapters/AWKAaveV4LendingAdapter.sol";
import {AWKLendingAdapter} from "../agentwalletkit/adapters/AWKLendingAdapter.sol";
import {YieldSeekerLendingAdapter} from "./LendingAdapter.sol";

/**
 * @title YieldSeekerAaveV4LendingAdapter
 * @notice Borrow against the wallet's base asset on registered Aave V4 spokes, with the borrow fee
 */
contract YieldSeekerAaveV4LendingAdapter is AWKAaveV4LendingAdapter, YieldSeekerLendingAdapter {
    function collateralPosition(bytes memory market) public pure override(AWKAaveV4LendingAdapter, AWKLendingAdapter) returns (address) {
        return super.collateralPosition(market);
    }

    function debtPosition(bytes memory market) public pure override(AWKAaveV4LendingAdapter, AWKLendingAdapter) returns (address) {
        return super.debtPosition(market);
    }

    function _supplyCollateralOperation(bytes memory market, uint256 amount) internal override(AWKLendingAdapter, YieldSeekerLendingAdapter) returns (uint256) {
        return super._supplyCollateralOperation(market, amount);
    }

    function _withdrawCollateralOperation(bytes memory market, uint256 amount) internal override(AWKLendingAdapter, YieldSeekerLendingAdapter) returns (uint256) {
        return super._withdrawCollateralOperation(market, amount);
    }

    function _borrowOperation(bytes memory market, uint256 amount) internal override(AWKLendingAdapter, YieldSeekerLendingAdapter) returns (uint256) {
        return super._borrowOperation(market, amount);
    }

    function _repayOperation(bytes memory market, uint256 amount) internal override(AWKLendingAdapter, YieldSeekerLendingAdapter) returns (uint256) {
        return super._repayOperation(market, amount);
    }

    function _checkpointOperation(bytes memory market) internal override(AWKLendingAdapter, YieldSeekerLendingAdapter) returns (uint256) {
        return super._checkpointOperation(market);
    }
}
