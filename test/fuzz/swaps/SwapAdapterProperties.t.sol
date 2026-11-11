// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../../src/AgentWalletV3.sol";
import {YieldSeekerAerodromeCLSwapAdapter} from "../../../src/adapters/AerodromeCLSwapAdapter.sol";
import {YieldSeekerAerodromeV2SwapAdapter} from "../../../src/adapters/AerodromeV2SwapAdapter.sol";
import {YieldSeekerUniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {AdapterExecutionFailed} from "../../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {AWKAerodromeCLSwapAdapter, IAerodromeCLSwapRouter} from "../../../src/agentwalletkit/adapters/AWKAerodromeCLSwapAdapter.sol";
import {AWKAerodromeV2SwapAdapter, IAerodromeV2Router} from "../../../src/agentwalletkit/adapters/AWKAerodromeV2SwapAdapter.sol";
import {InsufficientOutput, InvalidRouteEndpoints, SwapExpired, SwapInputMismatch} from "../../../src/agentwalletkit/adapters/AWKSwapAdapter.sol";
import {AWKUniswapV3SwapAdapter, IUniswapV3SwapRouter} from "../../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {IntegrationBase} from "../../integration/IntegrationBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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

    function refundETH() external payable {}

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
            bytes memory result = _executeDex(dex, SELL_AMOUNT, 1e6, deadline);
            assertEq(_decodeUint(result), BUY_AMOUNT);
            assertEq(routers[dex].lastAmountIn(), SELL_AMOUNT);
            assertEq(routers[dex].lastAmountOutMinimum(), 1e6);
            assertEq(routers[dex].lastRecipient(), address(wallet));
            assertEq(routers[dex].lastRouteStart(), address(rewardToken));
            assertEq(routers[dex].lastRouteEnd(), address(usdc));
            assertEq(routers[dex].calls(), 1);
            if (dex != 0) assertEq(routers[dex].lastDeadline(), deadline);
        }
    }

    function testFuzz_eachDexCountsMinimumOfMeasuredAndReportedOutput(uint8 dexSeed, uint256 deliveredSeed, uint256 reportedSeed) public {
        uint8 dex = uint8(bound(dexSeed, 0, 2));
        uint256 delivered = bound(deliveredSeed, 1e6, 100e6);
        uint256 reported = bound(reportedSeed, 1e6, 100e6);
        uint256 minimum = delivered < reported ? delivered : reported;
        routers[dex].configure(RouterBehaviorMock.Behavior.Exact, delivered, reported);

        bytes memory result = _executeDex(dex, SELL_AMOUNT, minimum, block.timestamp);
        assertEq(_decodeUint(result), minimum, "adapter did not cap output at the smaller measured or reported amount");
        assertEq(routers[dex].lastAmountOutMinimum(), minimum);
        assertEq(routers[dex].lastRouteStart(), address(rewardToken));
        assertEq(routers[dex].lastRouteEnd(), address(usdc));
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
}
