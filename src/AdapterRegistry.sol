// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

contract YieldSeekerAdapterRegistry is AccessControl, Pausable {
    using EnumerableMap for EnumerableMap.AddressToAddressMap;

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    EnumerableMap.AddressToAddressMap private _targetToAdapter;
    mapping(address adapter => bool registered) public isRegisteredAdapter;

    event AdapterRegistered(address indexed adapter);
    event AdapterUnregistered(address indexed adapter);
    event TargetRegistered(address indexed target, address indexed adapter);
    event TargetRemoved(address indexed target, address indexed previousAdapter);

    error ZeroAddress();
    error AdapterNotRegistered(address adapter);
    error TargetNotRegistered(address target);
    error NotAContract(address adapter);

    /// @param admin Address of the admin (gets admin roles for dangerous operations)
    /// @param emergencyAdmin Address that can perform emergency operations (pause, remove targets)
    constructor(address admin, address emergencyAdmin) {
        if (admin == address(0)) revert ZeroAddress();
        if (emergencyAdmin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, emergencyAdmin);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function registerAdapter(address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (adapter == address(0)) revert ZeroAddress();
        if (adapter.code.length == 0) revert NotAContract(adapter);
        isRegisteredAdapter[adapter] = true;
        emit AdapterRegistered(adapter);
    }

    function setTargetAdapter(address target, address adapter) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (target == address(0)) revert ZeroAddress();
        if (!isRegisteredAdapter[adapter]) revert AdapterNotRegistered(adapter);
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

    function removeTarget(address target) external onlyRole(EMERGENCY_ROLE) {
        (bool exists, address adapter) = _targetToAdapter.tryGet(target);
        if (!exists) revert TargetNotRegistered(target);
        _targetToAdapter.remove(target);
        emit TargetRemoved(target, adapter);
    }

    function unregisterAdapter(address adapter) external onlyRole(EMERGENCY_ROLE) {
        if (!isRegisteredAdapter[adapter]) revert AdapterNotRegistered(adapter);
        isRegisteredAdapter[adapter] = false;
        emit AdapterUnregistered(adapter);
    }

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
