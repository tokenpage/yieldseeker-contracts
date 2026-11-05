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
pragma solidity 0.8.38;

import {AWKAerodromeCLSwapAdapter} from "../agentwalletkit/adapters/AWKAerodromeCLSwapAdapter.sol";
import {AWKSwapAdapter} from "../agentwalletkit/adapters/AWKSwapAdapter.sol";
import {YieldSeekerSwapAdapter} from "./SwapAdapter.sol";

contract YieldSeekerAerodromeCLSwapAdapter is AWKAerodromeCLSwapAdapter, YieldSeekerSwapAdapter {
    constructor(address aerodromeClRouter) AWKAerodromeCLSwapAdapter(aerodromeClRouter) {}

    function _swapOperation(address router, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, bytes memory route) internal override(AWKSwapAdapter, YieldSeekerSwapAdapter) returns (uint256, uint256) {
        return super._swapOperation(router, sellToken, buyToken, sellAmount, minBuyAmount, route);
    }
}
