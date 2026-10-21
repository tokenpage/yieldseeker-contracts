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
import {AWKAgentWalletFactoryV2, UnknownProfile} from "./agentwalletkit/AWKAgentWalletFactoryV2.sol";
import {AWKErrors} from "./agentwalletkit/AWKErrors.sol";
import {IYieldSeekerFeeModule} from "./fees/IYieldSeekerFeeModule.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @title YieldSeekerAgentWalletFactoryV2
 * @notice YieldSeekerAgentWalletFactory with profiles: each profile (agent type) has its own adapter registry and fee contract
 * @dev feeTracker() answers for the calling wallet's profile. V3 wallets copy it once at creation and never re-read it,
 *      so changing a profile's fee contract only affects wallets created afterwards.
 */
contract YieldSeekerAgentWalletFactoryV2 is AWKAgentWalletFactoryV2 {
    mapping(bytes32 profile => FeeTracker) public profileFeeTracker;

    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 indexed ownerAgentIndex, address baseAsset, bytes32 profile);
    event ProfileTrackerUpdated(bytes32 indexed profile, address indexed oldTracker, address indexed newTracker);

    /// @param admin Address of the AdminTimelock contract (gets admin role for dangerous operations)
    /// @param agentOperator Address that can create agent wallets (typically backend server)
    constructor(address admin, address agentOperator) AWKAgentWalletFactoryV2(admin, agentOperator) {}

    /**
     * @notice Set the fee contract new wallets of a profile are created with (it must implement IYieldSeekerFeeModule)
     * @param profile The profile, e.g. keccak256("borrow")
     * @param newFeeTracker The new fee contract
     */
    function setProfileFeeTracker(bytes32 profile, FeeTracker newFeeTracker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (profile == bytes32(0)) revert UnknownProfile(profile);
        if (address(newFeeTracker) == address(0)) revert AWKErrors.ZeroAddress();
        if (address(newFeeTracker).code.length == 0) revert AWKErrors.NotAContract(address(newFeeTracker));
        if (!IERC165(address(newFeeTracker)).supportsInterface(type(IYieldSeekerFeeModule).interfaceId)) revert InvalidFeeTracker();
        FeeTracker oldFeeTracker = profileFeeTracker[profile];
        profileFeeTracker[profile] = newFeeTracker;
        emit ProfileTrackerUpdated(profile, address(oldFeeTracker), address(newFeeTracker));
    }

    /**
     * @notice The fee contract of the calling wallet's profile (what wallets read when they are created)
     */
    function feeTracker() external view returns (FeeTracker) {
        return profileFeeTracker[walletProfile[msg.sender]];
    }

    /**
     * @notice Create a YieldSeeker AgentWallet with baseAsset support
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner (enables multiple agents per owner)
     * @param baseAsset Base asset token address for this agent (e.g., USDC, or a borrow agent's collateral)
     * @param profile The agent type profile
     * @return ret The deployed AgentWallet
     */
    function createAgentWallet(address owner, uint256 ownerAgentIndex, address baseAsset, bytes32 profile) public onlyRole(AGENT_OPERATOR_ROLE) returns (AgentWallet ret) {
        if (baseAsset == address(0)) revert AWKErrors.ZeroAddress();
        if (baseAsset.code.length == 0) revert AWKErrors.NotAContract(baseAsset);
        if (address(profileFeeTracker[profile]) == address(0)) revert UnknownProfile(profile);
        ret = AgentWallet(payable(address(_deployWallet(owner, ownerAgentIndex, profile))));
        ret.initialize(owner, ownerAgentIndex, baseAsset);
        emit AgentWalletCreated(address(ret), owner, ownerAgentIndex, baseAsset, profile);
    }
}
