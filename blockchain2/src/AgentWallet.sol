// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {YieldSeekerAccessController} from "./AccessController.sol";

/**
 * @title YieldSeekerAgentWallet
 * @notice Agent wallet with secure calldata execution
 * @dev Allows backend to generate arbitrary calldata but enforces strict security:
 *      - Only approved contracts can be called
 *      - ERC20 transfers/approvals are monitored and validated
 *      - User can always withdraw their funds
 *      - No way for operator to steal funds even with compromised keys
 */
contract YieldSeekerAgentWallet {
    using SafeERC20 for IERC20;

    /// @notice Access controller
    YieldSeekerAccessController public immutable operator;

    /// @notice User who owns this agent wallet
    address public owner;

    /// @notice Agent index for this owner
    uint256 public ownerAgentIndex;

    /// @notice Base asset token (e.g., USDC)
    IERC20 public baseAsset;

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

    modifier onlyOperator() {
        if (!operator.isAuthorizedOperator(msg.sender)) revert NotOperator();
        if (owner == address(0)) revert NotInitialized();
        if (operator.paused()) revert SystemPaused();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address _operator) {
        if (_operator == address(0)) revert InvalidAddress();
        operator = YieldSeekerAccessController(_operator);
    }

    /**
     * @notice Initialize the agent wallet
     * @param _owner User who owns this agent wallet
     * @param _ownerAgentIndex Agent index for this owner
     * @param _baseAsset Base asset token address (e.g., USDC)
     */
    function initialize(address _owner, uint256 _ownerAgentIndex, address _baseAsset) external {
        if (owner != address(0)) revert AlreadyInitialized();
        if (_owner == address(0)) revert InvalidAddress();
        if (_baseAsset == address(0)) revert InvalidAddress();
        owner = _owner;
        ownerAgentIndex = _ownerAgentIndex;
        baseAsset = IERC20(_baseAsset);
        emit Initialized(_owner, _ownerAgentIndex);
    }

    // ============ SECURE CALLDATA EXECUTION ============

    /**
     * @notice Execute a single call with security checks
     * @param target Contract to call
     * @param value ETH value to send
     * @param data Calldata to execute
     * @dev Security checks:
     *      1. Target must be approved contract (vault, swap, or adapter)
     *      2. If calling ERC20, validate the operation is safe
     *      3. Cannot directly transfer baseAsset to arbitrary addresses
     *      4. Adapters are called via delegatecall for efficiency
     */
    function executeCall(address target, uint256 value, bytes calldata data) external onlyOperator returns (bool success, bytes memory result) {
        if (!operator.isCallAllowed(address(this), target, data)) revert TargetNotApproved();

        if (operator.isApprovedAdapter(target)) {
            (success, result) = target.delegatecall(data);
        } else {
            (success, result) = target.call{value: value}(data);
        }

        emit CallExecuted(target, value, data, success, result);

        if (!success) revert CallFailed();
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
            } else {
                (success, result) = call.target.call{value: call.value}(call.data);
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
        uint256 balance = baseAsset.balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();
        _withdrawBaseAsset(recipient, amount);
    }

    /**
     * @notice User withdraws all base asset from agent wallet
     * @param recipient Address to send the base asset to
     */
    function withdrawAllBaseAssetToUser(address recipient) external onlyOwner {
        uint256 balance = baseAsset.balanceOf(address(this));
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
        baseAsset.safeTransfer(recipient, amount);
        emit WithdrewBaseAssetToUser(owner, recipient, amount);
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
        emit WithdrewEthToUser(owner, recipient, amount);
    }

    /**
     * @notice Receive ETH (for gas refunds, etc.)
     */
    receive() external payable {}
}
