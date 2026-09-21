// SPDX-License-Identifier: MIT
//
//      _                    _ __        __    _ _      _   _  ___ _
//     / \   __ _  ___ _ __ | |\ \      / /_ _| | | ___| |_| |/ (_) |_
//    / _ \ / _` |/ _ \ '_ \| __\ \ /\ / / _` | | |/ _ \ __| ' /| | __|
//   / ___ \ (_| |  __/ | | | |_ \ V  V / (_| | | |  __/ |_| . \| | |_
//  /_/   \_\__, |\___|_| |_|\__| \_/\_/ \__,_|_|_|\___|\__|_|\_\_|\__|
//          |___/
//
//  Build verifiably secure onchain agents
//  https://agentwalletkit.tokenpage.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKAdapterRegistry as AdapterRegistry} from "./AWKAdapterRegistry.sol";
import {AdapterExecutionFailed, AdapterIsBlocked, AgentWalletStorageV1, InvalidRegistry, InvalidState, NotAllowed, NotApprovedImplementation, TargetIsBlocked, TransferFailed} from "./AWKAgentWalletV1.sol";
import {AWKErrors} from "./AWKErrors.sol";
import {IAWKAdapter} from "./IAWKAdapter.sol";
import {IAWKAgentWallet} from "./IAWKAgentWallet.sol";
import {IAWKAgentWalletFactory} from "./IAWKAgentWalletFactory.sol";
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
 * @title AWKAgentWalletV2
 * @notice Adds EntryPoint-relayed (gas-sponsored) owner authorization to every owner action.
 * @dev V1 (`AWKAgentWalletV1`) is never modified — it's already deployed and live for thousands
 *      of wallets. This is a brand-new, standalone implementation contract that existing V1
 *      wallets may opt in to via upgradeToLatest()/upgradeToAndCall() once the Factory is pointed
 *      here; new wallets deploy directly on this version.
 *
 *      This does NOT inherit AWKAgentWalletV1. Every `onlyOwner`-gated function in V1 is
 *      non-virtual, so a subclass can never legally change their behavior — not the function, not
 *      even the modifier name, regardless of whether the override body matches V1's or not
 *      (verified empirically: Solidity rejects it purely for sharing a selector/modifier name
 *      with a non-virtual declaration, independent of body content). The only way to change their
 *      behavior without touching V1 is to not inherit the contract that sealed them. What IS
 *      reused from V1's file: `AgentWalletStorageV1` (the storage library — same ERC-7201 slots,
 *      so an existing wallet's state is read identically after upgrading) and the shared error
 *      types, both plain imports, not inheritance, so reusing them doesn't touch V1 either.
 *
 *      Storage is untouched: no new fields, identical layout to V1.
 *
 *      Authorization model:
 *      - Owner signature: valid for any function, whether called directly or via a relayed
 *        UserOperation. Every owner action — withdrawals, blocklist management, upgrades — is
 *        paymaster-able; a relayer can submit and pay for the transaction, but only the owner's
 *        own signature can ever authorize it.
 *      - Operator signature: valid only for `executeViaAdapter`/`executeViaAdapterBatch`, exactly
 *        as in V1. Operators gain no new authority from this version.
 *
 *      Every function here is `virtual` so a future V3 can extend it directly through normal
 *      inheritance, without ever needing to duplicate anything again.
 */
