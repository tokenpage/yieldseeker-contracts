// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title YieldSeekerErrors
 * @notice YieldSeeker-specific error definitions
 * @dev For common errors, use AWKErrors library
 */
library YieldSeekerErrors {
    // ============ Fee Errors ============

    /// @notice Thrown when an invalid fee rate is provided
    error InvalidFeeRate();

    /// @notice Thrown when the fee tracker configuration is invalid
    error InvalidFeeTracker();

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
