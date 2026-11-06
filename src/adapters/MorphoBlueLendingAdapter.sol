// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AWKLendingAdapter} from "../agentwalletkit/adapters/AWKLendingAdapter.sol";
import {AWKMorphoBlueLendingAdapter} from "../agentwalletkit/adapters/AWKMorphoBlueLendingAdapter.sol";
import {YieldSeekerLendingAdapter} from "./LendingAdapter.sol";

/**
 * @title YieldSeekerMorphoBlueLendingAdapter
 * @notice Borrow against the wallet's base asset on registered Morpho Blue markets, with the borrow fee
 */
contract YieldSeekerMorphoBlueLendingAdapter is AWKMorphoBlueLendingAdapter, YieldSeekerLendingAdapter {
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
