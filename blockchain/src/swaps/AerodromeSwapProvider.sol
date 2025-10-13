// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ISwapProvider} from "./ISwapProvider.sol";

interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, Route[] calldata routes, address to, uint256 deadline) external returns (uint256[] memory amounts);

    function getAmountsOut(uint256 amountIn, Route[] calldata routes) external view returns (uint256[] memory amounts);
}

/**
 * @title AerodromeSwapProvider
 * @notice Swap provider wrapper for Aerodrome DEX
 * @dev Wraps Aerodrome router for Base network
 */
contract AerodromeSwapProvider is ISwapProvider {
    /// @notice Aerodrome Router
    IAerodromeRouter public immutable router;

    /// @notice Default factory address
    address public immutable defaultFactory;

    /// @notice Whether to use stable pools by default
    bool public immutable defaultStable;

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

    constructor(address _router, address _defaultFactory, bool _defaultStable, address _yieldSeekerSystem) {
        if (_router == address(0) || _defaultFactory == address(0) || _yieldSeekerSystem == address(0)) {
            revert InvalidAddress();
        }

        router = IAerodromeRouter(_router);
        defaultFactory = _defaultFactory;
        defaultStable = _defaultStable;
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

        // Approve router
        tokenInContract.approve(address(router), amountIn);

        // Build route
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({from: tokenIn, to: tokenOut, stable: defaultStable, factory: defaultFactory});

        // Execute swap
        uint256[] memory amounts = router.swapExactTokensForTokens(amountIn, minAmountOut, routes, recipient, block.timestamp);

        amountOut = amounts[amounts.length - 1];

        if (amountOut < minAmountOut) revert InsufficientOutput();
    }

    /**
     * @inheritdoc ISwapProvider
     */
    function getQuote(address tokenIn, address tokenOut, uint256 amountIn) external returns (uint256 amountOut) {
        IAerodromeRouter.Route[] memory routes = new IAerodromeRouter.Route[](1);
        routes[0] = IAerodromeRouter.Route({from: tokenIn, to: tokenOut, stable: defaultStable, factory: defaultFactory});

        uint256[] memory amounts = router.getAmountsOut(amountIn, routes);
        amountOut = amounts[amounts.length - 1];
    }

    /**
     * @inheritdoc ISwapProvider
     */
    function getRouter() external view returns (address routerAddress) {
        return address(router);
    }
}
