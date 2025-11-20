// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IPolicyValidator.sol";

/**
 * @title AgentActionPolicy
 * @notice The "Brain" logic contract.
 * @dev Defines exactly what actions are allowed.
 *      - Maps (Target, Selector) -> Validator
 *      - Can be swapped out globally by updating the AgentActionRouter.
 */
contract AgentActionPolicy is Ownable {

    // target contract -> function selector -> validator
    mapping(address => mapping(bytes4 => address)) public functionValidators;

    // Global allowed targets (allow all functions)
    mapping(address => bool) public allowedTargets;

    event PolicySet(address target, bytes4 selector, address validator);
    event TargetAllowed(address target, bool status);

    constructor() Ownable(msg.sender) {}

    // ============ Admin ============

    function setPolicy(address target, bytes4 selector, address validator) external onlyOwner {
        functionValidators[target][selector] = validator;
        emit PolicySet(target, selector, validator);
    }

    function setTargetAllowed(address target, bool status) external onlyOwner {
        allowedTargets[target] = status;
        emit TargetAllowed(target, status);
    }

    // ============ Validation ============

    function validateAction(
        address wallet,
        address target,
        uint256 value,
        bytes calldata data
    ) external view {
        // Check 1: Is target allowed globally?
        if (allowedTargets[target]) return;

        // Check 2: Is function selector allowed?
        bytes4 selector;
        if (data.length >= 4) {
            selector = bytes4(data[0:4]);
        } else {
            selector = bytes4(0); // Fallback/Receive
        }

        address validator = functionValidators[target][selector];

        require(validator != address(0), "Policy: action not allowed");

        // Check 3: Parameter Validation
        if (validator == address(1)) {
            // Allowed without checks
            return;
        } else {
            // Call external validator
            bool isValid = IPolicyValidator(validator).validateAction(wallet, target, selector, data);
            require(isValid, "Policy: validation failed");
        }
    }
}
