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
import {IV3SwapRouter as IUniswapV3SwapRouter} from "@uniswap/swap-router-contracts/contracts/interfaces/IV3SwapRouter.sol";
import {IPeripheryPayments} from "@uniswap/v3-periphery/contracts/interfaces/IPeripheryPayments.sol";

error InvalidUniswapV3RouterTarget(address target, address expected);
error InvalidUniswapV3FeeTier(uint24 fee);

/**
 * @title AWKUniswapV3SwapAdapterCore
 * @notice Uniswap V3 swaps using structured route parameters, without an operations layer
 * @dev Accepts multi-hop routes through path+fee arrays with strict validation. The router is the target of the
 *      execute call.
 */
abstract contract AWKUniswapV3SwapAdapterCore is AWKSwapAdapter {
    using SafeERC20 for IERC20;

    struct SwapRoute {
        address[] path;
        uint24[] fees;
    }

    address public immutable UNISWAP_V3_ROUTER;

    constructor(address uniswapV3Router) {
        if (uniswapV3Router == address(0)) revert AWKErrors.ZeroAddress();
        UNISWAP_V3_ROUTER = uniswapV3Router;
    }

    function swap(address sellToken, address buyToken, SwapRoute calldata route, uint256 sellAmount, uint256 minBuyAmount, uint256 deadline) external onlyExecute returns (uint256 buyAmount) {
        if (_target() != UNISWAP_V3_ROUTER) revert InvalidUniswapV3RouterTarget(_target(), UNISWAP_V3_ROUTER);
        _validateSwapRoute(sellToken, buyToken, sellAmount, minBuyAmount, route.path, route.fees.length);
        for (uint256 i = 0; i < route.fees.length; i++) {
            uint24 fee = route.fees[i];
            if (fee != 100 && fee != 500 && fee != 3000 && fee != 10000) revert InvalidUniswapV3FeeTier(fee);
        }
        (, buyAmount) = _swapOperation(UNISWAP_V3_ROUTER, sellToken, buyToken, sellAmount, minBuyAmount, deadline, abi.encode(route));
    }

    // ============ Internal Implementations ============

    function _swap(address router, address sellToken, uint256 sellAmount, uint256 minBuyAmount, uint256, bytes memory encodedRoute) internal virtual override returns (uint256) {
        SwapRoute memory route = abi.decode(encodedRoute, (SwapRoute));
        // The router pays a WETH input from its own ETH when it holds enough, so the wallet would spend nothing;
        // sweeping it to the wallet first keeps the swap paid from the wallet
        if (router.balance != 0) IPeripheryPayments(router).refundETH();
        IERC20(sellToken).forceApprove(router, sellAmount);
        bytes memory encodedPath = abi.encodePacked(route.path[0]);
        for (uint256 i = 0; i < route.fees.length; i++) {
            encodedPath = bytes.concat(encodedPath, abi.encodePacked(route.fees[i]), abi.encodePacked(route.path[i + 1]));
        }
        return IUniswapV3SwapRouter(router).exactInput(IUniswapV3SwapRouter.ExactInputParams({path: encodedPath, recipient: address(this), amountIn: sellAmount, amountOutMinimum: minBuyAmount}));
    }
}

/// @notice Uniswap V3 swap adapter with the kit's default operations
contract AWKUniswapV3SwapAdapter is AWKUniswapV3SwapAdapterCore, AWKSwapOperations {
    constructor(address uniswapV3Router) AWKUniswapV3SwapAdapterCore(uniswapV3Router) {}
}
