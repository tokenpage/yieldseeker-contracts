// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title ActionRegistry
 * @notice Central registry that maps external targets to their action adapters
 * @dev This is the single source of truth for what targets can be interacted with
 *      and which adapter handles each target.
 *
 *      Architecture:
 *      - Each protocol interface (ERC4626, Aave, etc.) has one adapter deployment
 *      - Multiple targets (vaults, pools) can point to the same adapter
 *      - Router checks this registry before delegatecalling adapters
 *
 *      Example registrations:
 *      - Morpho USDC vault (0x123) → ERC4626Adapter (0xAAA)
 *      - Yearn USDC vault (0x456) → ERC4626Adapter (0xAAA)
 *      - Aave USDC pool (0x789) → AaveV3Adapter (0xBBB)
 *      - 0x Exchange Proxy (0xDEF) → SwapAdapter (0xCCC)
 *      - Merkl Distributor (0x999) → MerklAdapter (0xDDD)
 *
 *      Security model:
 *      - REGISTRY_ADMIN_ROLE can add new targets (should be timelocked)
 *      - EMERGENCY_ROLE can remove targets immediately
 *      - Only registered adapters can be delegatecalled
 *      - Adapters are stateless - all state is in target contracts
 */
contract ActionRegistry is AccessControl {
    bytes32 public constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /// @notice Maps external target address → adapter that handles it
    /// @dev e.g., morphoVault → ERC4626Adapter, 0xRouter → SwapAdapter
    mapping(address target => address adapter) public targetToAdapter;

    /// @notice Set of registered adapters (for router to verify)
    mapping(address adapter => bool registered) public isRegisteredAdapter;

    /// @notice List of all registered targets (for enumeration)
    address[] public registeredTargets;

    /// @notice Index of target in registeredTargets array (for efficient removal)
    mapping(address target => uint256 index) private _targetIndex;

    event TargetRegistered(address indexed target, address indexed adapter);
    event TargetRemoved(address indexed target, address indexed previousAdapter);
    event AdapterRegistered(address indexed adapter);
    event AdapterUnregistered(address indexed adapter);


    error TargetNotRegistered(address target);
    error TargetAlreadyRegistered(address target);
    error AdapterNotRegistered(address adapter);
    error ZeroAddress();

    constructor(address _admin) {
        if (_admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(REGISTRY_ADMIN_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
    }

    // ============ Admin Functions (Timelocked) ============

    /**
     * @notice Register a new adapter
     * @param adapter Address of the adapter contract
     * @dev Should be called through timelock. Admin is responsible for verifying
     *      the adapter is a valid, audited contract before registration.
     */
    function registerAdapter(address adapter) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (adapter == address(0)) revert ZeroAddress();
        isRegisteredAdapter[adapter] = true;
        emit AdapterRegistered(adapter);
    }

    /**
     * @notice Register a target to use a specific adapter
     * @param target Address of the external contract (vault, router, etc.)
     * @param adapter Address of the adapter that handles this target
     * @dev Should be called through timelock. Adapter must already be registered.
     *
     *      Examples:
     *      - registerTarget(MORPHO_USDC_VAULT, ERC4626_ADAPTER)
     *      - registerTarget(ZEROX_EXCHANGE_PROXY, SWAP_ADAPTER)
     *      - registerTarget(MERKL_DISTRIBUTOR, MERKL_ADAPTER)
     */
    function registerTarget(address target, address adapter) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (target == address(0)) revert ZeroAddress();
        if (!isRegisteredAdapter[adapter]) revert AdapterNotRegistered(adapter);
        if (targetToAdapter[target] != address(0)) revert TargetAlreadyRegistered(target);
        targetToAdapter[target] = adapter;
        _targetIndex[target] = registeredTargets.length;
        registeredTargets.push(target);
        emit TargetRegistered(target, adapter);
    }

    /**
     * @notice Update the adapter for an existing target
     * @param target Address of the external contract
     * @param newAdapter Address of the new adapter
     * @dev Useful when upgrading adapters without removing targets.
     */
    function updateTargetAdapter(address target, address newAdapter) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (targetToAdapter[target] == address(0)) revert TargetNotRegistered(target);
        if (!isRegisteredAdapter[newAdapter]) revert AdapterNotRegistered(newAdapter);
        address previousAdapter = targetToAdapter[target];
        targetToAdapter[target] = newAdapter;
        emit TargetRemoved(target, previousAdapter);
        emit TargetRegistered(target, newAdapter);
    }

    // ============ Emergency Functions (Instant) ============

    /**
     * @notice Remove a target immediately (for emergencies)
     * @param target Address of the compromised target
     * @dev Bypasses timelock for fast response to exploits.
     */
    function removeTarget(address target) external onlyRole(EMERGENCY_ROLE) {
        address adapter = targetToAdapter[target];
        if (adapter == address(0)) revert TargetNotRegistered(target);
        delete targetToAdapter[target];
        uint256 index = _targetIndex[target];
        uint256 lastIndex = registeredTargets.length - 1;
        if (index != lastIndex) {
            address lastTarget = registeredTargets[lastIndex];
            registeredTargets[index] = lastTarget;
            _targetIndex[lastTarget] = index;
        }
        registeredTargets.pop();
        delete _targetIndex[target];
        emit TargetRemoved(target, adapter);
    }

    /**
     * @notice Unregister an adapter immediately
     * @param adapter Address of the compromised adapter
     * @dev Does NOT automatically remove targets using this adapter.
     *      Those targets will fail validation until reassigned.
     */
    function unregisterAdapter(address adapter) external onlyRole(EMERGENCY_ROLE) {
        if (!isRegisteredAdapter[adapter]) revert AdapterNotRegistered(adapter);
        isRegisteredAdapter[adapter] = false;
        emit AdapterUnregistered(adapter);
    }

    // ============ View Functions ============

    /**
     * @notice Get the adapter for a target
     * @param target Address of the external contract
     * @return adapter Address of the adapter, or address(0) if not registered
     */
    function getAdapter(address target) external view returns (address adapter) {
        return targetToAdapter[target];
    }

    /**
     * @notice Check if a target is registered and its adapter is valid
     * @param target Address to check
     * @return valid True if target has a registered, valid adapter
     * @return adapter The adapter address (or zero if not valid)
     */
    function isValidTarget(address target) external view returns (bool valid, address adapter) {
        adapter = targetToAdapter[target];
        valid = adapter != address(0) && isRegisteredAdapter[adapter];
    }

    /**
     * @notice Get all registered targets
     * @return Array of all target addresses
     */
    function getAllTargets() external view returns (address[] memory) {
        return registeredTargets;
    }

    /**
     * @notice Get the number of registered targets
     */
    function getTargetCount() external view returns (uint256) {
        return registeredTargets.length;
    }
}
