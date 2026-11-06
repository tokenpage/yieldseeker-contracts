// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {UnknownOperation} from "../AWKAdapter.sol";
import {AWKErrors} from "../AWKErrors.sol";
import {AWKSwapAdapter, InvalidRouteLength, InvalidSwapRoute, InvalidSwapTokenAddress} from "./AWKSwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error InvalidAerodromeV2RouterTarget(address target, address expected);

interface IAerodromeV2Router {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, Route[] memory routes, address to, uint256 deadline) external returns (uint256[] memory amounts);
}

/**
 * @title AWKAerodromeV2SwapAdapter
 * @notice Generic adapter for Aerodrome V2 swaps using structured route parameters
 * @dev Swap execution runs via delegatecall from AgentWallet.
 *      Accepts multi-hop routes through path+stable arrays with strict validation.
 */
contract AWKAerodromeV2SwapAdapter is AWKSwapAdapter {
    using SafeERC20 for IERC20;

    struct SwapRoute {
        address[] path;
        bool[] stables;
    }

    uint256 internal constant FAR_FUTURE_DEADLINE = type(uint32).max;
    uint256 internal constant MAX_HOPS = 4;

    address public immutable AERODROME_V2_ROUTER;
    address public immutable AERODROME_V2_FACTORY;

    constructor(address aerodromeV2Router, address aerodromeV2Factory) {
        if (aerodromeV2Router == address(0) || aerodromeV2Factory == address(0)) revert AWKErrors.ZeroAddress();
        AERODROME_V2_ROUTER = aerodromeV2Router;
        AERODROME_V2_FACTORY = aerodromeV2Factory;
    }

    // ============ Swap Operations ============

    /**
     * @notice Swap tokens via Aerodrome V2 (public interface, should not be called directly)
     * @dev This is a placeholder function signature. Actual execution happens via execute() -> _swapOperation()
     */
    function swap(address sellToken, address buyToken, SwapRoute calldata route, uint256 sellAmount, uint256 minBuyAmount) external pure returns (uint256) {
        revert AWKErrors.DirectCallForbidden();
    }

    // ============ Swap Execution (delegatecall only) ============

    /**
     * @notice Validate a swap call and run it
     * @param target The Aerodrome V2 router target contract
     * @param data ABI-encoded call data (must match swap() selector)
     * @return ABI-encoded buy amount
     */
    function execute(address target, bytes calldata data) external payable virtual override onlyDelegateCall returns (bytes memory) {
        if (bytes4(data[:4]) != this.swap.selector) revert UnknownOperation();
        (address sellToken, address buyToken, SwapRoute memory route, uint256 sellAmount, uint256 minBuyAmount) = abi.decode(data[4:], (address, address, SwapRoute, uint256, uint256));
        if (target != AERODROME_V2_ROUTER) revert InvalidAerodromeV2RouterTarget(target, AERODROME_V2_ROUTER);
        _validateRoute(sellToken, buyToken, route);
        _validateSwap(sellToken, buyToken, sellAmount, minBuyAmount);
        (, uint256 buyAmount) = _swapOperation(target, sellToken, buyToken, sellAmount, minBuyAmount, abi.encode(route));
        return abi.encode(buyAmount);
    }

    // ============ Internal Implementations ============

    function _swap(address router, address sellToken, uint256 sellAmount, uint256 minBuyAmount, bytes memory encodedRoute) internal virtual override {
        SwapRoute memory route = abi.decode(encodedRoute, (SwapRoute));
        IERC20(sellToken).forceApprove(router, sellAmount);
        IAerodromeV2Router.Route[] memory routes = new IAerodromeV2Router.Route[](route.stables.length);
        for (uint256 i = 0; i < route.stables.length; i++) {
            routes[i] = IAerodromeV2Router.Route({from: route.path[i], to: route.path[i + 1], stable: route.stables[i], factory: AERODROME_V2_FACTORY});
        }
        IAerodromeV2Router(router).swapExactTokensForTokens(sellAmount, minBuyAmount, routes, address(this), FAR_FUTURE_DEADLINE);
    }

    function _validateRoute(address sellToken, address buyToken, SwapRoute memory route) internal pure {
        uint256 pathLength = route.path.length;
        if (pathLength < 2 || pathLength > MAX_HOPS + 1) revert InvalidRouteLength(pathLength);
        if (route.stables.length != pathLength - 1) revert InvalidSwapRoute();
        _validateRouteEndpoints(sellToken, buyToken, route.path[0], route.path[pathLength - 1]);
        for (uint256 i = 0; i < pathLength; i++) {
            if (route.path[i] == address(0)) revert InvalidSwapTokenAddress(route.path[i]);
        }
    }
}
