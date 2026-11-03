// SPDX-License-Identifier: MIT
//
//   /$$     /$$ /$$           /$$       /$$  /$$$$$$                      /$$
//  |  $$   /$$/|__/          | $$      | $$ /$$__  $$                    | $$
//   \  $$ /$$/  /$$  /$$$$$$ | $$  /$$$$$$$| $$  \__/  /$$$$$$   /$$$$$$ | $$   /$$  /$$$$$$   /$$$$$$
//    \  $$$$/  | $$ /$$__  $$| $$ /$$__  $$|  $$$$$$  /$$__  $$ /$$__  $$| $$  /$$/ /$$__  $$ /$$__  $$
//     \  $$/   | $$| $$$$$$$$| $$| $$  | $$ \____  $$| $$$$$$$$| $$$$$$$$| $$$$$$/ | $$$$$$$$| $$  \__/
//      | $$    | $$| $$_____/| $$| $$  | $$ /$$  \ $$| $$_____/| $$_____/| $$_  $$ | $$_____/| $$
//      | $$    | $$|  $$$$$$$| $$|  $$$$$$$|  $$$$$$/|  $$$$$$$|  $$$$$$$| $$ \  $$|  $$$$$$$| $$
//      |__/    |__/ \_______/|__/ \_______/ \______/  \_______/ \_______/|__/  \__/ \_______/|__/
//
//  Build wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKAaveV3LendingAdapter} from "../agentwalletkit/adapters/AWKAaveV3LendingAdapter.sol";
import {AWKLendingAdapter} from "../agentwalletkit/adapters/AWKLendingAdapter.sol";
import {YieldSeekerLendingAdapter} from "./LendingAdapter.sol";

error EModeNotAllowed(uint8 eModeCategory);

/**
 * @title YieldSeekerAaveV3LendingAdapter
 * @notice Borrow against the wallet's base asset on registered Aave V3 pools, with the borrow fee
 * @dev Only markets with eMode 0: Aave keeps one eMode and one debt per (pool, asset) for the whole account, so eMode
 *      variants of a market would share that debt while the borrow fee tracks each market separately.
 */
contract YieldSeekerAaveV3LendingAdapter is AWKAaveV3LendingAdapter, YieldSeekerLendingAdapter {
    function _marketAssets(bytes memory market) internal pure override(AWKAaveV3LendingAdapter, AWKLendingAdapter) returns (address collateralAsset, address debtAsset) {
        uint8 eModeCategory;
        (, collateralAsset, debtAsset, eModeCategory) = _decodeMarket(market);
        if (eModeCategory != 0) revert EModeNotAllowed(eModeCategory);
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
