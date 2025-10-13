// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IVaultProvider} from "./IVaultProvider.sol";

/**
 * @title ERC4626VaultProvider
 * @notice Vault provider wrapper for ERC4626-compliant vaults
 * @dev Works with any ERC4626 vault (Yearn, Morpho, etc.)
 *      Deploy once and use for all ERC4626 vaults
 */
contract ERC4626VaultProvider is IVaultProvider {
    /// @notice Address of the YieldSeeker system (AgentController calls only)
    address public immutable yieldSeekerSystem;

    error NotAuthorized();
    error InvalidAddress();
    error DepositFailed();
    error WithdrawFailed();
    error InvalidToken();

    modifier onlyYieldSeeker() {
        if (msg.sender != yieldSeekerSystem) revert NotAuthorized();
        _;
    }

    constructor(address _yieldSeekerSystem) {
        if (_yieldSeekerSystem == address(0)) revert InvalidAddress();
        yieldSeekerSystem = _yieldSeekerSystem;
    }

    /**
     * @inheritdoc IVaultProvider
     */
    function deposit(address vaultAddress, address token, uint256 amount) external onlyYieldSeeker returns (uint256 shares) {
        if (vaultAddress == address(0)) revert InvalidAddress();
        IERC4626 vault = IERC4626(vaultAddress);
        IERC20 underlyingToken = IERC20(vault.asset());

        if (token != address(underlyingToken)) revert InvalidToken();

        // Transfer tokens from agent wallet to this provider
        bool success = underlyingToken.transferFrom(msg.sender, address(this), amount);
        if (!success) revert DepositFailed();

        // Approve vault to spend tokens
        underlyingToken.approve(vaultAddress, amount);

        // Deposit to vault and receive shares
        shares = vault.deposit(amount, msg.sender);
        if (shares == 0) revert DepositFailed();
    }

    /**
     * @inheritdoc IVaultProvider
     */
    function withdraw(address vaultAddress, uint256 shares) external onlyYieldSeeker returns (uint256 amount) {
        if (vaultAddress == address(0)) revert InvalidAddress();
        IERC4626 vault = IERC4626(vaultAddress);

        // Redeem shares for underlying tokens, send directly to agent wallet
        amount = vault.redeem(shares, msg.sender, msg.sender);
        if (amount == 0) revert WithdrawFailed();
    }

    /**
     * @inheritdoc IVaultProvider
     */
    function claimRewards(address /* vaultAddress */ ) external view onlyYieldSeeker returns (address[] memory tokens, uint256[] memory amounts) {
        // ERC4626 standard doesn't include rewards - return empty arrays
        // Override this in specific implementations if vault has rewards
        tokens = new address[](0);
        amounts = new uint256[](0);
    }

    /**
     * @inheritdoc IVaultProvider
     */
    function getShareValue(address vaultAddress, uint256 shares) external view returns (uint256 value) {
        if (vaultAddress == address(0)) revert InvalidAddress();
        IERC4626 vault = IERC4626(vaultAddress);
        return vault.convertToAssets(shares);
    }

    /**
     * @inheritdoc IVaultProvider
     */
    function getUnderlyingToken(address vaultAddress) external view returns (address token) {
        if (vaultAddress == address(0)) revert InvalidAddress();
        IERC4626 vault = IERC4626(vaultAddress);
        return vault.asset();
    }

    /**
     * @inheritdoc IVaultProvider
     */
    function getShareCount(address vaultAddress, address wallet) external view returns (uint256 shares) {
        if (vaultAddress == address(0)) revert InvalidAddress();
        IERC4626 vault = IERC4626(vaultAddress);
        return vault.balanceOf(wallet);
    }

    /**
     * @inheritdoc IVaultProvider
     */
    function getWithdrawableShareCount(address vaultAddress, address wallet) external view returns (uint256 shares) {
        if (vaultAddress == address(0)) revert InvalidAddress();
        IERC4626 vault = IERC4626(vaultAddress);
        return vault.maxRedeem(wallet);
    }

    /**
     * @inheritdoc IVaultProvider
     */
    function getVaultToken(address vaultAddress) external view returns (address vaultToken) {
        if (vaultAddress == address(0)) revert InvalidAddress();
        return vaultAddress;
    }
}
