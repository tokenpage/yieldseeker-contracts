// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../../src/AgentWalletV3.sol";
import {YieldSeekerAerodromeCLSwapAdapter} from "../../../src/adapters/AerodromeCLSwapAdapter.sol";
import {YieldSeekerAerodromeV2SwapAdapter} from "../../../src/adapters/AerodromeV2SwapAdapter.sol";
import {FeesOwed, NoSwapPolicy} from "../../../src/adapters/SwapAdapter.sol";
import {YieldSeekerUniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {AdapterExecutionFailed} from "../../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "../../../src/agentwalletkit/AWKErrors.sol";
import {AWKAerodromeCLSwapAdapter, IAerodromeCLSwapRouter} from "../../../src/agentwalletkit/adapters/AWKAerodromeCLSwapAdapter.sol";
import {AWKAerodromeV2SwapAdapter, IAerodromeV2Router} from "../../../src/agentwalletkit/adapters/AWKAerodromeV2SwapAdapter.sol";
import {InsufficientOutput, InvalidRouteEndpoints, InvalidRouteLength, InvalidSwapRoute, InvalidSwapTokenAddress, SwapExpired, SwapInputMismatch} from "../../../src/agentwalletkit/adapters/AWKSwapAdapter.sol";
import {AWKUniswapV3SwapAdapter, IUniswapV3SwapRouter} from "../../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {FeeActions} from "../../../src/fees/FeeActions.sol";
import {FeePlanChoice} from "../../../src/fees/FeeTracker.sol";
import {IntegrationBase} from "../../integration/IntegrationBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

contract RouterBehaviorMock {
    enum Behavior {
        Exact,
        UnderSpend,
        LateDelivery
    }

    Behavior public behavior;
    uint256 public deliveredAmount;
    uint256 public reportedAmount;
    uint256 public calls;
    uint256 public lastAmountIn;
    uint256 public lastAmountOutMinimum;
    uint256 public lastDeadline;
    address public lastRecipient;
    address public lastRouteStart;
    address public lastRouteEnd;

    function configure(Behavior behavior_, uint256 deliveredAmount_, uint256 reportedAmount_) external {
        behavior = behavior_;
        deliveredAmount = deliveredAmount_;
        reportedAmount = reportedAmount_;
    }

    function refundETH() external payable {
        (bool sent,) = msg.sender.call{value: address(this).balance}("");
        require(sent);
    }

    function exactInput(IUniswapV3SwapRouter.ExactInputParams calldata params) external payable returns (uint256) {
        (address routeStart, address routeEnd) = _decodePackedEndpoints(params.path);
        return _swap(IERC20(routeStart), IERC20(routeEnd), params.recipient, params.amountIn, params.amountOutMinimum, 0, routeStart, routeEnd);
    }

    function exactInput(IAerodromeCLSwapRouter.ExactInputParams calldata params) external payable returns (uint256) {
        (address routeStart, address routeEnd) = _decodePackedEndpoints(params.path);
        return _swap(IERC20(routeStart), IERC20(routeEnd), params.recipient, params.amountIn, params.amountOutMinimum, params.deadline, routeStart, routeEnd);
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMinimum, IAerodromeV2Router.Route[] memory routes, address recipient, uint256 deadline) external returns (uint256[] memory amounts) {
        require(routes.length > 0, "empty route");
        address routeStart = routes[0].from;
        address routeEnd = routes[routes.length - 1].to;
        uint256 reported = _swap(IERC20(routeStart), IERC20(routeEnd), recipient, amountIn, amountOutMinimum, deadline, routeStart, routeEnd);
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;
        amounts[routes.length] = reported;
    }

    function _swap(IERC20 sellToken, IERC20 buyToken, address recipient, uint256 amountIn, uint256 amountOutMinimum, uint256 deadline, address routeStart, address routeEnd) private returns (uint256) {
        calls++;
        lastAmountIn = amountIn;
        lastAmountOutMinimum = amountOutMinimum;
        lastDeadline = deadline;
        lastRecipient = recipient;
        lastRouteStart = routeStart;
        lastRouteEnd = routeEnd;

        uint256 spend = behavior == Behavior.UnderSpend ? amountIn - 1 : amountIn;
        require(sellToken.transferFrom(msg.sender, address(this), spend), "input transfer failed");
        if (behavior != Behavior.LateDelivery && deliveredAmount > 0) {
            require(buyToken.transfer(recipient, deliveredAmount), "output transfer failed");
        }
        return reportedAmount;
    }

    function _decodePackedEndpoints(bytes calldata path) private pure returns (address firstToken, address lastToken) {
        require(path.length >= 40, "short packed route");
        assembly {
            firstToken := shr(96, calldataload(path.offset))
            lastToken := shr(96, calldataload(add(path.offset, sub(path.length, 20))))
        }
    }
}

contract SwapAdapterProperties is IntegrationBase {
    uint256 private constant SELL_AMOUNT = 1e18;
    uint256 private constant BUY_AMOUNT = 10e6;

    RouterBehaviorMock[3] private routers;
    YieldSeekerUniswapV3SwapAdapter private uniswapAdapter;
    YieldSeekerAerodromeV2SwapAdapter private aerodromeV2Adapter;
    YieldSeekerAerodromeCLSwapAdapter private aerodromeCLAdapter;
    AgentWallet private wallet;

    function setUp() public override {
        super.setUp();
        for (uint8 i = 0; i < 3; i++) {
            routers[i] = new RouterBehaviorMock();
            _fund(address(usdc), address(routers[i]), 1_000_000e6);
        }
        uniswapAdapter = new YieldSeekerUniswapV3SwapAdapter(address(routers[0]));
        aerodromeV2Adapter = new YieldSeekerAerodromeV2SwapAdapter(address(routers[1]), address(0xFACADE));
        aerodromeCLAdapter = new YieldSeekerAerodromeCLSwapAdapter(address(routers[2]));
        _registerTarget(borrowRegistry, address(routers[0]), address(uniswapAdapter));
        _registerTarget(borrowRegistry, address(routers[1]), address(aerodromeV2Adapter));
        _registerTarget(borrowRegistry, address(routers[2]), address(aerodromeCLAdapter));
        wallet = _createBorrowWallet(owner, 14);
        _fundWallet(wallet, address(rewardToken), 3 * SELL_AMOUNT);
    }

    function test_eachDexUsesExactInputAndPassesValidatedRouteAndDeadline() public {
        uint256 deadline = block.timestamp;
        for (uint8 dex = 0; dex < 3; dex++) {
            routers[dex].configure(RouterBehaviorMock.Behavior.Exact, BUY_AMOUNT, BUY_AMOUNT);
            uint256 routerEth = dex == 1 ? 0 : 1 ether;
            vm.deal(address(routers[dex]), routerEth);
            uint256 walletEthBefore = address(wallet).balance;
            bytes memory result = _executeDex(dex, SELL_AMOUNT, 1e6, deadline);
            assertEq(_decodeUint(result), BUY_AMOUNT);
            assertEq(routers[dex].lastAmountIn(), SELL_AMOUNT);
            assertEq(routers[dex].lastAmountOutMinimum(), 1e6);
            assertEq(routers[dex].lastRecipient(), address(wallet));
            assertEq(routers[dex].lastRouteStart(), address(rewardToken));
            assertEq(routers[dex].lastRouteEnd(), address(usdc));
            assertEq(routers[dex].calls(), 1);
            if (dex != 0) assertEq(routers[dex].lastDeadline(), deadline);
            assertEq(address(routers[dex]).balance, 0);
            assertEq(address(wallet).balance, walletEthBefore + routerEth);
        }
    }

    function testFuzz_eachDexCountsMinimumOfMeasuredAndReportedOutput(uint8 dexSeed, uint256 deliveredSeed, uint256 reportedSeed, uint256 heldSeed) public {
        uint8 dex = uint8(bound(dexSeed, 0, 2));
        uint256 delivered = bound(deliveredSeed, 1e6, 100e6);
        uint256 reported = bound(reportedSeed, 1e6, 100e6);
        uint256 minimum = delivered < reported ? delivered : reported;
        _fundWallet(wallet, address(usdc), bound(heldSeed, 1, 1_000e6));
        routers[dex].configure(RouterBehaviorMock.Behavior.Exact, delivered, reported);

        bytes memory result = _executeDex(dex, SELL_AMOUNT, minimum, block.timestamp);
        assertEq(_decodeUint(result), minimum, "adapter did not cap output at the smaller measured or reported amount");
        assertEq(routers[dex].lastAmountOutMinimum(), minimum);
        assertEq(routers[dex].lastRouteStart(), address(rewardToken));
        assertEq(routers[dex].lastRouteEnd(), address(usdc));
    }

    function test_rewardSalesStillWorkWhileBorrowFeesStayOwed() public {
        address marketTarget = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        _fundWallet(wallet, address(usdc), 100e6);
        _execute(wallet, address(aaveV3LendingAdapter), marketTarget, abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, 100e6)));
        _execute(wallet, address(aaveV3LendingAdapter), marketTarget, abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, 1e16)));
        vm.warp(block.timestamp + 365 days);
        _execute(wallet, address(aaveV3LendingAdapter), marketTarget, abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));
        assertGt(wallet.feeTracker().feesOwedInBaseAsset(address(wallet)), 1);

        routers[0].configure(RouterBehaviorMock.Behavior.Exact, 1, 1);
        _executeDex(0, SELL_AMOUNT, 1, block.timestamp);
        assertGt(wallet.feeTracker().feesOwedInBaseAsset(address(wallet)), 0);
    }

    function test_eachDexRejectsUnderSpendUnderDeliveryAndLateDelivery() public {
        uint256 minBuy = 5e6;
        for (uint8 dex = 0; dex < 3; dex++) {
            routers[dex].configure(RouterBehaviorMock.Behavior.UnderSpend, minBuy, minBuy);
            _executeDexExpectRevert(dex, SELL_AMOUNT, minBuy, block.timestamp, abi.encodeWithSelector(SwapInputMismatch.selector, SELL_AMOUNT - 1, SELL_AMOUNT));

            routers[dex].configure(RouterBehaviorMock.Behavior.Exact, minBuy - 1, minBuy + 1);
            _executeDexExpectRevert(dex, SELL_AMOUNT, minBuy, block.timestamp, abi.encodeWithSelector(InsufficientOutput.selector, minBuy - 1, minBuy));

            routers[dex].configure(RouterBehaviorMock.Behavior.LateDelivery, minBuy, minBuy);
            _executeDexExpectRevert(dex, SELL_AMOUNT, minBuy, block.timestamp, abi.encodeWithSelector(InsufficientOutput.selector, uint256(0), minBuy));
        }
    }

    function test_borrowWalletCannotSwapBaseAssetWhileFeesRemainOwed() public {
        FeeActions.DebtChange memory debtChange = FeeActions.DebtChange({market: address(0xBEEF), debtToken: address(weth), debtBefore: 0, borrowed: 1e18, repaid: 0, debtPriceInBaseAsset: 1e36});
        vm.prank(address(wallet));
        borrowFeeTracker.reportAction(FeeActions.DEBT_CHANGE, abi.encode(debtChange));

        uint256 sellAmount = 100e6;
        uint256 boughtAmount = priceOracle.quote(address(usdc), address(weth), sellAmount);
        _fundWallet(wallet, address(usdc), sellAmount);
        _fund(address(weth), address(routers[0]), boughtAmount);
        routers[0].configure(RouterBehaviorMock.Behavior.Exact, boughtAmount, boughtAmount);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(usdc), address(weth));
        bytes memory data = abi.encodeCall(uniswapAdapter.swap, (address(usdc), address(weth), route, sellAmount, uint256(1), block.timestamp));
        vm.recordLogs();
        bytes memory result = _execute(wallet, address(uniswapAdapter), address(routers[0]), data);
        Vm.Log[] memory firstSwapLogs = vm.getRecordedLogs();
        assertFalse(_hasZeroFeeTransfer(firstSwapLogs, address(wallet)));
        assertEq(_decodeUint(result), boughtAmount);
        assertEq(borrowFeeTracker.feesOwedInBaseAsset(address(wallet)), 0);

        vm.prank(address(wallet));
        borrowFeeTracker.reportAction(FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(usdc), amount: 100e6})));
        uint256 owed = borrowFeeTracker.feesOwedInBaseAsset(address(wallet));
        assertGt(owed, 0);

        _fundWallet(wallet, address(usdc), sellAmount);
        _fund(address(weth), address(routers[0]), boughtAmount);
        _executeExpectRevert(wallet, address(uniswapAdapter), address(routers[0]), data, abi.encodeWithSelector(FeesOwed.selector, owed));
        assertEq(usdc.balanceOf(address(wallet)), sellAmount, "reverted swap retained its base-asset input");
        assertEq(weth.balanceOf(address(wallet)), boughtAmount, "reverted swap retained its output");
    }

    function test_walletWithoutSwapPolicyCannotReachTheRouter() public {
        bytes32 profile = keccak256("no swap policy");
        AgentWalletFactory policylessFactory = new AgentWalletFactory(address(this), address(this), operator);
        AgentWallet policylessImplementation = new AgentWallet(address(policylessFactory));
        policylessFactory.setAgentWalletImplementation(policylessImplementation);
        policylessFactory.setAdapterRegistry(profile, borrowRegistry);
        policylessFactory.setFeeTracker(profile, vaultFeeTracker);
        FeePlanChoice[] memory noPlans = new FeePlanChoice[](0);
        vm.prank(operator);
        AgentWallet policylessWallet = policylessFactory.createAgentWallet(owner, 1, address(usdc), profile, noPlans);
        assertEq(address(policylessWallet.swapPolicy()), address(0));

        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(rewardToken), address(usdc));
        bytes memory data = abi.encodeCall(uniswapAdapter.swap, (address(rewardToken), address(usdc), route, SELL_AMOUNT, uint256(1), block.timestamp));
        uint256 callsBefore = routers[0].calls();
        _executeExpectRevert(policylessWallet, address(uniswapAdapter), address(routers[0]), data, abi.encodeWithSelector(NoSwapPolicy.selector));
        assertEq(routers[0].calls(), callsBefore);
    }

    function test_eachDexRejectsExpiredSwapsAndRouteEndpointMismatchBeforeRouterCall() public {
        for (uint8 dex = 0; dex < 3; dex++) {
            uint256 callsBefore = routers[dex].calls();
            uint256 expiredDeadline = block.timestamp - 1;
            _executeDexExpectRevert(dex, SELL_AMOUNT, 1e6, expiredDeadline, abi.encodeWithSelector(SwapExpired.selector, expiredDeadline));
            assertEq(routers[dex].calls(), callsBefore, "expired swap reached the router");

            _executeWrongRouteExpectRevert(dex);
            assertEq(routers[dex].calls(), callsBefore, "invalid route reached the router");
        }
    }

    function test_eachDexRejectsZeroAmountsInvalidTokensAndMalformedRoutes() public {
        for (uint8 dex; dex < 3; ++dex) {
            _executeDexExpectRevert(dex, 0, 1, block.timestamp, abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
            _executeDexExpectRevert(dex, SELL_AMOUNT, 0, block.timestamp, abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
            _executeInvalidTokenExpectRevert(dex, address(0), address(usdc));
            _executeInvalidTokenExpectRevert(dex, address(rewardToken), address(0));
            _executeInvalidTokenExpectRevert(dex, address(rewardToken), address(rewardToken));
            _executeMalformedRouteExpectRevert(dex, false);
            _executeMalformedRouteExpectRevert(dex, true);
        }
    }

    function _executeInvalidTokenExpectRevert(uint8 dex, address sellToken, address buyToken) private {
        bytes memory data;
        address adapter;
        bytes memory expected = abi.encodeWithSelector(InvalidSwapTokenAddress.selector, sellToken == address(0) ? address(0) : buyToken);
        if (dex == 0) {
            AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(sellToken, buyToken);
            data = abi.encodeCall(uniswapAdapter.swap, (sellToken, buyToken, route, SELL_AMOUNT, uint256(1), block.timestamp));
            adapter = address(uniswapAdapter);
        } else if (dex == 1) {
            AWKAerodromeV2SwapAdapter.SwapRoute memory route = _aerodromeV2Route(sellToken, buyToken);
            data = abi.encodeCall(aerodromeV2Adapter.swap, (sellToken, buyToken, route, SELL_AMOUNT, uint256(1), block.timestamp));
            adapter = address(aerodromeV2Adapter);
        } else {
            AWKAerodromeCLSwapAdapter.SwapRoute memory route = _aerodromeCLRoute(sellToken, buyToken);
            data = abi.encodeCall(aerodromeCLAdapter.swap, (sellToken, buyToken, route, SELL_AMOUNT, uint256(1), block.timestamp));
            adapter = address(aerodromeCLAdapter);
        }
        _executeExpectRevert(wallet, adapter, address(routers[dex]), data, expected);
    }

    function _executeMalformedRouteExpectRevert(uint8 dex, bool mismatchedAuxiliaryLength) private {
        bytes memory data;
        address adapter;
        bytes memory expected;
        if (dex == 0) {
            AWKUniswapV3SwapAdapter.SwapRoute memory route;
            route.path = new address[](mismatchedAuxiliaryLength ? 2 : 1);
            route.path[0] = address(rewardToken);
            if (mismatchedAuxiliaryLength) route.path[1] = address(usdc);
            route.fees = new uint24[](mismatchedAuxiliaryLength ? 0 : 0);
            expected = mismatchedAuxiliaryLength ? abi.encodeWithSelector(InvalidSwapRoute.selector) : abi.encodeWithSelector(InvalidRouteLength.selector, uint256(1));
            data = abi.encodeCall(uniswapAdapter.swap, (address(rewardToken), address(usdc), route, SELL_AMOUNT, uint256(1), block.timestamp));
            adapter = address(uniswapAdapter);
        } else if (dex == 1) {
            AWKAerodromeV2SwapAdapter.SwapRoute memory route;
            route.path = new address[](mismatchedAuxiliaryLength ? 2 : 1);
            route.path[0] = address(rewardToken);
            if (mismatchedAuxiliaryLength) route.path[1] = address(usdc);
            route.stables = new bool[](0);
            expected = mismatchedAuxiliaryLength ? abi.encodeWithSelector(InvalidSwapRoute.selector) : abi.encodeWithSelector(InvalidRouteLength.selector, uint256(1));
            data = abi.encodeCall(aerodromeV2Adapter.swap, (address(rewardToken), address(usdc), route, SELL_AMOUNT, uint256(1), block.timestamp));
            adapter = address(aerodromeV2Adapter);
        } else {
            AWKAerodromeCLSwapAdapter.SwapRoute memory route;
            route.path = new address[](mismatchedAuxiliaryLength ? 2 : 1);
            route.path[0] = address(rewardToken);
            if (mismatchedAuxiliaryLength) route.path[1] = address(usdc);
            route.tickSpacings = new int24[](0);
            expected = mismatchedAuxiliaryLength ? abi.encodeWithSelector(InvalidSwapRoute.selector) : abi.encodeWithSelector(InvalidRouteLength.selector, uint256(1));
            data = abi.encodeCall(aerodromeCLAdapter.swap, (address(rewardToken), address(usdc), route, SELL_AMOUNT, uint256(1), block.timestamp));
            adapter = address(aerodromeCLAdapter);
        }
        _executeExpectRevert(wallet, adapter, address(routers[dex]), data, expected);
    }

    function _executeDex(uint8 dex, uint256 sellAmount, uint256 minBuyAmount, uint256 deadline) private returns (bytes memory) {
        if (dex == 0) {
            AWKUniswapV3SwapAdapter.SwapRoute memory uniswapRoute = _uniswapRoute(address(rewardToken), address(usdc));
            return _execute(wallet, address(uniswapAdapter), address(routers[dex]), abi.encodeCall(uniswapAdapter.swap, (address(rewardToken), address(usdc), uniswapRoute, sellAmount, minBuyAmount, deadline)));
        }
        if (dex == 1) {
            AWKAerodromeV2SwapAdapter.SwapRoute memory aerodromeV2Route = _aerodromeV2Route(address(rewardToken), address(usdc));
            return _execute(wallet, address(aerodromeV2Adapter), address(routers[dex]), abi.encodeCall(aerodromeV2Adapter.swap, (address(rewardToken), address(usdc), aerodromeV2Route, sellAmount, minBuyAmount, deadline)));
        }
        AWKAerodromeCLSwapAdapter.SwapRoute memory aerodromeCLRoute = _aerodromeCLRoute(address(rewardToken), address(usdc));
        return _execute(wallet, address(aerodromeCLAdapter), address(routers[dex]), abi.encodeCall(aerodromeCLAdapter.swap, (address(rewardToken), address(usdc), aerodromeCLRoute, sellAmount, minBuyAmount, deadline)));
    }

    function _executeDexExpectRevert(uint8 dex, uint256 sellAmount, uint256 minBuyAmount, uint256 deadline, bytes memory innerError) private {
        bytes memory data;
        address adapter;
        if (dex == 0) {
            AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(rewardToken), address(usdc));
            data = abi.encodeCall(uniswapAdapter.swap, (address(rewardToken), address(usdc), route, sellAmount, minBuyAmount, deadline));
            adapter = address(uniswapAdapter);
        } else if (dex == 1) {
            AWKAerodromeV2SwapAdapter.SwapRoute memory route = _aerodromeV2Route(address(rewardToken), address(usdc));
            data = abi.encodeCall(aerodromeV2Adapter.swap, (address(rewardToken), address(usdc), route, sellAmount, minBuyAmount, deadline));
            adapter = address(aerodromeV2Adapter);
        } else {
            AWKAerodromeCLSwapAdapter.SwapRoute memory route = _aerodromeCLRoute(address(rewardToken), address(usdc));
            data = abi.encodeCall(aerodromeCLAdapter.swap, (address(rewardToken), address(usdc), route, sellAmount, minBuyAmount, deadline));
            adapter = address(aerodromeCLAdapter);
        }
        _executeExpectRevert(wallet, adapter, address(routers[dex]), data, innerError);
    }

    function _executeWrongRouteExpectRevert(uint8 dex) private {
        bytes memory data;
        address adapter;
        bytes memory expected = abi.encodeWithSelector(InvalidRouteEndpoints.selector, address(rewardToken), address(usdc));
        if (dex == 0) {
            AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(wellToken), address(usdc));
            data = abi.encodeCall(uniswapAdapter.swap, (address(rewardToken), address(usdc), route, SELL_AMOUNT, uint256(1e6), block.timestamp));
            adapter = address(uniswapAdapter);
        } else if (dex == 1) {
            AWKAerodromeV2SwapAdapter.SwapRoute memory route = _aerodromeV2Route(address(wellToken), address(usdc));
            data = abi.encodeCall(aerodromeV2Adapter.swap, (address(rewardToken), address(usdc), route, SELL_AMOUNT, uint256(1e6), block.timestamp));
            adapter = address(aerodromeV2Adapter);
        } else {
            AWKAerodromeCLSwapAdapter.SwapRoute memory route = _aerodromeCLRoute(address(wellToken), address(usdc));
            data = abi.encodeCall(aerodromeCLAdapter.swap, (address(rewardToken), address(usdc), route, SELL_AMOUNT, uint256(1e6), block.timestamp));
            adapter = address(aerodromeCLAdapter);
        }
        _executeExpectRevert(wallet, adapter, address(routers[dex]), data, expected);
    }

    function _decodeUint(bytes memory data) private pure returns (uint256) {
        return abi.decode(abi.decode(data, (bytes)), (uint256));
    }

    function _uniswapRoute(address from, address to) private pure returns (AWKUniswapV3SwapAdapter.SwapRoute memory route) {
        route.path = new address[](2);
        route.path[0] = from;
        route.path[1] = to;
        route.fees = new uint24[](1);
        route.fees[0] = 3000;
    }

    function _aerodromeV2Route(address from, address to) private pure returns (AWKAerodromeV2SwapAdapter.SwapRoute memory route) {
        route.path = new address[](2);
        route.path[0] = from;
        route.path[1] = to;
        route.stables = new bool[](1);
    }

    function _aerodromeCLRoute(address from, address to) private pure returns (AWKAerodromeCLSwapAdapter.SwapRoute memory route) {
        route.path = new address[](2);
        route.path[0] = from;
        route.path[1] = to;
        route.tickSpacings = new int24[](1);
        route.tickSpacings[0] = 100;
    }

    function _hasZeroFeeTransfer(Vm.Log[] memory logs, address wallet_) private view returns (bool) {
        bytes32 transferTopic = keccak256("Transfer(address,address,uint256)");
        for (uint256 i; i < logs.length; i++) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != address(usdc) || entry.topics.length != 3 || entry.topics[0] != transferTopic) continue;
            address from = address(uint160(uint256(entry.topics[1])));
            address to = address(uint160(uint256(entry.topics[2])));
            if (from == wallet_ && to == feeCollector && abi.decode(entry.data, (uint256)) == 0) return true;
        }
        return false;
    }
}
