// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {YieldSeekerAccessController} from "./AccessController.sol";
import {AgentWalletStorageV1} from "./AgentWalletStorage.sol";

interface IAgentWalletFactory {
    function currentImplementation() external view returns (address);
}

/**
 * @title YieldSeekerAgentWallet
 * @notice UUPS upgradeable agent wallet with secure calldata execution
 * @dev Deployed as ERC1967 proxy by AgentWalletFactory
 *      Allows backend to generate arbitrary calldata but enforces strict security:
 *      - Only approved contracts can be called
 *      - ERC20 transfers/approvals are monitored and validated
 *      - User can always withdraw their funds
 *      - No way for operator to steal funds even with compromised keys
 *      - Only owner can upgrade wallet to factory-approved implementations
 */
contract YieldSeekerAgentWallet is Initializable, UUPSUpgradeable {
    using SafeERC20 for IERC20;

    /// @notice Access controller (immutable in implementation, not in proxy storage)
    YieldSeekerAccessController public immutable operator;

    /// @notice Factory that deployed this wallet (immutable in implementation, not in proxy storage)
    address public immutable FACTORY;

    /// @notice Struct for a single call operation
    struct CallOperation {
        address target; // Contract to call
        uint256 value; // ETH value to send
        bytes data; // Calldata to execute
    }

    event Initialized(address indexed owner, uint256 indexed ownerAgentIndex);
    event CallExecuted(address indexed target, uint256 value, bytes data, bool success, bytes result);
    event BatchExecuted(address indexed operator, uint256 callCount);
    event WithdrewBaseAssetToUser(address indexed owner, address indexed recipient, uint256 amount);
    event WithdrewEthToUser(address indexed owner, address indexed recipient, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOperator();
    error NotOwner();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidAddress();
    error SystemPaused();
    error TargetNotApproved();
    error UnsafeERC20Operation();
    error CallFailed();
    error InsufficientBalance();
    error TransferFailed();
    error NotApprovedImplementation();

    modifier onlyOperator() {
        if (!operator.isAuthorizedOperator(msg.sender)) revert NotOperator();
        AgentWalletStorageV1.Layout storage $ = AgentWalletStorageV1.layout();
        if ($.owner == address(0)) revert NotInitialized();
        if (operator.paused()) revert SystemPaused();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner()) revert NotOwner();
        _;
    }

    constructor(address _operator, address _factory) {
        if (_operator == address(0)) revert InvalidAddress();
        if (_factory == address(0)) revert InvalidAddress();
        operator = YieldSeekerAccessController(_operator);
        FACTORY = _factory;
        _disableInitializers();
    }

    /**
     * @notice Initialize the agent wallet
     * @param _owner User who owns this agent wallet
     * @param _ownerAgentIndex Agent index for this owner
     * @param _baseAsset Base asset token address (e.g., USDC)
     */
    function initialize(address _owner, uint256 _ownerAgentIndex, address _baseAsset) external initializer {
        if (_owner == address(0)) revert InvalidAddress();
        if (_baseAsset == address(0)) revert InvalidAddress();

        AgentWalletStorageV1.Layout storage $ = AgentWalletStorageV1.layout();
        $.owner = _owner;
        $.ownerAgentIndex = _ownerAgentIndex;
        $.baseAsset = IERC20(_baseAsset);

        emit Initialized(_owner, _ownerAgentIndex);
    }

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
     * @notice Transfer ownership to a new address
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();

        AgentWalletStorageV1.Layout storage $ = AgentWalletStorageV1.layout();
        address previousOwner = $.owner;
        $.owner = newOwner;

        emit OwnershipTransferred(previousOwner, newOwner);
    }

    /**
     * @notice Execute multiple calls atomically
     * @param calls Array of call operations
     * @dev All calls must pass security checks. If any fails, entire batch reverts.
     *      Adapters are automatically called via delegatecall.
     */
    function executeBatch(CallOperation[] calldata calls) external onlyOperator {
        for (uint256 i = 0; i < calls.length; i++) {
            CallOperation calldata call = calls[i];
            if (!operator.isCallAllowed(address(this), call.target, call.data)) revert TargetNotApproved();

            bool success;
            bytes memory result;

            if (operator.isApprovedAdapter(call.target)) {
                (success, result) = call.target.delegatecall(call.data);
            }

            emit CallExecuted(call.target, call.value, call.data, success, result);

            if (!success) revert CallFailed();
        }

        emit BatchExecuted(msg.sender, calls.length);
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
        emit WithdrewBaseAssetToUser(owner(), recipient, amount);
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

    /**
     * @notice Upgrade to latest approved implementation from factory
     * @dev Convenience function that upgrades to current factory implementation
     */
    function upgradeToLatest() external onlyOwner {
        address latest = IAgentWalletFactory(FACTORY).currentImplementation();
        upgradeToAndCall(latest, "");
    }

    /**
     * @notice UUPS upgrade authorization
     * @dev Only owner can upgrade, and only to current factory implementation (no downgrades)
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {
        address currentImpl = IAgentWalletFactory(FACTORY).currentImplementation();
        if (newImplementation != currentImpl) {
            revert NotApprovedImplementation();
        }
    }

    /**
     * @notice Receive ETH (for gas refunds, etc.)
     */
    receive() external payable {}
}
