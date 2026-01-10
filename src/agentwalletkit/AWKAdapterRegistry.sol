// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKErrors} from "./AWKErrors.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

error TargetNotRegistered(address target);

contract AWKAdapterRegistry is AccessControl, Pausable {
    using EnumerableMap for EnumerableMap.AddressToAddressMap;

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    EnumerableMap.AddressToAddressMap private _targetToAdapter;
    mapping(address adapter => bool registered) public isRegisteredAdapter;

    event AdapterRegistered(address indexed adapter);
    event AdapterUnregistered(address indexed adapter);
    event TargetRegistered(address indexed target, address indexed adapter);
    event TargetRemoved(address indexed target, address indexed previousAdapter);

    /// @param admin Address of the admin (gets admin roles for dangerous operations)
    /// @param emergencyAdmin Address that can perform emergency operations (pause, remove targets)
    constructor(address admin, address emergencyAdmin) {
        if (admin == address(0)) revert AWKErrors.ZeroAddress();
        if (emergencyAdmin == address(0)) revert AWKErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, emergencyAdmin);
    }

    /// @notice Pause all registry lookups (emergency only)
    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    /// @notice Unpause registry lookups (admin only)
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Register a new adapter
     * @param adapter The adapter address to register
     * @dev This allows the adapter to be used with previously configured targets.
     *
     * Important: If this adapter address was previously unregistered, re-registering it
     * will REACTIVATE all previous target→adapter mappings that were configured before
     * the unregistration. This is by design for gas efficiency, but means re-registration
     * should be done carefully, considering what targets this adapter was previously mapped to.
     */
    function registerAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adapter == address(0)) revert AWKErrors.ZeroAddress();
        if (adapter.code.length == 0) revert AWKErrors.NotAContract(adapter);
        isRegisteredAdapter[adapter] = true;
        emit AdapterRegistered(adapter);
    }

    /**
     * @notice Set the adapter for a target contract
     * @param target The target contract address (e.g., a vault)
     * @param adapter The adapter to use for this target
     * @dev If target already has a different adapter, emits TargetRemoved then TargetRegistered
     */
    function setTargetAdapter(address target, address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (target == address(0)) revert AWKErrors.ZeroAddress();
        if (!isRegisteredAdapter[adapter]) revert AWKErrors.AdapterNotRegistered(adapter);
        (bool exists, address previousAdapter) = _targetToAdapter.tryGet(target);
        if (exists) {
            if (previousAdapter != adapter) {
                _targetToAdapter.set(target, adapter);
                emit TargetRemoved(target, previousAdapter);
                emit TargetRegistered(target, adapter);
            }
        } else {
            _targetToAdapter.set(target, adapter);
            emit TargetRegistered(target, adapter);
        }
    }

    /**
     * @notice Remove a target from the registry
     * @param target The target address to remove
     * @dev Can be called by EMERGENCY_ROLE for quick removal of compromised targets
     */
    function removeTarget(address target) external onlyRole(EMERGENCY_ROLE) {
        (bool exists, address adapter) = _targetToAdapter.tryGet(target);
        if (!exists) revert TargetNotRegistered(target);
        _targetToAdapter.remove(target);
        emit TargetRemoved(target, adapter);
    }

    /**
     * @notice Unregister an adapter in case of emergency
     * @param adapter The adapter address to unregister
     * @dev This marks the adapter as unregistered, making getTargetAdapter() return address(0)
     *      for all targets mapped to this adapter. However, the underlying target→adapter mappings
     *      are NOT cleared from storage.
     *
     * Important behavior notes:
     * - Wallets immediately stop being able to use this adapter (safe)
     * - If the same adapter is re-registered later, ALL previous target mappings are reactivated
     * - This design prioritizes gas efficiency and emergency response speed
     * - To permanently remove specific targets, use removeTarget() after unregistering
     *
     * This is intentional behavior: unregister is for quick emergency shutdowns,
     * not permanent removal. Re-registration requires explicit admin action anyway.
     */
    function unregisterAdapter(address adapter) external onlyRole(EMERGENCY_ROLE) {
        if (!isRegisteredAdapter[adapter]) revert AWKErrors.AdapterNotRegistered(adapter);
        isRegisteredAdapter[adapter] = false;
        emit AdapterUnregistered(adapter);
    }

    /**
     * @notice Get the adapter for a target contract
     * @param target The target contract address
     * @return The adapter address, or address(0) if not registered or adapter is unregistered
     * @dev Reverts when paused (via whenNotPaused modifier) to ensure clear failure when registry is disabled
     */
    function getTargetAdapter(address target) external view whenNotPaused returns (address) {
        (bool exists, address adapter) = _targetToAdapter.tryGet(target);
        return (exists && isRegisteredAdapter[adapter]) ? adapter : address(0);
    }

    /**
     * @notice Get all targets that are currently mapped to registered adapters
     * @return An array of active target addresses
     */
    function getAllTargets() external view returns (address[] memory) {
        uint256 total = _targetToAdapter.length();
        uint256 activeCount = 0;

        // First pass to count active targets
        for (uint256 i = 0; i < total; i++) {
            (, address adapter) = _targetToAdapter.at(i);
            if (isRegisteredAdapter[adapter]) {
                activeCount++;
            }
        }

        // Second pass to populate the result array
        address[] memory activeTargets = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < total; i++) {
            (address target, address adapter) = _targetToAdapter.at(i);
            if (isRegisteredAdapter[adapter]) {
                activeTargets[index] = target;
                index++;
            }
        }
        return activeTargets;
    }
}
