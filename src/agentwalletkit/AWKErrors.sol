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

/**
 * @title AWKErrors
 * @notice Centralized error definitions for the AgentWalletKit protocol
 * @dev Errors used across multiple contracts. Contract-specific errors should be defined in their respective files.
 */
library AWKErrors {
    // ============ Address Validation Errors ============

    /// @notice Thrown when a zero address is provided where not allowed
    error ZeroAddress();

    /// @notice Thrown when an address is expected to be a contract but isn't
    /// @param addr The address that is not a contract
    error NotAContract(address addr);

    // ============ Amount Validation Errors ============

    /// @notice Thrown when a zero amount is provided where not allowed
    error ZeroAmount();

    /// @notice Thrown when an insufficient balance exists for an operation
    error InsufficientBalance();

    // ============ Authorization Errors ============

    /// @notice Thrown when caller is not authorized for an operation
    /// @param caller The unauthorized caller address
    error Unauthorized(address caller);

    /// @notice Thrown when a direct function call is forbidden (use execute instead)
    error DirectCallForbidden();

    // ============ Adapter Registry Errors ============

    /// @notice Thrown when an adapter is not registered
    /// @param adapter The unregistered adapter address
    error AdapterNotRegistered(address adapter);
}
