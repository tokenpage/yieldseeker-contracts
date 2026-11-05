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
//  Build wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "./AgentWalletV3.sol";
import {AWKAgentWalletFactory, UnknownAgentProfile} from "./agentwalletkit/AWKAgentWalletFactory.sol";
import {AWKErrors} from "./agentwalletkit/AWKErrors.sol";
import {FeePlanChoice, YieldSeekerFeeTracker as FeeTracker} from "./fees/FeeTracker.sol";
import {IYieldSeekerSwapPolicy} from "./swaps/IYieldSeekerSwapPolicy.sol";

/**
 * @title YieldSeekerAgentWalletFactory
 * @notice Factory for deploying YieldSeeker agent wallets with fee tracking
 * @dev Extends AWKAgentWalletFactory with baseAsset handling and the YieldSeeker config of each agent profile: its fee
 *      tracker (the fee modules that apply to that agent type, and their plans) and its swap policy (the swaps its
 *      wallets may make). Together with the AWK adapter registry, these are what a wallet copies when it syncs.
 *      Note: agentWalletImplementation() returns YieldSeekerAgentWalletV3 (aliased as AgentWallet in this contract)
 *      Reuses AWKAgentWalletProxy since YieldSeekerAgentWalletFactory IS-A AWKAgentWalletFactory (inheritance)
 */
contract YieldSeekerAgentWalletFactory is AWKAgentWalletFactory {
    mapping(bytes32 agentProfile => FeeTracker) internal _agentProfileFeeTrackerMap;
    mapping(bytes32 agentProfile => IYieldSeekerSwapPolicy) internal _agentProfileSwapPolicyMap;

    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 indexed ownerAgentIndex, address baseAsset, bytes32 agentProfile);
    event FeeTrackerUpdated(bytes32 indexed agentProfile, address indexed oldFeeTracker, address indexed newFeeTracker);
    event SwapPolicyUpdated(bytes32 indexed agentProfile, address indexed oldSwapPolicy, address indexed newSwapPolicy);

    /// @param admin Address of the AdminTimelock contract (gets admin role for dangerous operations)
    /// @param emergencyAdmin Address that can remove agent operators at once (removeAgentOperator)
    /// @param agentOperator Address that can create agent wallets (typically backend server)
    constructor(address admin, address emergencyAdmin, address agentOperator) AWKAgentWalletFactory(admin, emergencyAdmin, agentOperator) {}

    /// @notice The fee tracker of an agent profile, or address(0) if it has none
    function feeTracker(bytes32 agentProfile) public view returns (FeeTracker) {
        return _agentProfileFeeTrackerMap[agentProfile];
    }

    /// @notice The swap policy of an agent profile, or address(0) if its wallets can't swap
    function swapPolicy(bytes32 agentProfile) public view returns (IYieldSeekerSwapPolicy) {
        return _agentProfileSwapPolicyMap[agentProfile];
    }

    /**
     * @notice Update the FeeTracker of an agent profile (its existing wallets pick it up on their next sync)
     * @param agentProfile The agent profile, e.g. keccak256("vault")
     * @param newFeeTracker The new tracker contract
     */
    function setFeeTracker(bytes32 agentProfile, FeeTracker newFeeTracker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (agentProfile == bytes32(0)) revert UnknownAgentProfile(agentProfile);
        if (address(newFeeTracker).code.length == 0) revert AWKErrors.NotAContract(address(newFeeTracker));
        FeeTracker oldFeeTracker = _agentProfileFeeTrackerMap[agentProfile];
        _agentProfileFeeTrackerMap[agentProfile] = newFeeTracker;
        emit FeeTrackerUpdated(agentProfile, address(oldFeeTracker), address(newFeeTracker));
    }

    /**
     * @notice Update the swap policy of an agent profile (its existing wallets pick it up on their next sync)
     * @param agentProfile The agent profile, e.g. keccak256("vault")
     * @param newSwapPolicy The new policy contract
     */
    function setSwapPolicy(bytes32 agentProfile, IYieldSeekerSwapPolicy newSwapPolicy) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (agentProfile == bytes32(0)) revert UnknownAgentProfile(agentProfile);
        if (address(newSwapPolicy).code.length == 0) revert AWKErrors.NotAContract(address(newSwapPolicy));
        IYieldSeekerSwapPolicy oldSwapPolicy = _agentProfileSwapPolicyMap[agentProfile];
        _agentProfileSwapPolicyMap[agentProfile] = newSwapPolicy;
        emit SwapPolicyUpdated(agentProfile, address(oldSwapPolicy), address(newSwapPolicy));
    }

    /**
     * @notice Create a YieldSeeker AgentWallet with baseAsset support
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner (enables multiple agents per owner)
     * @param baseAsset Base asset token address for this agent (e.g., USDC, or a borrow agent's collateral)
     * @param agentProfile The agent profile (agent type), which selects the adapter registry, fee tracker and swap policy
     * @param feePlans The wallet's plan per fee type, fixed for its life (fee types not listed use plan 0)
     * @return ret The deployed AgentWallet
     */
    function createAgentWallet(address owner, uint256 ownerAgentIndex, address baseAsset, bytes32 agentProfile, FeePlanChoice[] calldata feePlans) public onlyRole(AGENT_OPERATOR_ROLE) returns (AgentWallet ret) {
        if (baseAsset == address(0)) revert AWKErrors.ZeroAddress();
        if (baseAsset.code.length == 0) revert AWKErrors.NotAContract(baseAsset);
        ret = AgentWallet(payable(address(_deployWallet(owner, ownerAgentIndex, agentProfile))));
        ret.initialize(owner, ownerAgentIndex, baseAsset, agentProfile);
        if (feePlans.length > 0) _agentProfileFeeTrackerMap[agentProfile].initWalletPlans(address(ret), feePlans);
        emit AgentWalletCreated(address(ret), owner, ownerAgentIndex, baseAsset, agentProfile);
    }
}
