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

import {AWKAdapter} from "../AWKAdapter.sol";
import {AWKErrors} from "../AWKErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

error InvalidSwapTokenAddress(address token);
error InvalidSwapRoute();
error InvalidRouteLength(uint256 length);
error InvalidRouteEndpoints(address expectedSellToken, address expectedBuyToken);
error InsufficientOutput(uint256 received, uint256 minimum);
error SwapExpired(uint256 deadline);
error SwapInputMismatch(uint256 sold, uint256 sellAmount);

/**
 * @title AWKSwapAdapter
 * @notice Base class for swap adapters
 * @dev Each DEX's execute decodes its own route, checks it (_validateSwapRoute) and calls the operation
 *      (_swapOperation), which an operations layer implements around the measured swap (_measuredSwap): AWKSwapOperations
 *      for a plain kit adapter, or a wallet's own rules layer. The measured swap measures the balances around the DEX
 *      implementation (_swap), which receives the route ABI-encoded and returns the router's reported output. Every swap
 *      carries a deadline so a signed swap can't be held and run later against a stale minimum output.
 *      Tokens that reach the wallet during the swap from anywhere else (e.g. a withdrawal from the owner's other
 *      wallet that an operator triggers from a token hook on the route) must not count: the wallet must have spent
 *      exactly `sellAmount`, and the output is the measured increase capped at what the router reports it paid.
 */
abstract contract AWKSwapAdapter is AWKAdapter {
    event Swapped(address indexed wallet, address indexed router, address sellToken, address buyToken, uint256 soldAmount, uint256 buyAmount);

    uint256 internal constant MAX_HOPS = 4;

    /// @dev Checks a route of `path` tokens joined by `hopCount` pools, then the swap's tokens and amounts
    function _validateSwapRoute(address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, address[] memory path, uint256 hopCount) internal pure {
        uint256 pathLength = path.length;
        if (pathLength < 2 || pathLength > MAX_HOPS + 1) revert InvalidRouteLength(pathLength);
        if (hopCount != pathLength - 1) revert InvalidSwapRoute();
        if (path[0] != sellToken || path[pathLength - 1] != buyToken) revert InvalidRouteEndpoints(sellToken, buyToken);
        for (uint256 i = 0; i < pathLength; i++) {
            if (path[i] == address(0)) revert InvalidSwapTokenAddress(path[i]);
        }
        if (sellToken == address(0) || buyToken == address(0) || sellToken == buyToken) revert InvalidSwapTokenAddress(sellToken);
        if (sellAmount == 0 || minBuyAmount == 0) revert AWKErrors.ZeroAmount();
    }

    // ============ Operations (implemented by an operations layer) ============

    function _swapOperation(address router, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, uint256 deadline, bytes memory route) internal virtual returns (uint256 soldAmount, uint256 buyAmount);

    function _measuredSwap(address router, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, uint256 deadline, bytes memory route) internal returns (uint256 soldAmount, uint256 buyAmount) {
        if (block.timestamp > deadline) revert SwapExpired(deadline);
        uint256 sellBalanceBefore = IERC20(sellToken).balanceOf(address(this));
        uint256 buyBalanceBefore = IERC20(buyToken).balanceOf(address(this));
        uint256 reportedBuyAmount = _swap(router, sellToken, sellAmount, minBuyAmount, deadline, route);
        soldAmount = sellBalanceBefore - IERC20(sellToken).balanceOf(address(this));
        if (soldAmount != sellAmount) revert SwapInputMismatch(soldAmount, sellAmount);
        buyAmount = Math.min(IERC20(buyToken).balanceOf(address(this)) - buyBalanceBefore, reportedBuyAmount);
        if (buyAmount < minBuyAmount) revert InsufficientOutput(buyAmount, minBuyAmount);
        emit Swapped(address(this), router, sellToken, buyToken, soldAmount, buyAmount);
    }

    // ============ Protocol Implementation ============

    /// @dev Sells `sellAmount` of `sellToken` on the router along `route` (the DEX's route type, ABI-encoded); the
    ///      bought token stays in the wallet. Returns the amount the router reports it paid out.
    function _swap(address router, address sellToken, uint256 sellAmount, uint256 minBuyAmount, uint256 deadline, bytes memory route) internal virtual returns (uint256 buyAmount);
}

/// @notice The kit's default operations: the measured swap with no further rules
abstract contract AWKSwapOperations is AWKSwapAdapter {
    function _swapOperation(address router, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, uint256 deadline, bytes memory route) internal override returns (uint256 soldAmount, uint256 buyAmount) {
        return _measuredSwap(router, sellToken, buyToken, sellAmount, minBuyAmount, deadline, route);
    }
}
