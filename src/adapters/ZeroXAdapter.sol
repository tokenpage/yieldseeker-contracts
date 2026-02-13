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

import {AWKZeroXAdapter} from "../agentwalletkit/adapters/AWKZeroXAdapter.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";

/**
 * @title YieldSeekerZeroXAdapter
 * @notice YieldSeeker-specific 0x adapter with fee tracking
 * @dev Extends the generic AWKZeroXAdapter and implements hooks for base asset validation and fee tracking.
 */
contract YieldSeekerZeroXAdapter is AWKZeroXAdapter, YieldSeekerAdapter {
    constructor(address allowanceTarget_, address admin_, address emergencyAdmin_, bool allowAllTokens_) AWKZeroXAdapter(allowanceTarget_, admin_, emergencyAdmin_, allowAllTokens_) {}

    /**
     * @notice Internal swap implementation with validation and fee tracking
     * @dev Overrides AWK logic to add pre-check and post-fee-tracking
     */
    function _swapInternal(address target, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, bytes memory swapCallData, uint256 value) internal override returns (uint256 buyAmount, uint256 soldAmount) {
        _requireBaseAsset(buyToken);
        (buyAmount, soldAmount) = super._swapInternal(target, sellToken, buyToken, sellAmount, minBuyAmount, swapCallData, value);
        _feeTracker().recordAgentTokenSwap(sellToken, soldAmount, buyAmount);
    }
}
