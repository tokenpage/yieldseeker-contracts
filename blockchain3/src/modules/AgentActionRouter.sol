// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC7579Module, IERC7579Execution, Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {ERC7579Utils} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

interface IAgentActionPolicy {
    function validateAction(address wallet, address target, uint256 value, bytes calldata data) external view;
}

interface IERC7579ModuleConfig {
    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata additionalContext) external view returns (bool);
}

/**
 * @title AgentActionRouter
 * @notice The "Executor Module" installed on every Agent Wallet.
 * @dev Acts as a pointer to the current Policy contract.
 *      - Installed on the wallet as an Executor.
 *      - Can be called by operators directly OR via the wallet's execute() (ERC-4337 flow).
 *      - This contract checks the Policy.
 *      - If valid, it triggers execution on the wallet.
 *
 *      UPGRADE STRATEGY:
 *      - To change the logic for ALL users, simply call setPolicy() on this contract.
 *      - No need to touch the user wallets.
 */
contract AgentActionRouter is IERC7579Module, AccessControl {
    bytes32 public constant POLICY_ADMIN_ROLE = keccak256("POLICY_ADMIN_ROLE");
    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    // The current "Brain" contract
    IAgentActionPolicy public policy;

    // Authorized backend operators
    mapping(address => bool) public operators;

    event PolicyUpdated(address indexed newPolicy);
    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event ActionExecuted(address indexed wallet, address indexed target, bytes4 selector);
    event BatchExecuted(address indexed wallet, uint256 actionCount);

    error EmptyBatch();
    error BatchTooLarge();

    uint256 public constant MAX_BATCH_SIZE = 20;

    modifier onlyOperatorOrWallet(address wallet) {
        bool isOperator = operators[msg.sender];
        bool isWalletCall = msg.sender == wallet && IERC7579ModuleConfig(wallet).isModuleInstalled(2, address(this), "");
        require(isOperator || isWalletCall, "Router: not authorized");
        _;
    }

    constructor(address _initialPolicy, address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(POLICY_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ADMIN_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        policy = IAgentActionPolicy(_initialPolicy);
    }

    // ============ Admin (Timelocked) ============

    /**
     * @notice Update the policy contract (should go through timelock)
     */
    function setPolicy(address _policy) external onlyRole(POLICY_ADMIN_ROLE) {
        policy = IAgentActionPolicy(_policy);
        emit PolicyUpdated(_policy);
    }

    /**
     * @notice Add a new operator (should go through timelock)
     */
    function addOperator(address operator) external onlyRole(OPERATOR_ADMIN_ROLE) {
        operators[operator] = true;
        emit OperatorAdded(operator);
    }

    // ============ Emergency (Instant) ============

    /**
     * @notice Remove an operator immediately (for emergencies)
     * @dev This bypasses timelock for fast response to compromised keys
     */
    function removeOperator(address operator) external onlyRole(EMERGENCY_ROLE) {
        operators[operator] = false;
        emit OperatorRemoved(operator);
    }

    // ============ Module Interface ============

    function onInstall(bytes calldata) external override {}
    function onUninstall(bytes calldata) external override {}

    function isModuleType(uint256 moduleTypeId) external pure override returns (bool) {
        return moduleTypeId == 2; // EXECUTOR
    }

    // ============ Execution ============

    /**
     * @notice Execute an action on a specific wallet
     * @dev The wallet MUST have this contract installed as an Executor.
     */
    function executeAction(address wallet, address target, uint256 value, bytes calldata data) external onlyOperatorOrWallet(wallet) {
        policy.validateAction(wallet, target, value, data);
        bytes memory executionCalldata = ERC7579Utils.encodeSingle(target, value, data);
        bytes32 mode = _encodeSingleMode();
        IERC7579Execution(wallet).executeFromExecutor(mode, executionCalldata);
        emit ActionExecuted(wallet, target, bytes4(data));
    }

    /**
     * @notice Execute multiple actions on a specific wallet in a single batch
     * @dev All actions are validated against the policy before execution.
     *      Uses ERC-7579 batch execution mode.
     * @param wallet The wallet to execute actions on
     * @param executions Array of (target, value, callData) tuples
     */
    function executeActions(address wallet, Execution[] calldata executions) external onlyOperatorOrWallet(wallet) {
        uint256 length = executions.length;
        if (length == 0) revert EmptyBatch();
        if (length > MAX_BATCH_SIZE) revert BatchTooLarge();
        for (uint256 i = 0; i < length; ++i) {
            policy.validateAction(wallet, executions[i].target, executions[i].value, executions[i].callData);
        }
        bytes memory executionCalldata = ERC7579Utils.encodeBatch(executions);
        bytes32 mode = _encodeBatchMode();
        IERC7579Execution(wallet).executeFromExecutor(mode, executionCalldata);
        emit BatchExecuted(wallet, length);
    }

    /**
     * @notice Encode single call mode (0x00 callType, 0x00 execType)
     */
    function _encodeSingleMode() internal pure returns (bytes32) {
        return bytes32(0);
    }

    /**
     * @notice Encode batch call mode (0x01 callType, 0x00 execType)
     */
    function _encodeBatchMode() internal pure returns (bytes32) {
        return bytes32(uint256(1) << 248);
    }
}
