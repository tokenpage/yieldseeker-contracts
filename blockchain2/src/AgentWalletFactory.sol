// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {YieldSeekerAgentWallet} from "./AgentWallet.sol";

/**
 * @title YieldSeekerAgentWalletFactory
 * @notice Factory for deploying upgradeable AgentWallet proxies using ERC1967
 * @dev Deploys UUPS upgradeable proxies that users can upgrade to approved implementations
 *
 *      UPGRADE MECHANISM:
 *      - Factory maintains whitelist of approved implementations
 *      - Only wallet owner can upgrade their wallet
 *      - Upgrades can only be to factory-approved implementations
 *      - Admin cannot force upgrades
 *
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

    /// @notice Current recommended implementation version
    address public currentImplementation;

    /// @notice Mapping of user => userAgentIndex => agent wallet address
    mapping(address => mapping(uint256 => address)) public userWallets;

    /// @notice Array of all created agent wallets
    address[] public allAgentWallets;

    event AgentWalletCreated(address indexed user, uint256 indexed userAgentIndex, address indexed agentWallet, address baseAsset);
    event ImplementationSet(address indexed implementation);

    error InvalidAddress();
    error InitializationFailed();
    error AgentAlreadyExists(address user, uint256 userAgentIndex);
    error NoImplementationSet();

    constructor(address _defaultAdmin) {
        if (_defaultAdmin == address(0)) revert InvalidAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _grantRole(AGENT_CREATOR_ROLE, _defaultAdmin);
    }

    /**
     * @notice Set new wallet implementation
     * @param implementation Address of the new AgentWallet implementation
     * @dev Sets as current implementation. All future upgrades will use this version.
     */
    function setImplementation(address implementation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (implementation == address(0)) revert InvalidAddress();

        currentImplementation = implementation;

        emit ImplementationSet(implementation);
    }

    /**
     * @notice Create a new agent wallet for a user with deterministic CREATE2 address
     * @param user User address who will own the wallet
     * @param userAgentIndex Index of this agent for the user (enables multiple agents per user)
     * @param baseAsset Base asset token address for this agent (e.g., USDC)
     * @return agentWallet Address of the newly created agent wallet
     */
    function createAgentWallet(address user, uint256 userAgentIndex, address baseAsset) external onlyRole(AGENT_CREATOR_ROLE) returns (address agentWallet) {
        if (user == address(0)) revert InvalidAddress();
        if (baseAsset == address(0)) revert InvalidAddress();
        if (currentImplementation == address(0)) revert NoImplementationSet();

        // Check if agent already exists at this index
        if (userWallets[user][userAgentIndex] != address(0)) {
            revert AgentAlreadyExists(user, userAgentIndex);
        }

        // Create deterministic salt: hash of user address + agent index
        bytes32 salt = keccak256(abi.encodePacked(user, userAgentIndex));

        // Create initialization data
        bytes memory initData = abi.encodeCall(
            YieldSeekerAgentWallet.initialize,
            (user, userAgentIndex, baseAsset)
        );

        // Deploy ERC1967 proxy using CREATE2 for deterministic address
        agentWallet = address(new ERC1967Proxy{salt: salt}(currentImplementation, initData));

        // Store at the actual userAgentIndex
        userWallets[user][userAgentIndex] = agentWallet;
        allAgentWallets.push(agentWallet);

        emit AgentWalletCreated(user, userAgentIndex, agentWallet, baseAsset);
    }

    /**
     * @notice Predict the address of an agent wallet before deployment
     * @param user User address who will own the wallet
     * @param userAgentIndex Index of this agent for the user
     * @param baseAsset Base asset address (needed for accurate prediction)
     * @return predicted Predicted agent wallet address
     */
    function predictAgentWalletAddress(
        address user,
        uint256 userAgentIndex,
        address baseAsset
    ) external view returns (address predicted) {
        bytes32 salt = keccak256(abi.encodePacked(user, userAgentIndex));

        bytes memory initData = abi.encodeCall(
            YieldSeekerAgentWallet.initialize,
            (user, userAgentIndex, baseAsset)
        );

        bytes memory bytecode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(currentImplementation, initData)
        );

        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(bytecode)
            )
        );

        return address(uint160(uint256(hash)));
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
