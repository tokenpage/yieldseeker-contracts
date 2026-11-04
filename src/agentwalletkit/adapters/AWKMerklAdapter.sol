// SPDX-License-Identifier: MIT
//
//      _                    _ __        __    _ _      _   _  ___ _
//     / \   __ _  ___ _ __ | |\ \      / /_ _| | | ___| |_| |/ (_) |_
//    / _ \ / _` |/ _ \ '_ \| __\ \ /\ / / _` | | |/ _ \ __| ' /| | __|
//   / ___ \ (_| |  __/ | | | |_ \ V  V / (_| | | |  __/ |_| . \| | |_
//  /_/   \_\__, |\___|_| |_|\__| \_/\_/ \__,_|_|_|\___|\__|_|\_\_|\__|
//          |___/
//
//  Build verifiably secure onchain agents
//  https://agentwalletkit.tokenpage.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKAdapter, UnknownOperation} from "../AWKAdapter.sol";
import {AWKErrors} from "../AWKErrors.sol";

/**
 * @title IMerklDistributor
 * @notice Minimal interface for the Merkl Distributor
 */
interface IMerklDistributor {
    function claim(address[] calldata users, address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs) external;
}

/**
 * @title AWKMerklAdapter
 * @notice Generic adapter for claiming the wallet's own rewards via Merkl
 * @dev execute calls the operation (_claimOperation), which subclasses override to add rules; the operation calls
 *      the protocol implementation (_claim).
 */
contract AWKMerklAdapter is AWKAdapter {
    function execute(address target, bytes calldata data) external payable virtual override onlyDelegateCall returns (bytes memory) {
        if (bytes4(data[:4]) != this.claim.selector) revert UnknownOperation();
        (address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) = abi.decode(data[4:], (address[], uint256[], bytes32[][]));
        _claimOperation(target, tokens, amounts, proofs);
        return "";
    }

    /**
     * @notice Claim the wallet's Merkl rewards (public interface, should not be called directly)
     * @dev Only used for selector generation
     */
    function claim(address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs) external pure {
        revert AWKErrors.DirectCallForbidden();
    }

    // ============ Operations (override to add rules) ============

    function _claimOperation(address distributor, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) internal virtual {
        _claim(distributor, tokens, amounts, proofs);
    }

    // ============ Protocol Implementation ============

    /// @dev Merkl takes one user per claimed token and pays each user, so every entry is the wallet itself
    function _claim(address distributor, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) internal virtual {
        address[] memory users = new address[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            users[i] = address(this);
        }
        IMerklDistributor(distributor).claim(users, tokens, amounts, proofs);
    }
}