abstract contract AWKAgentWalletV2 is IAWKAgentWallet, BaseAccount, Initializable, UUPSUpgradeable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;
    using SafeERC20 for IERC20;

    // ERC-4337 v0.6 canonical EntryPoint address
    IEntryPoint private constant ENTRY_POINT = IEntryPoint(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789);
    IAWKAgentWalletFactory public immutable FACTORY;

    event AgentWalletInitialized(IEntryPoint indexed entryPoint, address indexed owner);
    event WithdrewTokenToUser(address indexed owner, address indexed recipient, address indexed token, uint256 amount);
    event WithdrewEthToUser(address indexed owner, address indexed recipient, uint256 amount);
    event AdapterBlocked(address indexed adapter);
    event AdapterUnblocked(address indexed adapter);
    event TargetBlocked(address indexed target);
    event TargetUnblocked(address indexed target);
    event SyncedFromFactory(address indexed adapterRegistry);

    /// @dev Accepts a direct owner call, or a call relayed by the canonical EntryPoint on behalf
    ///      of a UserOperation. Authorization for the EntryPoint-relayed case is enforced in
    ///      `_validateSignature`, which only accepts an operator signature for the adapter-
    ///      execution selectors — every other selector requires the owner's own signature.
    modifier onlyOwner() virtual {
        if (msg.sender != owner() && msg.sender != address(ENTRY_POINT)) {
            revert AWKErrors.Unauthorized(msg.sender);
        }
        _;
    }

    modifier onlyExecutors() virtual {
        if (msg.sender != address(ENTRY_POINT) && msg.sender != owner() && !isAgentOperator(msg.sender)) {
            revert AWKErrors.Unauthorized(msg.sender);
        }
        _;
    }

    constructor(address factory) {
        FACTORY = IAWKAgentWalletFactory(factory);
        _disableInitializers();
    }

    receive() external payable {}

    // ============ Initializers ============

    /**
     * @notice Initialize the wallet with owner and index
     * @param _owner The owner address for the wallet
     * @param _ownerAgentIndex Index of this agent for the owner
     * @dev SECURITY: This function is intentionally public without caller restrictions because:
     *      1. The `initializer` modifier prevents re-initialization after first call
     *      2. Factory subclasses MUST call initialize() atomically in the same transaction as deployment
     *      3. See YieldSeekerAgentWalletFactory.createAgentWallet() for the correct pattern
     *      Factories that expose deployment without atomic initialization would create a vulnerability.
     */
    function initialize(address _owner, uint256 _ownerAgentIndex) public virtual initializer {
        _initializeV1(_owner, _ownerAgentIndex);
    }

    function _initializeV1(address _owner, uint256 _ownerAgentIndex) internal virtual {
        if (_owner == address(0)) revert AWKErrors.ZeroAddress();
        AgentWalletStorageV1.Layout storage $ = AgentWalletStorageV1.layout();
        $.owner = _owner;
        $.ownerAgentIndex = _ownerAgentIndex;
        _syncFromFactory();
        emit AgentWalletInitialized(ENTRY_POINT, _owner);
    }

    // ============ Storage Accessors ============

    /**
     * @notice Get the owner of this wallet
     * @return Owner address
     */
    function owner() public view virtual returns (address) {
        return AgentWalletStorageV1.layout().owner;
    }

    /**
     * @notice Get the owner agent index
     * @return Owner agent index
     */
    function ownerAgentIndex() public view virtual returns (uint256) {
        return AgentWalletStorageV1.layout().ownerAgentIndex;
    }

    /**
     * @notice Get the adapter registry
     * @return AdapterRegistry instance
     */
    function adapterRegistry() public view virtual returns (AdapterRegistry) {
        return AgentWalletStorageV1.layout().adapterRegistry;
    }

    /**
     * @notice Get the list of agent operators (cached)
     */
    function listAgentOperators() public view virtual returns (address[] memory) {
        return AgentWalletStorageV1.layout().agentOperators;
    }

    /**
     * @notice Check if an address is a cached agent operator
     * @param operator The address to check
     * @return True if the address is a cached operator
     */
    function isAgentOperator(address operator) public view virtual returns (bool) {
        return AgentWalletStorageV1.layout().isAgentOperator[operator];
    }

    // ============ User Blocklist Management ============

    /**
     * @notice Block an adapter from being used by this wallet
     * @param adapter The adapter address to block
     * @dev Owner can block adapters even if they are globally approved.
     *      This provides user sovereignty over their agent's operations.
     */
    function blockAdapter(address adapter) external virtual onlyOwner {
        AgentWalletStorageV1.layout().blockedAdapters[adapter] = true;
        emit AdapterBlocked(adapter);
    }

    /**
     * @notice Unblock a previously blocked adapter
     * @param adapter The adapter address to unblock
     */
    function unblockAdapter(address adapter) external virtual onlyOwner {
        AgentWalletStorageV1.layout().blockedAdapters[adapter] = false;
        emit AdapterUnblocked(adapter);
    }

    /**
     * @notice Block a target from being interacted with by this wallet
     * @param target The target address to block
     * @dev Owner can block specific protocols/vaults even if globally approved.
     *      Example: Block a risky vault while keeping other vaults accessible.
     */
    function blockTarget(address target) external virtual onlyOwner {
        AgentWalletStorageV1.layout().blockedTargets[target] = true;
        emit TargetBlocked(target);
    }

    /**
     * @notice Unblock a previously blocked target
     * @param target The target address to unblock
     */
    function unblockTarget(address target) external virtual onlyOwner {
        AgentWalletStorageV1.layout().blockedTargets[target] = false;
        emit TargetUnblocked(target);
    }

    /**
     * @notice Check if an adapter is blocked by the owner
     * @param adapter The adapter address to check
     * @return True if the adapter is blocked
     */
    function isAdapterBlocked(address adapter) public view virtual returns (bool) {
        return AgentWalletStorageV1.layout().blockedAdapters[adapter];
    }

    /**
     * @notice Check if a target is blocked by the owner
     * @param target The target address to check
     * @return True if the target is blocked
     */
    function isTargetBlocked(address target) public view virtual returns (bool) {
        return AgentWalletStorageV1.layout().blockedTargets[target];
    }

    /**
     * @notice Refresh configuration from the factory
     * @dev On onlyExecutors (not a separate onlySyncers) — with EntryPoint already included in
     *      onlyExecutors, a distinct owner-or-operator-only modifier would be redundant.
     */
    function syncFromFactory() external virtual onlyExecutors {
        _syncFromFactory();
    }

    /**
     * @notice Internal helper to sync configuration from the factory
     */
    function _syncFromFactory() internal virtual {
        AgentWalletStorageV1.Layout storage $ = AgentWalletStorageV1.layout();

        // Operators
        for (uint256 i = 0; i < $.agentOperators.length; i++) {
            $.isAgentOperator[$.agentOperators[i]] = false;
        }
        $.agentOperators = FACTORY.listAgentOperators();
        for (uint256 i = 0; i < $.agentOperators.length; i++) {
            $.isAgentOperator[$.agentOperators[i]] = true;
        }

        // AdapterRegistry
        address registryAddr = FACTORY.adapterRegistry();
        if (registryAddr == address(0)) revert InvalidRegistry();
        if (registryAddr.code.length == 0) revert InvalidRegistry();
        $.adapterRegistry = AdapterRegistry(registryAddr);

        emit SyncedFromFactory(registryAddr);
    }

    // ============ ERC-4337 / BaseAccount Overrides ============

    /// @inheritdoc BaseAccount
    function entryPoint() public view virtual override returns (IEntryPoint) {
        return ENTRY_POINT;
    }

    /// @dev Operators may only authorize adapter execution. Every other selector — including
    ///      every `onlyOwner` function — requires the owner's own signature.
    function _validateSignature(UserOperation calldata userOp, bytes32 userOpHash) internal virtual override returns (uint256 validationData) {
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        address signer = hash.recover(userOp.signature);
        if (signer == owner()) {
            return 0;
        }
        bytes4 selector = userOp.callData.length >= 4 ? bytes4(userOp.callData[:4]) : bytes4(0);
        bool isAdapterCall = selector == this.executeViaAdapter.selector || selector == this.executeViaAdapterBatch.selector;
        if (isAgentOperator(signer) && isAdapterCall) {
            return 0;
        }
        return SIG_VALIDATION_FAILED;
    }

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
     * @dev Enforces the standard IAWKAdapter interface.
     *      Checks user blocklists first, then global registry validation.
     */
    function _executeAdapterCall(address adapter, address target, bytes calldata data) private returns (bytes memory result) {
        AgentWalletStorageV1.Layout storage $ = AgentWalletStorageV1.layout();

        // Check user-level blocklists first (owner sovereignty)
        if ($.blockedAdapters[adapter]) {
            revert AdapterIsBlocked(adapter);
        }
        if ($.blockedTargets[target]) {
            revert TargetIsBlocked(target);
        }

        // Then check global registry validation
        address registeredAdapter = adapterRegistry().getTargetAdapter(target);
        if (registeredAdapter == address(0) || registeredAdapter != adapter) {
            revert AWKErrors.AdapterNotRegistered(adapter);
        }

        bytes memory callData = abi.encodeWithSelector(IAWKAdapter.execute.selector, target, data);
        bool success;
        (success, result) = adapter.delegatecall(callData);
        if (!success) {
            revert AdapterExecutionFailed(result);
        }
    }

    /**
     * @notice Execute a call through a registered adapter via delegatecall
     * @param adapter The address of the adapter to use
     * @param target The target contract the adapter will interact with
     * @param data The operation data for the adapter
     */
    function executeViaAdapter(address adapter, address target, bytes calldata data) external virtual onlyExecutors returns (bytes memory result) {
        return _executeAdapterCall(adapter, target, data);
    }

    /**
     * @notice Execute multiple adapter calls in a batch
     */
    function executeViaAdapterBatch(address[] calldata adapters, address[] calldata targets, bytes[] calldata datas) external virtual onlyExecutors returns (bytes[] memory results) {
        uint256 length = adapters.length;
        if (length != targets.length || length != datas.length) revert InvalidState();
        results = new bytes[](length);
        for (uint256 i; i < length; ++i) {
            results[i] = _executeAdapterCall(adapters[i], targets[i], datas[i]);
        }
    }

    // ============ UUPS Upgradeability ============

    /**
     * @notice Upgrade to latest approved implementation from factory and sync registry
     */
    function upgradeToLatest() external virtual onlyOwner {
        upgradeToAndCall(FACTORY.agentWalletImplementation(), "");
        _syncFromFactory();
    }

    /**
     * @notice Authorize UUPS upgrades
     * @dev Restricts upgrades to:
     *      1. Owner only (user sovereignty)
     *      2. Factory-approved implementations only
     */
    function _authorizeUpgrade(address newImplementation) internal view virtual override onlyOwner {
        address approvedImplementation = FACTORY.agentWalletImplementation();
        if (newImplementation != approvedImplementation) {
            revert NotApprovedImplementation();
        }
    }

    // ============ USER WITHDRAWAL FUNCTIONS ============

    /**
     * @notice User withdraws any ERC20 asset from agent wallet
     * @param recipient Address to send the asset to
     * @param asset Address of the ERC20 token to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawAssetToUser(address recipient, address asset, uint256 amount) external virtual onlyOwner {
        _withdrawAsset(recipient, asset, amount);
    }

    /**
     * @notice User withdraws all of a specific ERC20 asset from agent wallet
     * @param recipient Address to send the asset to
     * @param asset Address of the ERC20 token to withdraw
     */
    function withdrawAllAssetToUser(address recipient, address asset) external virtual onlyOwner {
        IERC20 token = IERC20(asset);
        uint256 balance = token.balanceOf(address(this));
        _withdrawAsset(recipient, asset, balance);
    }

    /**
     * @notice Internal function to withdraw asset
     * @param recipient Address to send the asset to
     * @param asset Address of the ERC20 token to withdraw
     * @param amount Amount to withdraw
     */
    function _withdrawAsset(address recipient, address asset, uint256 amount) internal virtual {
        if (recipient == address(0)) revert AWKErrors.ZeroAddress();
        if (asset == address(0)) revert AWKErrors.ZeroAddress();
        IERC20 token = IERC20(asset);
        token.safeTransfer(recipient, amount);
        emit WithdrewTokenToUser(owner(), recipient, asset, amount);
    }

    /**
     * @notice User withdraws ETH from agent wallet
     * @param recipient Address to send the ETH to
     * @param amount Amount of ETH to withdraw
     */
    function withdrawEthToUser(address recipient, uint256 amount) external virtual onlyOwner {
        _withdrawEth(recipient, amount);
    }

    /**
     * @notice User withdraws all ETH from agent wallet
     * @param recipient Address to send the ETH to
     */
    function withdrawAllEthToUser(address recipient) external virtual onlyOwner {
        uint256 balance = address(this).balance;
        _withdrawEth(recipient, balance);
    }

    /**
     * @notice Internal function to withdraw ETH
     * @param recipient Address to send the ETH to
     * @param amount Amount of ETH to withdraw
     */
    function _withdrawEth(address recipient, uint256 amount) internal virtual {
        if (recipient == address(0)) revert AWKErrors.ZeroAddress();
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        emit WithdrewEthToUser(owner(), recipient, amount);
    }
}
