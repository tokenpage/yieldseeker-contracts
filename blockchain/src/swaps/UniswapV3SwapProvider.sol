// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapProvider} from "./ISwapProvider.sol";

interface ISwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

interface IQuoter {
    function quoteExactInputSingle(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint160 sqrtPriceLimitX96) external returns (uint256 amountOut);
}

/**
 * @title UniswapV3SwapProvider
 * @notice Swap provider wrapper for Uniswap V3
 * @dev Wraps Uniswap V3 swap router
 */
contract UniswapV3SwapProvider is ISwapProvider {
    /// @notice Uniswap V3 Swap Router
    ISwapRouter public immutable swapRouter;

    /// @notice Uniswap V3 Quoter (for getting quotes)
    IQuoter public immutable quoter;

    /// @notice Default pool fee tier (e.g., 3000 = 0.3%)
    uint24 public immutable defaultFeeTier;

    /// @notice Address of the YieldSeeker system (AgentController calls only)
    address public immutable yieldSeekerSystem;

    error NotAuthorized();
    error InvalidAddress();
    error SwapFailed();
    error InsufficientOutput();

    modifier onlyYieldSeeker() {
        if (msg.sender != yieldSeekerSystem) revert NotAuthorized();
        _;
    }

    constructor(address _swapRouter, address _quoter, uint24 _defaultFeeTier, address _yieldSeekerSystem) {
        if (_swapRouter == address(0) || _quoter == address(0) || _yieldSeekerSystem == address(0)) {
            revert InvalidAddress();
        }

        swapRouter = ISwapRouter(_swapRouter);
        quoter = IQuoter(_quoter);
        defaultFeeTier = _defaultFeeTier;
        yieldSeekerSystem = _yieldSeekerSystem;
    }

    /**
     * @inheritdoc ISwapProvider
     */
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut, address recipient) external onlyYieldSeeker returns (uint256 amountOut) {
        // Transfer tokens from agent wallet to this provider
        IERC20 tokenInContract = IERC20(tokenIn);
        bool success = tokenInContract.transferFrom(msg.sender, address(this), amountIn);
        if (!success) revert SwapFailed();

        // Approve swap router
        tokenInContract.approve(address(swapRouter), amountIn);

        // Execute swap
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: defaultFeeTier,
            recipient: recipient,
            deadline: block.timestamp,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });

        amountOut = swapRouter.exactInputSingle(params);

        if (amountOut < minAmountOut) revert InsufficientOutput();
    }

    /**
     * @inheritdoc ISwapProvider
     */
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 amountOut) {
        return quoter.quoteExactInputSingle(tokenIn, tokenOut, defaultFeeTier, amountIn, 0);
    }

    /**
     * @inheritdoc ISwapProvider
     */
    function getRouter() external view returns (address router) {
        return address(swapRouter);
    }
}
