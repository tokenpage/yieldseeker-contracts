// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV1 as AgentWalletV1} from "../../src/AgentWalletV1.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {AssetNotAllowed} from "../../src/adapters/Adapter.sol";
import {YieldSeekerAerodromeCLSwapAdapter as AerodromeCLSwapAdapter} from "../../src/adapters/AerodromeCLSwapAdapter.sol";
import {YieldSeekerAerodromeV2SwapAdapter as AerodromeV2SwapAdapter} from "../../src/adapters/AerodromeV2SwapAdapter.sol";
import {SellTokenNotAllowed, YieldSeekerSwapSellPolicy} from "../../src/adapters/SwapSellPolicy.sol";
import {YieldSeekerUniswapV3SwapAdapter as UniswapV3SwapAdapter} from "../../src/adapters/UniswapV3SwapAdapter.sol";
import {AdapterExecutionFailed} from "../../src/agentwalletkit/AWKAgentWalletV1.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {AWKAerodromeCLSwapAdapter, IAerodromeCLSwapRouter} from "../../src/agentwalletkit/adapters/AWKAerodromeCLSwapAdapter.sol";
import {AWKAerodromeV2SwapAdapter, IAerodromeV2Router} from "../../src/agentwalletkit/adapters/AWKAerodromeV2SwapAdapter.sol";
import {InvalidRouteEndpoints} from "../../src/agentwalletkit/adapters/AWKSwapAdapter.sol";
import {AWKUniswapV3SwapAdapter, IUniswapV3SwapRouter} from "../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {Test} from "forge-std/Test.sol";

