// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKAdapterRegistry as AdapterRegistry} from "./AWKAdapterRegistry.sol";
import {AWKAgentWalletV1 as AgentWallet} from "./AWKAgentWalletV1.sol";
import {AWKErrors} from "./AWKErrors.sol";
import {AccessControlEnumerable} from "@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

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
 * @notice Factory for deploying AgentWallet proxies using CREATE2
 * @dev Each agent wallet is tied to a specific base asset (e.g., USDC)
 *      Users can create multiple agents with different ownerAgentIndex values
 *      Salt formula: keccak256(abi.encodePacked(owner, ownerAgentIndex))
 */
contract AWKAgentWalletFactory is AccessControlEnumerable {
    bytes32 public constant AGENT_OPERATOR_ROLE = keccak256("AGENT_OPERATOR_ROLE");
    uint256 public constant MAX_OPERATORS = 10;

    AgentWallet internal _agentWalletImplementation;
    AdapterRegistry public adapterRegistry;

    /// @notice Mapping of owner => ownerAgentIndex => agent wallet address
    mapping(address => mapping(uint256 => address)) public userWallets;

    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 indexed ownerAgentIndex);
    event RegistryUpdated(address indexed oldRegistry, address indexed newAdapterRegistry);
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
            revert AWKErrors.TooManyOperators();
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
        if (address(newAgentWalletImplementation.FACTORY()) != address(this)) revert AWKErrors.InvalidImplementationFactory();
        _agentWalletImplementation = newAgentWalletImplementation;
        emit ImplementationSet(address(newAgentWalletImplementation));
    }

    /**
     * @notice Update the AdapterRegistry address for future wallet deployments
     * @param newAdapterRegistry The new registry contract
     */
    function setAdapterRegistry(AdapterRegistry newAdapterRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newAdapterRegistry) == address(0)) revert AWKErrors.ZeroAddress();
        if (address(newAdapterRegistry).code.length == 0) revert AWKErrors.NotAContract(address(newAdapterRegistry));
        AdapterRegistry oldAdapterRegistry = adapterRegistry;
        adapterRegistry = newAdapterRegistry;
        emit RegistryUpdated(address(oldAdapterRegistry), address(newAdapterRegistry));
    }

    /**
     * @notice Calculate the CREATE2 salt for a wallet
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner
     * @return salt The CREATE2 salt
     */
    function _calculateSalt(address owner, uint256 ownerAgentIndex) internal pure returns (bytes32) {
        return keccak256(abi.encode(owner, ownerAgentIndex));
    }

    /**
     * @notice Validate wallet creation preconditions
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner
     */
    function _validateWalletCreation(address owner, uint256 ownerAgentIndex) internal view {
        if (owner == address(0)) revert AWKErrors.ZeroAddress();
        if (address(_agentWalletImplementation) == address(0)) revert AWKErrors.NoAgentWalletImplementationSet();
        if (address(adapterRegistry) == address(0)) revert AWKErrors.NoAdapterRegistrySet();
        if (userWallets[owner][ownerAgentIndex] != address(0)) revert AWKErrors.AgentAlreadyExists(owner, ownerAgentIndex);
    }

    /**
     * @notice Create an AgentWallet for the given owner with deterministic CREATE2 address
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner (enables multiple agents per owner)
     * @return ret The deployed AgentWallet
     */
    function createAgentWallet(address owner, uint256 ownerAgentIndex) public virtual onlyRole(AGENT_OPERATOR_ROLE) returns (AgentWallet ret) {
        _validateWalletCreation(owner, ownerAgentIndex);
        bytes32 salt = _calculateSalt(owner, ownerAgentIndex);
        ret = AgentWallet(payable(new AWKAgentWalletProxy{salt: salt}()));
        ret.initialize(owner, ownerAgentIndex);
        userWallets[owner][ownerAgentIndex] = address(ret);
        emit AgentWalletCreated(address(ret), owner, ownerAgentIndex);
    }

    /**
     * @notice Calculate the counterfactual address of an AgentWallet
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner
     * @return The predicted wallet address
     */
    function getAddress(address owner, uint256 ownerAgentIndex) public view virtual returns (address) {
        bytes32 salt = _calculateSalt(owner, ownerAgentIndex);
        return Create2.computeAddress(salt, keccak256(type(AWKAgentWalletProxy).creationCode));
    }
}
