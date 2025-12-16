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
    AgentWallet public accountImplementation;
    ActionRegistry public actionRegistry;

    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 salt);
    event RegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event ImplementationSet(address indexed newImplementation);

    /// @param timelock Address of the AdminTimelock contract (gets admin role for dangerous operations)
    /// @param agentCreator Address that can create agent wallets (typically backend server)
    constructor(address timelock, address agentCreator) {
        require(timelock != address(0), "Invalid timelock");
        require(agentCreator != address(0), "Invalid agent creator");

        // Timelock controls dangerous operations (setImplementation, setRegistry)
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);

        // Agent creator can create wallets instantly
        _grantRole(AGENT_CREATOR_ROLE, agentCreator);
    }

    /**
     * @notice Set the current implementation for NEW wallets
     * @param newImplementation Address of the new AgentWallet logic
     */
    function setImplementation(AgentWallet newImplementation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(address(newImplementation) != address(0), "Invalid implementation");
        accountImplementation = newImplementation;
        emit ImplementationSet(address(newImplementation));
    }

    /**
     * @notice Update the ActionRegistry address for future wallet deployments
     * @param newRegistry The new registry contract
     */
    function setRegistry(ActionRegistry newRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emit RegistryUpdated(address(actionRegistry), address(newRegistry));
        actionRegistry = newRegistry;
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
        ret = AgentWallet(payable(new ERC1967Proxy{salt: bytes32(salt)}(address(accountImplementation), abi.encodeCall(AgentWallet.initialize, (owner, actionRegistry)))));
        emit AgentWalletCreated(address(ret), owner, salt);
    }

    /**
     * @notice Calculate the counterfactual address of an AgentWallet
     * @param owner The owner address for the wallet
     * @param salt Salt for CREATE2
     * @return The predicted wallet address
     */
    function getAddress(address owner, uint256 salt) public view returns (address) {
        return Create2.computeAddress(bytes32(salt), keccak256(abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(address(accountImplementation), abi.encodeCall(AgentWallet.initialize, (owner, actionRegistry))))));
    }
}
