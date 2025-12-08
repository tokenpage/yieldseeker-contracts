// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/access/AccessControl.sol";

contract ActionRegistry is AccessControl {
    bytes32 public constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    mapping(address target => address adapter) public targetToAdapter;
    mapping(address adapter => bool registered) public isRegisteredAdapter;
    address[] public registeredTargets;
    mapping(address target => uint256 index) private _targetIndex;
    bool public paused;

    event AdapterRegistered(address indexed adapter);
    event AdapterUnregistered(address indexed adapter);
    event TargetRegistered(address indexed target, address indexed adapter);
    event TargetRemoved(address indexed target, address indexed previousAdapter);
    event Paused(address indexed by);
    event Unpaused(address indexed by);

    error RegistryPaused();
    error ZeroAddress();
    error AdapterNotRegistered(address adapter);
    error TargetNotRegistered(address target);
    error TargetAlreadyRegistered(address target);

    modifier whenNotPaused() {
        if (paused) revert RegistryPaused();
        _;
    }

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(REGISTRY_ADMIN_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, admin);
    }

    function registerAdapter(address adapter) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (adapter == address(0)) revert ZeroAddress();
        isRegisteredAdapter[adapter] = true;
        emit AdapterRegistered(adapter);
    }

    function registerTarget(address target, address adapter) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (target == address(0)) revert ZeroAddress();
        if (!isRegisteredAdapter[adapter]) revert AdapterNotRegistered(adapter);
        if (targetToAdapter[target] != address(0)) revert TargetAlreadyRegistered(target);
        targetToAdapter[target] = adapter;
        _targetIndex[target] = registeredTargets.length;
        registeredTargets.push(target);
        emit TargetRegistered(target, adapter);
    }

    function updateTargetAdapter(address target, address newAdapter) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (targetToAdapter[target] == address(0)) revert TargetNotRegistered(target);
        if (!isRegisteredAdapter[newAdapter]) revert AdapterNotRegistered(newAdapter);
        address previousAdapter = targetToAdapter[target];
        targetToAdapter[target] = newAdapter;
        emit TargetRemoved(target, previousAdapter);
        emit TargetRegistered(target, newAdapter);
    }

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

    function unregisterAdapter(address adapter) external onlyRole(EMERGENCY_ROLE) {
        if (!isRegisteredAdapter[adapter]) revert AdapterNotRegistered(adapter);
        isRegisteredAdapter[adapter] = false;
        emit AdapterUnregistered(adapter);
    }

    function pause() external onlyRole(EMERGENCY_ROLE) {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyRole(REGISTRY_ADMIN_ROLE) {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function getAdapter(address target) external view returns (address) {
        return targetToAdapter[target];
    }

    function isValidTarget(address target) external view whenNotPaused returns (bool valid, address adapter) {
        adapter = targetToAdapter[target];
        valid = adapter != address(0) && isRegisteredAdapter[adapter];
    }

    function getAllTargets() external view returns (address[] memory) {
        return registeredTargets;
    }

    function getTargetCount() external view returns (uint256) {
        return registeredTargets.length;
    }
}
