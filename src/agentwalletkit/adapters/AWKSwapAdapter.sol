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
 * @dev Each DEX's execute decodes and validates its own route, then calls the operation (_swapOperation), which
 *      subclasses override to add rules; the operation measures the balances around the DEX implementation (_swap),
 *      which receives the route ABI-encoded and returns the router's reported output. Every swap carries a deadline
 *      so a signed swap can't be held and run later against a stale minimum output.
 *      Tokens that reach the wallet during the swap from anywhere else (e.g. a withdrawal from the owner's other
 *      wallet that an operator triggers from a token hook on the route) must not count: the wallet must have spent
 *      exactly `sellAmount`, and the output is the measured increase capped at what the router reports it paid.
 */
abstract contract AWKSwapAdapter is AWKAdapter {
    event Swapped(address indexed wallet, address indexed router, address sellToken, address buyToken, uint256 soldAmount, uint256 buyAmount);

    function _validateSwap(address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount) internal pure {
        if (sellToken == address(0) || buyToken == address(0) || sellToken == buyToken) revert InvalidSwapTokenAddress(sellToken);
        if (sellAmount == 0 || minBuyAmount == 0) revert AWKErrors.ZeroAmount();
    }

    function _validateRouteEndpoints(address sellToken, address buyToken, address routeStartToken, address routeEndToken) internal pure {
        if (routeStartToken != sellToken || routeEndToken != buyToken) revert InvalidRouteEndpoints(sellToken, buyToken);
    }

    // ============ Operations (override to add rules) ============

    function _swapOperation(address router, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, uint256 deadline, bytes memory route) internal virtual returns (uint256 soldAmount, uint256 buyAmount) {
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
