// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IERC7579.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

interface IAgentActionPolicy {
    function validateAction(address wallet, address target, uint256 value, bytes calldata data) external view;
}

/**
 * @title AgentActionRouter
 * @notice The "Executor Module" installed on every Agent Wallet.
 * @dev Acts as a pointer to the current Policy contract.
 *      - Installed on the wallet as an Executor.
 *      - Backend calls executeAction() on THIS contract.
 *      - This contract checks the Policy.
 *      - If valid, it triggers execution on the wallet.
 *
 *      UPGRADE STRATEGY:
 *      - To change the logic for ALL users, simply call setPolicy() on this contract.
 *      - No need to touch the user wallets.
 */
contract AgentActionRouter is IExecutor, Ownable {

    // The current "Brain" contract
    IAgentActionPolicy public policy;

    // Authorized backend operators
    mapping(address => bool) public operators;

    event PolicyUpdated(address indexed newPolicy);
    event OperatorSet(address indexed operator, bool status);
    event ActionExecuted(address indexed wallet, address indexed target, bytes4 selector);

    modifier onlyOperator() {
        require(operators[msg.sender] || msg.sender == owner(), "Router: not operator");
        _;
    }

    constructor(address _initialPolicy) Ownable(msg.sender) {
        policy = IAgentActionPolicy(_initialPolicy);
    }

    // ============ Admin ============

    function setPolicy(address _policy) external onlyOwner {
        policy = IAgentActionPolicy(_policy);
        emit PolicyUpdated(_policy);
    }

    function setOperator(address operator, bool status) external onlyOwner {
        operators[operator] = status;
        emit OperatorSet(operator, status);
    }

    // ============ Module Interface ============

    function onInstall(bytes calldata) external payable override {}
    function onUninstall(bytes calldata) external payable override {}
    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == 2; // EXECUTOR
    }

    // ============ Execution ============

    /**
     * @notice Execute an action on a specific wallet
     * @dev The wallet MUST have this contract installed as an Executor.
     */
    function executeAction(
        address wallet,
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyOperator {
        // 1. Delegate validation to the Policy contract
        //    This will revert if the action is not allowed
        policy.validateAction(wallet, target, value, data);

        // 2. Construct Execution Calldata for the Wallet
        //    Mode: Single Call (0x00...00)
        bytes memory executionCalldata = abi.encode(target, value, data);

        // 3. Execute
        IERC7579Account(wallet).executeFromExecutor(bytes32(0), executionCalldata);

        emit ActionExecuted(wallet, target, bytes4(data));
    }
}
