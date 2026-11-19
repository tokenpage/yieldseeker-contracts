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
import {IPeripheryPayments} from "aerodrome-slipstream/periphery/interfaces/IPeripheryPayments.sol";
import {ISwapRouter as IAerodromeCLSwapRouter} from "aerodrome-slipstream/periphery/interfaces/ISwapRouter.sol";

error InvalidAerodromeCLRouterTarget(address target, address expected);

/**
 * @title AWKAerodromeCLSwapAdapterCore
 * @notice Aerodrome CL swaps using structured route parameters, without an operations layer
 * @dev Accepts multi-hop routes through path+tickSpacing arrays with strict validation. The router is the target of
 *      the execute call.
 */
abstract contract AWKAerodromeCLSwapAdapterCore is AWKSwapAdapter {
    using SafeERC20 for IERC20;

    struct SwapRoute {
        address[] path;
        int24[] tickSpacings;
    }

    address public immutable AERODROME_CL_ROUTER;

    constructor(address aerodromeClRouter) {
        if (aerodromeClRouter == address(0)) revert AWKErrors.ZeroAddress();
        AERODROME_CL_ROUTER = aerodromeClRouter;
    }

    function swap(address sellToken, address buyToken, SwapRoute calldata route, uint256 sellAmount, uint256 minBuyAmount, uint256 deadline) external onlyExecute returns (uint256 buyAmount) {
        if (_target() != AERODROME_CL_ROUTER) revert InvalidAerodromeCLRouterTarget(_target(), AERODROME_CL_ROUTER);
        _validateSwapRoute(sellToken, buyToken, sellAmount, minBuyAmount, route.path, route.tickSpacings.length);
        (, buyAmount) = _swapOperation(AERODROME_CL_ROUTER, sellToken, buyToken, sellAmount, minBuyAmount, deadline, abi.encode(route));
    }

    // ============ Internal Implementations ============

    function _swap(address router, address sellToken, uint256 sellAmount, uint256 minBuyAmount, uint256 deadline, bytes memory encodedRoute) internal virtual override returns (uint256) {
        SwapRoute memory route = abi.decode(encodedRoute, (SwapRoute));
        // The router pays a WETH input from its own ETH when it holds enough, so the wallet would spend nothing;
        // sweeping it to the wallet first keeps the swap paid from the wallet
        if (router.balance != 0) IPeripheryPayments(router).refundETH();
        IERC20(sellToken).forceApprove(router, sellAmount);
        bytes memory encodedPath = abi.encodePacked(route.path[0]);
        for (uint256 i = 0; i < route.tickSpacings.length; i++) {
            encodedPath = bytes.concat(encodedPath, abi.encodePacked(route.tickSpacings[i]), abi.encodePacked(route.path[i + 1]));
        }
        return IAerodromeCLSwapRouter(router).exactInput(IAerodromeCLSwapRouter.ExactInputParams({path: encodedPath, recipient: address(this), deadline: deadline, amountIn: sellAmount, amountOutMinimum: minBuyAmount}));
    }
}

/// @notice Aerodrome CL swap adapter with the kit's default operations
contract AWKAerodromeCLSwapAdapter is AWKAerodromeCLSwapAdapterCore, AWKSwapOperations {
    constructor(address aerodromeClRouter) AWKAerodromeCLSwapAdapterCore(aerodromeClRouter) {}
}
