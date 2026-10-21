// SPDX-License-Identifier: MIT
//
//      _                    _ __        __    _ _      _   _  ___ _
//     / \   __ _  ___ _ __ | |\ \      / /_ _| | | ___| |_| |/ (_) |_
//    / _ \ / _` |/ _ \ '_ \| __\ \ /\ / / _` | | |/ _ \ __| ' /| | __|
//   / ___ \ (_| |  __/ | | | |_ \ V  V / (_| | | |  __/ |_| . \| | |_
//  /_/   \_\__, |\___|_| |_|\__| \_/\_/ \__,_|_|_|\___|\__|_|\_\_|\__|
//          |___/
//
//  Build verifiably secure onchain agents
//  https://agentwalletkit.tokenpage.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKAdapterRegistry as AdapterRegistry} from "./AWKAdapterRegistry.sol";
import {AWKAgentWalletProxy, AgentAlreadyExists, InvalidImplementationFactory, NoAgentWalletImplementationSet, TooManyOperators} from "./AWKAgentWalletFactory.sol";
import {AWKAgentWalletV2 as AgentWallet} from "./AWKAgentWalletV2.sol";
import {AWKErrors} from "./AWKErrors.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

error UnknownProfile(bytes32 profile);

/**
 * @title AWKAgentWalletFactoryV2
 * @notice AWKAgentWalletFactory where each wallet has a profile (e.g. an agent type) with its own adapter registry
 * @dev Same deployment, implementation and operator logic as AWKAgentWalletFactory. The difference: the factory
 *      records each wallet's profile, and adapterRegistry() answers for the calling wallet's profile, so wallets
 *      sync with the unchanged V2 code. Callers that are not wallets of this factory get address(0).
 *      Subclasses must call _deployWallet() and initialize() atomically.
 */
abstract contract AWKAgentWalletFactoryV2 is AccessControlEnumerable {
    bytes32 public constant AGENT_OPERATOR_ROLE = keccak256("AGENT_OPERATOR_ROLE");
    uint256 public constant MAX_OPERATORS = 10;

    AgentWallet internal _agentWalletImplementation;

    mapping(bytes32 profile => AdapterRegistry) public profileAdapterRegistry;
    mapping(address wallet => bytes32 profile) public walletProfile;
    mapping(address => mapping(uint256 => address)) public userWallets;

    event ProfileRegistryUpdated(bytes32 indexed profile, address indexed oldRegistry, address indexed newAdapterRegistry);
    event ImplementationSet(address indexed newAgentWalletImplementation);

    /// @param admin Address of the AdminTimelock contract (gets admin role for dangerous operations)
    /// @param agentOperator Address that can create agent wallets (typically backend server)
    constructor(address admin, address agentOperator) {
        if (admin == address(0)) revert AWKErrors.ZeroAddress();
        if (agentOperator == address(0)) revert AWKErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AGENT_OPERATOR_ROLE, agentOperator);
    }

    /**
     * @notice List all addresses with the AGENT_OPERATOR_ROLE
     * @return Array of operator addresses
     */
    function listAgentOperators() external view returns (address[] memory) {
        uint256 count = getRoleMemberCount(AGENT_OPERATOR_ROLE);
        address[] memory operators = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            operators[i] = getRoleMember(AGENT_OPERATOR_ROLE, i);
        }
        return operators;
    }

    /**
     * @dev Internal override to enforce the operator limit
     * @dev Only reverts if we're at the limit AND trying to add a new operator
     */
    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        if (role == AGENT_OPERATOR_ROLE && getRoleMemberCount(role) >= MAX_OPERATORS && !hasRole(role, account)) {
            revert TooManyOperators();
        }
        return super._grantRole(role, account);
    }

    /**
     * @notice Get the current AgentWallet implementation
     * @return The implementation contract
     */
    function agentWalletImplementation() public view virtual returns (AgentWallet) {
        return _agentWalletImplementation;
    }

    /**
     * @notice Set the current implementation for NEW wallets
     * @param newAgentWalletImplementation Address of the new AgentWallet logic
     */
    function setAgentWalletImplementation(AgentWallet newAgentWalletImplementation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newAgentWalletImplementation) == address(0)) revert AWKErrors.ZeroAddress();
        if (address(newAgentWalletImplementation).code.length == 0) revert AWKErrors.NotAContract(address(newAgentWalletImplementation));
        if (address(newAgentWalletImplementation.FACTORY()) != address(this)) revert InvalidImplementationFactory();
        _agentWalletImplementation = newAgentWalletImplementation;
        emit ImplementationSet(address(newAgentWalletImplementation));
    }

    /**
     * @notice Set the AdapterRegistry for a profile (existing wallets pick it up on their next sync)
     * @param profile The profile, e.g. keccak256("vault")
     * @param newAdapterRegistry The new registry contract
     */
    function setProfileAdapterRegistry(bytes32 profile, AdapterRegistry newAdapterRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (profile == bytes32(0)) revert UnknownProfile(profile);
        if (address(newAdapterRegistry) == address(0)) revert AWKErrors.ZeroAddress();
        if (address(newAdapterRegistry).code.length == 0) revert AWKErrors.NotAContract(address(newAdapterRegistry));
        AdapterRegistry oldAdapterRegistry = profileAdapterRegistry[profile];
        profileAdapterRegistry[profile] = newAdapterRegistry;
        emit ProfileRegistryUpdated(profile, address(oldAdapterRegistry), address(newAdapterRegistry));
    }

    /**
     * @notice The adapter registry of the calling wallet's profile (what wallets read when they sync)
     */
    function adapterRegistry() external view returns (AdapterRegistry) {
        return profileAdapterRegistry[walletProfile[msg.sender]];
    }

    /**
     * @notice Deploy a new wallet proxy, validate preconditions, and register it
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner
     * @param profile The wallet's profile, recorded before the caller initializes the wallet
     * @return ret The deployed wallet proxy
     */
    function _deployWallet(address owner, uint256 ownerAgentIndex, bytes32 profile) internal returns (AgentWallet ret) {
        if (owner == address(0)) revert AWKErrors.ZeroAddress();
        if (address(_agentWalletImplementation) == address(0)) revert NoAgentWalletImplementationSet();
        if (address(profileAdapterRegistry[profile]) == address(0)) revert UnknownProfile(profile);
        if (userWallets[owner][ownerAgentIndex] != address(0)) revert AgentAlreadyExists(owner, ownerAgentIndex);
        bytes32 salt = keccak256(abi.encode(owner, ownerAgentIndex));
        ret = AgentWallet(payable(new AWKAgentWalletProxy{salt: salt}()));
        userWallets[owner][ownerAgentIndex] = address(ret);
        walletProfile[address(ret)] = profile;
    }

    /**
     * @notice Calculate the counterfactual address of an AgentWallet
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner
     * @return The predicted wallet address
     */
    function getAddress(address owner, uint256 ownerAgentIndex) public view returns (address) {
        bytes32 salt = keccak256(abi.encode(owner, ownerAgentIndex));
        return Create2.computeAddress(salt, keccak256(type(AWKAgentWalletProxy).creationCode));
    }
}
