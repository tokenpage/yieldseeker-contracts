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

import {YieldSeekerAgentWalletV1 as AgentWallet} from "./AgentWalletV1.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "./FeeTracker.sol";
import {AWKAgentWalletFactory} from "./agentwalletkit/AWKAgentWalletFactory.sol";
import {AWKErrors} from "./agentwalletkit/AWKErrors.sol";

/**
 * @title YieldSeekerAgentWalletFactory
 * @notice Factory for deploying YieldSeeker agent wallets with fee tracking
 * @dev Extends AWKAgentWalletFactory with YieldSeeker-specific fee tracker and baseAsset handling
 *      Note: agentWalletImplementation() returns YieldSeekerAgentWalletV1 (aliased as AgentWallet in this contract)
 *      Reuses AWKAgentWalletProxy since YieldSeekerAgentWalletFactory IS-A AWKAgentWalletFactory (inheritance)
 */
contract YieldSeekerAgentWalletFactory is AWKAgentWalletFactory {
    FeeTracker public feeTracker;

    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 indexed ownerAgentIndex, address baseAsset);

    /// @param admin Address of the AdminTimelock contract (gets admin role for dangerous operations)
    /// @param agentOperator Address that can create agent wallets (typically backend server)
    constructor(address admin, address agentOperator) AWKAgentWalletFactory(admin, agentOperator) {}

    /**
     * @notice Update the FeeTracker address for future wallet deployments
     * @param newFeeTracker The new tracker contract
     */
    function setFeeTracker(FeeTracker newFeeTracker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newFeeTracker) == address(0)) revert AWKErrors.ZeroAddress();
        if (address(newFeeTracker).code.length == 0) revert AWKErrors.NotAContract(address(newFeeTracker));
        FeeTracker oldFeeTracker = feeTracker;
        feeTracker = newFeeTracker;
        emit TrackerUpdated(address(oldFeeTracker), address(newFeeTracker));
    }

    /**
     * @notice Create a YieldSeeker AgentWallet with baseAsset support
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner (enables multiple agents per owner)
     * @param baseAsset Base asset token address for this agent (e.g., USDC)
     * @return ret The deployed AgentWallet
     */
    function createAgentWallet(address owner, uint256 ownerAgentIndex, address baseAsset) public onlyRole(AGENT_OPERATOR_ROLE) returns (AgentWallet ret) {
        if (baseAsset == address(0)) revert AWKErrors.ZeroAddress();
        if (baseAsset.code.length == 0) revert AWKErrors.NotAContract(baseAsset);
        ret = AgentWallet(payable(address(_deployWallet(owner, ownerAgentIndex))));
        ret.initialize(owner, ownerAgentIndex, baseAsset);
        emit AgentWalletCreated(address(ret), owner, ownerAgentIndex, baseAsset);
    }
}