contract MockUniswapV3RouterIntegration {
    uint256 public configuredBuyAmount;

    function setBuyAmount(uint256 amount) external {
        configuredBuyAmount = amount;
    }

    function exactInput(IUniswapV3SwapRouter.ExactInputParams calldata params) external payable returns (uint256 amountOut) {
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

contract MockAerodromeV2RouterIntegration {
    uint256 public configuredBuyAmount;

    function setBuyAmount(uint256 amount) external {
        configuredBuyAmount = amount;
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, IAerodromeV2Router.Route[] memory routes, address, uint256) external returns (uint256[] memory amounts) {
        require(routes.length > 0, "invalid routes");
        address sellToken = routes[0].from;
        address buyToken = routes[routes.length - 1].to;
        require(MockERC20(sellToken).transferFrom(msg.sender, address(this), amountIn), "TransferFrom failed");
        uint256 amountOut = configuredBuyAmount == 0 ? amountOutMin : configuredBuyAmount;
        require(MockERC20(buyToken).transfer(msg.sender, amountOut), "Transfer failed");
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;
        amounts[routes.length] = amountOut;
    }
}

contract MockAerodromeCLRouterIntegration {
    uint256 public configuredBuyAmount;

    function setBuyAmount(uint256 amount) external {
        configuredBuyAmount = amount;
    }

    function exactInput(IAerodromeCLSwapRouter.ExactInputParams calldata params) external payable returns (uint256 amountOut) {
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

contract SwapAdapterIntegrationTest is Test {
    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    YieldSeekerSwapSellPolicy sellPolicy;
    UniswapV3SwapAdapter uniswapAdapter;
    AerodromeV2SwapAdapter aerodromeV2Adapter;
    AerodromeCLSwapAdapter aerodromeClAdapter;
    MockUniswapV3RouterIntegration uniswapRouter;
    MockAerodromeV2RouterIntegration aerodromeV2Router;
    MockAerodromeCLRouterIntegration aerodromeClRouter;
    MockERC20 baseAsset;
    MockERC20 sellToken;
    MockERC20 otherToken;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address user = makeAddr("user");
    address feeCollector = makeAddr("feeCollector");

    function _decodeUint(bytes memory data) internal pure returns (uint256) {
        return abi.decode(abi.decode(data, (bytes)), (uint256));
    }

    function _createWallet() internal returns (AgentWalletV1 wallet) {
        vm.prank(operator);
        wallet = factory.createAgentWallet(user, 1, address(baseAsset));
    }

    function _uniswapRoute(address fromToken, address toToken) internal pure returns (AWKUniswapV3SwapAdapter.SwapRoute memory route) {
        route.path = new address[](2);
        route.path[0] = fromToken;
        route.path[1] = toToken;
        route.fees = new uint24[](1);
        route.fees[0] = 3000;
    }

    function _aerodromeV2Route(address fromToken, address toToken) internal pure returns (AWKAerodromeV2SwapAdapter.SwapRoute memory route) {
        route.path = new address[](2);
        route.path[0] = fromToken;
        route.path[1] = toToken;
        route.stables = new bool[](1);
        route.stables[0] = false;
    }

    function _aerodromeClRoute(address fromToken, address toToken) internal pure returns (AWKAerodromeCLSwapAdapter.SwapRoute memory route) {
        route.path = new address[](2);
        route.path[0] = fromToken;
        route.path[1] = toToken;
        route.tickSpacings = new int24[](1);
        route.tickSpacings[0] = 100;
    }

    function setUp() public {
        baseAsset = new MockERC20("Mock USDC", "mUSDC");
        sellToken = new MockERC20("Mock Yield", "mYLD");
        otherToken = new MockERC20("Other", "mOTH");
        uniswapRouter = new MockUniswapV3RouterIntegration();
        aerodromeV2Router = new MockAerodromeV2RouterIntegration();
        aerodromeClRouter = new MockAerodromeCLRouterIntegration();
        vm.startPrank(admin);
        registry = new AdapterRegistry(admin, admin);
        feeTracker = new FeeTracker(admin);
        feeTracker.setFeeConfig(1000, feeCollector);
        factory = new AgentWalletFactory(admin, operator);
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(feeTracker);
        AgentWalletV1 walletImplementation = new AgentWalletV1(address(factory));
        factory.setAgentWalletImplementation(walletImplementation);
        sellPolicy = new YieldSeekerSwapSellPolicy(admin, admin, false);
        sellPolicy.addSellableToken(address(sellToken));
        uniswapAdapter = new UniswapV3SwapAdapter(address(uniswapRouter), address(sellPolicy));
        aerodromeV2Adapter = new AerodromeV2SwapAdapter(address(aerodromeV2Router), address(0xFACADE), address(sellPolicy));
        aerodromeClAdapter = new AerodromeCLSwapAdapter(address(aerodromeClRouter), address(sellPolicy));
        registry.registerAdapter(address(uniswapAdapter));
        registry.registerAdapter(address(aerodromeV2Adapter));
        registry.registerAdapter(address(aerodromeClAdapter));
        registry.setTargetAdapter(address(uniswapRouter), address(uniswapAdapter));
        registry.setTargetAdapter(address(aerodromeV2Router), address(aerodromeV2Adapter));
        registry.setTargetAdapter(address(aerodromeClRouter), address(aerodromeClAdapter));
        vm.stopPrank();
        baseAsset.mint(address(uniswapRouter), 2_000_000e6);
        baseAsset.mint(address(aerodromeV2Router), 2_000_000e6);
        baseAsset.mint(address(aerodromeClRouter), 2_000_000e6);
        otherToken.mint(address(uniswapRouter), 2_000_000e6);
        otherToken.mint(address(aerodromeV2Router), 2_000_000e6);
        otherToken.mint(address(aerodromeClRouter), 2_000_000e6);
    }

    function test_UniswapSwap_ThroughWallet_Succeeds() public {
        AgentWalletV1 wallet = _createWallet();
        sellToken.mint(address(wallet), 1_000e6);
        uniswapRouter.setBuyAmount(500e6);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(sellToken), address(baseAsset));
        bytes memory data = abi.encodeCall(uniswapAdapter.swap, (address(sellToken), address(baseAsset), route, uint256(100e6), uint256(400e6)));
        vm.prank(user);
        bytes memory result = wallet.executeViaAdapter(address(uniswapAdapter), address(uniswapRouter), data);
        uint256 buyAmount = _decodeUint(result);
        assertEq(buyAmount, 500e6);
        assertEq(sellToken.balanceOf(address(wallet)), 900e6);
        assertEq(baseAsset.balanceOf(address(wallet)), 500e6);
    }

    function test_AerodromeV2Swap_ThroughWallet_Succeeds() public {
        AgentWalletV1 wallet = _createWallet();
        sellToken.mint(address(wallet), 1_000e6);
        aerodromeV2Router.setBuyAmount(450e6);
        AWKAerodromeV2SwapAdapter.SwapRoute memory route = _aerodromeV2Route(address(sellToken), address(baseAsset));
        bytes memory data = abi.encodeCall(aerodromeV2Adapter.swap, (address(sellToken), address(baseAsset), route, uint256(100e6), uint256(300e6)));
        vm.prank(user);
        bytes memory result = wallet.executeViaAdapter(address(aerodromeV2Adapter), address(aerodromeV2Router), data);
        uint256 buyAmount = _decodeUint(result);
        assertEq(buyAmount, 450e6);
        assertEq(baseAsset.balanceOf(address(wallet)), 450e6);
    }

    function test_AerodromeCLSwap_ThroughWallet_Succeeds() public {
        AgentWalletV1 wallet = _createWallet();
        sellToken.mint(address(wallet), 1_000e6);
        aerodromeClRouter.setBuyAmount(470e6);
        AWKAerodromeCLSwapAdapter.SwapRoute memory route = _aerodromeClRoute(address(sellToken), address(baseAsset));
        bytes memory data = abi.encodeCall(aerodromeClAdapter.swap, (address(sellToken), address(baseAsset), route, uint256(100e6), uint256(300e6)));
        vm.prank(user);
        bytes memory result = wallet.executeViaAdapter(address(aerodromeClAdapter), address(aerodromeClRouter), data);
        uint256 buyAmount = _decodeUint(result);
        assertEq(buyAmount, 470e6);
        assertEq(baseAsset.balanceOf(address(wallet)), 470e6);
    }

    function test_SwapBatchAcrossAdapters_Succeeds() public {
        AgentWalletV1 wallet = _createWallet();
        sellToken.mint(address(wallet), 1_000e6);
        uniswapRouter.setBuyAmount(120e6);
        aerodromeV2Router.setBuyAmount(130e6);
        aerodromeClRouter.setBuyAmount(140e6);
        AWKUniswapV3SwapAdapter.SwapRoute memory uniRoute = _uniswapRoute(address(sellToken), address(baseAsset));
        AWKAerodromeV2SwapAdapter.SwapRoute memory v2Route = _aerodromeV2Route(address(sellToken), address(baseAsset));
        AWKAerodromeCLSwapAdapter.SwapRoute memory clRoute = _aerodromeClRoute(address(sellToken), address(baseAsset));
        address[] memory adapters = new address[](3);
        address[] memory targets = new address[](3);
        bytes[] memory datas = new bytes[](3);
        adapters[0] = address(uniswapAdapter);
        adapters[1] = address(aerodromeV2Adapter);
        adapters[2] = address(aerodromeClAdapter);
        targets[0] = address(uniswapRouter);
        targets[1] = address(aerodromeV2Router);
        targets[2] = address(aerodromeClRouter);
        datas[0] = abi.encodeCall(uniswapAdapter.swap, (address(sellToken), address(baseAsset), uniRoute, uint256(100e6), uint256(100e6)));
        datas[1] = abi.encodeCall(aerodromeV2Adapter.swap, (address(sellToken), address(baseAsset), v2Route, uint256(100e6), uint256(100e6)));
        datas[2] = abi.encodeCall(aerodromeClAdapter.swap, (address(sellToken), address(baseAsset), clRoute, uint256(100e6), uint256(100e6)));
        vm.prank(user);
        bytes[] memory results = wallet.executeViaAdapterBatch(adapters, targets, datas);
        assertEq(_decodeUint(results[0]), 120e6);
        assertEq(_decodeUint(results[1]), 130e6);
        assertEq(_decodeUint(results[2]), 140e6);
        assertEq(baseAsset.balanceOf(address(wallet)), 390e6);
        assertEq(sellToken.balanceOf(address(wallet)), 700e6);
    }

    function test_UniswapSwap_RevertsOnEndpointMismatch() public {
        AgentWalletV1 wallet = _createWallet();
        sellToken.mint(address(wallet), 500e6);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(sellToken), address(otherToken));
        bytes memory data = abi.encodeCall(uniswapAdapter.swap, (address(sellToken), address(baseAsset), route, uint256(100e6), uint256(50e6)));
        bytes memory innerError = abi.encodeWithSelector(InvalidRouteEndpoints.selector, address(sellToken), address(baseAsset));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AdapterExecutionFailed.selector, innerError));
        wallet.executeViaAdapter(address(uniswapAdapter), address(uniswapRouter), data);
    }

    function test_Swap_RevertsWhenSellPolicyBlocksToken() public {
        AgentWalletV1 wallet = _createWallet();
        sellToken.mint(address(wallet), 500e6);
        vm.prank(admin);
        sellPolicy.removeSellableToken(address(sellToken));
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(sellToken), address(baseAsset));
        bytes memory data = abi.encodeCall(uniswapAdapter.swap, (address(sellToken), address(baseAsset), route, uint256(100e6), uint256(50e6)));
        bytes memory innerError = abi.encodeWithSelector(SellTokenNotAllowed.selector, address(sellToken));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AdapterExecutionFailed.selector, innerError));
        wallet.executeViaAdapter(address(uniswapAdapter), address(uniswapRouter), data);
    }

    function test_Swap_RevertsWhenBuyingNonBaseAsset() public {
        AgentWalletV1 wallet = _createWallet();
        sellToken.mint(address(wallet), 500e6);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(sellToken), address(otherToken));
        bytes memory data = abi.encodeCall(uniswapAdapter.swap, (address(sellToken), address(otherToken), route, uint256(100e6), uint256(50e6)));
        bytes memory innerError = abi.encodeWithSelector(AssetNotAllowed.selector);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AdapterExecutionFailed.selector, innerError));
        wallet.executeViaAdapter(address(uniswapAdapter), address(uniswapRouter), data);
    }

    function test_WalletEnforcesTargetToAdapterMapping() public {
        AgentWalletV1 wallet = _createWallet();
        sellToken.mint(address(wallet), 500e6);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(sellToken), address(baseAsset));
        bytes memory data = abi.encodeCall(uniswapAdapter.swap, (address(sellToken), address(baseAsset), route, uint256(100e6), uint256(50e6)));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(uniswapAdapter)));
        wallet.executeViaAdapter(address(uniswapAdapter), address(aerodromeV2Router), data);
    }

    function test_UniswapSwap_RecordsAndConvertsYieldTokenFees() public {
        AgentWalletV1 wallet = _createWallet();
        sellToken.mint(address(wallet), 1_000e6);
        vm.prank(address(wallet));
        feeTracker.recordAgentYieldTokenEarned(address(sellToken), 100e6);
        assertEq(feeTracker.agentYieldTokenFeesOwed(address(wallet), address(sellToken)), 10e6);
        uniswapRouter.setBuyAmount(200e6);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(sellToken), address(baseAsset));
        bytes memory data = abi.encodeCall(uniswapAdapter.swap, (address(sellToken), address(baseAsset), route, uint256(50e6), uint256(100e6)));
        vm.prank(user);
        wallet.executeViaAdapter(address(uniswapAdapter), address(uniswapRouter), data);
        assertEq(feeTracker.agentYieldTokenFeesOwed(address(wallet), address(sellToken)), 0);
        assertEq(feeTracker.agentFeesCharged(address(wallet)), 40e6);
    }
}
