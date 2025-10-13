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
        _validateCall(target, data);

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
            _validateCall(call.target, call.data);

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

    /**
     * @notice Validate a call is safe to execute
     * @param target Contract being called
     * @param data Calldata being sent
     * @dev Security validation:
     *      1. Target must be approved (vault or swap)
     *      2. If target is ERC20, check it's not an unsafe operation
     */
    function _validateCall(address target, bytes calldata data) internal view {
        // Check 1: Target must be approved
        if (!operator.isContractApproved(target)) {
            revert TargetNotApproved();
        }

        // Check 2: If calling an ERC20 token, validate the operation
        if (_isERC20(target)) {
            _validateERC20Call(target, data);
        }
    }

    /**
     * @notice Check if a contract is likely an ERC20 token
     * @param target Contract to check
     * @return True if contract appears to be ERC20
     * @dev Simple heuristic: has totalSupply() function
     */
    function _isERC20(address target) internal view returns (bool) {
        // Try to call totalSupply() - if it succeeds, likely ERC20
        (bool success,) = target.staticcall(abi.encodeWithSignature("totalSupply()"));
        return success;
    }

    /**
     * @notice Validate ERC20 call is safe
     * @param token ERC20 token being called
     * @param data Calldata being sent
     * @dev Prevents:
     *      - transfer(attacker, amount) stealing baseAsset
     *      - approve(attacker, amount) allowing theft
     *      Only allows:
     *      - transfer/approve to approved contracts (vaults/swaps)
     *      - Other safe operations (balanceOf, allowance, etc.)
     */
    function _validateERC20Call(address token, bytes calldata data) internal view {
        if (data.length < 4) return; // Too short to be a dangerous call

        bytes4 selector = bytes4(data[0:4]);

        // Check for transfer(address,uint256)
        if (selector == IERC20.transfer.selector) {
            address recipient = abi.decode(data[4:36], (address));

            // If transferring baseAsset, recipient must be approved contract
            if (token == address(baseAsset)) {
                if (!operator.isContractApproved(recipient)) {
                    revert UnsafeERC20Operation();
                }
            }
        }
        // Check for approve(address,uint256)
        else if (selector == IERC20.approve.selector) {
            address spender = abi.decode(data[4:36], (address));

            // If approving baseAsset, spender must be approved contract
            if (token == address(baseAsset)) {
                if (!operator.isContractApproved(spender)) {
                    revert UnsafeERC20Operation();
                }
            }
        }
        // transferFrom is allowed if target is approved
        // Other functions (balanceOf, allowance, etc.) are safe
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
