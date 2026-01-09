// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapter} from "./Adapter.sol";
import {AWKZeroXAdapter} from "../agentwalletkit/AWKZeroXAdapter.sol";

/**
 * @title YieldSeekerZeroXAdapter
 * @notice YieldSeeker-specific 0x adapter with fee tracking
 * @dev Extends the generic AWKZeroXAdapter and implements hooks for base asset validation and fee tracking.
 */
contract YieldSeekerZeroXAdapter is AWKZeroXAdapter, YieldSeekerAdapter {
    constructor(address allowanceTarget_) AWKZeroXAdapter(allowanceTarget_) {}

    /**
     * @notice Pre-swap hook - validate buy token is base asset
     * @dev Called before swap to ensure we're buying the correct base asset
     */
    function _preSwap(address target, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount) internal view override {
        _requireBaseAsset(buyToken);
    }

    /**
     * @notice Post-swap hook - record fee tracking
     * @dev Called after swap to record token swap for yield fee calculation
     */
    function _postSwap(address target, address sellToken, address buyToken, uint256 actualSellAmount, uint256 buyAmount) internal override {
        _feeTracker().recordAgentTokenSwap(sellToken, actualSellAmount, buyAmount);
    }
}
