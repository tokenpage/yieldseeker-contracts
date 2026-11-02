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

import {IAWKAgentWalletFactory} from "./agentwalletkit/IAWKAgentWalletFactory.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "./fees/FeeTracker.sol";
import {IYieldSeekerSwapPolicy} from "./swaps/IYieldSeekerSwapPolicy.sol";

/**
 * @title IAgentWalletFactory
 * @notice Interface for the YieldSeeker agent wallet factory
 * @dev Extends AWK factory interface with each agent profile's fee tracker and swap policy
 */
interface IAgentWalletFactory is IAWKAgentWalletFactory {
    /// @notice Get the fee tracker of an agent profile
    function feeTracker(bytes32 agentProfile) external view returns (FeeTracker);

    /// @notice Get the swap policy of an agent profile
    function swapPolicy(bytes32 agentProfile) external view returns (IYieldSeekerSwapPolicy);
}
