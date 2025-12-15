// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title YieldSeekerAdminTimelock
/// @notice TimelockController for YieldSeeker admin operations with a 24-hour delay
/// @dev All security-critical operations (adding operators, policies, vaults) must go through this timelock.
///      Emergency removals bypass the timelock via EMERGENCY_ROLE on individual contracts.
contract YieldSeekerAdminTimelock is TimelockController {
    uint256 public constant DEFAULT_MIN_DELAY = 24 hours;

    /// @notice Deploy the admin timelock
    /// @param proposers Addresses that can schedule operations (typically a multisig)
    /// @param executors Addresses that can execute ready operations (can be same as proposers or address(0) for anyone)
    /// @param admin Optional admin that can grant/revoke roles. Use address(0) for self-administered timelock.
    constructor(
        address[] memory proposers,
        address[] memory executors,
        address admin
    )
        TimelockController(DEFAULT_MIN_DELAY, proposers, executors, admin)
    {}
}
