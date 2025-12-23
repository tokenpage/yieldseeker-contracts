// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title YieldSeekerErrors
 * @notice Centralized error definitions for the YieldSeeker protocol
 * @dev Using a shared library reduces code duplication and ensures consistency
 */
library YieldSeekerErrors {
    // ============ Address Validation Errors ============

    /// @notice Thrown when a zero address is provided where not allowed
    error ZeroAddress();

    /// @notice Thrown when an invalid address is provided
    error InvalidAddress();

    /// @notice Thrown when an address is expected to be a contract but isn't
    /// @param addr The address that is not a contract
    error NotAContract(address addr);

    // ============ Amount Validation Errors ============

    /// @notice Thrown when a zero amount is provided where not allowed
    error ZeroAmount();

    /// @notice Thrown when an insufficient balance exists for an operation
    error InsufficientBalance();

    /// @notice Thrown when a percentage value is invalid
    /// @param percentage The invalid percentage value
    error InvalidPercentage(uint256 percentage);

    // ============ Authorization Errors ============

    /// @notice Thrown when caller is not authorized for an operation
    /// @param caller The unauthorized caller address
    error Unauthorized(address caller);

    /// @notice Thrown when an operation is not allowed
    error NotAllowed();

    /// @notice Thrown when a direct function call is forbidden (use execute instead)
    error DirectCallForbidden();

    // ============ State Errors ============

    /// @notice Thrown when an operation is attempted in an invalid state
    error InvalidState();

    // ============ Adapter Registry Errors ============

    /// @notice Thrown when an adapter is not registered
    /// @param adapter The unregistered adapter address
    error AdapterNotRegistered(address adapter);

    /// @notice Thrown when a target is not registered
    /// @param target The unregistered target address
    error TargetNotRegistered(address target);
}
