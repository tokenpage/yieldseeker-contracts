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
import {AWKAgentWalletV3 as AgentWallet} from "./AWKAgentWalletV3.sol";
import {AWKErrors} from "./AWKErrors.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

error AgentAlreadyExists(address owner, uint256 ownerAgentIndex);
error NoAgentWalletImplementationSet();
error UnknownAgentProfile(bytes32 agentProfile);
error InvalidImplementationFactory();
error TooManyOperators();

/**
 * @title AWKAgentWalletProxy
 * @notice A custom ERC1967Proxy that queries the Factory for its implementation.
 * @dev This ensures the init-code hash is constant regardless of the implementation address.
 */
contract AWKAgentWalletProxy is ERC1967Proxy {
    constructor() ERC1967Proxy(address(AWKAgentWalletFactory(msg.sender).agentWalletImplementation()), "") {}
}

/**
 * @title AWKAgentWalletFactory
 * @notice Abstract factory for deploying AgentWallet proxies using CREATE2
 * @dev Each agent wallet is tied to a specific base asset (e.g., USDC) and an agent profile (its agent type).
 *      Each agent profile has its own adapter registry. A wallet stores its agent profile at initialization and reads
 *      its registry from adapterRegistry(agentProfile) when it syncs.
 *      Users can create multiple agents with different ownerAgentIndex values
 *      Salt formula: keccak256(abi.encodePacked(owner, ownerAgentIndex))
 *
 *      IMPORTANT: This contract is abstract and must be inherited. Subclasses must:
 *      1. Implement a public deployment function (e.g., createAgentWallet)
 *      2. Call _deployWallet() followed by initialize() ATOMICALLY in the same transaction
 *      3. See YieldSeekerAgentWalletFactory for the correct implementation pattern
 */
abstract contract AWKAgentWalletFactory is AccessControlEnumerable {
    bytes32 public constant AGENT_OPERATOR_ROLE = keccak256("AGENT_OPERATOR_ROLE");
    uint256 public constant MAX_OPERATORS = 10;

    AgentWallet internal _agentWalletImplementation;
    mapping(bytes32 agentProfile => AdapterRegistry) internal _agentProfileAdapterRegistryMap;

    /// @notice Mapping of owner => ownerAgentIndex => agent wallet address
    mapping(address => mapping(uint256 => address)) public userWallets;

    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 indexed ownerAgentIndex);
    event RegistryUpdated(bytes32 indexed agentProfile, address indexed oldRegistry, address indexed newAdapterRegistry);
    event TrackerUpdated(address indexed oldTracker, address indexed newTracker);
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
     * @notice Get the AdapterRegistry of an agent profile
     * @param agentProfile The agent profile, e.g. keccak256("vault")
     * @return The registry contract, or address(0) if the agent profile has none
     */
    function adapterRegistry(bytes32 agentProfile) public view virtual returns (AdapterRegistry) {
        return _agentProfileAdapterRegistryMap[agentProfile];
    }

    /**
     * @notice Update the AdapterRegistry of an agent profile (its existing wallets pick it up on their next sync)
     * @param agentProfile The agent profile, e.g. keccak256("vault")
     * @param newAdapterRegistry The new registry contract
     */
    function setAdapterRegistry(bytes32 agentProfile, AdapterRegistry newAdapterRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (agentProfile == bytes32(0)) revert UnknownAgentProfile(agentProfile);
        if (address(newAdapterRegistry) == address(0)) revert AWKErrors.ZeroAddress();
        if (address(newAdapterRegistry).code.length == 0) revert AWKErrors.NotAContract(address(newAdapterRegistry));
        AdapterRegistry oldAdapterRegistry = _agentProfileAdapterRegistryMap[agentProfile];
        _agentProfileAdapterRegistryMap[agentProfile] = newAdapterRegistry;
        emit RegistryUpdated(agentProfile, address(oldAdapterRegistry), address(newAdapterRegistry));
    }

    /**
     * @notice Deploy a new wallet proxy, validate preconditions, and register it
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner
     * @param agentProfile The wallet's agent profile, which must have an adapter registry; the caller passes it to initialize()
     * @return ret The deployed wallet proxy
     */
    function _deployWallet(address owner, uint256 ownerAgentIndex, bytes32 agentProfile) internal returns (AgentWallet ret) {
        if (owner == address(0)) revert AWKErrors.ZeroAddress();
        if (address(_agentWalletImplementation) == address(0)) revert NoAgentWalletImplementationSet();
        if (address(_agentProfileAdapterRegistryMap[agentProfile]) == address(0)) revert UnknownAgentProfile(agentProfile);
        if (userWallets[owner][ownerAgentIndex] != address(0)) revert AgentAlreadyExists(owner, ownerAgentIndex);
        bytes32 salt = keccak256(abi.encode(owner, ownerAgentIndex));
        ret = AgentWallet(payable(new AWKAgentWalletProxy{salt: salt}()));
        userWallets[owner][ownerAgentIndex] = address(ret);
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
