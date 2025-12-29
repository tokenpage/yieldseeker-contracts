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

    // ============ User Blocklist Errors ============

    /// @notice Thrown when an adapter is blocked by the wallet owner
    /// @param adapter The blocked adapter address
    error AdapterBlocked(address adapter);

    /// @notice Thrown when a target is blocked by the wallet owner
    /// @param target The blocked target address
    error TargetBlocked(address target);

    // ============ Wallet Errors ============

    /// @notice Thrown when an adapter execution fails
    /// @param reason The revert reason from the adapter
    error AdapterExecutionFailed(bytes reason);

    /// @notice Thrown when an ETH transfer fails
    error TransferFailed();

    /// @notice Thrown when trying to upgrade to a non-approved implementation
    error NotApprovedImplementation();

    /// @notice Thrown when the registry configuration is invalid
    error InvalidRegistry();

    /// @notice Thrown when the fee tracker configuration is invalid
    error InvalidFeeTracker();

    // ============ Factory Errors ============

    /// @notice Thrown when an agent already exists for owner/index combination
    /// @param owner The owner address
    /// @param ownerAgentIndex The agent index
    error AgentAlreadyExists(address owner, uint256 ownerAgentIndex);

    /// @notice Thrown when no wallet implementation has been set
    error NoAgentWalletImplementationSet();

    /// @notice Thrown when no adapter registry has been set
    error NoAdapterRegistrySet();

    /// @notice Thrown when the implementation has wrong factory
    error InvalidImplementationFactory();

    /// @notice Thrown when trying to add too many operators
    error TooManyOperators();

    // ============ Fee Errors ============

    /// @notice Thrown when an invalid fee rate is provided
    error InvalidFeeRate();

    // ============ Swap Errors ============

    /// @notice Thrown when the allowance target is invalid
    error InvalidAllowanceTarget();

    /// @notice Thrown when a swap operation fails
    /// @param reason The revert reason from the swap
    error SwapFailed(bytes reason);

    /// @notice Thrown when swap output is below minimum
    /// @param received The amount received
    /// @param minExpected The minimum expected amount
    error InsufficientOutput(uint256 received, uint256 minExpected);

    /// @notice Thrown when insufficient ETH for swap
    /// @param have The available ETH balance
    /// @param need The required ETH amount
    error InsufficientEth(uint256 have, uint256 need);
}
