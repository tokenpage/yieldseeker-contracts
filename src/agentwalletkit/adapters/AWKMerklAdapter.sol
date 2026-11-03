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
 * @notice Generic adapter for claiming rewards via Merkl
 * @dev execute calls the operation (_claimOperation), which subclasses override to add rules; the operation calls
 *      the protocol implementation (_claim).
 */
contract AWKMerklAdapter is AWKAdapter {
    using SafeERC20 for IERC20;

    function execute(address target, bytes calldata data) external payable virtual override onlyDelegateCall returns (bytes memory) {
        if (bytes4(data[:4]) != this.claim.selector) revert UnknownOperation();
        (address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) = abi.decode(data[4:], (address[], address[], uint256[], bytes32[][]));
        _claimOperation(target, users, tokens, amounts, proofs);
        return "";
    }

    /**
     * @notice Claim rewards from Merkl (public interface, should not be called directly)
     * @dev Only used for selector generation
     */
    function claim(address[] calldata users, address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata proofs) external pure {
        revert AWKErrors.DirectCallForbidden();
    }

    // ============ Operations (override to add rules) ============

    function _claimOperation(address distributor, address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) internal virtual {
        _claim(distributor, users, tokens, amounts, proofs);
    }

    // ============ Protocol Implementation ============

    function _claim(address distributor, address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) internal virtual {
        IMerklDistributor(distributor).claim(users, tokens, amounts, proofs);
    }
}
