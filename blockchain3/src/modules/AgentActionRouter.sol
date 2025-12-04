// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC7579Module, IERC7579Execution, Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {ERC7579Utils, CallType, ExecType, Mode, ModeSelector, ModePayload} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

interface IActionRegistry {
    function isValidTarget(address target) external view returns (bool valid, address adapter);
    function isRegisteredAdapter(address adapter) external view returns (bool);
}

interface IERC7579ModuleConfig {
    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata additionalContext) external view returns (bool);
}

/**
 * @title AgentActionRouter
 * @notice The "Executor Module" installed on every Agent Wallet.
 * @dev This router enables operators to execute validated actions on wallets.
 *
 *      Architecture:
 *      - Installed on wallets as an ERC-7579 Executor module
 *      - Uses ActionRegistry to validate targets and get adapters
 *      - Executes via DELEGATECALL to adapters (adapter code runs in wallet context)
 *
 *      Execution Flow:
 *      1. Operator calls executeAdapterAction(wallet, adapter, actionData)
 *      2. Router checks adapter is registered in ActionRegistry
 *      3. Router tells wallet to DELEGATECALL the adapter
 *      4. Adapter code runs in wallet context (address(this) = wallet)
 *      5. Adapter validates target is registered for this adapter
 *      6. Adapter executes the actual protocol call
 *
 *      Why DELEGATECALL?
 *      - Adapter code runs AS the wallet
 *      - approve() + deposit() happen in single context
 *      - No intermediate token transfers needed
 *      - More gas efficient
 *
 *      Security:
 *      - Only registered adapters can be called
 *      - Each adapter validates its own targets
 *      - Operators can only do what adapters allow
 *      - Emergency role can remove operators instantly
 */
contract AgentActionRouter is IERC7579Module, AccessControl {
    bytes32 public constant REGISTRY_ADMIN_ROLE = keccak256("REGISTRY_ADMIN_ROLE");
    bytes32 public constant OPERATOR_ADMIN_ROLE = keccak256("OPERATOR_ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /// @notice The ActionRegistry that maps targets to adapters
    IActionRegistry public registry;

    /// @notice Authorized backend operators
    mapping(address => bool) public operators;

    event RegistryUpdated(address indexed newRegistry);
    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);
    event AdapterActionExecuted(address indexed wallet, address indexed adapter, bytes4 selector);
    event BatchAdapterActionsExecuted(address indexed wallet, uint256 actionCount);

    error AdapterNotRegistered(address adapter);
    error EmptyBatch();
    error BatchTooLarge();
    error ZeroAddress();

    uint256 public constant MAX_BATCH_SIZE = 20;

    modifier onlyOperatorOrWallet(address wallet) {
        bool isOperator = operators[msg.sender];
        bool isWalletCall = msg.sender == wallet && IERC7579ModuleConfig(wallet).isModuleInstalled(2, address(this), "");
        require(isOperator || isWalletCall, "Router: not authorized");
        _;
    }

    constructor(address _registry, address _admin) {
        if (_registry == address(0) || _admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(REGISTRY_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ADMIN_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        registry = IActionRegistry(_registry);
    }

    // ============ Admin (Timelocked) ============

    /**
     * @notice Update the registry contract (should go through timelock)
     */
    function setRegistry(address _registry) external onlyRole(REGISTRY_ADMIN_ROLE) {
        if (_registry == address(0)) revert ZeroAddress();
        registry = IActionRegistry(_registry);
        emit RegistryUpdated(_registry);
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

    // ============ Adapter Execution (DELEGATECALL) ============

    /**
     * @notice Execute an action via a registered adapter using DELEGATECALL
     * @param wallet The wallet to execute on
     * @param adapter The adapter contract to delegatecall
     * @param actionData Encoded function call for the adapter (e.g., deposit(vault, amount))
     * @dev The adapter code runs in the wallet's context:
     *      - address(this) inside adapter = wallet address
     *      - Storage/balance operations happen on wallet
     *      - Adapter must be registered in ActionRegistry
     *
     *      Example: To deposit into an ERC4626 vault:
     *      - adapter = ERC4626Adapter address
     *      - actionData = abi.encodeCall(ERC4626Adapter.deposit, (vaultAddress, amount))
     */
    function executeAdapterAction(
        address wallet,
        address adapter,
        bytes calldata actionData
    ) external onlyOperatorOrWallet(wallet) {
        if (!registry.isRegisteredAdapter(adapter)) {
            revert AdapterNotRegistered(adapter);
        }
        Mode mode = ERC7579Utils.encodeMode(
            ERC7579Utils.CALLTYPE_DELEGATECALL,
            ERC7579Utils.EXECTYPE_DEFAULT,
            ModeSelector.wrap(bytes4(0)),
            ModePayload.wrap(bytes22(0))
        );
        bytes memory executionCalldata = ERC7579Utils.encodeDelegate(adapter, actionData);
        IERC7579Execution(wallet).executeFromExecutor(Mode.unwrap(mode), executionCalldata);
        emit AdapterActionExecuted(wallet, adapter, bytes4(actionData));
    }

    /**
     * @notice Execute multiple adapter actions in a single batch
     * @param wallet The wallet to execute on
     * @param adapters Array of adapter addresses
     * @param actionDatas Array of encoded function calls
     * @dev All adapters must be registered. Uses batch delegatecall mode.
     */
    function executeAdapterActions(
        address wallet,
        address[] calldata adapters,
        bytes[] calldata actionDatas
    ) external onlyOperatorOrWallet(wallet) {
        uint256 length = adapters.length;
        if (length == 0) revert EmptyBatch();
        if (length > MAX_BATCH_SIZE) revert BatchTooLarge();
        require(length == actionDatas.length, "Router: length mismatch");
        Execution[] memory executions = new Execution[](length);
        for (uint256 i = 0; i < length; ++i) {
            if (!registry.isRegisteredAdapter(adapters[i])) {
                revert AdapterNotRegistered(adapters[i]);
            }
            executions[i] = Execution({
                target: adapters[i],
                value: 0,
                callData: actionDatas[i]
            });
        }
        bytes memory executionCalldata = ERC7579Utils.encodeBatch(executions);
        Mode mode = ERC7579Utils.encodeMode(
            ERC7579Utils.CALLTYPE_DELEGATECALL,
            ERC7579Utils.EXECTYPE_DEFAULT,
            ModeSelector.wrap(bytes4(0)),
            ModePayload.wrap(bytes22(0))
        );
        IERC7579Execution(wallet).executeFromExecutor(Mode.unwrap(mode), executionCalldata);
        emit BatchAdapterActionsExecuted(wallet, length);
    }
}
