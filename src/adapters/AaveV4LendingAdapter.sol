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
//  Grow your wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {IYieldSeekerPriceOracle} from "../PriceOracle.sol";
import {AWKAaveV4LendingAdapter} from "../agentwalletkit/adapters/AWKAaveV4LendingAdapter.sol";
import {AWKLendingAdapter} from "../agentwalletkit/adapters/AWKLendingAdapter.sol";
import {YieldSeekerLendingAdapter} from "./LendingAdapter.sol";

/**
 * @title YieldSeekerAaveV4LendingAdapter
 * @notice Borrow against the wallet's base asset on registered Aave V4 spokes, with the borrow fee
 */
contract YieldSeekerAaveV4LendingAdapter is AWKAaveV4LendingAdapter, YieldSeekerLendingAdapter {
    constructor(IYieldSeekerPriceOracle priceOracle) YieldSeekerLendingAdapter(priceOracle) {}

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
}
