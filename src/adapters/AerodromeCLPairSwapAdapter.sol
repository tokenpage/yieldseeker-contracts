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
import {AWKAerodromeCLSwapAdapter} from "../agentwalletkit/adapters/AWKAerodromeCLSwapAdapter.sol";
import {AWKSwapAdapter} from "../agentwalletkit/adapters/AWKSwapAdapter.sol";
import {YieldSeekerPairSwapAdapter} from "./PairSwapAdapter.sol";

contract YieldSeekerAerodromeCLPairSwapAdapter is AWKAerodromeCLSwapAdapter, YieldSeekerPairSwapAdapter {
    constructor(address aerodromeClRouter, address sellPolicy, IYieldSeekerPriceOracle priceOracle, uint256 maxSlippageBps) AWKAerodromeCLSwapAdapter(aerodromeClRouter) YieldSeekerPairSwapAdapter(sellPolicy, priceOracle, maxSlippageBps) {}

    function _beforeSwap(address sellToken, address buyToken) internal view override(AWKSwapAdapter, YieldSeekerPairSwapAdapter) {
        super._beforeSwap(sellToken, buyToken);
    }

    function _afterSwapInternal(address router, address sellToken, address buyToken, uint256 minBuyAmount, SwapBalanceSnapshot memory snapshot) internal override(AWKSwapAdapter, YieldSeekerPairSwapAdapter) returns (uint256, uint256) {
        return super._afterSwapInternal(router, sellToken, buyToken, minBuyAmount, snapshot);
    }
}
