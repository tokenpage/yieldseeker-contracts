// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {YieldSeekerActionRegistry as ActionRegistry} from "./ActionRegistry.sol";
import {YieldSeekerAgentWallet as AgentWallet} from "./AgentWallet.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/**
 * @title YieldSeekerAgentWalletFactory
 * @notice Factory for deploying AgentWallet proxies using CREATE2
 * @dev Based on SimpleAccountFactory pattern from eth-infinitism/account-abstraction v0.6
 *      Adds AccessControl for permissioned wallet creation and ActionRegistry integration
 */
contract YieldSeekerAgentWalletFactory is AccessControl {
    bytes32 public constant AGENT_CREATOR_ROLE = keccak256("AGENT_CREATOR_ROLE");
    AgentWallet public agentWalletImplementation;
    ActionRegistry public actionRegistry;

    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 salt);
    event RegistryUpdated(address indexed oldRegistry, address indexed newActionRegistry);
    event ImplementationSet(address indexed newAgentWalletImplementation);

    /// @param admin Address of the AdminTimelock contract (gets admin role for dangerous operations)
    /// @param agentCreator Address that can create agent wallets (typically backend server)
    constructor(address admin, address agentCreator) {
        require(admin != address(0), "Invalid admin");
        require(agentCreator != address(0), "Invalid agent creator");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AGENT_CREATOR_ROLE, agentCreator);
    }

    /**
     * @notice Set the current implementation for NEW wallets
     * @param newAgentWalletImplementation Address of the new AgentWallet logic
     */
    function setAgentWalletImplementation(AgentWallet newAgentWalletImplementation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(newAgentWalletImplementation) != address(0), "Invalid newAgentWalletImplementation");
        agentWalletImplementation = newAgentWalletImplementation;
        emit ImplementationSet(address(newAgentWalletImplementation));
    }

    /**
     * @notice Update the ActionRegistry address for future wallet deployments
     * @param newActionRegistry The new registry contract
     */
    function setActionRegistry(ActionRegistry newActionRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(newActionRegistry) != address(0), "Invalid newActionRegistry");
        ActionRegistry oldActionRegistry = this.actionRegistry();
        actionRegistry = newActionRegistry;
        emit RegistryUpdated(address(oldActionRegistry), address(newActionRegistry));
    }

    /**
     * @notice Create an AgentWallet for the given owner
     * @dev Returns existing address if already deployed (for EntryPoint.getSenderAddress compatibility)
     * @param owner The owner address for the wallet
     * @param salt Salt for CREATE2 deterministic deployment
     * @return ret The deployed or existing AgentWallet
     */
    function createAccount(address owner, uint256 salt) public onlyRole(AGENT_CREATOR_ROLE) returns (AgentWallet ret) {
        address addr = getAddress(owner, salt);
        uint256 codeSize = addr.code.length;
        if (codeSize > 0) {
            return AgentWallet(payable(addr));
        }
        ret = AgentWallet(payable(new ERC1967Proxy{salt: bytes32(salt)}(address(agentWalletImplementation), abi.encodeCall(AgentWallet.initialize, (owner, actionRegistry)))));
        emit AgentWalletCreated(address(ret), owner, salt);
    }

    /**
     * @notice Calculate the counterfactual address of an AgentWallet
     * @param owner The owner address for the wallet
     * @param salt Salt for CREATE2
     * @return The predicted wallet address
     */
    function getAddress(address owner, uint256 salt) public view returns (address) {
        return Create2.computeAddress(bytes32(salt), keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(agentWalletImplementation), abi.encodeCall(AgentWallet.initialize, (owner, actionRegistry))))));
    }
}
