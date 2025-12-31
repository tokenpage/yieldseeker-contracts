// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker as FeeTracker} from "./FeeTracker.sol";
import {IAWKAgentWallet} from "./agentwalletkit/IAWKAgentWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title IAgentWallet
 * @notice Interface for YieldSeeker agent wallets
 * @dev Extends AWK interface with YieldSeeker-specific fee tracking and base asset methods
 */
interface IAgentWallet is IAWKAgentWallet {
    /// @notice Get the base asset token for this wallet
    function baseAsset() external view returns (IERC20);

    /// @notice Get the fee tracker contract
    function feeTracker() external view returns (FeeTracker);
}
