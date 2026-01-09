// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapter} from "./Adapter.sol";
import {AWKMerklAdapter} from "../agentwalletkit/AWKMerklAdapter.sol";

/**
 * @title YieldSeekerMerklAdapter
 * @notice YieldSeeker-specific Merkl adapter with fee tracking
 * @dev Extends the generic AWKMerklAdapter and implements post hooks for fee tracking on claimed rewards.
 */
contract YieldSeekerMerklAdapter is AWKMerklAdapter, YieldSeekerAdapter {
    /**
     * @notice Post-claim hook for each token - record fee tracking
     * @dev Called after each unique token is claimed to record yield earned
     */
    function _postClaimToken(address distributor, address token, uint256 amountClaimed) internal override {
        address baseAsset = _baseAssetAddress();
        if (token == baseAsset) {
            _feeTracker().recordAgentYieldEarned(amountClaimed);
        } else {
            _feeTracker().recordAgentYieldTokenEarned(token, amountClaimed);
        }
    }
}

