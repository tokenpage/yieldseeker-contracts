// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IVaultProvider
 * @notice Standardized interface for vault provider wrappers
 * @dev Each vault provider (Aave, Morpho, etc.) implements this interface
 *      Providers are deployed once and work with multiple vault instances
 */
interface IVaultProvider {
    /**
     * @notice Deposit assets into the vault
     * @param vault The vault contract address
     * @param token The token to deposit (e.g., USDC)
     * @param amount Amount of tokens to deposit
     * @return shares Amount of vault shares received
     */
    function deposit(address vault, address token, uint256 amount) external returns (uint256 shares);

    /**
     * @notice Withdraw assets from the vault by redeeming shares
     * @param vault The vault contract address
     * @param shares Amount of vault shares to redeem
     * @return amount Amount of underlying tokens received
     */
    function withdraw(address vault, uint256 shares) external returns (uint256 amount);

    /**
     * @notice Claim all available rewards from the vault
     * @param vault The vault contract address
     * @dev Returns parallel arrays of reward tokens and amounts
     * @return tokens Array of reward token addresses
     * @return amounts Array of reward token amounts
     */
    function claimRewards(address vault) external returns (address[] memory tokens, uint256[] memory amounts);

    /**
     * @notice Get the current value of shares in underlying tokens
     * @param vault The vault contract address
     * @param shares Amount of vault shares
     * @return value Value in underlying tokens
     */
    function getShareValue(address vault, uint256 shares) external view returns (uint256 value);

    /**
     * @notice Get the share balance for a specific wallet
     * @param vault The vault contract address
     * @param wallet The wallet address to check
     * @return shares Amount of vault shares held by the wallet
     */
    function getShareCount(address vault, address wallet) external view returns (uint256 shares);

    /**
     * @notice Get the maximum withdrawable share count for a specific wallet
     * @dev This accounts for vault liquidity constraints and withdrawal limits
     * @param vault The vault contract address
     * @param wallet The wallet address to check
     * @return shares Maximum amount of vault shares that can be withdrawn
     */
    function getWithdrawableShareCount(address vault, address wallet) external view returns (uint256 shares);

    /**
     * @notice Get the underlying token address for this vault
     * @param vault The vault contract address
     * @return token The underlying token address (e.g., USDC)
     */
    function getUnderlyingToken(address vault) external view returns (address token);

    /**
     * @notice Get the vault token address (share token)
     * @param vault The vault contract address
     * @return vaultToken The vault share token address
     */
    function getVaultToken(address vault) external view returns (address vaultToken);
}
