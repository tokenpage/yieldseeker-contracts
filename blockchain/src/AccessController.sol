// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title YieldSeekerAccessController
 * @notice Central access control and registry for all backend operations on agent wallets
 * @dev Single point of control for:
 *      - Backend EOA authorization (key rotation via role management)
 *      - Emergency pause (1 tx pauses all agents)
 *      - Vault and swap provider registry
 *      - Vault to provider mappings
 *      Uses OpenZeppelin AccessControl for role-based permissions:
 *      - DEFAULT_ADMIN_ROLE: Can manage all roles, system settings, and pause/unpause
 *      - OPERATOR_ROLE: Backend EOAs authorized to execute agent operations
 *      - REGISTRY_ADMIN_ROLE: Can manage vault/swap registrations
 */
contract YieldSeekerAccessController is AccessControl, Pausable {
    /// @notice Role for backend EOAs that can execute agent operations
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    /// @notice Role for managing vault and swap registrations
    bytes32 public constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");

    // ============ VAULT REGISTRY ============

    /// @notice Mapping of vault provider address => approval status
    mapping(address => bool) public isVaultProviderApproved;

    /// @notice Mapping of vault address => vault provider address
    mapping(address => address) public vaultToProvider;

    /// @notice Array of all approved vault providers
    address[] public approvedVaultProviders;

    /// @notice Array of all registered vaults
    address[] public registeredVaults;

    // ============ SWAP REGISTRY ============

    /// @notice Mapping of swap provider address => approval status
    mapping(address => bool) public isSwapProviderApproved;

    /// @notice Array of all approved swap providers
    address[] public approvedSwapProviders;

    // ============ EVENTS ============

    event VaultProviderApproved(address indexed provider);
    event VaultProviderRemoved(address indexed provider);
    event VaultRegistered(address indexed vault, address indexed provider);
    event VaultUnregistered(address indexed vault);
    event SwapProviderApproved(address indexed provider);
    event SwapProviderRemoved(address indexed provider);

    // ============ ERRORS ============

    error InvalidAddress();
    error AlreadyApproved();
    error NotApproved();
    error VaultAlreadyRegistered();
    error VaultNotRegistered();
    error ProviderNotApproved();

    constructor(address _admin) {
        if (_admin == address(0)) revert InvalidAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _admin);
        _grantRole(REGISTRY_ADMIN_ROLE, _admin);
    }

    // ============ PAUSE CONTROL ============

    /**
     * @notice Emergency pause all agent operations
     * @dev Only admin can pause. Pauses all vault deposits, withdrawals, swaps, and rebalances
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause agent operations
     * @dev Only admin can unpause
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ============ OPERATOR MANAGEMENT ============

    /**
     * @notice Check if an address is an authorized operator
     * @param operator Address to check
     * @return True if authorized
     */
    function isAuthorizedOperator(address operator) external view returns (bool) {
        return hasRole(OPERATOR_ROLE, operator);
    }

    // ============ VAULT PROVIDER MANAGEMENT ============

    /**
     * @notice Approve a vault provider
     * @param provider Address of the vault provider contract
     * @dev SECURITY CRITICAL: Adding malicious provider = instant fund theft
     */
    function approveVaultProvider(address provider) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (provider == address(0)) revert InvalidAddress();
        if (isVaultProviderApproved[provider]) revert AlreadyApproved();

        isVaultProviderApproved[provider] = true;
        approvedVaultProviders.push(provider);

        emit VaultProviderApproved(provider);
    }

    /**
     * @notice Remove a vault provider from approved list
     * @param provider Address of the vault provider contract
     */
    function removeVaultProvider(address provider) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (!isVaultProviderApproved[provider]) revert NotApproved();

        isVaultProviderApproved[provider] = false;

        // Remove from array
        for (uint256 i = 0; i < approvedVaultProviders.length; i++) {
            if (approvedVaultProviders[i] == provider) {
                approvedVaultProviders[i] = approvedVaultProviders[approvedVaultProviders.length - 1];
                approvedVaultProviders.pop();
                break;
            }
        }

        emit VaultProviderRemoved(provider);
    }

    /**
     * @notice Get all approved vault providers
     * @return Array of approved provider addresses
     */
    function getApprovedVaultProviders() external view returns (address[] memory) {
        return approvedVaultProviders;
    }

    // ============ VAULT REGISTRATION ============

    /**
     * @notice Register a vault with its provider
     * @param vault Address of the vault
     * @param provider Address of the vault provider
     * @dev Provider must be approved first
     */
    function registerVault(address vault, address provider) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (vault == address(0)) revert InvalidAddress();
        if (vaultToProvider[vault] != address(0)) revert VaultAlreadyRegistered();
        if (!isVaultProviderApproved[provider]) revert ProviderNotApproved();

        vaultToProvider[vault] = provider;
        registeredVaults.push(vault);

        emit VaultRegistered(vault, provider);
    }

    /**
     * @notice Unregister a vault
     * @param vault Address of the vault
     */
    function unregisterVault(address vault) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (vaultToProvider[vault] == address(0)) revert VaultNotRegistered();

        delete vaultToProvider[vault];

        // Remove from array
        for (uint256 i = 0; i < registeredVaults.length; i++) {
            if (registeredVaults[i] == vault) {
                registeredVaults[i] = registeredVaults[registeredVaults.length - 1];
                registeredVaults.pop();
                break;
            }
        }

        emit VaultUnregistered(vault);
    }

    /**
     * @notice Get provider for a vault
     * @param vault Address of the vault
     * @return provider Address of the vault provider
     * @dev Reverts if vault is not registered or provider is not approved
     */
    function getVaultProvider(address vault) external view returns (address provider) {
        provider = vaultToProvider[vault];
        if (provider == address(0)) revert VaultNotRegistered();
        if (!isVaultProviderApproved[provider]) revert ProviderNotApproved();
    }

    /**
     * @notice Get all registered vaults
     * @return Array of registered vault addresses
     */
    function getRegisteredVaults() external view returns (address[] memory) {
        return registeredVaults;
    }

    // ============ SWAP PROVIDER MANAGEMENT ============

    /**
     * @notice Approve a swap provider
     * @param provider Address of the swap provider contract
     * @dev SECURITY CRITICAL: Adding malicious provider = instant fund theft
     */
    function approveSwapProvider(address provider) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (provider == address(0)) revert InvalidAddress();
        if (isSwapProviderApproved[provider]) revert AlreadyApproved();

        isSwapProviderApproved[provider] = true;
        approvedSwapProviders.push(provider);

        emit SwapProviderApproved(provider);
    }

    /**
     * @notice Remove a swap provider from approved list
     * @param provider Address of the swap provider contract
     */
    function removeSwapProvider(address provider) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (!isSwapProviderApproved[provider]) revert NotApproved();

        isSwapProviderApproved[provider] = false;

        // Remove from array
        for (uint256 i = 0; i < approvedSwapProviders.length; i++) {
            if (approvedSwapProviders[i] == provider) {
                approvedSwapProviders[i] = approvedSwapProviders[approvedSwapProviders.length - 1];
                approvedSwapProviders.pop();
                break;
            }
        }

        emit SwapProviderRemoved(provider);
    }

    /**
     * @notice Get all approved swap providers
     * @return Array of approved provider addresses
     */
    function getApprovedSwapProviders() external view returns (address[] memory) {
        return approvedSwapProviders;
    }

    /**
     * @notice Check if a swap provider is approved
     * @param provider Swap provider address
     * @return True if approved
     */
    function isSwapApproved(address provider) external view returns (bool) {
        return isSwapProviderApproved[provider];
    }
}
