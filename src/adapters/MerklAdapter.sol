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
     */
    function claim(address[] calldata users, address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs) external pure {
        revert YieldSeekerErrors.DirectCallForbidden();
    }

    /**
     * @notice Internal claim implementation
     * @dev Runs in wallet context via delegatecall
     */
    function _claimInternal(address distributor, address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) internal {
        uint256[] memory balancesBefore = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balancesBefore[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
        IMerklDistributor(distributor).claim(users, tokens, amounts, proofs);
        address baseAsset = _baseAssetAddress();
        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balanceAfter = IERC20(tokens[i]).balanceOf(address(this));
            uint256 claimed = balanceAfter - balancesBefore[i];
            if (claimed > 0) {
                if (tokens[i] == baseAsset) {
                    _feeTracker().recordAgentYieldEarned(claimed);
                } else {
                    _feeTracker().recordAgentYieldTokenEarned(tokens[i], claimed);
                }
            }
        }
    }
}
