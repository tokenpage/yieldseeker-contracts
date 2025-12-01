// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import "../interfaces/IPolicyValidator.sol";

/**
 * @title AgentActionPolicy
 * @notice The "Brain" logic contract.
 * @dev Defines exactly what actions are allowed.
 *      - Maps (Target, Selector) -> Validator
 *      - Can be swapped out globally by updating the AgentActionRouter.
 */
contract AgentActionPolicy is AccessControl {
    bytes32 public constant POLICY_SETTER_ROLE = keccak256("POLICY_SETTER_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // target contract -> function selector -> validator
    mapping(address => mapping(bytes4 => address)) public functionValidators;

    event PolicyAdded(address indexed target, bytes4 indexed selector, address validator);
    event PolicyRemoved(address indexed target, bytes4 indexed selector);

    constructor(address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(POLICY_SETTER_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
    }

    // ============ Admin (Timelocked) ============

    /**
     * @notice Add or update a policy rule (should go through timelock)
     * @param target The target contract address
     * @param selector The function selector
     * @param validator The validator address (address(1) for allow-all, or validator contract)
     */
    function addPolicy(address target, bytes4 selector, address validator) external onlyRole(POLICY_SETTER_ROLE) {
        require(validator != address(0), "Policy: use removePolicy to remove");
        functionValidators[target][selector] = validator;
        emit PolicyAdded(target, selector, validator);
    }

    // ============ Emergency (Instant) ============

    /**
     * @notice Remove a policy rule immediately (for emergencies)
     * @dev This bypasses timelock for fast response to discovered vulnerabilities
     */
    function removePolicy(address target, bytes4 selector) external onlyRole(EMERGENCY_ROLE) {
        functionValidators[target][selector] = address(0);
        emit PolicyRemoved(target, selector);
    }

    // ============ Validation ============

    function validateAction(address wallet, address target, uint256 value, bytes calldata data) external view {
        // Extract function selector
        bytes4 selector;
        if (data.length >= 4) {
            selector = bytes4(data[0:4]);
        } else {
            selector = bytes4(0); // Fallback/Receive
        }

        address validator = functionValidators[target][selector];
        require(validator != address(0), "Policy: action not allowed");

        // Parameter Validation
        if (validator == address(1)) {
            // Allowed without parameter checks
            return;
        } else {
            // Call external validator
            bool isValid = IPolicyValidator(validator).validateAction(wallet, target, selector, data);
            require(isValid, "Policy: validation failed");
        }
    }
}
