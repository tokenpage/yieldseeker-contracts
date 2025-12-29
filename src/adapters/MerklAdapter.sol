// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerErrors} from "../Errors.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title IMerklDistributor
 * @notice Minimal interface for the Merkl Distributor
 */
interface IMerklDistributor {
    function claim(address[] calldata users, address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs) external;
}

/**
 * @title YieldSeekerMerklAdapter
 * @notice Adapter for claiming rewards via Merkl
 */
contract YieldSeekerMerklAdapter is YieldSeekerAdapter {
    using SafeERC20 for IERC20;

    /**
     * @notice Override execute to properly handle dynamic array parameters
     * @dev Already running in wallet context via delegatecall from AgentWallet
     */
    function execute(address target, bytes calldata data) external payable override onlyDelegateCall returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == this.claim.selector) {
            (address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) = abi.decode(data[4:], (address[], address[], uint256[], bytes32[][]));
            _claimInternal(target, users, tokens, amounts, proofs);
            return "";
        }
        revert UnknownOperation();
    }

    // ============ Merkl Operations ============

    /**
     * @notice Claim rewards from Merkl (public interface, should not be called directly)
     * @param users Array of user addresses claiming rewards
     * @param tokens Array of token addresses to claim
     * @param amounts Array of amounts to claim per token
     * @param proofs Merkle proofs for each claim
     * @dev This is a placeholder - actual execution happens via execute() -> _claimInternal()
     */
    function claim(address[] calldata users, address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs) external pure {
        revert YieldSeekerErrors.DirectCallForbidden();
    }

    /**
     * @notice Internal claim implementation
     * @dev Runs in wallet context via delegatecall.
     *      Uses a bitmap-based deduplication to prevent O(n²) gas costs.
     */
    function _claimInternal(address distributor, address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) internal {
        uint256 tokensLength = tokens.length;
        // Use a bitmap to track which indices represent unique tokens (first occurrence)
        // This avoids O(n²) nested loops for deduplication
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
        // Capture balances before claim for unique tokens only
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
        // Execute claim (Merkl handles original tokens array with potential duplicates)
        IMerklDistributor(distributor).claim(users, tokens, amounts, proofs);
        // Record yield for unique tokens only
        address baseAsset = _baseAssetAddress();
        for (uint256 i = 0; i < uniqueCount; i++) {
            uint256 balanceAfter = IERC20(uniqueTokens[i]).balanceOf(address(this));
            uint256 claimed = balanceAfter - balancesBefore[i];
            if (claimed > 0) {
                if (uniqueTokens[i] == baseAsset) {
                    _feeTracker().recordAgentYieldEarned(claimed);
                } else {
                    _feeTracker().recordAgentYieldTokenEarned(uniqueTokens[i], claimed);
                }
            }
        }
    }
}
