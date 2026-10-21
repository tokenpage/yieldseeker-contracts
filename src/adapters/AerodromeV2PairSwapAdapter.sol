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
import {AWKAerodromeV2SwapAdapter} from "../agentwalletkit/adapters/AWKAerodromeV2SwapAdapter.sol";
import {AWKSwapAdapter} from "../agentwalletkit/adapters/AWKSwapAdapter.sol";
import {YieldSeekerPairSwapAdapter} from "./PairSwapAdapter.sol";

contract YieldSeekerAerodromeV2PairSwapAdapter is AWKAerodromeV2SwapAdapter, YieldSeekerPairSwapAdapter {
    constructor(
        address aerodromeV2Router,
        address aerodromeV2Factory,
        address sellPolicy,
        IYieldSeekerPriceOracle priceOracle,
        uint256 maxSlippageBps
    )
        AWKAerodromeV2SwapAdapter(aerodromeV2Router, aerodromeV2Factory)
        YieldSeekerPairSwapAdapter(sellPolicy, priceOracle, maxSlippageBps)
    {}

    function _beforeSwap(address sellToken, address buyToken) internal view override(AWKSwapAdapter, YieldSeekerPairSwapAdapter) {
        super._beforeSwap(sellToken, buyToken);
    }

    function _afterSwapInternal(address router, address sellToken, address buyToken, uint256 minBuyAmount, SwapBalanceSnapshot memory snapshot) internal override(AWKSwapAdapter, YieldSeekerPairSwapAdapter) returns (uint256, uint256) {
        return super._afterSwapInternal(router, sellToken, buyToken, minBuyAmount, snapshot);
    }
}
