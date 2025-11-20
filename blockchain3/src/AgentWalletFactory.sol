// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {YieldSeekerAgentWallet} from "./AgentWallet.sol";

/**
 * @title YieldSeekerAgentWalletFactory
 * @notice Factory for deploying ERC1967 Proxy Agent Wallets
 * @dev Deploys UUPS upgradeable proxies.
 *      - Factory maintains a "currentImplementation" address.
 *      - New wallets are deployed pointing to this implementation.
 *      - Existing wallets are NOT automatically upgraded (User Sovereignty).
 *      - Users must manually upgrade their wallet to the new implementation.
 */
contract YieldSeekerAgentWalletFactory is AccessControl {

    bytes32 public constant AGENT_CREATOR_ROLE = keccak256("AGENT_CREATOR_ROLE");

    // Current recommended implementation version
    address public currentImplementation;

    // Default Executor Module to install on new wallets
    address public defaultExecutorModule;

    event AgentWalletCreated(address indexed wallet, address indexed owner);
    event ImplementationSet(address indexed newImplementation);
    event DefaultExecutorSet(address indexed executor);

    constructor(address _implementation, address _admin) {
        require(_implementation != address(0), "Invalid implementation");
        require(_admin != address(0), "Invalid admin");

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(AGENT_CREATOR_ROLE, _admin);

        currentImplementation = _implementation;
    }

    /**
     * @notice Set the current implementation for NEW wallets
     * @param newImplementation Address of the new AgentWallet logic
     */
    function setImplementation(address newImplementation) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(newImplementation != address(0), "Invalid implementation");
        currentImplementation = newImplementation;
        emit ImplementationSet(newImplementation);
    }

    /**
     * @notice Set the default executor module to install on new wallets
     */
    function setDefaultExecutor(address _executor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        defaultExecutorModule = _executor;
        emit DefaultExecutorSet(_executor);
    }

    /**
     * @notice Create a new agent wallet for a user with deterministic CREATE2 address
     * @param user User address who will own the wallet
     * @param userAgentIndex Index of this agent for the user (enables multiple agents per user)
     * @param baseAsset Base asset token address for this agent (e.g., USDC)
     * @return agentWallet Address of the newly created agent wallet
     */
    function createAgentWallet(address user, uint256 userAgentIndex, address baseAsset) external onlyRole(AGENT_CREATOR_ROLE) returns (address agentWallet) {
        // Create deterministic salt: hash of user address + agent index
        bytes32 salt = keccak256(abi.encodePacked(user, userAgentIndex));

        // 1. Prepare initialization data
        //    - Initialize the wallet with user, index, and baseAsset
        bytes memory walletInitData = abi.encodeCall(YieldSeekerAgentWallet.initialize, (user, userAgentIndex, baseAsset));

        // 2. Deploy ERC1967Proxy
        //    - Points to currentImplementation
        //    - Executes walletInitData
        ERC1967Proxy proxy = new ERC1967Proxy{salt: salt}(currentImplementation, walletInitData);
        agentWallet = address(proxy);

        // 3. Install Default Executor (if set)
        //    TODO: In a real prod version, we would encode the module installation into the
        //    wallet's initialize function or use a bootstrap module.

        emit AgentWalletCreated(agentWallet, user);
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

        bytes memory walletInitData = abi.encodeCall(YieldSeekerAgentWallet.initialize, (user, userAgentIndex, baseAsset));

        bytes memory bytecode = abi.encodePacked(
            type(ERC1967Proxy).creationCode,
            abi.encode(currentImplementation, walletInitData)
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
}
