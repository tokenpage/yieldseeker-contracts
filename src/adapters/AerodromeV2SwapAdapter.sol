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

import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {AWKAerodromeV2SwapAdapter} from "../agentwalletkit/adapters/AWKAerodromeV2SwapAdapter.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IYieldSeekerSwapSellPolicy} from "./SwapSellPolicy.sol";

contract YieldSeekerAerodromeV2SwapAdapter is AWKAerodromeV2SwapAdapter, YieldSeekerAdapter {
    address public immutable SELL_POLICY;

    constructor(address aerodromeV2Router, address aerodromeV2Factory, address sellPolicy) AWKAerodromeV2SwapAdapter(aerodromeV2Router, aerodromeV2Factory) {
        if (sellPolicy == address(0)) revert AWKErrors.ZeroAddress();
        SELL_POLICY = sellPolicy;
    }

    function _beforeSwap(address sellToken, address buyToken) internal view override {
        IYieldSeekerSwapSellPolicy(SELL_POLICY).validateSellableToken(sellToken);
        _requireNotBaseAsset(sellToken);
        _requireBaseAsset(buyToken);
    }

    function _afterSwap(address sellToken, uint256 soldAmount, uint256 buyAmount) internal override {
        _feeTracker().recordAgentTokenSwap(sellToken, soldAmount, buyAmount);
    }
}
