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
pragma solidity 0.8.38;

import {UnknownOperation} from "../AWKAdapter.sol";
import {AWKErrors} from "../AWKErrors.sol";
import {AWKSwapAdapter, InvalidRouteLength, InvalidSwapRoute, InvalidSwapTokenAddress} from "./AWKSwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error InvalidAerodromeCLRouterTarget(address target, address expected);

interface IAerodromeCLSwapRouter {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title AWKAerodromeCLSwapAdapter
 * @notice Generic adapter for Aerodrome CL swaps using structured route parameters
 * @dev Swap execution runs via delegatecall from AgentWallet.
 *      Accepts multi-hop routes through path+tickSpacing arrays with strict validation.
 */
contract AWKAerodromeCLSwapAdapter is AWKSwapAdapter {
    using SafeERC20 for IERC20;

    struct SwapRoute {
        address[] path;
        int24[] tickSpacings;
    }

    uint256 internal constant FAR_FUTURE_DEADLINE = type(uint32).max;
    uint256 internal constant MAX_HOPS = 4;

    address public immutable AERODROME_CL_ROUTER;

    constructor(address aerodromeClRouter) {
        if (aerodromeClRouter == address(0)) revert AWKErrors.ZeroAddress();
        AERODROME_CL_ROUTER = aerodromeClRouter;
    }

    // ============ Swap Operations ============

    /**
     * @notice Swap tokens via Aerodrome CL (public interface, should not be called directly)
     * @dev This is a placeholder function signature. Actual execution happens via execute() -> _swapOperation()
     */
    function swap(address sellToken, address buyToken, SwapRoute calldata route, uint256 sellAmount, uint256 minBuyAmount) external pure returns (uint256) {
        revert AWKErrors.DirectCallForbidden();
    }

    // ============ Swap Execution (delegatecall only) ============

    /**
     * @notice Validate a swap call and run it
     * @param target The Aerodrome CL router target contract
     * @param data ABI-encoded call data (must match swap() selector)
     * @return ABI-encoded buy amount
     */
    function execute(address target, bytes calldata data) external payable virtual override onlyDelegateCall returns (bytes memory) {
        if (bytes4(data[:4]) != this.swap.selector) revert UnknownOperation();
        (address sellToken, address buyToken, SwapRoute memory route, uint256 sellAmount, uint256 minBuyAmount) = abi.decode(data[4:], (address, address, SwapRoute, uint256, uint256));
        if (target != AERODROME_CL_ROUTER) revert InvalidAerodromeCLRouterTarget(target, AERODROME_CL_ROUTER);
        _validateRoute(sellToken, buyToken, route);
        _validateSwap(sellToken, buyToken, sellAmount, minBuyAmount);
        (, uint256 buyAmount) = _swapOperation(target, sellToken, buyToken, sellAmount, minBuyAmount, abi.encode(route));
        return abi.encode(buyAmount);
    }

    // ============ Internal Implementations ============

    function _swap(address router, address sellToken, uint256 sellAmount, uint256 minBuyAmount, bytes memory encodedRoute) internal virtual override {
        SwapRoute memory route = abi.decode(encodedRoute, (SwapRoute));
        IERC20(sellToken).forceApprove(router, sellAmount);
        bytes memory encodedPath = abi.encodePacked(route.path[0]);
        for (uint256 i = 0; i < route.tickSpacings.length; i++) {
            encodedPath = bytes.concat(encodedPath, abi.encodePacked(route.tickSpacings[i]), abi.encodePacked(route.path[i + 1]));
        }
        IAerodromeCLSwapRouter(router).exactInput(IAerodromeCLSwapRouter.ExactInputParams({path: encodedPath, recipient: address(this), deadline: FAR_FUTURE_DEADLINE, amountIn: sellAmount, amountOutMinimum: minBuyAmount}));
    }

    function _validateRoute(address sellToken, address buyToken, SwapRoute memory route) internal pure {
        uint256 pathLength = route.path.length;
        if (pathLength < 2 || pathLength > MAX_HOPS + 1) revert InvalidRouteLength(pathLength);
        if (route.tickSpacings.length != pathLength - 1) revert InvalidSwapRoute();
        _validateRouteEndpoints(sellToken, buyToken, route.path[0], route.path[pathLength - 1]);
        for (uint256 i = 0; i < pathLength; i++) {
            if (route.path[i] == address(0)) revert InvalidSwapTokenAddress(route.path[i]);
        }
    }
}
