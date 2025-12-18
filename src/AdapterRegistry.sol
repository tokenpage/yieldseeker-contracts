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

    function getAllTargets() external view returns (address[] memory) {
        return _targetToAdapter.keys();
    }
}
