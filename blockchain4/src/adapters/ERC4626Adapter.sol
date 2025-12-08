// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IActionRegistry {
    function isValidTarget(address target) external view returns (bool valid, address adapter);
}

/**
 * @title IERC4626
 * @notice Minimal ERC4626 interface
 */
interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title ERC4626Adapter
 * @notice Adapter for interacting with ERC4626 vaults via delegatecall
 * @dev Called via delegatecall from AgentWallet - executes in wallet context
 */
contract ERC4626Adapter {
    using SafeERC20 for IERC20;

    /// @notice The central registry that validates targets
    IActionRegistry public immutable registry;

    /// @notice This adapter's own address (for validation during delegatecall)
    address public immutable self;

    event Deposited(address indexed wallet, address indexed vault, uint256 assets, uint256 shares);
    event Withdrawn(address indexed wallet, address indexed vault, uint256 shares, uint256 assets);

    error VaultNotRegistered(address vault);
    error WrongAdapter(address vault, address expectedAdapter);
    error ZeroAmount();

    constructor(address _registry) {
        registry = IActionRegistry(_registry);
        self = address(this);
    }

    // ============ Internal Validation ============

    /**
     * @notice Validate that target vault is registered for this adapter
     * @param vault The vault address to validate
     * @dev Makes external call to registry (works in delegatecall context)
     *      Uses `self` immutable to check adapter matches
     */
    function _validateVault(address vault) internal view {
        (bool valid, address adapter) = registry.isValidTarget(vault);
        if (!valid) revert VaultNotRegistered(vault);
        if (adapter != self) revert WrongAdapter(vault, adapter);
    }

    // ============ Vault Operations (called via DELEGATECALL) ============

    /**
     * @notice Deposit assets into an ERC4626 vault
     * @param vault Address of the ERC4626 vault (must be registered)
     * @param amount Amount of assets to deposit
     * @return shares Amount of vault shares received
     */
    function deposit(address vault, uint256 amount) external returns (uint256 shares) {
        _validateVault(vault);
        if (amount == 0) revert ZeroAmount();
        address asset = IERC4626(vault).asset();
        IERC20(asset).forceApprove(vault, amount);
        shares = IERC4626(vault).deposit(amount, address(this));
        emit Deposited(address(this), vault, amount, shares);
    }

    /**
     * @notice Withdraw assets from an ERC4626 vault
     * @param vault Address of the ERC4626 vault (must be registered)
     * @param shares Amount of shares to redeem
     * @return assets Amount of underlying assets received
     */
    function withdraw(address vault, uint256 shares) external returns (uint256 assets) {
        _validateVault(vault);
        if (shares == 0) revert ZeroAmount();
        assets = IERC4626(vault).redeem(shares, address(this), address(this));
        emit Withdrawn(address(this), vault, shares, assets);
    }

    // ============ View Functions ============

    /**
     * @notice Get the underlying asset of a vault
     */
    function getAsset(address vault) external view returns (address) {
        return IERC4626(vault).asset();
    }

    /**
     * @notice Get share balance for a wallet
     */
    function getShareBalance(address vault, address wallet) external view returns (uint256) {
        return IERC4626(vault).balanceOf(wallet);
    }
}
