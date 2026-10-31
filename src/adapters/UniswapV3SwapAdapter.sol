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
import {AWKSwapAdapter} from "../agentwalletkit/adapters/AWKSwapAdapter.sol";
import {AWKUniswapV3SwapAdapter} from "../agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {YieldSeekerSwapAdapter} from "./SwapAdapter.sol";

contract YieldSeekerUniswapV3SwapAdapter is AWKUniswapV3SwapAdapter, YieldSeekerSwapAdapter {
    constructor(address uniswapV3Router, address sellPolicy, IYieldSeekerPriceOracle priceOracle, uint256 maxSlippageBps) AWKUniswapV3SwapAdapter(uniswapV3Router) YieldSeekerSwapAdapter(sellPolicy, priceOracle, maxSlippageBps) {}

    function _beforeSwap(address sellToken, address buyToken) internal view override(AWKSwapAdapter, YieldSeekerSwapAdapter) {
        super._beforeSwap(sellToken, buyToken);
    }

    function _afterSwapInternal(address router, address sellToken, address buyToken, uint256 minBuyAmount, SwapBalanceSnapshot memory snapshot) internal override(AWKSwapAdapter, YieldSeekerSwapAdapter) returns (uint256, uint256) {
        return super._afterSwapInternal(router, sellToken, buyToken, minBuyAmount, snapshot);
    }
}
