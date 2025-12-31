// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "./AdapterRegistry.sol";
import {YieldSeekerErrors} from "./Errors.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "./FeeTracker.sol";
import {IAgentWallet} from "./IAgentWallet.sol";
import {IAgentWalletFactory} from "./IAgentWalletFactory.sol";
import {IYieldSeekerAdapter} from "./adapters/IAdapter.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {BaseAccount} from "account-abstraction/core/BaseAccount.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";

/**
 * @title AgentWalletStorageV1
 * @notice Storage layout for AgentWallet V1 using ERC-7201 namespaced storage pattern
 * @dev Uses deterministic storage slot to avoid collisions with proxy storage and future versions
 */
library AgentWalletStorageV1 {
    /// @custom:storage-location erc7201:yieldseeker.agentwallet.storage.v1
    bytes32 private constant STORAGE_LOCATION = keccak256("yieldseeker.agentwallet.storage.v1");

    struct Layout {
        address owner;
        uint256 ownerAgentIndex;
        IERC20 baseAsset;
        AdapterRegistry adapterRegistry;
        FeeTracker feeTracker;
        address[] agentOperators;
        // NOTE(krishan711): keep a map for fast lookup
        mapping(address => bool) isAgentOperator;
        // User-level blocklists for sovereignty
        mapping(address => bool) blockedAdapters;
        mapping(address => bool) blockedTargets;
    }

    function layout() internal pure returns (Layout storage l) {
        bytes32 slot = STORAGE_LOCATION;
        assembly {
            l.slot := slot
        }
    }
}

/**
 * @title YieldSeekerAgentWalletV1
 * @notice ERC-4337 v0.6 smart wallet for yield-seeking agents.
 * @dev Implements:
 *      - ERC-4337 v0.6 Account (BaseAccount)
 *      - Single owner ECDSA validation
 *      - UUPS Upgradeability
 *      - ERC-7201 namespaced storage
 *      - "Onchain Proof" enforcement (executeViaAdapter only)
 */
