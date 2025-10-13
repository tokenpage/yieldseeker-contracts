// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ISwapProvider
 * @notice Standardized interface for DEX swap provider wrappers
 * @dev Each swap provider (Uniswap, Aerodrome, etc.) implements this interface
 */
interface ISwapProvider {
    /**
     * @notice Execute a token swap
     * @param tokenIn The token to swap from
     * @param tokenOut The token to swap to
     * @param amountIn Amount of tokenIn to swap
     * @param minAmountOut Minimum amount of tokenOut to receive (slippage protection)
     * @param recipient Address to receive the swapped tokens
     * @return amountOut Actual amount of tokenOut received
     */
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient) external returns (uint256 amountOut);

    /**
     * @notice Get quote for a swap
     * @param tokenIn Input token address
     * @param tokenOut Output token address
     * @param amountIn Amount of tokenIn to swap
     * @return amountOut Expected amount of tokenOut
     * @dev Note: Some providers (e.g., Uniswap V3) may not support view quotes
     *      and may require off-chain simulation or non-view calls
     */
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 amountOut);
    /**
     * @notice Get the DEX router address this provider wraps
     * @return router The underlying DEX router address
     */
    function getRouter() external view returns (address router);
}
