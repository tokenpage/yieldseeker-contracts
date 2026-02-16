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

import {UnknownOperation} from "../AWKAdapter.sol";
import {AWKErrors} from "../AWKErrors.sol";
import {AWKSwapAdapter} from "./AWKSwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

error InvalidUniswapV3RouterTarget(address target, address expected);
error InvalidSwapTokenAddress(address token);
error InvalidUniswapV3FeeTier(uint24 fee);
error InvalidSwapRoute();
error InvalidRouteLength(uint256 length);
error InvalidRouteEndpoints(address expectedSellToken, address expectedBuyToken);

interface IUniswapV3SwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/**
 * @title AWKUniswapV3SwapAdapter
 * @notice Generic adapter for Uniswap V3 swaps using structured route parameters
 * @dev Swap execution runs via delegatecall from AgentWallet.
 *      Accepts multi-hop routes through path+fee arrays with strict validation.
 */
contract AWKUniswapV3SwapAdapter is AWKSwapAdapter {
    using SafeERC20 for IERC20;

    uint256 internal constant MAX_HOPS = 4;

    struct SwapRoute {
        address[] path;
        uint24[] fees;
    }

    address public immutable UNISWAP_V3_ROUTER;

    constructor(address uniswapV3Router) {
        if (uniswapV3Router == address(0)) revert AWKErrors.ZeroAddress();
        UNISWAP_V3_ROUTER = uniswapV3Router;
    }

    // ============ Swap Operations ============

    /**
     * @notice Swap tokens via Uniswap V3 (public interface, should not be called directly)
     * @dev This is a placeholder function signature. Actual execution happens via execute() -> _swap()
     */
    function swap(address sellToken, address buyToken, SwapRoute calldata route, uint256 sellAmount, uint256 minBuyAmount) external pure returns (uint256) {
        revert AWKErrors.DirectCallForbidden();
    }

    // ============ Swap Execution (delegatecall only) ============

    /**
     * @notice Route delegatecall operations to the swap handler
     * @param target The Uniswap V3 router target contract
     * @param data ABI-encoded call data (must match swap() selector)
     * @return ABI-encoded buy amount
     */
    function execute(address target, bytes calldata data) external payable virtual override onlyDelegateCall returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == this.swap.selector) {
            (address sellToken, address buyToken, SwapRoute memory route, uint256 sellAmount, uint256 minBuyAmount) = abi.decode(data[4:], (address, address, SwapRoute, uint256, uint256));
            (uint256 buyAmount,) = _swap(target, sellToken, buyToken, route, sellAmount, minBuyAmount);
            return abi.encode(buyAmount);
        }
        revert UnknownOperation();
    }

    // ============ Internal Implementations ============

    function _swap(address target, address sellToken, address buyToken, SwapRoute memory route, uint256 sellAmount, uint256 minBuyAmount) internal virtual returns (uint256 buyAmount, uint256 soldAmount) {
        if (target != UNISWAP_V3_ROUTER) revert InvalidUniswapV3RouterTarget(target, UNISWAP_V3_ROUTER);
        _validateRoute(sellToken, buyToken, route);
        SwapBalanceSnapshot memory balanceSnapshot = _beforeSwapInternal(sellToken, buyToken, sellAmount, minBuyAmount);
        IERC20(sellToken).forceApprove(UNISWAP_V3_ROUTER, sellAmount);
        bytes memory encodedPath = abi.encodePacked(route.path[0]);
        for (uint256 i = 0; i < route.fees.length; i++) {
            encodedPath = bytes.concat(encodedPath, abi.encodePacked(route.fees[i]), abi.encodePacked(route.path[i + 1]));
        }
        IUniswapV3SwapRouter(UNISWAP_V3_ROUTER).exactInput(IUniswapV3SwapRouter.ExactInputParams({path: encodedPath, recipient: address(this), amountIn: sellAmount, amountOutMinimum: minBuyAmount}));
        (buyAmount, soldAmount) = _afterSwapInternal(UNISWAP_V3_ROUTER, sellToken, buyToken, minBuyAmount, balanceSnapshot);
    }

    function _validateFeeTier(uint24 fee) internal pure {
        if (fee != 100 && fee != 500 && fee != 3000 && fee != 10000) revert InvalidUniswapV3FeeTier(fee);
    }

    function _validateRoute(address sellToken, address buyToken, SwapRoute memory route) internal pure {
        uint256 pathLength = route.path.length;
        if (pathLength < 2 || pathLength > MAX_HOPS + 1) revert InvalidRouteLength(pathLength);
        if (route.fees.length != pathLength - 1) revert InvalidSwapRoute();
        if (route.path[0] != sellToken || route.path[pathLength - 1] != buyToken) {
            revert InvalidRouteEndpoints(sellToken, buyToken);
        }
        for (uint256 i = 0; i < pathLength; i++) {
            if (route.path[i] == address(0)) revert InvalidSwapTokenAddress(route.path[i]);
        }
        for (uint256 i = 0; i < route.fees.length; i++) {
            _validateFeeTier(route.fees[i]);
        }
    }
}
