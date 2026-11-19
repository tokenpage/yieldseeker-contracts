// SPDX-License-Identifier: MIT
//
//      _                    _ __        __    _ _      _   _  ___ _
//     / \   __ _  ___ _ __ | |\ \      / /_ _| | | ___| |_| |/ (_) |_
//    / _ \ / _` |/ _ \ '_ \| __\ \ /\ / / _` | | |/ _ \ __| ' /| | __|
//   / ___ \ (_| |  __/ | | | |_ \ V  V / (_| | | |  __/ |_| . \| | |_
//  /_/   \_\__, |\___|_| |_|\__| \_/\_/ \__,_|_|_|\___|\__|_|\_\_|\__|
//          |___/
//
//  Build verifiably secure onchain agents
//  https://agentwalletkit.com
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.38;

import {AWKErrors} from "../AWKErrors.sol";
import {AWKSwapAdapter, AWKSwapOperations} from "./AWKSwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IRouter as IAerodromeV2Router} from "aerodrome/interfaces/IRouter.sol";

error InvalidAerodromeV2RouterTarget(address target, address expected);

/**
 * @title AWKAerodromeV2SwapAdapterCore
 * @notice Aerodrome V2 swaps using structured route parameters, without an operations layer
 * @dev Accepts multi-hop routes through path+stable arrays with strict validation. The router is the target of the
 *      execute call.
 */
abstract contract AWKAerodromeV2SwapAdapterCore is AWKSwapAdapter {
    using SafeERC20 for IERC20;

    struct SwapRoute {
        address[] path;
        bool[] stables;
    }

    address public immutable AERODROME_V2_ROUTER;
    address public immutable AERODROME_V2_FACTORY;

    constructor(address aerodromeV2Router, address aerodromeV2Factory) {
        if (aerodromeV2Router == address(0) || aerodromeV2Factory == address(0)) revert AWKErrors.ZeroAddress();
        AERODROME_V2_ROUTER = aerodromeV2Router;
        AERODROME_V2_FACTORY = aerodromeV2Factory;
    }

    function swap(address sellToken, address buyToken, SwapRoute calldata route, uint256 sellAmount, uint256 minBuyAmount, uint256 deadline) external onlyExecute returns (uint256 buyAmount) {
        if (_target() != AERODROME_V2_ROUTER) revert InvalidAerodromeV2RouterTarget(_target(), AERODROME_V2_ROUTER);
        _validateSwapRoute(sellToken, buyToken, sellAmount, minBuyAmount, route.path, route.stables.length);
        (, buyAmount) = _swapOperation(AERODROME_V2_ROUTER, sellToken, buyToken, sellAmount, minBuyAmount, deadline, abi.encode(route));
    }

    // ============ Internal Implementations ============

    function _swap(address router, address sellToken, uint256 sellAmount, uint256 minBuyAmount, uint256 deadline, bytes memory encodedRoute) internal virtual override returns (uint256) {
        SwapRoute memory route = abi.decode(encodedRoute, (SwapRoute));
        IERC20(sellToken).forceApprove(router, sellAmount);
        IAerodromeV2Router.Route[] memory routes = new IAerodromeV2Router.Route[](route.stables.length);
        for (uint256 i = 0; i < route.stables.length; i++) {
            routes[i] = IAerodromeV2Router.Route({from: route.path[i], to: route.path[i + 1], stable: route.stables[i], factory: AERODROME_V2_FACTORY});
        }
        uint256[] memory amounts = IAerodromeV2Router(router).swapExactTokensForTokens(sellAmount, minBuyAmount, routes, address(this), deadline);
        return amounts[amounts.length - 1];
    }
}

/// @notice Aerodrome V2 swap adapter with the kit's default operations
contract AWKAerodromeV2SwapAdapter is AWKAerodromeV2SwapAdapterCore, AWKSwapOperations {
    constructor(address aerodromeV2Router, address aerodromeV2Factory) AWKAerodromeV2SwapAdapterCore(aerodromeV2Router, aerodromeV2Factory) {}
}
