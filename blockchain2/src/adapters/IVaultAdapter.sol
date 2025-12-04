// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IVaultAdapter
 * @notice Interface for vault adapters that provide safe, standardized access to DeFi protocols
 * @dev Adapters are called via DELEGATECALL from AgentWallet
 *      This means address(this) == agentWallet during execution
 *      This allows direct vault interactions without intermediate token transfers
 *      All deposits/withdrawals automatically use address(this) as recipient
 *      This prevents compromised operator from redirecting funds to arbitrary addresses
 */
interface IVaultAdapter {
    /**
     * @notice Deposit base asset into vault
     * @param vault Address of the vault/pool
     * @param asset Address of the asset to deposit
     * @param amount Amount of base asset to deposit
     * @return shares Amount of vault shares received
     * @dev Via delegatecall (address(this) = agentWallet):
     *      1. Approve vault to spend tokens
     *      2. Call vault.deposit(amount, address(this))
     *      3. Shares are minted to address(this) = agentWallet
     */
    function deposit(address vault, address asset, uint256 amount) external returns (uint256 shares);

    /**
     * @notice Withdraw base asset from vault
     * @param vault Address of the vault/pool
     * @param asset Address of the asset to withdraw
     * @param amount Amount to withdraw (shares for ERC4626, amount for Aave)
     * @return actualAmount Amount of base asset received
     * @dev Via delegatecall (address(this) = agentWallet):
     *      Calls vault.withdraw()/redeem() with address(this) as receiver
     *      Assets are sent to address(this) = agentWallet
     */
    function withdraw(address vault, address asset, uint256 amount) external returns (uint256 actualAmount);

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
