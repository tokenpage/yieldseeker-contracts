// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker as FeeTracker} from "./FeeTracker.sol";
import {IAWKAgentWalletFactory} from "./agentwalletkit/IAWKAgentWalletFactory.sol";

/**
 * @title IAgentWalletFactory
 * @notice Interface for the YieldSeeker agent wallet factory
 * @dev Extends AWK factory interface with YieldSeeker-specific fee tracker
 */
interface IAgentWalletFactory is IAWKAgentWalletFactory {
    /// @notice Get the fee tracker contract
    function feeTracker() external view returns (FeeTracker);
}
