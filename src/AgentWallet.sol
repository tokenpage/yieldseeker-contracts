// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "./AdapterRegistry.sol";
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
    function adapterRegistry() external view returns (AdapterRegistry);
    function listAgentOperators() external view returns (address[] memory);
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

    // ERC-4337 v0.6 canonical EntryPoint address
    IEntryPoint private constant ENTRY_POINT = IEntryPoint(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789);
    IAgentWalletFactory public immutable FACTORY;

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
        require(msg.sender == owner(), "only owner");
        _;
    }

    modifier onlySyncers() {
        require(msg.sender == address(FACTORY) || msg.sender == owner() || isAgentOperator(msg.sender), "only syncers");
        _;
    }

    modifier onlyExecutors() {
        require(msg.sender == address(ENTRY_POINT) || msg.sender == owner() || isAgentOperator(msg.sender), "only executors");
        _;
    }

    constructor(address factory) {
        FACTORY = IAgentWalletFactory(factory);
        _disableInitializers();
    }

    receive() external payable {}

    // ============ Initializers ============

    function initialize(address _owner, uint256 _ownerAgentIndex, address _baseAsset) public virtual initializer {
        require(_owner != address(0), "Invalid owner");
        require(_baseAsset != address(0), "Invalid base asset");
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

        $.adapterRegistry = FACTORY.adapterRegistry();
    }

    // ============ ERC-4337 / BaseAccount Overrides ============

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
        address registeredAdapter = adapterRegistry().getTargetAdapter(target);
        if (registeredAdapter == address(0) || registeredAdapter != adapter) {
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
     * @dev Implements "Peek and Verify" logic.
     */
    function executeViaAdapter(address adapter, bytes calldata data) external payable onlyExecutors returns (bytes memory result) {
        return _executeAdapterCall(adapter, data);
    }

    /**
     * @notice Execute multiple adapter calls in a batch
     */
    function executeViaAdapterBatch(address[] calldata adapters, bytes[] calldata datas) external payable onlyExecutors returns (bytes[] memory results) {
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
        address latest = FACTORY.agentWalletImplementation();
        // Refresh all configuration before upgrading
        _syncFromFactory();
        upgradeToAndCall(latest, "");
    }

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        address currentImpl = FACTORY.agentWalletImplementation();
        if (newImplementation != currentImpl) {
            revert NotApprovedImplementation();
        }
    }

    // ============ USER WITHDRAWAL FUNCTIONS ============

    /**
     * @notice User withdraws base asset from agent wallet
     * @param recipient Address to send the base asset to
     * @param amount Amount to withdraw
     */
    function withdrawBaseAssetToUser(address recipient, uint256 amount) external onlyOwner {
        IERC20 asset = baseAsset();
        uint256 balance = asset.balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();
        _withdrawBaseAsset(recipient, amount);
    }

    /**
     * @notice User withdraws all base asset from agent wallet
     * @param recipient Address to send the base asset to
     */
    function withdrawAllBaseAssetToUser(address recipient) external onlyOwner {
        IERC20 asset = baseAsset();
        uint256 balance = asset.balanceOf(address(this));
        _withdrawBaseAsset(recipient, balance);
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
     * @notice Internal function to withdraw base asset
     * @param recipient Address to send the base asset to
     * @param amount Amount to withdraw
     */
    function _withdrawBaseAsset(address recipient, uint256 amount) internal {
        if (recipient == address(0)) revert InvalidAddress();
        IERC20 asset = baseAsset();
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
