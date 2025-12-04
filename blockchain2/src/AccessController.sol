// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title YieldSeekerAccessController
 * @notice Central access control and contract registry
 * @dev Manages operators, pause state, and approved vaults/swaps
 */
contract YieldSeekerAccessController is AccessControl, Pausable {
    /**
     * @notice Validate a call via the YieldSeekerCallValidator
     * @param wallet The agent wallet making the call
     * @param target The contract being called
     * @param data The calldata for the call
     * @return True if call is allowed
     */
    function isCallAllowed(address wallet, address target, bytes calldata data) external view returns (bool) {
        require(callValidator != address(0), "Validator not set");
        (bool success, bytes memory result) = callValidator.staticcall(abi.encodeWithSignature("isCallAllowed(address,address,bytes)", wallet, target, data));
        require(success && result.length >= 32, "Validator call failed");
        return abi.decode(result, (bool));
    }
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");

    /// @notice Approved vault contracts
    mapping(address => bool) public isApprovedVault;

    /// @notice Approved swap provider contracts
    mapping(address => bool) public isApprovedSwapProvider;

    /// @notice Approved adapter contracts (for secure vault interactions)
    mapping(address => bool) public isApprovedAdapter;

    /// @notice List of all approved vaults
    address[] public approvedVaults;

    /// @notice List of all approved swap providers
    address[] public approvedSwapProviders;

    /// @notice List of all approved adapters
    address[] public approvedAdapters;

    /// @notice YieldSeekerCallValidator contract address
    address public callValidator;

    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event VaultApproved(address indexed vault);
    event VaultRemoved(address indexed vault);
    event SwapProviderApproved(address indexed swapProvider);
    event SwapProviderRemoved(address indexed swapProvider);
    event AdapterApproved(address indexed adapter);
    event AdapterRemoved(address indexed adapter);

    event CallValidatorSet(address indexed validator);

    error AlreadyApproved();
    error NotApproved();

    error NotAdmin();

    constructor(address admin) {
        if (admin == address(0)) {
            revert("Invalid address");
        }

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(REGISTRY_ADMIN_ROLE, admin);
        callValidator = address(0);
    }

    /**
     * @notice Set the YieldSeekerCallValidator contract address
     * @param validator Address of the validator contract
     */
    function setCallValidator(address validator) external onlyRole(REGISTRY_ADMIN_ROLE) {
        callValidator = validator;
        emit CallValidatorSet(validator);
    }

    /**
     * @notice Get the YieldSeekerCallValidator contract address
     * @return Address of the validator contract
     */
    function getCallValidator() external view returns (address) {
        return callValidator;
    }

    /**
     * @notice Check if an address is an admin (for validator)
     * @param user Address to check
     * @return True if user is admin
     */
    function isAdmin(address user) external view returns (bool) {
        return hasRole(REGISTRY_ADMIN_ROLE, user);
    }

    // ============ OPERATOR MANAGEMENT ============

    /**
     * @notice Check if an address is an authorized operator
     * @param operator Address to check
     * @return True if operator is authorized
     */
    function isAuthorizedOperator(address operator) external view returns (bool) {
        return hasRole(OPERATOR_ROLE, operator);
    }

    // ============ PAUSE CONTROL ============

    /**
     * @notice Pause the system
     */
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause the system
     */
    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    // ============ VAULT MANAGEMENT ============

    /**
     * @notice Approve a vault contract
     * @param vault Address of vault to approve
     */
    function approveVault(address vault) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (isApprovedVault[vault]) revert AlreadyApproved();
        isApprovedVault[vault] = true;
        approvedVaults.push(vault);
        emit VaultApproved(vault);
    }

    /**
     * @notice Remove a vault contract
     * @param vault Address of vault to remove
     */
    function removeVault(address vault) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (!isApprovedVault[vault]) revert NotApproved();
        isApprovedVault[vault] = false;
        emit VaultRemoved(vault);
    }

    /**
     * @notice Get all approved vaults
     * @return Array of approved vault addresses
     */
    function getApprovedVaults() external view returns (address[] memory) {
        return approvedVaults;
    }

    // ============ SWAP PROVIDER MANAGEMENT ============

    /**
     * @notice Approve a swap provider contract
     * @param swapProvider Address of swap provider to approve
     */
    function approveSwapProvider(address swapProvider) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (isApprovedSwapProvider[swapProvider]) revert AlreadyApproved();
        isApprovedSwapProvider[swapProvider] = true;
        approvedSwapProviders.push(swapProvider);
        emit SwapProviderApproved(swapProvider);
    }

    /**
     * @notice Remove a swap provider contract
     * @param swapProvider Address of swap provider to remove
     */
    function removeSwapProvider(address swapProvider) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (!isApprovedSwapProvider[swapProvider]) revert NotApproved();
        isApprovedSwapProvider[swapProvider] = false;
        emit SwapProviderRemoved(swapProvider);
    }

    /**
     * @notice Get all approved swap providers
     * @return Array of approved swap provider addresses
     */
    function getApprovedSwapProviders() external view returns (address[] memory) {
        return approvedSwapProviders;
    }

    // ============ ADAPTER MANAGEMENT ============

    /**
     * @notice Approve an adapter contract
     * @param adapter Address of adapter to approve
     * @dev Adapters are secure wrappers that enforce security constraints
     */
    function approveAdapter(address adapter) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (isApprovedAdapter[adapter]) revert AlreadyApproved();
        isApprovedAdapter[adapter] = true;
        approvedAdapters.push(adapter);
        emit AdapterApproved(adapter);
    }

    /**
     * @notice Remove an adapter contract
     * @param adapter Address of adapter to remove
     */
    function removeAdapter(address adapter) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (!isApprovedAdapter[adapter]) revert NotApproved();
        isApprovedAdapter[adapter] = false;
        emit AdapterRemoved(adapter);
    }

    /**
     * @notice Get all approved adapters
     * @return Array of approved adapter addresses
     */
    function getApprovedAdapters() external view returns (address[] memory) {
        return approvedAdapters;
    }

    // ============ QUERY HELPERS ============

    /**
     * @notice Check if a contract is approved (vault, swap provider, or adapter)
     * @param target Contract address to check
     * @return isApproved True if approved as vault, swap provider, or adapter
     */
    function isContractApproved(address target) external view returns (bool) {
        return isApprovedVault[target] || isApprovedSwapProvider[target] || isApprovedAdapter[target];
    }
}
