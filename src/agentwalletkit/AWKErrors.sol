// SPDX-License-Identifier: MIT
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
