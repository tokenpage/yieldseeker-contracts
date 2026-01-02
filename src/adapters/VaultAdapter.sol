// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";

/**
 * @title YieldSeekerVaultAdapter
 * @notice Abstract base class for all vault adapters
 * @dev Defines the standard vault operations interface that all vault adapters must implement.
 *      This ensures consistency for operations like rebalancePortfolio which rely on these functions.
 */
abstract contract YieldSeekerVaultAdapter is YieldSeekerAdapter {
    event Deposited(address indexed wallet, address indexed vault, uint256 assets, uint256 shares);
    event Withdrawn(address indexed wallet, address indexed vault, uint256 shares, uint256 assets);

    /**
     * @notice Deposit assets into a vault (public interface, should not be called directly)
     * @param amount The amount of assets to deposit
     * @return shares The amount of vault shares received
     * @dev This is a placeholder function signature. Actual execution happens via execute() -> _depositInternal()
     */
    function deposit(uint256 amount) external pure returns (uint256 shares) {
        revert AWKErrors.DirectCallForbidden();
    }

    /**
     * @notice Deposit a percentage of base asset balance into a vault (public interface, should not be called directly)
     * @param percentageBps The percentage in basis points (10000 = 100%)
     * @return shares The amount of vault shares received
     * @dev This is a placeholder function signature. Actual execution happens via execute() -> _depositPercentageInternal()
     */
    function depositPercentage(uint256 percentageBps) external pure returns (uint256 shares) {
        revert AWKErrors.DirectCallForbidden();
    }

    /**
     * @notice Internal deposit implementation
     * @param vault The vault address
     * @param amount The amount of assets to deposit
     * @return shares The amount of vault shares received
     * @dev Must be implemented by concrete vault adapters
     */
    function _depositInternal(address vault, uint256 amount) internal virtual returns (uint256 shares);

    /**
     * @notice Internal deposit percentage implementation
     * @param vault The vault address
     * @param percentageBps The percentage in basis points (10000 = 100%)
     * @return shares The amount of vault shares received
     * @dev Implemented in base class - calculates amount and calls _depositInternal
     */
    function _depositPercentageInternal(address vault, uint256 percentageBps) internal returns (uint256 shares) {
        if (percentageBps == 0 || percentageBps > 1e4) revert AWKErrors.InvalidPercentage(percentageBps);
        uint256 balance = _baseAsset().balanceOf(address(this));
        uint256 amount = (balance * percentageBps) / 1e4;
        return _depositInternal(vault, amount);
    }

    /**
     * @notice Withdraw assets from a vault (public interface, should not be called directly)
     * @param shares The amount of vault shares to withdraw
     * @return assets The amount of assets received
     * @dev This is a placeholder function signature. Actual execution happens via execute() -> _withdrawInternal()
     */
    function withdraw(uint256 shares) external pure returns (uint256 assets) {
        revert AWKErrors.DirectCallForbidden();
    }

    /**
     * @notice Internal withdraw implementation
     * @param vault The vault address
     * @param shares The amount of vault shares to withdraw
     * @return assets The amount of assets received
     * @dev Must be implemented by concrete vault adapters
     */
    function _withdrawInternal(address vault, uint256 shares) internal virtual returns (uint256 assets);
}
