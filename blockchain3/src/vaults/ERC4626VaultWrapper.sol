// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "../interfaces/IPolicyValidator.sol";

interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function balanceOf(address account) external view returns (uint256);
}

interface IAgentWallet {
    function baseAsset() external view returns (address);
}

/**
 * @title ERC4626VaultWrapper
 * @notice Combined wrapper + validator for ERC4626 vaults (Yearn V3, MetaMorpho, etc.)
 * @dev This contract:
 *      1. Acts as a VALIDATOR for the AgentActionPolicy (implements IPolicyValidator)
 *      2. Acts as a WRAPPER that wallets call to interact with vaults
 *
 *      Security guarantees:
 *      - Only allowed vaults can be interacted with
 *      - Asset must match wallet's baseAsset
 *      - All shares are minted directly to the calling wallet
 *      - Wallet must pre-approve this wrapper for token transfers
 *
 *      Flow:
 *      1. Router calls Policy.validateAction() → Policy calls this.validateAction()
 *      2. If valid, Router triggers wallet.executeFromExecutor() → wallet CALLs this.deposit()
 *      3. This contract pulls tokens from wallet, deposits to vault, shares go to wallet
 */
contract ERC4626VaultWrapper is IPolicyValidator, Ownable {
    using SafeERC20 for IERC20;

    mapping(address => bool) public allowedVaults;

    event VaultAllowed(address indexed vault, bool allowed);
    event Deposited(address indexed wallet, address indexed vault, uint256 assets, uint256 shares);
    event Withdrawn(address indexed wallet, address indexed vault, uint256 shares, uint256 assets);

    error VaultNotAllowed(address vault);
    error AssetMismatch(address expected, address actual);
    error InvalidSelector(bytes4 selector);
    error ZeroAmount();

    bytes4 public constant DEPOSIT_SELECTOR = bytes4(keccak256("deposit(address,uint256)"));
    bytes4 public constant WITHDRAW_SELECTOR = bytes4(keccak256("withdraw(address,uint256)"));

    constructor() Ownable(msg.sender) {}

    // ============ Admin ============

    function setVaultAllowed(address vault, bool allowed) external onlyOwner {
        allowedVaults[vault] = allowed;
        emit VaultAllowed(vault, allowed);
    }

    // ============ IPolicyValidator ============

    function validateAction(
        address wallet,
        address, // target (this contract)
        bytes4 selector,
        bytes calldata data
    ) external view override returns (bool) {
        if (selector != DEPOSIT_SELECTOR && selector != WITHDRAW_SELECTOR) {
            revert InvalidSelector(selector);
        }
        if (data.length < 4 + 64) return false;
        (address vault, uint256 amount) = abi.decode(data[4:], (address, uint256));
        if (amount == 0) return false;
        if (!allowedVaults[vault]) return false;
        if (selector == DEPOSIT_SELECTOR) {
            address vaultAsset = IERC4626(vault).asset();
            address walletBaseAsset = IAgentWallet(wallet).baseAsset();
            if (vaultAsset != walletBaseAsset) return false;
        }
        return true;
    }

    // ============ Vault Operations ============

    /**
     * @notice Deposit assets into an ERC4626 vault
     * @param vault Address of the ERC4626 vault
     * @param amount Amount of assets to deposit
     * @return shares Amount of vault shares received
     * @dev Caller (wallet) must have approved this contract for the asset
     *      Shares are minted directly to the calling wallet (msg.sender)
     */
    function deposit(address vault, uint256 amount) external returns (uint256 shares) {
        if (!allowedVaults[vault]) revert VaultNotAllowed(vault);
        if (amount == 0) revert ZeroAmount();
        address asset = IERC4626(vault).asset();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(vault, amount);
        shares = IERC4626(vault).deposit(amount, msg.sender);
        emit Deposited(msg.sender, vault, amount, shares);
    }

    /**
     * @notice Withdraw assets from an ERC4626 vault
     * @param vault Address of the ERC4626 vault
     * @param shares Amount of shares to redeem
     * @return assets Amount of assets received
     * @dev Caller (wallet) must have approved this contract for the vault shares
     *      Assets are sent directly to the calling wallet (msg.sender)
     */
    function withdraw(address vault, uint256 shares) external returns (uint256 assets) {
        if (!allowedVaults[vault]) revert VaultNotAllowed(vault);
        if (shares == 0) revert ZeroAmount();
        IERC20(vault).safeTransferFrom(msg.sender, address(this), shares);
        assets = IERC4626(vault).redeem(shares, msg.sender, address(this));
        emit Withdrawn(msg.sender, vault, shares, assets);
    }

    // ============ View Functions ============

    function getAsset(address vault) external view returns (address) {
        return IERC4626(vault).asset();
    }

    function getShareBalance(address vault, address wallet) external view returns (uint256) {
        return IERC4626(vault).balanceOf(wallet);
    }
}
