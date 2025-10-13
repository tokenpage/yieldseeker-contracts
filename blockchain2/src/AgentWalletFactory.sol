// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {YieldSeekerAgentWallet} from "./AgentWallet.sol";

/**
 * @title YieldSeekerAgentWalletFactory
 * @notice Factory for deploying AgentWallet minimal proxies using OpenZeppelin Clones
 * @dev Uses OpenZeppelin's battle-tested EIP-1167 implementation for deterministic CREATE2 deployment
 *      DETERMINISTIC CROSS-CHAIN ADDRESSES:
 *      Agent wallets have the SAME address on ALL chains (Base, Optimism, Arbitrum, etc.) when:
 *      1. Factory is deployed at same address on all chains (via CREATE2)
 *      2. AgentWallet implementation is at same address on all chains (via CREATE2)
 *      3. Same user + userAgentIndex combination is used
 *      Salt formula: keccak256(abi.encodePacked(user, userAgentIndex))
 *      Users can create multiple agents with different indices, each with a unique deterministic address.
 *
 *      ROLE-BASED ACCESS CONTROL:
 *      - DEFAULT_ADMIN_ROLE: Can grant/revoke all roles (owners/multisig)
 *      - AGENT_CREATOR_ROLE: Can call createAgentWallet (backend operators)
 */
contract YieldSeekerAgentWalletFactory is AccessControl {
    /// @notice Role for addresses that can create agent wallets (backend operators)
    bytes32 public constant AGENT_CREATOR_ROLE = keccak256("AGENT_CREATOR_ROLE");

    /// @notice Implementation contract for agent wallets
    address public immutable agentWalletImplementation;

    /// @notice Mapping of user => userAgentIndex => agent wallet address
    mapping(address => mapping(uint256 => address)) public userWallets;

    /// @notice Array of all created agent wallets
    address[] public allAgentWallets;

    event AgentWalletCreated(address indexed user, uint256 indexed userAgentIndex, address indexed agentWallet, address baseAsset);

    error InvalidAddress();
    error InitializationFailed();
    error AgentAlreadyExists(address user, uint256 userAgentIndex);

    constructor(address _defaultAdmin, address _agentWalletImplementation) {
        if (_defaultAdmin == address(0)) revert InvalidAddress();
        if (_agentWalletImplementation == address(0)) revert InvalidAddress();
        agentWalletImplementation = _agentWalletImplementation;
        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _grantRole(AGENT_CREATOR_ROLE, _defaultAdmin);
    }

    /**
     * @notice Create a new agent wallet for a user with deterministic address
     * @param user User address who will own the wallet
     * @param userAgentIndex Index of this agent for the user (enables multiple agents per user)
     * @param baseAsset Base asset token address for this agent (e.g., USDC)
     * @return agentWallet Address of the newly created agent wallet
     */
    function createAgentWallet(address user, uint256 userAgentIndex, address baseAsset) external onlyRole(AGENT_CREATOR_ROLE) returns (address agentWallet) {
        if (user == address(0)) revert InvalidAddress();
        if (baseAsset == address(0)) revert InvalidAddress();

        // Check if agent already exists at this index
        if (userWallets[user][userAgentIndex] != address(0)) {
            revert AgentAlreadyExists(user, userAgentIndex);
        }

        // Create deterministic salt: hash of user address + agent index
        bytes32 salt = keccak256(abi.encodePacked(user, userAgentIndex));

        // Deploy minimal proxy using OpenZeppelin Clones (CREATE2)
        agentWallet = Clones.cloneDeterministic(agentWalletImplementation, salt);

        // Initialize the agent wallet with user, userAgentIndex, and baseAsset
        (bool success,) = agentWallet.call(abi.encodeWithSelector(YieldSeekerAgentWallet.initialize.selector, user, userAgentIndex, baseAsset));
        if (!success) revert InitializationFailed();

        // Store at the actual userAgentIndex
        userWallets[user][userAgentIndex] = agentWallet;
        allAgentWallets.push(agentWallet);

        emit AgentWalletCreated(user, userAgentIndex, agentWallet, baseAsset);
    }

    /**
     * @notice Predict the address of an agent wallet before deployment
     * @param user User address who will own the wallet
     * @param userAgentIndex Index of this agent for the user
     * @return predicted Predicted agent wallet address
     */
    function predictAgentWalletAddress(address user, uint256 userAgentIndex) external view returns (address predicted) {
        bytes32 salt = keccak256(abi.encodePacked(user, userAgentIndex));
        return Clones.predictDeterministicAddress(agentWalletImplementation, salt, address(this));
    }

    /**
     * @notice Get total number of deployed wallets across all users
     * @return count Total number of wallets
     */
    function getTotalWalletCount() external view returns (uint256 count) {
        return allAgentWallets.length;
    }

    /**
     * @notice Get all agent wallets
     * @return Array of all agent wallet addresses
     */
    function getAllAgentWallets() external view returns (address[] memory) {
        return allAgentWallets;
    }
}
