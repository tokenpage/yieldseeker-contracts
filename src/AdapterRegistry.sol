// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKAdapterRegistry} from "./agentwalletkit/AWKAdapterRegistry.sol";

/**
 * @title YieldSeekerAdapterRegistry
 * @notice YieldSeeker adapter registry - inherits all functionality from AWK
 * @dev This is just an alias/wrapper for AWKAdapterRegistry to maintain naming consistency
 */
contract YieldSeekerAdapterRegistry is AWKAdapterRegistry {
    /// @param admin Address of the admin (gets admin roles for dangerous operations)
    /// @param emergencyAdmin Address that can perform emergency operations (pause, remove targets)
    constructor(address admin, address emergencyAdmin) AWKAdapterRegistry(admin, emergencyAdmin) {}
}
