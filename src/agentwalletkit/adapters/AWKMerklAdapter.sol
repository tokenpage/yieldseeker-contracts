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
//  https://agentwalletkit.com
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.38;

import {AWKAdapter} from "../AWKAdapter.sol";
import {IMerklDistributor} from "vendored-interfaces/IMerklDistributor.sol";

/**
 * @title AWKMerklAdapter
 * @notice Generic adapter for claiming the wallet's own rewards via Merkl. The distributor is the target of the execute
 *         call.
 * @dev claim calls the operation (_claimOperation), which subclasses override to add rules; the operation calls
 *      the protocol implementation (_claim).
 */
contract AWKMerklAdapter is AWKAdapter {
    function claim(address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs) external onlyExecute {
        _claimOperation(_target(), tokens, amounts, proofs);
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
