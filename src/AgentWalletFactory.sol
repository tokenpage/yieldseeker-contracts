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

import {InvalidFeeTracker} from "./AgentWalletV1.sol";
import {YieldSeekerAgentWalletV3 as AgentWallet} from "./AgentWalletV3.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "./FeeTracker.sol";
import {AWKAgentWalletFactory} from "./agentwalletkit/AWKAgentWalletFactory.sol";
import {AWKErrors} from "./agentwalletkit/AWKErrors.sol";
import {IYieldSeekerFeeModuleHost} from "./fees/IYieldSeekerFeeModule.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title YieldSeekerAgentWalletFactory
 * @notice Factory for deploying YieldSeeker agent wallets with fee tracking
 * @dev Extends AWKAgentWalletFactory with YieldSeeker-specific fee tracker and baseAsset handling
 *      Note: agentWalletImplementation() returns YieldSeekerAgentWalletV3 (aliased as AgentWallet in this contract)
 *      Reuses AWKAgentWalletProxy since YieldSeekerAgentWalletFactory IS-A AWKAgentWalletFactory (inheritance)
 */
contract YieldSeekerAgentWalletFactory is AWKAgentWalletFactory {
    FeeTracker public feeTracker;

    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 indexed ownerAgentIndex, address baseAsset, bytes32 profile);

    /// @param admin Address of the AdminTimelock contract (gets admin role for dangerous operations)
    /// @param agentOperator Address that can create agent wallets (typically backend server)
    constructor(address admin, address agentOperator) AWKAgentWalletFactory(admin, agentOperator) {}

    /**
     * @notice Update the FeeTracker address for future wallet deployments
     * @dev V3 wallets pin the tracker they are created with, so it must support fee modules (withdrawReserve())
     * @param newFeeTracker The new tracker contract
     */
    function setFeeTracker(FeeTracker newFeeTracker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newFeeTracker) == address(0)) revert AWKErrors.ZeroAddress();
        if (address(newFeeTracker).code.length == 0) revert AWKErrors.NotAContract(address(newFeeTracker));
        if (!IERC165(address(newFeeTracker)).supportsInterface(type(IYieldSeekerFeeModuleHost).interfaceId)) revert InvalidFeeTracker();
        FeeTracker oldFeeTracker = feeTracker;
        feeTracker = newFeeTracker;
        emit TrackerUpdated(address(oldFeeTracker), address(newFeeTracker));
    }

    /**
     * @notice Create a YieldSeeker AgentWallet with baseAsset support
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner (enables multiple agents per owner)
     * @param baseAsset Base asset token address for this agent (e.g., USDC, or a borrow agent's collateral)
     * @param profile The agent type profile, which selects the adapter registry
     * @return ret The deployed AgentWallet
     */
    function createAgentWallet(address owner, uint256 ownerAgentIndex, address baseAsset, bytes32 profile) public onlyRole(AGENT_OPERATOR_ROLE) returns (AgentWallet ret) {
        if (baseAsset == address(0)) revert AWKErrors.ZeroAddress();
        if (baseAsset.code.length == 0) revert AWKErrors.NotAContract(baseAsset);
        ret = AgentWallet(payable(address(_deployWallet(owner, ownerAgentIndex, profile))));
        ret.initialize(owner, ownerAgentIndex, baseAsset);
        emit AgentWalletCreated(address(ret), owner, ownerAgentIndex, baseAsset, profile);
    }
}
