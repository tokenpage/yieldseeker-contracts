// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC7579Module, IERC7579Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

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
contract AgentActionRouter is IERC7579Module, Ownable {

    // The current "Brain" contract
    IAgentActionPolicy public policy;

    // Authorized backend operators
    mapping(address => bool) public operators;

    event PolicyUpdated(address indexed newPolicy);
    event OperatorSet(address indexed operator, bool status);
    event ActionExecuted(address indexed wallet, address indexed target, bytes4 selector);

    modifier onlyOperatorOrWallet(address wallet) {
        bool isOperator = operators[msg.sender] || msg.sender == owner();
        bool isWalletCall = msg.sender == wallet && IERC7579ModuleConfig(wallet).isModuleInstalled(2, address(this), "");
        require(isOperator || isWalletCall, "Router: not authorized");
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
    function executeAction(
        address wallet,
        address target,
        uint256 value,
        bytes calldata data
    ) external onlyOperatorOrWallet(wallet) {
        // 1. Delegate validation to the Policy contract
        //    This will revert if the action is not allowed
        policy.validateAction(wallet, target, value, data);

        // 2. Construct Execution Calldata for the Wallet
        //    Mode: Single Call (0x00...00)
        bytes memory executionCalldata = abi.encode(target, value, data);

        // 3. Execute
        IERC7579Execution(wallet).executeFromExecutor(bytes32(0), executionCalldata);

        emit ActionExecuted(wallet, target, bytes4(data));
    }
}
