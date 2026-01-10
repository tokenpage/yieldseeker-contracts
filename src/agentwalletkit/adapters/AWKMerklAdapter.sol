// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKAdapter, UnknownOperation} from "../AWKAdapter.sol";
import {AWKErrors} from "../AWKErrors.sol";
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
 * @title AWKMerklAdapter
 * @notice Generic adapter for claiming rewards via Merkl with pre/post hooks
 * @dev Subclasses can override hooks to add custom logic (e.g., fee tracking).
 */
contract AWKMerklAdapter is AWKAdapter {
    using SafeERC20 for IERC20;

    /**
     * @notice Override execute to properly handle dynamic array parameters
     * @dev Already running in wallet context via delegatecall from AgentWallet
     */
    function execute(address target, bytes calldata data) external payable virtual override onlyDelegateCall returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == this.claim.selector) {
            (address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) = abi.decode(data[4:], (address[], address[], uint256[], bytes32[][]));
            _claimInternal(target, users, tokens, amounts, proofs);
            return "";
        }
        revert UnknownOperation();
    }

    /**
     * @notice Claim rewards from Merkl (public interface, should not be called directly)
     * @dev Only used for selector generation
     */
    function claim(address[] calldata users, address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs) external pure {
        revert AWKErrors.DirectCallForbidden();
    }

    /**
     * @notice Internal claim implementation
     * @dev Runs in wallet context via delegatecall.
     */
    function _claimInternal(address distributor, address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) internal virtual {
        IMerklDistributor(distributor).claim(users, tokens, amounts, proofs);
    }
}
