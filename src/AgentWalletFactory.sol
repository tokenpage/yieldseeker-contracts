// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "./AdapterRegistry.sol";
import {YieldSeekerAgentWalletV1 as AgentWallet} from "./AgentWalletV1.sol";
import {YieldSeekerErrors} from "./Errors.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "./FeeTracker.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/**
 * @title YieldSeekerAgentWalletProxy
 * @notice A custom ERC1967Proxy that queries the Factory for its implementation.
 * @dev This ensures the init-code hash is constant regardless of the implementation address.
 */
contract YieldSeekerAgentWalletProxy is ERC1967Proxy {
    constructor() ERC1967Proxy(address(YieldSeekerAgentWalletFactory(msg.sender).agentWalletImplementation()), "") {}
}

/**
 * @title YieldSeekerAgentWalletFactory
 * @notice Factory for deploying AgentWallet proxies using CREATE2
 * @dev Each agent wallet is tied to a specific base asset (e.g., USDC)
 *      Users can create multiple agents with different ownerAgentIndex values
 *      Salt formula: keccak256(abi.encodePacked(owner, ownerAgentIndex))
 */
contract YieldSeekerAgentWalletFactory is AccessControlEnumerable {
    bytes32 public constant AGENT_OPERATOR_ROLE = keccak256("AGENT_OPERATOR_ROLE");
    AgentWallet public agentWalletImplementation;
    AdapterRegistry public adapterRegistry;
    FeeTracker public feeTracker;

    /// @notice Mapping of owner => ownerAgentIndex => agent wallet address
    mapping(address => mapping(uint256 => address)) public userWallets;

    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 indexed ownerAgentIndex, address baseAsset);
    event RegistryUpdated(address indexed oldRegistry, address indexed newAdapterRegistry);
    event TrackerUpdated(address indexed oldTracker, address indexed newTracker);
    event ImplementationSet(address indexed newAgentWalletImplementation);

    error AgentAlreadyExists(address owner, uint256 ownerAgentIndex);
    error NoAgentWalletImplementationSet();
    error NoAdapterRegistrySet();
    error InvalidImplementationFactory();
    error TooManyOperators();

    /// @param admin Address of the AdminTimelock contract (gets admin role for dangerous operations)
    /// @param agentOperator Address that can create agent wallets (typically backend server)
    constructor(address admin, address agentOperator) {
        if (admin == address(0)) revert YieldSeekerErrors.ZeroAddress();
        if (agentOperator == address(0)) revert YieldSeekerErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AGENT_OPERATOR_ROLE, agentOperator);
    }

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
     */
    function _grantRole(bytes32 role, address account) internal override returns (bool) {
        if (role == AGENT_OPERATOR_ROLE && getRoleMemberCount(role) >= 10) {
            revert TooManyOperators();
        }
        return super._grantRole(role, account);
    }

    /**
     * @notice Set the current implementation for NEW wallets
     * @param newAgentWalletImplementation Address of the new AgentWallet logic
     */
    function setAgentWalletImplementation(AgentWallet newAgentWalletImplementation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newAgentWalletImplementation) == address(0)) revert YieldSeekerErrors.ZeroAddress();
        if (address(newAgentWalletImplementation).code.length == 0) revert YieldSeekerErrors.NotAContract(address(newAgentWalletImplementation));
        if (address(newAgentWalletImplementation.FACTORY()) != address(this)) revert InvalidImplementationFactory();
        agentWalletImplementation = newAgentWalletImplementation;
        emit ImplementationSet(address(newAgentWalletImplementation));
    }

    /**
     * @notice Update the AdapterRegistry address for future wallet deployments
     * @param newAdapterRegistry The new registry contract
     */
    function setAdapterRegistry(AdapterRegistry newAdapterRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newAdapterRegistry) == address(0)) revert YieldSeekerErrors.ZeroAddress();
        if (address(newAdapterRegistry).code.length == 0) revert YieldSeekerErrors.NotAContract(address(newAdapterRegistry));
        AdapterRegistry oldAdapterRegistry = adapterRegistry;
        adapterRegistry = newAdapterRegistry;
        emit RegistryUpdated(address(oldAdapterRegistry), address(newAdapterRegistry));
    }

    /**
     * @notice Update the FeeTracker address for future wallet deployments
     * @param newFeeTracker The new tracker contract
     */
    function setFeeTracker(FeeTracker newFeeTracker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newFeeTracker) == address(0)) revert YieldSeekerErrors.ZeroAddress();
        if (address(newFeeTracker).code.length == 0) revert YieldSeekerErrors.NotAContract(address(newFeeTracker));
        FeeTracker oldFeeTracker = feeTracker;
        feeTracker = newFeeTracker;
        emit TrackerUpdated(address(oldFeeTracker), address(newFeeTracker));
    }

    /**
     * @notice Create an AgentWallet for the given owner with deterministic CREATE2 address
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner (enables multiple agents per owner)
     * @param baseAsset Base asset token address for this agent (e.g., USDC)
     * @return ret The deployed AgentWallet
     */
    function createAgentWallet(address owner, uint256 ownerAgentIndex, address baseAsset) public onlyRole(AGENT_OPERATOR_ROLE) returns (AgentWallet ret) {
        if (owner == address(0)) revert YieldSeekerErrors.ZeroAddress();
        if (baseAsset == address(0)) revert YieldSeekerErrors.ZeroAddress();
        if (baseAsset.code.length == 0) revert YieldSeekerErrors.NotAContract(baseAsset);
        if (address(agentWalletImplementation) == address(0)) revert NoAgentWalletImplementationSet();
        if (address(adapterRegistry) == address(0)) revert NoAdapterRegistrySet();
        if (userWallets[owner][ownerAgentIndex] != address(0)) revert AgentAlreadyExists(owner, ownerAgentIndex);
        bytes32 salt = keccak256(abi.encode(owner, ownerAgentIndex));
        ret = AgentWallet(payable(new YieldSeekerAgentWalletProxy{salt: salt}()));
        ret.initialize(owner, ownerAgentIndex, baseAsset);
        userWallets[owner][ownerAgentIndex] = address(ret);
        emit AgentWalletCreated(address(ret), owner, ownerAgentIndex, baseAsset);
    }

    /**
     * @notice Calculate the counterfactual address of an AgentWallet
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner
     * @return The predicted wallet address
     */
    function getAddress(address owner, uint256 ownerAgentIndex) public view returns (address) {
        bytes32 salt = keccak256(abi.encode(owner, ownerAgentIndex));
        return Create2.computeAddress(salt, keccak256(type(YieldSeekerAgentWalletProxy).creationCode));
    }
}
