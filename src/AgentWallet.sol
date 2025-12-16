// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {YieldSeekerActionRegistry as ActionRegistry} from "./ActionRegistry.sol";
import {YieldSeekerAgentWalletStorageV1 as AgentWalletStorageV1} from "./AgentWalletStorage.sol";
import {BaseAccount} from "./erc4337/BaseAccount.sol";
import {IEntryPoint} from "./erc4337/IEntryPoint.sol";
import {UserOperation} from "./erc4337/UserOperation.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IAgentWalletFactory {
    function agentWalletImplementation() external view returns (address);
    function actionRegistry() external view returns (ActionRegistry);
}

/**
 * @title YieldSeekerAgentWallet
 * @notice ERC-4337 v0.6 smart wallet for yield-seeking agents.
 * @dev Implements:
 *      - ERC-4337 v0.6 Account (BaseAccount)
 *      - Single owner ECDSA validation
 *      - UUPS Upgradeability
 *      - ERC-7201 namespaced storage
 *      - "Onchain Proof" enforcement (executeViaAdapter only)
 */
contract YieldSeekerAgentWallet is BaseAccount, Initializable, UUPSUpgradeable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    IEntryPoint private immutable _ENTRY_POINT;
    address public immutable FACTORY;

    event AgentWalletInitialized(IEntryPoint indexed entryPoint, address indexed owner);
    event ExecutedViaAdapter(address indexed adapter, bytes data, bytes result);
    event WithdrewTokenToUser(address indexed owner, address indexed recipient, address indexed token, uint256 amount);
    event WithdrewEthToUser(address indexed owner, address indexed recipient, uint256 amount);

    error AdapterNotRegistered(address adapter);
    error AdapterExecutionFailed(bytes reason);
    error NotAllowed();
    error InvalidAddress();
    error InsufficientBalance();
    error TransferFailed();
    error NotApprovedImplementation();

    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    constructor(IEntryPoint anEntryPoint, address factory) {
        _ENTRY_POINT = anEntryPoint;
        FACTORY = factory;
        _disableInitializers();
    }

    receive() external payable {}

    // ============ Initializers ============

    function initialize(address anOwner, ActionRegistry actionRegistry_) public virtual initializer {
        AgentWalletStorageV1.Layout storage $ = AgentWalletStorageV1.layout();
        $.owner = anOwner;
        $.actionRegistry = actionRegistry_;
        emit AgentWalletInitialized(_ENTRY_POINT, anOwner);
    }

    // ============ Storage Accessors ============

    /**
     * @notice Get the owner of this wallet
     * @return Owner address
     */
    function owner() public view returns (address) {
        return AgentWalletStorageV1.layout().owner;
    }

    /**
     * @notice Get the action registry
     * @return ActionRegistry instance
     */
    function actionRegistry() public view returns (ActionRegistry) {
        return AgentWalletStorageV1.layout().actionRegistry;
    }

    // ============ ERC-4337 / BaseAccount Overrides ============

    function entryPoint() public view virtual override returns (IEntryPoint) {
        return _ENTRY_POINT;
    }

    function _validateSignature(UserOperation calldata userOp, bytes32 userOpHash) internal virtual override returns (uint256 validationData) {
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        address signer = hash.recover(userOp.signature);

        // Allow either the owner or the centralized yieldSeekerServer to sign
        if (signer == owner()) {
            return 0;
        }

        address authorizedServer = actionRegistry().yieldSeekerServer();
        if (authorizedServer != address(0) && signer == authorizedServer) {
            return 0;
        }

        return SIG_VALIDATION_FAILED;
    }

    // ============ Access Control ============

    function _onlyOwner() internal view {
        require(msg.sender == owner() || msg.sender == address(this), "only owner");
    }

    function _requireFromEntryPointOrOwner() internal view {
        require(msg.sender == address(entryPoint()) || msg.sender == owner(), "account: not Owner or EntryPoint");
    }

    // ============ Execution (Direct - DISABLED) ============

    /**
     * @notice Standard execute disallowed to enforce authorized adapter usage
     */
    function execute(address, uint256, bytes calldata) external virtual {
        revert NotAllowed();
    }

    /**
     * @notice Standard executeBatch disallowed to enforce authorized adapter usage
     */
    function executeBatch(address[] calldata, bytes[] calldata) external virtual {
        revert NotAllowed();
    }

    // ============ Execution (Via Adapter) ============

    /**
     * @notice Internal helper to validate and execute adapter call
     */
    function _executeAdapterCall(address adapter, bytes calldata data) private returns (bytes memory result) {
        // 1. Peek: Extract target from first 32 bytes of data (after selector is handled by adapter)
        // Convention: Adapter functions MUST take `target` as the first argument.
        if (data.length < 36) revert InvalidAddress(); // 4 bytes selector + 32 bytes address

        // Skip selector (4 bytes) and decode first argument
        address target = abi.decode(data[4:], (address));

        // 2. Verify: Check Registry
        (bool valid, address expectedAdapter) = actionRegistry().isValidTarget(target);
        if (!valid || expectedAdapter != adapter) {
            revert AdapterNotRegistered(adapter);
        }

        // 3. Execute
        bool success;
        (success, result) = adapter.delegatecall(data);
        if (!success) {
            revert AdapterExecutionFailed(result);
        }
        emit ExecutedViaAdapter(adapter, data, result);
    }

    /**
     * @notice Execute a call through a registered adapter via delegatecall
     */
    /**
     * @notice Execute a call through a registered adapter via delegatecall
     * @dev Implements "Peek and Verify" logic.
     */
    function executeViaAdapter(address adapter, bytes calldata data) external payable virtual returns (bytes memory result) {
        _requireFromEntryPointOrOwner();
        return _executeAdapterCall(adapter, data);
    }

    /**
     * @notice Execute multiple adapter calls in a batch
     */
    function executeViaAdapterBatch(address[] calldata adapters, bytes[] calldata datas) external payable virtual returns (bytes[] memory results) {
        _requireFromEntryPointOrOwner();
        uint256 length = adapters.length;
        if (length != datas.length) revert InvalidAddress();

        results = new bytes[](length);
        for (uint256 i; i < length; ++i) {
            results[i] = _executeAdapterCall(adapters[i], datas[i]);
        }
    }

    // ============ UUPS Upgradeability ============

    /**
     * @notice Upgrade to latest approved implementation from factory and sync registry
     */
    function upgradeToLatest() external onlyOwner {
        IAgentWalletFactory factory = IAgentWalletFactory(FACTORY);
        address latest = factory.agentWalletImplementation();

        // Sync registry reference from factory
        AgentWalletStorageV1.Layout storage $ = AgentWalletStorageV1.layout();
        $.actionRegistry = factory.actionRegistry();

        upgradeToAndCall(latest, "");
    }

    function _authorizeUpgrade(address newImplementation) internal view override {
        address currentImpl = IAgentWalletFactory(FACTORY).agentWalletImplementation();
        if (newImplementation != currentImpl) {
            revert NotApprovedImplementation();
        }
        _onlyOwner();
    }

    // ============ USER WITHDRAWAL FUNCTIONS ============

    /**
     * @notice User withdraws ERC20 token from agent wallet
     * @param token Address of the token to withdraw
     * @param recipient Address to send the token to
     * @param amount Amount to withdraw
     */
    function withdrawTokenToUser(address token, address recipient, uint256 amount) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        IERC20 asset = IERC20(token);
        uint256 balance = asset.balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();
        _withdrawToken(asset, recipient, amount);
    }

    /**
     * @notice User withdraws all of an ERC20 token from agent wallet
     * @param token Address of the token to withdraw
     * @param recipient Address to send the token to
     */
    function withdrawAllTokenToUser(address token, address recipient) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        IERC20 asset = IERC20(token);
        uint256 balance = asset.balanceOf(address(this));
        _withdrawToken(asset, recipient, balance);
    }

    /**
     * @notice User withdraws ETH from agent wallet
     * @param recipient Address to send the ETH to
     * @param amount Amount of ETH to withdraw
     */
    function withdrawEthToUser(address recipient, uint256 amount) external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance < amount) revert InsufficientBalance();
        _withdrawEth(recipient, amount);
    }

    /**
     * @notice User withdraws all ETH from agent wallet
     * @param recipient Address to send the ETH to
     */
    function withdrawAllEthToUser(address recipient) external onlyOwner {
        uint256 balance = address(this).balance;
        _withdrawEth(recipient, balance);
    }

    /**
     * @notice Internal function to withdraw ERC20 token
     * @param asset Token contract
     * @param recipient Address to send the token to
     * @param amount Amount to withdraw
     */
    function _withdrawToken(IERC20 asset, address recipient, uint256 amount) internal {
        if (recipient == address(0)) revert InvalidAddress();
        asset.safeTransfer(recipient, amount);
        emit WithdrewTokenToUser(owner(), recipient, address(asset), amount);
    }

    /**
     * @notice Internal function to withdraw ETH
     * @param recipient Address to send the ETH to
     * @param amount Amount of ETH to withdraw
     */
    function _withdrawEth(address recipient, uint256 amount) internal {
        if (recipient == address(0)) revert InvalidAddress();
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        emit WithdrewEthToUser(owner(), recipient, amount);
    }
}
