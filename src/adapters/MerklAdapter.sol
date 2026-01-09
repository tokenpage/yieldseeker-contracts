// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKMerklAdapter} from "../agentwalletkit/adapters/AWKMerklAdapter.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title YieldSeekerMerklAdapter
 * @notice YieldSeeker-specific Merkl adapter with fee tracking
 * @dev Extends the generic AWKMerklAdapter to add fee tracking
 */
contract YieldSeekerMerklAdapter is AWKMerklAdapter, YieldSeekerAdapter {
    /**
     * @notice Internal claim implementation with fee tracking
     * @dev Overrides AWK logic to track yield earned
     */
    function _claimInternal(address distributor, address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) internal override {
        // 1. Deduplicate tokens to find unique ones to track
        uint256 tokensLength = tokens.length;
        uint256 uniqueCount = 0;
        bool[] memory isFirstOccurrence = new bool[](tokensLength);

        for (uint256 i = 0; i < tokensLength; i++) {
            bool isDuplicate = false;
            for (uint256 j = 0; j < i; j++) {
                if (tokens[i] == tokens[j]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                isFirstOccurrence[i] = true;
                uniqueCount++;
            }
        }

        // 2. Snapshot balances
        uint256[] memory balancesBefore = new uint256[](uniqueCount);
        address[] memory uniqueTokens = new address[](uniqueCount);
        uint256 uniqueIndex = 0;
        for (uint256 i = 0; i < tokensLength; i++) {
            if (isFirstOccurrence[i]) {
                uniqueTokens[uniqueIndex] = tokens[i];
                balancesBefore[uniqueIndex] = IERC20(tokens[i]).balanceOf(address(this));
                uniqueIndex++;
            }
        }

        // 3. Call super to execute claim
        super._claimInternal(distributor, users, tokens, amounts, proofs);

        // 4. Check balances and record fees
        address baseAsset = _baseAssetAddress();
        for (uint256 i = 0; i < uniqueCount; i++) {
            address token = uniqueTokens[i];
            uint256 balanceAfter = IERC20(token).balanceOf(address(this));
            uint256 claimed = balanceAfter - balancesBefore[i];

            if (claimed > 0) {
                if (token == baseAsset) {
                    _feeTracker().recordAgentYieldEarned(claimed);
                } else {
                    _feeTracker().recordAgentYieldTokenEarned(token, claimed);
                }
            }
        }
    }
}
