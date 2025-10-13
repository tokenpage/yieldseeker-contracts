// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IVaultAdapter
 * @notice Interface for vault adapters that provide safe, standardized access to DeFi protocols
 * @dev Adapters are called via DELEGATECALL from AgentWallet
 *      This allows direct vault interactions without intermediate token transfers
 *      Adapters enforce that all deposits/withdrawals go to/from the agent wallet only
 *      This prevents compromised operator from withdrawing to arbitrary addresses
 */
interface IVaultAdapter {
    /**
     * @notice Deposit base asset into vault
     * @param vault Address of the vault/pool
     * @param asset Address of the asset to deposit
     * @param amount Amount of base asset to deposit
     * @param agentWallet Address of the agent wallet (enforced as recipient)
     * @return shares Amount of vault shares received
     * @dev CRITICAL: Adapter must enforce agentWallet as the recipient
     *      Via delegatecall: adapter approves vault, then calls vault.deposit()
     *      Vault transfers directly from agentWallet, mints shares to agentWallet
     */
    function deposit(address vault, address asset, uint256 amount, address agentWallet) external returns (uint256 shares);

    /**
     * @notice Withdraw base asset from vault
     * @param vault Address of the vault/pool
     * @param asset Address of the asset to withdraw
     * @param amount Amount to withdraw (shares for ERC4626, amount for Aave)
     * @param agentWallet Address of the agent wallet (enforced as recipient)
     * @return actualAmount Amount of base asset received
     * @dev CRITICAL: Adapter must enforce agentWallet as the recipient
     *      Via delegatecall: calls vault.withdraw()/redeem() with agentWallet as receiver
     */
    function withdraw(address vault, address asset, uint256 amount, address agentWallet) external returns (uint256 actualAmount);

    /**
     * @notice Get the base asset for a vault
     * @param vault Address of the vault
     * @return asset Address of the underlying asset
     */
    function getAsset(address vault) external view returns (address asset);

    /**
     * @notice Get share balance for an agent wallet
     * @param vault Address of the vault
     * @param agentWallet Address of the agent wallet
     * @return shares Amount of vault shares owned
     */
    function getShareBalance(address vault, address agentWallet) external view returns (uint256 shares);
}
