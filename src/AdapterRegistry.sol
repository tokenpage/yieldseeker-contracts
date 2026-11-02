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

import {AWKAdapterRegistry} from "./agentwalletkit/AWKAdapterRegistry.sol";
import {AWKErrors} from "./agentwalletkit/AWKErrors.sol";
import {IYieldSeekerSwapPolicy} from "./swaps/IYieldSeekerSwapPolicy.sol";

/**
 * @title YieldSeekerAdapterRegistry
 * @notice YieldSeeker adapter registry: AWK's adapters and targets, plus the swap rules of its agent type
 * @dev Each agent profile has its own registry, so the swap policy here is that agent type's. Swap adapters read it
 *      at every swap, so replacing it applies to every wallet of the type at its next swap.
 */
contract YieldSeekerAdapterRegistry is AWKAdapterRegistry {
    /// @notice The swap rules of this registry's wallets (address(0): they can't swap)
    IYieldSeekerSwapPolicy public swapPolicy;

    event SwapPolicyUpdated(address indexed swapPolicy);

    /// @param admin Address of the admin (gets admin roles for dangerous operations)
    /// @param emergencyAdmin Address that can perform emergency operations (pause, remove targets)
    constructor(address admin, address emergencyAdmin) AWKAdapterRegistry(admin, emergencyAdmin) {}

    function setSwapPolicy(IYieldSeekerSwapPolicy newSwapPolicy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newSwapPolicy).code.length == 0) revert AWKErrors.NotAContract(address(newSwapPolicy));
        swapPolicy = newSwapPolicy;
        emit SwapPolicyUpdated(address(newSwapPolicy));
    }
}
