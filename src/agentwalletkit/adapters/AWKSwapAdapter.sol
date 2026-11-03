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
//  https://agentwalletkit.tokenpage.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKAdapter} from "../AWKAdapter.sol";
import {AWKErrors} from "../AWKErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error InvalidSwapTokenAddress(address token);
error InvalidSwapRoute();
error InvalidRouteLength(uint256 length);
error InvalidRouteEndpoints(address expectedSellToken, address expectedBuyToken);
error InsufficientOutput(uint256 received, uint256 minimum);

/**
 * @title AWKSwapAdapter
 * @notice Base class for swap adapters
 * @dev Each DEX's execute decodes and validates its own route, then calls the operation (_swapOperation), which
 *      subclasses override to add rules; the operation measures the balances around the DEX implementation (_swap),
 *      which receives the route ABI-encoded.
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

    function _swapOperation(address router, address sellToken, address buyToken, uint256 sellAmount, uint256 minBuyAmount, bytes memory route) internal virtual returns (uint256 soldAmount, uint256 buyAmount) {
        uint256 sellBalanceBefore = IERC20(sellToken).balanceOf(address(this));
        uint256 buyBalanceBefore = IERC20(buyToken).balanceOf(address(this));
        _swap(router, sellToken, sellAmount, minBuyAmount, route);
        soldAmount = sellBalanceBefore - IERC20(sellToken).balanceOf(address(this));
        buyAmount = IERC20(buyToken).balanceOf(address(this)) - buyBalanceBefore;
        if (buyAmount < minBuyAmount) revert InsufficientOutput(buyAmount, minBuyAmount);
        emit Swapped(address(this), router, sellToken, buyToken, soldAmount, buyAmount);
    }

    // ============ Protocol Implementation ============

    /// @dev Sells `sellAmount` of `sellToken` on the router along `route` (the DEX's route type, ABI-encoded); the
    ///      bought token stays in the wallet
    function _swap(address router, address sellToken, uint256 sellAmount, uint256 minBuyAmount, bytes memory route) internal virtual;
}
