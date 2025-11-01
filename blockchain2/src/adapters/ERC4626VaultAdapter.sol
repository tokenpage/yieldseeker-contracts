// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVaultAdapter} from "./IVaultAdapter.sol";

/**
 * @title IERC4626
 * @notice Minimal ERC4626 interface
 */
interface IERC4626 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title ERC4626VaultAdapter
 * @notice Adapter for ERC4626-compliant vaults (Yearn V3, MetaMorpho, etc.)
 * @dev This adapter is called via DELEGATECALL from AgentWallet
 *      When executed via delegatecall:
 *      - address(this) = agentWallet address
 *      - msg.sender = original caller (operator)
 *      - Storage/balance context = agentWallet
 *      This allows direct vault interactions without intermediate token transfers
 *
 *      Security guarantees:
 *      1. Only approves vault (which must be pre-approved in AccessController)
 *      2. Only transfers tokens to vault via vault.deposit() call
 *      3. All deposits/withdrawals use address(this) as recipient (= agentWallet)
 *      4. No way to redirect tokens to arbitrary addresses
 */
contract ERC4626VaultAdapter is IVaultAdapter {
    using SafeERC20 for IERC20;

    /**
     * @notice Deposit base asset into ERC4626 vault
     * @param vault Address of the ERC4626 vault
     * @param asset Address of the asset to deposit
     * @param amount Amount of base asset to deposit
     * @return shares Amount of vault shares received
     * @dev Via delegatecall, this runs in agentWallet context (address(this) = agentWallet):
     *      1. Approve vault to spend tokens (vault must be pre-approved in AccessController)
     *      2. Call vault.deposit(amount, address(this))
     *      3. Vault transfers tokens from address(this), mints shares to address(this)
     */
    function deposit(address vault, address asset, uint256 amount) external override returns (uint256 shares) {
        IERC20(asset).forceApprove(vault, amount);
        shares = IERC4626(vault).deposit(amount, address(this));
    }

    /**
     * @notice Withdraw base asset from ERC4626 vault
     * @param vault Address of the ERC4626 vault
     * @param shares Amount of vault shares to redeem (amount parameter for interface compatibility)
     * @return actualAmount Amount of base asset received
     * @dev Via delegatecall, this runs in agentWallet context (address(this) = agentWallet):
     *      Vault burns shares from address(this), sends assets to address(this)
     */
    function withdraw(address vault, address, uint256 shares) external override returns (uint256 actualAmount) {
        actualAmount = IERC4626(vault).redeem(shares, address(this), address(this));
    }

    /**
     * @notice Get the base asset for an ERC4626 vault
     * @param vault Address of the vault
     * @return asset Address of the underlying asset
     */
    function getAsset(address vault) external view override returns (address asset) {
        return IERC4626(vault).asset();
    }

    /**
     * @notice Get share balance for an agent wallet
     * @param vault Address of the vault
     * @param agentWallet Address of the agent wallet
     * @return shares Amount of vault shares owned
     */
    function getShareBalance(address vault, address agentWallet) external view override returns (uint256 shares) {
        return IERC4626(vault).balanceOf(agentWallet);
    }
}
