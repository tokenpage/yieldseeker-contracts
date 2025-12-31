// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerErrors} from "../../src/Errors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";

interface IAdapterRegistry {
    function getTargetAdapter(address target) external view returns (address);
}

interface IFeeTracker {
    function getReferralDiscount(address user) external view returns (uint256);
    function getFeesOwed(address agent) external view returns (uint256);
}

/// @title MockAgentWallet
/// @notice Simple mock for isolated AgentWallet testing without proxy complexity
contract MockAgentWallet {
    using MessageHashUtils for bytes32;

    // Core state
    address public owner;
    address public baseAsset;
    IAdapterRegistry public adapterRegistry;
    IFeeTracker public feeTracker;

    // User sovereignty storage
    mapping(address => bool) private _blockedAdapters;
    mapping(address => bool) private _blockedTargets;

    // Events
    event WithdrewTokenToUser(address indexed owner, address indexed recipient, address indexed token, uint256 amount);
    event WithdrewEthToUser(address indexed owner, address indexed recipient, uint256 amount);
    event AdapterBlocked(address indexed adapter);
    event AdapterUnblocked(address indexed adapter);
    event TargetBlocked(address indexed target);
    event TargetUnblocked(address indexed target);
    event SyncedFromFactory(address indexed adapterRegistry, address indexed feeTracker);

    constructor(address _owner, address _baseAsset, address _adapterRegistry, address _feeTracker) {
        owner = _owner;
        baseAsset = _baseAsset;
        adapterRegistry = IAdapterRegistry(_adapterRegistry);
        feeTracker = IFeeTracker(_feeTracker);
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Unauthorized");
        _;
    }

    /// @dev Simplified signature validation for testing
    function validateSignature(UserOperation memory userOp, bytes32 userOpHash) external view returns (uint256) {
        // Only validate the signature itself - other validations are handled by EntryPoint
        if (userOp.signature.length == 0) return 1; // SIG_VALIDATION_FAILED
        if (userOp.signature.length < 65) return 1; // Too short (malformed)

        // For this mock, we'll simulate signature validation by checking the sender address
        // In real implementation, we'd recover the signer from the signature
        // For the test, we expect the signature to be from the owner
        if (userOp.sender != owner) return 1; // Wrong signer

        return 0; // SIG_VALIDATION_SUCCESS
    }

    /// @dev Execute via adapter with validation
    function executeViaAdapter(address adapter, address target, bytes calldata data) external view onlyOwner returns (bytes memory) {
        // Validate adapter is registered for target
        address registeredAdapter = adapterRegistry.getTargetAdapter(target);
        require(registeredAdapter == adapter, "Invalid adapter");
        require(registeredAdapter != address(0), "Unregistered adapter");

        // Check user-level blocks
        require(!_blockedAdapters[adapter], "Adapter blocked");
        require(!_blockedTargets[target], "Target blocked");

        // Mock execution
        return _mockExecution(data);
    }

    /// @dev Batch execute via adapters
    function executeViaAdapterBatch(address[] calldata adapters, address[] calldata targets, bytes[] calldata datas) external view onlyOwner returns (bytes[] memory results) {
        if (adapters.length != targets.length || targets.length != datas.length) {
            revert YieldSeekerErrors.InvalidState();
        }

        results = new bytes[](adapters.length);
        for (uint256 i = 0; i < adapters.length; i++) {
            // Use internal call to executeViaAdapter logic
            address registeredAdapter = adapterRegistry.getTargetAdapter(targets[i]);
            require(registeredAdapter == adapters[i], "Invalid adapter");
            require(registeredAdapter != address(0), "Unregistered adapter");
            require(!_blockedAdapters[adapters[i]], "Adapter blocked");
            require(!_blockedTargets[targets[i]], "Target blocked");

            results[i] = _mockExecution(datas[i]);
        }
    }

    /// @dev Block adapter
    function blockAdapter(address adapter) external onlyOwner {
        _blockedAdapters[adapter] = true;
        emit AdapterBlocked(adapter);
    }

    /// @dev Unblock adapter
    function unblockAdapter(address adapter) external onlyOwner {
        _blockedAdapters[adapter] = false;
        emit AdapterUnblocked(adapter);
    }

    /// @dev Block target
    function blockTarget(address target) external onlyOwner {
        _blockedTargets[target] = true;
        emit TargetBlocked(target);
    }

    /// @dev Unblock target
    function unblockTarget(address target) external onlyOwner {
        _blockedTargets[target] = false;
        emit TargetUnblocked(target);
    }

    /// @dev Check if adapter is blocked
    function isAdapterBlocked(address adapter) external view returns (bool) {
        return _blockedAdapters[adapter];
    }

    /// @dev Check if target is blocked
    function isTargetBlocked(address target) external view returns (bool) {
        return _blockedTargets[target];
    }

    /// @dev Withdraw specific asset to user
    function withdrawAssetToUser(address recipient, address asset, uint256 amount) external onlyOwner {
        if (recipient == address(0)) revert YieldSeekerErrors.ZeroAddress();
        if (asset == address(0)) revert YieldSeekerErrors.ZeroAddress();

        IERC20 token = IERC20(asset);
        uint256 balance = token.balanceOf(address(this));

        // If withdrawing baseAsset, respect fees
        if (asset == baseAsset) {
            uint256 feesOwed = feeTracker.getFeesOwed(address(this));
            uint256 withdrawable = balance > feesOwed ? balance - feesOwed : 0;
            if (withdrawable < amount) revert YieldSeekerErrors.InsufficientBalance();
        } else {
            // For non-baseAsset tokens, allow direct withdrawal (recovery mechanism)
            if (balance < amount) revert YieldSeekerErrors.InsufficientBalance();
        }

        if (amount > 0) {
            require(token.transfer(recipient, amount), "Transfer failed");
        }
        emit WithdrewTokenToUser(owner, recipient, asset, amount);
    }

    /// @dev Withdraw all of a specific asset to user
    function withdrawAllAssetToUser(address recipient, address asset) external onlyOwner {
        if (recipient == address(0)) revert YieldSeekerErrors.ZeroAddress();
        if (asset == address(0)) revert YieldSeekerErrors.ZeroAddress();

        IERC20 token = IERC20(asset);
        uint256 balance = token.balanceOf(address(this));
        uint256 amount = balance;

        // If withdrawing baseAsset, deduct fees from withdrawable amount
        if (asset == baseAsset) {
            uint256 feesOwed = feeTracker.getFeesOwed(address(this));
            amount = balance > feesOwed ? balance - feesOwed : 0;
        }

        if (amount > 0) {
            require(token.transfer(recipient, amount), "Transfer failed");
        }
        emit WithdrewTokenToUser(owner, recipient, asset, amount);
    }

    /// @dev Withdraw tokens to user (legacy - uses baseAsset)
    function withdrawTokenToUser(address recipient, uint256 amount) external onlyOwner {
        IERC20 token = IERC20(baseAsset);
        if (token.balanceOf(address(this)) < amount) {
            revert YieldSeekerErrors.InsufficientBalance();
        }

        if (amount > 0) {
            require(token.transfer(recipient, amount), "Transfer failed");
        }

        emit WithdrewTokenToUser(owner, recipient, baseAsset, amount);
    }

    /// @dev Withdraw ETH to user
    function withdrawEthToUser(address recipient, uint256 amount) external onlyOwner {
        if (address(this).balance < amount) {
            revert YieldSeekerErrors.InsufficientBalance();
        }

        if (amount > 0) {
            (bool success,) = recipient.call{value: amount}("");
            require(success, "ETH transfer failed");
        }

        emit WithdrewEthToUser(owner, recipient, amount);
    }

    /// @dev Sync from factory (mock)
    function syncFromFactory(address newRegistry, address newFeeTracker) external onlyOwner {
        adapterRegistry = IAdapterRegistry(newRegistry);
        feeTracker = IFeeTracker(newFeeTracker);
        emit SyncedFromFactory(newRegistry, newFeeTracker);
    }

    /// @dev Mock upgrade functionality
    function upgradeToAndCall(address, bytes calldata) external onlyOwner {
        // Mock upgrade - just verify owner permission
    }

    /// @dev Mock execution logic
    function _mockExecution(bytes calldata data) internal pure returns (bytes memory) {
        // Simple mock responses based on data content
        if (keccak256(data) == keccak256("revert")) {
            revert("execution failed");
        }
        if (keccak256(data) == keccak256("return_custom")) {
            return "custom_data";
        }
        return "success";
    }

    /// @dev Receive ETH
    receive() external payable {}
}