contract YieldSeekerAgentWalletV1 is IAgentWallet, BaseAccount, Initializable, UUPSUpgradeable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    // ERC-4337 v0.6 canonical EntryPoint address
    IEntryPoint private constant ENTRY_POINT = IEntryPoint(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789);
    IAgentWalletFactory public immutable FACTORY;

    event AgentWalletInitialized(IEntryPoint indexed entryPoint, address indexed owner);
    event WithdrewTokenToUser(address indexed owner, address indexed recipient, address indexed token, uint256 amount);
    event WithdrewEthToUser(address indexed owner, address indexed recipient, uint256 amount);
    event AdapterBlocked(address indexed adapter);
    event AdapterUnblocked(address indexed adapter);
    event TargetBlocked(address indexed target);
    event TargetUnblocked(address indexed target);
    event SyncedFromFactory(address indexed adapterRegistry, address indexed feeTracker);

    modifier onlyOwner() {
        if (msg.sender != owner()) revert YieldSeekerErrors.Unauthorized(msg.sender);
        _;
    }

    modifier onlySyncers() {
        if (msg.sender != owner() && !isAgentOperator(msg.sender)) revert YieldSeekerErrors.Unauthorized(msg.sender);
        _;
    }

    modifier onlyExecutors() {
        if (msg.sender != address(ENTRY_POINT) && msg.sender != owner() && !isAgentOperator(msg.sender)) {
            revert YieldSeekerErrors.Unauthorized(msg.sender);
        }
        _;
    }

    constructor(address factory) {
        FACTORY = IAgentWalletFactory(factory);
        _disableInitializers();
    }

    receive() external payable {}

    // ============ Initializers ============

    function initialize(address _owner, uint256 _ownerAgentIndex, address _baseAsset) public virtual initializer {
        _initializeV1(_owner, _ownerAgentIndex, _baseAsset);
    }

    function _initializeV1(address _owner, uint256 _ownerAgentIndex, address _baseAsset) internal {
        if (_owner == address(0)) revert YieldSeekerErrors.ZeroAddress();
        if (_baseAsset == address(0)) revert YieldSeekerErrors.ZeroAddress();
        if (_baseAsset.code.length == 0) revert YieldSeekerErrors.NotAContract(_baseAsset);
        AgentWalletStorageV1.Layout storage $ = AgentWalletStorageV1.layout();
        $.owner = _owner;
        $.ownerAgentIndex = _ownerAgentIndex;
        $.baseAsset = IERC20(_baseAsset);
        _syncFromFactory();
        emit AgentWalletInitialized(ENTRY_POINT, _owner);
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
     * @notice Get the owner agent index
     * @return Owner agent index
     */
    function ownerAgentIndex() public view returns (uint256) {
        return AgentWalletStorageV1.layout().ownerAgentIndex;
    }

    /**
     * @notice Get the base asset
     * @return Base asset token
     */
    function baseAsset() public view returns (IERC20) {
        return AgentWalletStorageV1.layout().baseAsset;
    }

    /**
     * @notice Get the adapter registry
     * @return AdapterRegistry instance
     */
    function adapterRegistry() public view returns (AdapterRegistry) {
        return AgentWalletStorageV1.layout().adapterRegistry;
    }

    /**
     * @notice Get the fee tracker
     * @return FeeTracker instance
     */
    function feeTracker() public view returns (FeeTracker) {
        return AgentWalletStorageV1.layout().feeTracker;
    }

    /**
     * @notice Get the list of agent operators (cached)
     */
    function listAgentOperators() public view returns (address[] memory) {
        return AgentWalletStorageV1.layout().agentOperators;
    }

    /**
     * @notice Check if an address is a cached agent operator
     * @param operator The address to check
     * @return True if the address is a cached operator
     */
    function isAgentOperator(address operator) public view returns (bool) {
        return AgentWalletStorageV1.layout().isAgentOperator[operator];
    }

    // ============ User Blocklist Management ============

    /**
     * @notice Block an adapter from being used by this wallet
     * @param adapter The adapter address to block
     * @dev Owner can block adapters even if they are globally approved.
     *      This provides user sovereignty over their agent's operations.
     */
    function blockAdapter(address adapter) external onlyOwner {
        AgentWalletStorageV1.layout().blockedAdapters[adapter] = true;
        emit AdapterBlocked(adapter);
    }

    /**
     * @notice Unblock a previously blocked adapter
     * @param adapter The adapter address to unblock
     */
    function unblockAdapter(address adapter) external onlyOwner {
        AgentWalletStorageV1.layout().blockedAdapters[adapter] = false;
        emit AdapterUnblocked(adapter);
    }

    /**
     * @notice Block a target from being interacted with by this wallet
     * @param target The target address to block
     * @dev Owner can block specific protocols/vaults even if globally approved.
     *      Example: Block a risky vault while keeping other vaults accessible.
     */
    function blockTarget(address target) external onlyOwner {
        AgentWalletStorageV1.layout().blockedTargets[target] = true;
        emit TargetBlocked(target);
    }

    /**
     * @notice Unblock a previously blocked target
     * @param target The target address to unblock
     */
    function unblockTarget(address target) external onlyOwner {
        AgentWalletStorageV1.layout().blockedTargets[target] = false;
        emit TargetUnblocked(target);
    }

    /**
     * @notice Check if an adapter is blocked by the owner
     * @param adapter The adapter address to check
     * @return True if the adapter is blocked
     */
    function isAdapterBlocked(address adapter) public view returns (bool) {
        return AgentWalletStorageV1.layout().blockedAdapters[adapter];
    }

    /**
     * @notice Check if a target is blocked by the owner
     * @param target The target address to check
     * @return True if the target is blocked
     */
    function isTargetBlocked(address target) public view returns (bool) {
        return AgentWalletStorageV1.layout().blockedTargets[target];
    }

    /**
     * @notice Refresh configuration from the factory
     */
    function syncFromFactory() external onlySyncers {
        _syncFromFactory();
    }

    /**
     * @notice Internal helper to sync configuration from the factory
     */
    function _syncFromFactory() internal {
        AgentWalletStorageV1.Layout storage $ = AgentWalletStorageV1.layout();

        // Clear old mapping
        uint256 oldLength = $.agentOperators.length;
        for (uint256 i = 0; i < oldLength; i++) {
            $.isAgentOperator[$.agentOperators[i]] = false;
        }

        // Update array and mapping
        $.agentOperators = FACTORY.listAgentOperators();
        uint256 newLength = $.agentOperators.length;
        for (uint256 i = 0; i < newLength; i++) {
            $.isAgentOperator[$.agentOperators[i]] = true;
        }

        AdapterRegistry newRegistry = FACTORY.adapterRegistry();
        if (address(newRegistry) == address(0)) revert YieldSeekerErrors.InvalidRegistry();
        if (address(newRegistry).code.length == 0) revert YieldSeekerErrors.InvalidRegistry();
        $.adapterRegistry = newRegistry;

        FeeTracker newTracker = FACTORY.feeTracker();
        if (address(newTracker) == address(0)) revert YieldSeekerErrors.InvalidFeeTracker();
        if (address(newTracker).code.length == 0) revert YieldSeekerErrors.InvalidFeeTracker();
        $.feeTracker = newTracker;

        emit SyncedFromFactory(address(newRegistry), address(newTracker));
    }

    // ============ ERC-4337 / BaseAccount Overrides ============

    /// @inheritdoc BaseAccount
    function entryPoint() public view virtual override returns (IEntryPoint) {
        return ENTRY_POINT;
    }

    function _validateSignature(UserOperation calldata userOp, bytes32 userOpHash) internal virtual override returns (uint256 validationData) {
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        address signer = hash.recover(userOp.signature);

        // Allow either the owner or the centralized yieldSeekerServer to sign
        if (signer == owner()) {
            return 0;
        }

        if (isAgentOperator(signer)) {
            return 0;
        }

        return SIG_VALIDATION_FAILED;
    }

    /**
     * @notice Standard execute disallowed to enforce authorized adapter usage
     */
    function execute(address, uint256, bytes calldata) external virtual {
        revert YieldSeekerErrors.NotAllowed();
    }

    /**
     * @notice Standard executeBatch disallowed to enforce authorized adapter usage
     */
    function executeBatch(address[] calldata, bytes[] calldata) external virtual {
        revert YieldSeekerErrors.NotAllowed();
    }

    // ============ Execution (Via Adapter) ============

    /**
     * @notice Internal helper to validate and execute adapter call
     * @dev Enforces the standard IYieldSeekerAdapter interface.
     *      Checks user blocklists first, then global registry validation.
     */
    function _executeAdapterCall(address adapter, address target, bytes calldata data) private returns (bytes memory result) {
        AgentWalletStorageV1.Layout storage $ = AgentWalletStorageV1.layout();

        // Check user-level blocklists first (owner sovereignty)
        if ($.blockedAdapters[adapter]) {
            revert YieldSeekerErrors.AdapterBlocked(adapter);
        }
        if ($.blockedTargets[target]) {
            revert YieldSeekerErrors.TargetBlocked(target);
        }

        // Then check global registry validation
        address registeredAdapter = adapterRegistry().getTargetAdapter(target);
        if (registeredAdapter == address(0) || registeredAdapter != adapter) {
            revert YieldSeekerErrors.AdapterNotRegistered(adapter);
        }

        bytes memory callData = abi.encodeWithSelector(IYieldSeekerAdapter.execute.selector, target, data);
        bool success;
        (success, result) = adapter.delegatecall(callData);
        if (!success) {
            revert YieldSeekerErrors.AdapterExecutionFailed(result);
        }
    }

    /**
     * @notice Execute a call through a registered adapter via delegatecall
     * @param adapter The address of the adapter to use
     * @param target The target contract the adapter will interact with
     * @param data The operation data for the adapter
     */
    function executeViaAdapter(address adapter, address target, bytes calldata data) external onlyExecutors returns (bytes memory result) {
        return _executeAdapterCall(adapter, target, data);
    }

    /**
     * @notice Execute multiple adapter calls in a batch
     */
    function executeViaAdapterBatch(address[] calldata adapters, address[] calldata targets, bytes[] calldata datas) external onlyExecutors returns (bytes[] memory results) {
        uint256 length = adapters.length;
        if (length != targets.length || length != datas.length) revert YieldSeekerErrors.InvalidState();
        results = new bytes[](length);
        for (uint256 i; i < length; ++i) {
            results[i] = _executeAdapterCall(adapters[i], targets[i], datas[i]);
        }
    }

    // ============ UUPS Upgradeability ============

    /**
     * @notice Upgrade to latest approved implementation from factory and sync registry
     */
    // TODO(krishan711): do we need to upate itratively thorugh all the versions or is it fine to skip to latest?
    function upgradeToLatest() external onlyOwner {
        upgradeToAndCall(FACTORY.agentWalletImplementation(), "");
        _syncFromFactory();
    }

    /**
     * @notice Authorize UUPS upgrades
     * @dev Restricts upgrades to:
     *      1. Owner only (user sovereignty)
     *      2. Factory-approved implementations only
     *      See README for full upgrade authorization model documentation.
     */
    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        address approvedImplementation = FACTORY.agentWalletImplementation();
        if (newImplementation != approvedImplementation) {
            revert YieldSeekerErrors.NotApprovedImplementation();
        }
    }

    // ============ USER WITHDRAWAL FUNCTIONS ============

    /**
     * @notice Collect any owed fees from the wallet
     * @dev Can be called by executors during normal operations
     */
    function collectFees() external onlyExecutors {
        FeeTracker tracker = feeTracker();
        uint256 owed = tracker.getFeesOwed(address(this));
        if (owed == 0) return;
        IERC20 asset = baseAsset();
        uint256 available = asset.balanceOf(address(this));
        uint256 toCollect = owed > available ? available : owed;
        if (toCollect > 0) {
            address collector = tracker.feeCollector();
            asset.safeTransfer(collector, toCollect);
            tracker.recordFeePaid(toCollect);
        }
    }

    /**
     * @notice User withdraws any ERC20 asset from agent wallet
     * @param recipient Address to send the asset to
     * @param asset Address of the ERC20 token to withdraw
     * @param amount Amount to withdraw
     * @dev If asset is baseAsset, respects fee deductions. Otherwise transfers directly (recovery mechanism).
     */
    function withdrawAssetToUser(address recipient, address asset, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert YieldSeekerErrors.ZeroAddress();
        if (asset == address(0)) revert YieldSeekerErrors.ZeroAddress();
        IERC20 token = IERC20(asset);
        uint256 balance = token.balanceOf(address(this));
        // If withdrawing baseAsset, respect fees
        if (asset == address(baseAsset())) {
            uint256 feesOwed = feeTracker().getFeesOwed(address(this));
            uint256 withdrawable = balance > feesOwed ? balance - feesOwed : 0;
            if (withdrawable < amount) revert YieldSeekerErrors.InsufficientBalance();
        } else {
            // For non-baseAsset tokens, allow direct withdrawal (recovery mechanism)
            if (balance < amount) revert YieldSeekerErrors.InsufficientBalance();
        }
        _withdrawAsset(recipient, asset, amount);
    }

    /**
     * @notice User withdraws all of a specific ERC20 asset from agent wallet
     * @param recipient Address to send the asset to
     * @param asset Address of the ERC20 token to withdraw
     * @dev If asset is baseAsset, respects fee deductions. Otherwise transfers directly (recovery mechanism).
     */
    function withdrawAllAssetToUser(address recipient, address asset) external onlyOwner {
        if (recipient == address(0)) revert YieldSeekerErrors.ZeroAddress();
        if (asset == address(0)) revert YieldSeekerErrors.ZeroAddress();
        IERC20 token = IERC20(asset);
        uint256 balance = token.balanceOf(address(this));
        uint256 amount = balance;
        // If withdrawing baseAsset, deduct fees from withdrawable amount
        if (asset == address(baseAsset())) {
            uint256 feesOwed = feeTracker().getFeesOwed(address(this));
            amount = balance > feesOwed ? balance - feesOwed : 0;
        }
        _withdrawAsset(recipient, asset, amount);
    }

    /**
     * @notice User withdraws base asset from agent wallet
     * @param recipient Address to send the base asset to
     * @param amount Amount to withdraw
     */
    function withdrawBaseAssetToUser(address recipient, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert YieldSeekerErrors.ZeroAddress();

        IERC20 asset = baseAsset();
        uint256 balance = asset.balanceOf(address(this));
        uint256 feesOwed = feeTracker().getFeesOwed(address(this));
        uint256 withdrawable = balance > feesOwed ? balance - feesOwed : 0;
        if (withdrawable < amount) revert YieldSeekerErrors.InsufficientBalance();
        _withdrawAsset(recipient, address(asset), amount);
    }

    /**
     * @notice User withdraws all base asset from agent wallet
     * @param recipient Address to send the base asset to
     */
    function withdrawAllBaseAssetToUser(address recipient) external onlyOwner {
        if (recipient == address(0)) revert YieldSeekerErrors.ZeroAddress();
        IERC20 asset = baseAsset();
        uint256 balance = asset.balanceOf(address(this));
        uint256 feesOwed = feeTracker().getFeesOwed(address(this));
        uint256 withdrawable = balance > feesOwed ? balance - feesOwed : 0;
        _withdrawAsset(recipient, address(asset), withdrawable);
    }

    /**
     * @notice Internal function to withdraw asset
     * @param recipient Address to send the asset to
     * @param asset Address of the ERC20 token to withdraw
     * @param amount Amount to withdraw
     */
    function _withdrawAsset(address recipient, address asset, uint256 amount) internal {
        IERC20 token = IERC20(asset);
        token.safeTransfer(recipient, amount);
        emit WithdrewTokenToUser(owner(), recipient, asset, amount);
    }

    /**
     * @notice User withdraws ETH from agent wallet
     * @param recipient Address to send the ETH to
     * @param amount Amount of ETH to withdraw
     */
    function withdrawEthToUser(address recipient, uint256 amount) external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance < amount) revert YieldSeekerErrors.InsufficientBalance();
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
     * @notice Internal function to withdraw ETH
     * @param recipient Address to send the ETH to
     * @param amount Amount of ETH to withdraw
     */
    function _withdrawEth(address recipient, uint256 amount) internal {
        if (recipient == address(0)) revert YieldSeekerErrors.ZeroAddress();
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert YieldSeekerErrors.TransferFailed();
        emit WithdrewEthToUser(owner(), recipient, amount);
    }
}
