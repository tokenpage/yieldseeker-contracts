// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../../src/FeeTracker.sol";
import {AssetNotAllowed, BaseAssetNotAllowed} from "../../../src/adapters/Adapter.sol";
import {SellTokenNotAllowed, YieldSeekerSwapSellPolicy} from "../../../src/adapters/SwapSellPolicy.sol";
import {YieldSeekerUniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {AWKErrors} from "../../../src/agentwalletkit/AWKErrors.sol";
import {InsufficientOutput, InvalidRouteEndpoints, InvalidRouteLength, InvalidSwapRoute, InvalidSwapTokenAddress} from "../../../src/agentwalletkit/adapters/AWKSwapAdapter.sol";
import {AWKUniswapV3SwapAdapter, IUniswapV3SwapRouter, InvalidUniswapV3FeeTier, InvalidUniswapV3RouterTarget} from "../../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {AdapterWalletHarness} from "./AdapterHarness.t.sol";
import {Test} from "forge-std/Test.sol";

contract MockUniswapV3Router {
    uint256 public configuredBuyAmount;
    bool public shouldRevert;

    function setBuyAmount(uint256 amount) external {
        configuredBuyAmount = amount;
    }

    function setRevert(bool value) external {
        shouldRevert = value;
    }

    function exactInput(IUniswapV3SwapRouter.ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        if (shouldRevert) revert("swap failed");
        (address sellToken, address buyToken) = _decodePathEndpoints(params.path);
        require(MockERC20(sellToken).transferFrom(msg.sender, address(this), params.amountIn), "TransferFrom failed");
        amountOut = configuredBuyAmount == 0 ? params.amountOutMinimum : configuredBuyAmount;
        require(MockERC20(buyToken).transfer(msg.sender, amountOut), "Transfer failed");
    }

    function _decodePathEndpoints(bytes memory path) internal pure returns (address firstToken, address lastToken) {
        require(path.length >= 43, "invalid path");
        assembly {
            firstToken := shr(96, mload(add(path, 0x20)))
            lastToken := shr(96, mload(add(add(path, 0x20), sub(mload(path), 20))))
        }
    }
}

contract UniswapV3SwapAdapterTest is Test {
    YieldSeekerUniswapV3SwapAdapter adapter;
    YieldSeekerFeeTracker feeTracker;
    YieldSeekerSwapSellPolicy sellPolicy;
    AdapterWalletHarness wallet;
    MockERC20 baseAsset;
    MockERC20 sellToken;
    MockERC20 otherToken;
    MockUniswapV3Router router;

    function _decodeUint(bytes memory data) internal pure returns (uint256) {
        return abi.decode(abi.decode(data, (bytes)), (uint256));
    }

    function _buildRoute(address from, address to) internal pure returns (AWKUniswapV3SwapAdapter.SwapRoute memory route) {
        route.path = new address[](2);
        route.path[0] = from;
        route.path[1] = to;
        route.fees = new uint24[](1);
        route.fees[0] = 3000;
    }

    function _executeSwap(address buyToken, AWKUniswapV3SwapAdapter.SwapRoute memory route, uint256 sellAmount, uint256 minBuyAmount) internal returns (bytes memory) {
        bytes memory data = abi.encodeWithSelector(adapter.swap.selector, address(sellToken), buyToken, route, sellAmount, minBuyAmount);
        return wallet.executeAdapter(address(adapter), address(router), data);
    }

    function setUp() public {
        baseAsset = new MockERC20("Mock USDC", "mUSDC");
        sellToken = new MockERC20("Mock Token", "mTKN");
        otherToken = new MockERC20("Other Token", "oTKN");
        feeTracker = new YieldSeekerFeeTracker(address(this));
        feeTracker.setFeeConfig(1000, address(0xBEEF));
        sellPolicy = new YieldSeekerSwapSellPolicy(address(this), address(this), false);
        sellPolicy.addSellableToken(address(sellToken));
        router = new MockUniswapV3Router();
        adapter = new YieldSeekerUniswapV3SwapAdapter(address(router), address(sellPolicy));
        wallet = new AdapterWalletHarness(baseAsset, feeTracker);
        baseAsset.mint(address(router), 1_000_000e6);
        otherToken.mint(address(router), 1_000_000e18);
        sellToken.mint(address(wallet), 1_000e18);
    }

    function test_Execute_Swap_Succeeds() public {
        router.setBuyAmount(500e6);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _buildRoute(address(sellToken), address(baseAsset));
        bytes memory result = _executeSwap(address(baseAsset), route, 100e18, 400e6);
        uint256 buyAmount = _decodeUint(result);
        assertEq(buyAmount, 500e6);
        assertEq(sellToken.balanceOf(address(wallet)), 900e18);
        assertEq(baseAsset.balanceOf(address(wallet)), 500e6);
    }

    function test_Execute_Swap_RevertsOnLowOutput() public {
        router.setBuyAmount(100e6);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _buildRoute(address(sellToken), address(baseAsset));
        vm.expectRevert(abi.encodeWithSelector(InsufficientOutput.selector, uint256(100e6), uint256(150e6)));
        _executeSwap(address(baseAsset), route, 100e18, 150e6);
    }

    function test_Execute_Swap_RevertsOnZeroAmounts() public {
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _buildRoute(address(sellToken), address(baseAsset));
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        _executeSwap(address(baseAsset), route, 0, 0);
    }

    function test_Execute_Swap_RevertsOnWrongTarget() public {
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _buildRoute(address(sellToken), address(baseAsset));
        bytes memory data = abi.encodeWithSelector(adapter.swap.selector, address(sellToken), address(baseAsset), route, uint256(10e18), uint256(1e6));
        vm.expectRevert(abi.encodeWithSelector(InvalidUniswapV3RouterTarget.selector, address(0x1234), address(router)));
        wallet.executeAdapter(address(adapter), address(0x1234), data);
    }

    function test_Execute_Swap_RevertsOnInvalidFeeTier() public {
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _buildRoute(address(sellToken), address(baseAsset));
        route.fees[0] = 250;
        vm.expectRevert(abi.encodeWithSelector(InvalidUniswapV3FeeTier.selector, uint24(250)));
        _executeSwap(address(baseAsset), route, 100e18, 1e6);
    }

    function test_Execute_Swap_RevertsOnInvalidRouteLength() public {
        AWKUniswapV3SwapAdapter.SwapRoute memory route;
        route.path = new address[](1);
        route.path[0] = address(sellToken);
        route.fees = new uint24[](0);
        vm.expectRevert(abi.encodeWithSelector(InvalidRouteLength.selector, uint256(1)));
        _executeSwap(address(baseAsset), route, 100e18, 1e6);
    }

    function test_Execute_Swap_RevertsOnFeePathMismatch() public {
        AWKUniswapV3SwapAdapter.SwapRoute memory route;
        route.path = new address[](2);
        route.path[0] = address(sellToken);
        route.path[1] = address(baseAsset);
        route.fees = new uint24[](0);
        vm.expectRevert(abi.encodeWithSelector(InvalidSwapRoute.selector));
        _executeSwap(address(baseAsset), route, 100e18, 1e6);
    }

    function test_Execute_Swap_RevertsOnRouteSellEndpointMismatch() public {
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _buildRoute(address(otherToken), address(baseAsset));
        vm.expectRevert(abi.encodeWithSelector(InvalidRouteEndpoints.selector, address(sellToken), address(baseAsset)));
        _executeSwap(address(baseAsset), route, 100e18, 1e6);
    }

    function test_Execute_Swap_RevertsOnRouteBuyEndpointMismatch() public {
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _buildRoute(address(sellToken), address(otherToken));
        vm.expectRevert(abi.encodeWithSelector(InvalidRouteEndpoints.selector, address(sellToken), address(baseAsset)));
        _executeSwap(address(baseAsset), route, 100e18, 1e6);
    }

    function test_Execute_Swap_RevertsOnZeroPathToken() public {
        AWKUniswapV3SwapAdapter.SwapRoute memory route;
        route.path = new address[](3);
        route.path[0] = address(sellToken);
        route.path[1] = address(0);
        route.path[2] = address(baseAsset);
        route.fees = new uint24[](2);
        route.fees[0] = 3000;
        route.fees[1] = 3000;
        vm.expectRevert(abi.encodeWithSelector(InvalidSwapTokenAddress.selector, address(0)));
        _executeSwap(address(baseAsset), route, 100e18, 1e6);
    }

    function test_Execute_Swap_RevertsOnNonSellableToken() public {
        sellPolicy.removeSellableToken(address(sellToken));
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _buildRoute(address(sellToken), address(baseAsset));
        vm.expectRevert(abi.encodeWithSelector(SellTokenNotAllowed.selector, address(sellToken)));
        _executeSwap(address(baseAsset), route, 100e18, 1e6);
    }

    function test_Execute_Swap_RevertsWhenBuyTokenNotBaseAsset() public {
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _buildRoute(address(sellToken), address(otherToken));
        vm.expectRevert(abi.encodeWithSelector(AssetNotAllowed.selector));
        _executeSwap(address(otherToken), route, 100e18, 1e18);
    }

    function test_Execute_Swap_RevertsWhenSellingBaseAsset() public {
        sellPolicy.addSellableToken(address(baseAsset));
        baseAsset.mint(address(wallet), 1_000e6);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _buildRoute(address(baseAsset), address(otherToken));
        bytes memory data = abi.encodeWithSelector(adapter.swap.selector, address(baseAsset), address(otherToken), route, uint256(100e6), uint256(1e18));
        vm.expectRevert(abi.encodeWithSelector(BaseAssetNotAllowed.selector));
        wallet.executeAdapter(address(adapter), address(router), data);
    }
}
