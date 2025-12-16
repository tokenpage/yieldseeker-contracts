// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title YieldSeekerAdminTimelock
/// @notice TimelockController for YieldSeeker admin operations with configurable delay
/// @dev All security-critical operations must go through this timelock.
///      Emergency removals bypass the timelock via EMERGENCY_ROLE on individual contracts.
contract YieldSeekerAdminTimelock is TimelockController {
    // NOTE(krishan711): change this before real deployment
    uint256 public constant DEFAULT_MIN_DELAY = 1 hours;

    /// @notice Deploy the admin timelock with optional custom delay (for testing)
    /// @dev Pass minDelay=0 for testing with immediate execution, any other value for custom delay
    /// @param minDelay Delay in seconds (0 for testing with no delay)
    /// @param proposers Addresses that can schedule operations (typically a multisig)
    /// @param executors Addresses that can execute ready operations (can be same as proposers or address(0) for anyone)
    /// @param admin Optional admin that can grant/revoke roles. Use address(0) for self-administered timelock.
    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin
    )
        TimelockController(minDelay, proposers, executors, admin)
    {}
}
