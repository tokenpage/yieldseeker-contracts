// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IVaultAdapter} from "./IVaultAdapter.sol";

/**
 * @title IAaveV3Pool
 * @notice Minimal Aave V3 Pool interface
 */
interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

/**
 * @title IAToken
 * @notice Minimal aToken interface
 */
interface IAToken {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
}

/**
 * @title AaveV3PoolAdapter
 * @notice Adapter for Aave V3 pools with per-asset operations
 * @dev This adapter is called via DELEGATECALL from AgentWallet
 *      Aave V3 has a single Pool contract that manages multiple assets
 *      Each asset has its own aToken. This adapter enforces security per asset.
 *      Via delegatecall: address(this) = agentWallet, allowing direct interactions
 */
contract AaveV3PoolAdapter is IVaultAdapter {
    using SafeERC20 for IERC20;

    /**
     * @notice Deposit asset into Aave V3 pool
     * @param pool Address of the Aave V3 pool
     * @param asset Address of the asset to deposit
     * @param amount Amount to deposit
     * @param agentWallet Address of the agent wallet (enforced as recipient)
     * @return shares Amount deposited (Aave is 1:1 with aTokens)
     * @dev Via delegatecall:
     *      1. Approve pool to spend agentWallet's tokens
     *      2. Call pool.supply with agentWallet as onBehalfOf
     *      3. Pool transfers from agentWallet, mints aTokens to agentWallet
     *      Security: Hardcodes agentWallet as onBehalfOf parameter
     */
    function deposit(address pool, address asset, uint256 amount, address agentWallet) external override returns (uint256 shares) {
        IERC20(asset).forceApprove(pool, amount);
        IAaveV3Pool(pool).supply(asset, amount, agentWallet, 0);

        return amount;
    }

    /**
     * @notice Withdraw asset from Aave V3 pool
     * @param pool Address of the Aave V3 pool
     * @param asset Address of the asset to withdraw
     * @param amount Amount to withdraw (use type(uint256).max for full balance)
     * @param agentWallet Address of the agent wallet (enforced as recipient)
     * @return actualAmount Amount withdrawn
     * @dev Via delegatecall:
     *      Pool burns aTokens from agentWallet, sends assets to agentWallet
     *      Security: Hardcodes agentWallet as to parameter
     */
    function withdraw(address pool, address asset, uint256 amount, address agentWallet) external override returns (uint256 actualAmount) {
        return IAaveV3Pool(pool).withdraw(asset, amount, agentWallet);
    }

    /**
     * @notice Get the base asset for an aToken
     * @param aToken Address of the aToken
     * @return asset Address of the underlying asset
     * @dev For Aave, we need the aToken address to get the underlying asset
     */
    function getAsset(address aToken) external view override returns (address asset) {
        return IAToken(aToken).UNDERLYING_ASSET_ADDRESS();
    }

    /**
     * @notice Get aToken balance for an agent wallet
     * @param aToken Address of the aToken
     * @param agentWallet Address of the agent wallet
     * @return balance Amount of aTokens owned
     */
    function getShareBalance(address aToken, address agentWallet) external view override returns (uint256 balance) {
        return IAToken(aToken).balanceOf(agentWallet);
    }
}
