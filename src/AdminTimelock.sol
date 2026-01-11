// SPDX-License-Identifier: MIT
//
//   /$$     /$$ /$$           /$$       /$$  /$$$$$$                      /$$
//  |  $$   /$$/|__/          | $$      | $$ /$$__  $$                    | $$
//   \  $$ /$$/  /$$  /$$$$$$ | $$  /$$$$$$$| $$  \__/  /$$$$$$   /$$$$$$ | $$   /$$  /$$$$$$   /$$$$$$
//    \  $$$$/  | $$ /$$__  $$| $$ /$$__  $$|  $$$$$$  /$$__  $$ /$$__  $$| $$  /$$/ /$$__  $$ /$$__  $$
//     \  $$/   | $$| $$$$$$$$| $$| $$  | $$ \____  $$| $$$$$$$$| $$$$$$$$| $$$$$$/ | $$$$$$$$| $$  \__/
//      | $$    | $$| $$_____/| $$| $$  | $$ /$$  \ $$| $$_____/| $$_____/| $$_  $$ | $$_____/| $$
//      | $$    | $$|  $$$$$$$| $$|  $$$$$$$|  $$$$$$/|  $$$$$$$|  $$$$$$$| $$ \  $$|  $$$$$$$| $$
//      |__/    |__/ \_______/|__/ \_______/ \______/  \_______/ \_______/|__/  \__/ \_______/|__/
//
//  Grow your wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title YieldSeekerAdminTimelock
/// @notice TimelockController for YieldSeeker admin operations with configurable delay
/// @dev All security-critical operations must go through this timelock.
///      Emergency removals bypass the timelock via EMERGENCY_ROLE on individual contracts.
contract YieldSeekerAdminTimelock is TimelockController {
    /// @dev Pass minDelay=0 for testing with immediate execution, any other value for custom delay
    /// @param minDelay Delay in seconds (0 for testing with no delay)
    /// @param proposers Addresses that can schedule operations (typically a multisig)
    /// @param executors Addresses that can execute ready operations (can be same as proposers or address(0) for anyone)
    /// @param admin Optional admin that can grant/revoke roles. Use address(0) for self-administered timelock.
    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin) TimelockController(minDelay, proposers, executors, admin) {}
}
