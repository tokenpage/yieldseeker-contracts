// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKZeroXAdapter} from "../agentwalletkit/adapters/AWKZeroXAdapter.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";

/**
 * @title YieldSeekerZeroXAdapter
 * @notice YieldSeeker-specific 0x adapter with fee tracking
 * @dev Extends the generic AWKZeroXAdapter and implements hooks for base asset validation and fee tracking.
 */
contract YieldSeekerZeroXAdapter is AWKZeroXAdapter, YieldSeekerAdapter {
    constructor(address allowanceTarget_) AWKZeroXAdapter(allowanceTarget_) {}

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
