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

import {YieldSeekerAgentWalletV3 as AgentWallet} from "./AgentWalletV3.sol";
import {AWKAgentWalletFactory} from "./agentwalletkit/AWKAgentWalletFactory.sol";
import {AWKErrors} from "./agentwalletkit/AWKErrors.sol";
import {FeePlanChoice, YieldSeekerFeeTracker as FeeTracker} from "./fees/FeeTracker.sol";
import {IYieldSeekerSwapPolicy} from "./swaps/IYieldSeekerSwapPolicy.sol";

/**
 * @title YieldSeekerAgentWalletFactory
 * @notice Factory for deploying YieldSeeker agent wallets with fee tracking
 * @dev Extends AWKAgentWalletFactory with YieldSeeker-specific fee tracker, baseAsset handling and a swap policy per
 *      agent profile (the swap rules of that agent type, read by the swap adapters at every swap).
 *      Note: agentWalletImplementation() returns YieldSeekerAgentWalletV3 (aliased as AgentWallet in this contract)
 *      Reuses AWKAgentWalletProxy since YieldSeekerAgentWalletFactory IS-A AWKAgentWalletFactory (inheritance)
 */
contract YieldSeekerAgentWalletFactory is AWKAgentWalletFactory {
    FeeTracker public feeTracker;
    mapping(bytes32 agentProfile => IYieldSeekerSwapPolicy) internal _agentProfileSwapPolicyMap;

    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 indexed ownerAgentIndex, address baseAsset, bytes32 agentProfile);
    event SwapPolicyUpdated(bytes32 indexed agentProfile, address indexed swapPolicy);

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

    /// @notice The swap rules of an agent profile's wallets (address(0): its wallets can't swap)
    function swapPolicy(bytes32 agentProfile) external view returns (IYieldSeekerSwapPolicy) {
        return _agentProfileSwapPolicyMap[agentProfile];
    }

    /// @notice Set or replace an agent profile's swap rules; takes effect at its wallets' next swap
    function setSwapPolicy(bytes32 agentProfile, IYieldSeekerSwapPolicy newSwapPolicy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newSwapPolicy).code.length == 0) revert AWKErrors.NotAContract(address(newSwapPolicy));
        _agentProfileSwapPolicyMap[agentProfile] = newSwapPolicy;
        emit SwapPolicyUpdated(agentProfile, address(newSwapPolicy));
    }

    /**
     * @notice Create a YieldSeeker AgentWallet with baseAsset support
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner (enables multiple agents per owner)
     * @param baseAsset Base asset token address for this agent (e.g., USDC, or a borrow agent's collateral)
     * @param agentProfile The agent profile (agent type), which selects the adapter registry
     * @param feePlans The wallet's plan per fee type, fixed for its life (fee types not listed use plan 0)
     * @return ret The deployed AgentWallet
     */
    function createAgentWallet(address owner, uint256 ownerAgentIndex, address baseAsset, bytes32 agentProfile, FeePlanChoice[] calldata feePlans) public onlyRole(AGENT_OPERATOR_ROLE) returns (AgentWallet ret) {
        if (baseAsset == address(0)) revert AWKErrors.ZeroAddress();
        if (baseAsset.code.length == 0) revert AWKErrors.NotAContract(baseAsset);
        ret = AgentWallet(payable(address(_deployWallet(owner, ownerAgentIndex, agentProfile))));
        ret.initialize(owner, ownerAgentIndex, baseAsset, agentProfile);
        if (feePlans.length > 0) feeTracker.initWalletPlans(address(ret), feePlans);
        emit AgentWalletCreated(address(ret), owner, ownerAgentIndex, baseAsset, agentProfile);
    }
}
