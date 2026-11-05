// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {IYieldSeekerPriceOracle} from "../../src/PriceOracle.sol";
import {YieldSeekerAerodromeCLSwapAdapter} from "../../src/adapters/AerodromeCLSwapAdapter.sol";
import {YieldSeekerAerodromeV2SwapAdapter} from "../../src/adapters/AerodromeV2SwapAdapter.sol";
import {FeesOwed, NoSwapPolicy} from "../../src/adapters/SwapAdapter.sol";
import {SellTokenNotAllowed} from "../../src/adapters/SwapSellPolicy.sol";
import {YieldSeekerUniswapV3SwapAdapter} from "../../src/adapters/UniswapV3SwapAdapter.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {AWKAerodromeCLSwapAdapter, IAerodromeCLSwapRouter, InvalidAerodromeCLRouterTarget} from "../../src/agentwalletkit/adapters/AWKAerodromeCLSwapAdapter.sol";
import {AWKAerodromeV2SwapAdapter, IAerodromeV2Router, InvalidAerodromeV2RouterTarget} from "../../src/agentwalletkit/adapters/AWKAerodromeV2SwapAdapter.sol";
import {InsufficientOutput, InvalidRouteEndpoints, InvalidRouteLength, InvalidSwapRoute, InvalidSwapTokenAddress} from "../../src/agentwalletkit/adapters/AWKSwapAdapter.sol";
import {AWKUniswapV3SwapAdapter, IUniswapV3SwapRouter, InvalidUniswapV3FeeTier, InvalidUniswapV3RouterTarget} from "../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {FeePlanChoice} from "../../src/fees/FeeTracker.sol";
import {SwapAboveDebt, SwapBelowOraclePrice, YieldSeekerBorrowSwapPolicy} from "../../src/swaps/BorrowSwapPolicy.sol";
import {SwapNotAllowed} from "../../src/swaps/IYieldSeekerSwapPolicy.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract RecipientAwareSwapRouter {
    uint256 public configuredBuyAmount;

    function setBuyAmount(uint256 amount) external {
        configuredBuyAmount = amount;
    }

    function exactInput(IUniswapV3SwapRouter.ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        (address sellToken, address buyToken) = _decodePathEndpoints(params.path);
        amountOut = _swap(sellToken, buyToken, params.amountIn, params.amountOutMinimum, params.recipient);
    }

    function exactInput(IAerodromeCLSwapRouter.ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        (address sellToken, address buyToken) = _decodePathEndpoints(params.path);
        amountOut = _swap(sellToken, buyToken, params.amountIn, params.amountOutMinimum, params.recipient);
    }

    function swapExactTokensForTokens(uint256 amountIn, uint256 amountOutMin, IAerodromeV2Router.Route[] memory routes, address to, uint256) external returns (uint256[] memory amounts) {
        require(routes.length > 0);
        uint256 amountOut = _swap(routes[0].from, routes[routes.length - 1].to, amountIn, amountOutMin, to);
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;
        amounts[routes.length] = amountOut;
    }

    function _swap(address sellToken, address buyToken, uint256 amountIn, uint256 amountOutMin, address recipient) private returns (uint256 amountOut) {
        require(IERC20(sellToken).transferFrom(msg.sender, address(this), amountIn));
        amountOut = configuredBuyAmount == 0 ? amountOutMin : configuredBuyAmount;
        require(IERC20(buyToken).transfer(recipient, amountOut));
    }

    function _decodePathEndpoints(bytes calldata path) private pure returns (address firstToken, address lastToken) {
        assembly {
            firstToken := shr(96, calldataload(path.offset))
            lastToken := shr(96, calldataload(add(path.offset, sub(path.length, 20))))
        }
    }
}

contract SwapsTest is IntegrationBase {
    bytes32 private constant NO_SWAP_POLICY_PROFILE = keccak256("no-swap-policy");

    RecipientAwareSwapRouter private recipientUniswapRouter;
    RecipientAwareSwapRouter private recipientAerodromeV2Router;
    RecipientAwareSwapRouter private recipientAerodromeCLRouter;
    YieldSeekerUniswapV3SwapAdapter private recipientUniswapAdapter;
    YieldSeekerAerodromeV2SwapAdapter private recipientAerodromeV2Adapter;
    YieldSeekerAerodromeCLSwapAdapter private recipientAerodromeCLAdapter;

    function setUp() public override {
        super.setUp();
        recipientUniswapRouter = new RecipientAwareSwapRouter();
        recipientAerodromeV2Router = new RecipientAwareSwapRouter();
        recipientAerodromeCLRouter = new RecipientAwareSwapRouter();
        recipientUniswapAdapter = new YieldSeekerUniswapV3SwapAdapter(address(recipientUniswapRouter));
        recipientAerodromeV2Adapter = new YieldSeekerAerodromeV2SwapAdapter(address(recipientAerodromeV2Router), address(0xFACADE));
        recipientAerodromeCLAdapter = new YieldSeekerAerodromeCLSwapAdapter(address(recipientAerodromeCLRouter));
        _registerTarget(vaultRegistry, address(recipientUniswapRouter), address(recipientUniswapAdapter));
        _registerTarget(vaultRegistry, address(recipientAerodromeV2Router), address(recipientAerodromeV2Adapter));
        _registerTarget(vaultRegistry, address(recipientAerodromeCLRouter), address(recipientAerodromeCLAdapter));
    }

    function testRewardSalePaysYieldFeeAndEachDexSendsOutputToTheWallet() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 sellAmount = 10e18;
        _fundWallet(wallet, address(rewardToken), 4 * sellAmount);
        priceOracle.removeSource(address(rewardToken));
        _fund(address(usdc), address(recipientUniswapRouter), 1_000_000e6);
        _fund(address(usdc), address(recipientAerodromeV2Router), 1_000_000e6);
        _fund(address(usdc), address(recipientAerodromeCLRouter), 1_000_000e6);
        uint256 feesBefore = _feesCollected(address(usdc));

        recipientUniswapRouter.setBuyAmount(200e6);
        AWKUniswapV3SwapAdapter.SwapRoute memory uniRoute = _uniswapRoute(address(rewardToken), address(usdc));
        bytes memory result = _execute(wallet, address(recipientUniswapAdapter), address(recipientUniswapRouter), abi.encodeCall(recipientUniswapAdapter.swap, (address(rewardToken), address(usdc), uniRoute, sellAmount, uint256(1))));
        assertEq(_decodeUint(result), 200e6);

        recipientAerodromeV2Router.setBuyAmount(150e6);
        AWKAerodromeV2SwapAdapter.SwapRoute memory v2Route = _aerodromeV2Route(address(rewardToken), address(usdc));
        result = _execute(wallet, address(recipientAerodromeV2Adapter), address(recipientAerodromeV2Router), abi.encodeCall(recipientAerodromeV2Adapter.swap, (address(rewardToken), address(usdc), v2Route, sellAmount, uint256(1))));
        assertEq(_decodeUint(result), 150e6);

        recipientAerodromeCLRouter.setBuyAmount(120e6);
        AWKAerodromeCLSwapAdapter.SwapRoute memory clRoute = _aerodromeCLRoute(address(rewardToken), address(usdc));
        result = _execute(wallet, address(recipientAerodromeCLAdapter), address(recipientAerodromeCLRouter), abi.encodeCall(recipientAerodromeCLAdapter.swap, (address(rewardToken), address(usdc), clRoute, sellAmount, uint256(1))));
        assertEq(_decodeUint(result), 120e6);

        assertEq(rewardToken.balanceOf(address(wallet)), 10e18);
        assertEq(usdc.balanceOf(address(wallet)), 423e6);
        assertEq(_feesCollected(address(usdc)) - feesBefore, 47e6);
    }

    function testVaultPolicyRejectsNonRewardPairsAndSellPolicyBlocksRemovedTokens() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(rewardToken), 100e18);
        _fundWallet(wallet, address(usdc), 100e6);
        AWKUniswapV3SwapAdapter.SwapRoute memory rewardToWeth = _uniswapRoute(address(rewardToken), address(weth));
        bytes memory rewardToWethData = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(weth), rewardToWeth, uint256(1e18), uint256(1)));
        bytes memory notRewardSale = abi.encodeWithSelector(SwapNotAllowed.selector, address(rewardToken), address(weth));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), rewardToWethData, notRewardSale);

        AWKUniswapV3SwapAdapter.SwapRoute memory baseToWeth = _uniswapRoute(address(usdc), address(weth));
        swapSellPolicy.addSellableToken(address(usdc));
        bytes memory baseToWethData = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(usdc), address(weth), baseToWeth, uint256(10e6), uint256(1)));
        bytes memory baseSaleNotAllowed = abi.encodeWithSelector(SwapNotAllowed.selector, address(usdc), address(weth));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), baseToWethData, baseSaleNotAllowed);

        swapSellPolicy.removeSellableToken(address(rewardToken));
        AWKUniswapV3SwapAdapter.SwapRoute memory rewardToBase = _uniswapRoute(address(rewardToken), address(usdc));
        bytes memory rewardToBaseData = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), rewardToBase, uint256(1e18), uint256(1)));
        bytes memory sellBlocked = abi.encodeWithSelector(SellTokenNotAllowed.selector, address(rewardToken));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), rewardToBaseData, sellBlocked);

        assertEq(rewardToken.balanceOf(address(wallet)), 100e18);
        assertEq(usdc.balanceOf(address(wallet)), 100e6);
        assertEq(weth.balanceOf(address(wallet)), 0);
    }

    function testVaultPolicyRejectsPositionTokensWhenAllTokensAreSellable() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        uint256 positionAmount = 100e6;
        _fundWallet(wallet, address(usdc), 2 * positionAmount);
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (positionAmount)));
        _execute(wallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeCall(aaveV3Adapter.deposit, (positionAmount)));
        _fundWallet(wallet, address(rewardToken), 10e18);
        swapSellPolicy.setAllowSellingAllTokens(true);

        AWKUniswapV3SwapAdapter.SwapRoute memory shareRoute = _uniswapRoute(address(erc4626Vault), address(usdc));
        bytes memory shareSale = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(erc4626Vault), address(usdc), shareRoute, positionAmount, uint256(1)));
        bytes memory shareNotAllowed = abi.encodeWithSelector(SwapNotAllowed.selector, address(erc4626Vault), address(usdc));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), shareSale, shareNotAllowed);

        AWKUniswapV3SwapAdapter.SwapRoute memory aTokenRoute = _uniswapRoute(address(aaveV3Vault), address(usdc));
        bytes memory aTokenSale = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(aaveV3Vault), address(usdc), aTokenRoute, positionAmount, uint256(1)));
        bytes memory aTokenNotAllowed = abi.encodeWithSelector(SwapNotAllowed.selector, address(aaveV3Vault), address(usdc));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), aTokenSale, aTokenNotAllowed);

        assertEq(erc4626Vault.balanceOf(address(wallet)), positionAmount);
        assertEq(aaveV3Vault.balanceOf(address(wallet)), positionAmount);
        uniswapV3Router.setBuyAmount(100e6);
        AWKUniswapV3SwapAdapter.SwapRoute memory rewardRoute = _uniswapRoute(address(rewardToken), address(usdc));
        bytes memory rewardSale = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), rewardRoute, 10e18, uint256(1)));
        uint256 feesBefore = _feesCollected(address(usdc));
        bytes memory result = _execute(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), rewardSale);
        assertEq(_decodeUint(result), 100e6);
        assertEq(rewardToken.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 90e6);
        assertEq(_feesCollected(address(usdc)) - feesBefore, 10e6);
    }

    function testUniswapRejectsInvalidRoutesAndRouterTargets() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(rewardToken), 10e18);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(wellToken), address(usdc));
        bytes memory data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        bytes memory invalidEndpoints = abi.encodeWithSelector(InvalidRouteEndpoints.selector, address(rewardToken), address(usdc));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data, invalidEndpoints);

        route = _uniswapRoute(address(rewardToken), address(wellToken));
        data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data, invalidEndpoints);

        route.path = new address[](1);
        route.path[0] = address(rewardToken);
        route.fees = new uint24[](0);
        data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data, abi.encodeWithSelector(InvalidRouteLength.selector, uint256(1)));

        route = _uniswapRoute(address(rewardToken), address(usdc));
        route.fees = new uint24[](0);
        data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data, abi.encodeWithSelector(InvalidSwapRoute.selector));

        route.path = new address[](3);
        route.path[0] = address(rewardToken);
        route.path[1] = address(0);
        route.path[2] = address(usdc);
        route.fees = new uint24[](2);
        route.fees[0] = 3000;
        route.fees[1] = 3000;
        data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data, abi.encodeWithSelector(InvalidSwapTokenAddress.selector, address(0)));

        route = _uniswapRoute(address(rewardToken), address(usdc));
        route.fees[0] = 250;
        data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data, abi.encodeWithSelector(InvalidUniswapV3FeeTier.selector, uint24(250)));

        address wrongTarget = address(0x1234);
        vaultRegistry.setTargetAdapter(wrongTarget, address(uniswapV3SwapAdapter));
        route = _uniswapRoute(address(rewardToken), address(usdc));
        data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), wrongTarget, data, abi.encodeWithSelector(InvalidUniswapV3RouterTarget.selector, wrongTarget, address(uniswapV3Router)));
        assertEq(rewardToken.balanceOf(address(wallet)), 10e18);
    }

    function testAerodromeV2RejectsInvalidRoutesAndRouterTargets() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(rewardToken), 10e18);
        AWKAerodromeV2SwapAdapter.SwapRoute memory route = _aerodromeV2Route(address(wellToken), address(usdc));
        bytes memory data = abi.encodeCall(aerodromeV2SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        bytes memory invalidEndpoints = abi.encodeWithSelector(InvalidRouteEndpoints.selector, address(rewardToken), address(usdc));
        _executeExpectRevert(wallet, address(aerodromeV2SwapAdapter), address(aerodromeV2Router), data, invalidEndpoints);

        route = _aerodromeV2Route(address(rewardToken), address(wellToken));
        data = abi.encodeCall(aerodromeV2SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(aerodromeV2SwapAdapter), address(aerodromeV2Router), data, invalidEndpoints);

        route.path = new address[](1);
        route.path[0] = address(rewardToken);
        route.stables = new bool[](0);
        data = abi.encodeCall(aerodromeV2SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(aerodromeV2SwapAdapter), address(aerodromeV2Router), data, abi.encodeWithSelector(InvalidRouteLength.selector, uint256(1)));

        route = _aerodromeV2Route(address(rewardToken), address(usdc));
        route.stables = new bool[](0);
        data = abi.encodeCall(aerodromeV2SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(aerodromeV2SwapAdapter), address(aerodromeV2Router), data, abi.encodeWithSelector(InvalidSwapRoute.selector));

        route.path = new address[](3);
        route.path[0] = address(rewardToken);
        route.path[1] = address(0);
        route.path[2] = address(usdc);
        route.stables = new bool[](2);
        data = abi.encodeCall(aerodromeV2SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(aerodromeV2SwapAdapter), address(aerodromeV2Router), data, abi.encodeWithSelector(InvalidSwapTokenAddress.selector, address(0)));

        address wrongTarget = address(0x1234);
        vaultRegistry.setTargetAdapter(wrongTarget, address(aerodromeV2SwapAdapter));
        route = _aerodromeV2Route(address(rewardToken), address(usdc));
        data = abi.encodeCall(aerodromeV2SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(aerodromeV2SwapAdapter), wrongTarget, data, abi.encodeWithSelector(InvalidAerodromeV2RouterTarget.selector, wrongTarget, address(aerodromeV2Router)));
        assertEq(rewardToken.balanceOf(address(wallet)), 10e18);
    }

    function testAerodromeCLRejectsInvalidRoutesAndRouterTargets() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(rewardToken), 10e18);
        AWKAerodromeCLSwapAdapter.SwapRoute memory route = _aerodromeCLRoute(address(wellToken), address(usdc));
        bytes memory data = abi.encodeCall(aerodromeCLSwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        bytes memory invalidEndpoints = abi.encodeWithSelector(InvalidRouteEndpoints.selector, address(rewardToken), address(usdc));
        _executeExpectRevert(wallet, address(aerodromeCLSwapAdapter), address(aerodromeCLRouter), data, invalidEndpoints);

        route = _aerodromeCLRoute(address(rewardToken), address(wellToken));
        data = abi.encodeCall(aerodromeCLSwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(aerodromeCLSwapAdapter), address(aerodromeCLRouter), data, invalidEndpoints);

        route.path = new address[](1);
        route.path[0] = address(rewardToken);
        route.tickSpacings = new int24[](0);
        data = abi.encodeCall(aerodromeCLSwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(aerodromeCLSwapAdapter), address(aerodromeCLRouter), data, abi.encodeWithSelector(InvalidRouteLength.selector, uint256(1)));

        route = _aerodromeCLRoute(address(rewardToken), address(usdc));
        route.tickSpacings = new int24[](0);
        data = abi.encodeCall(aerodromeCLSwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(aerodromeCLSwapAdapter), address(aerodromeCLRouter), data, abi.encodeWithSelector(InvalidSwapRoute.selector));

        route.path = new address[](3);
        route.path[0] = address(rewardToken);
        route.path[1] = address(0);
        route.path[2] = address(usdc);
        route.tickSpacings = new int24[](2);
        route.tickSpacings[0] = 100;
        route.tickSpacings[1] = 100;
        data = abi.encodeCall(aerodromeCLSwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(aerodromeCLSwapAdapter), address(aerodromeCLRouter), data, abi.encodeWithSelector(InvalidSwapTokenAddress.selector, address(0)));

        address wrongTarget = address(0x1234);
        vaultRegistry.setTargetAdapter(wrongTarget, address(aerodromeCLSwapAdapter));
        route = _aerodromeCLRoute(address(rewardToken), address(usdc));
        data = abi.encodeCall(aerodromeCLSwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        _executeExpectRevert(wallet, address(aerodromeCLSwapAdapter), wrongTarget, data, abi.encodeWithSelector(InvalidAerodromeCLRouterTarget.selector, wrongTarget, address(aerodromeCLRouter)));
        assertEq(rewardToken.balanceOf(address(wallet)), 10e18);
    }

    function testAllDexesRejectZeroAmountsAndEnforceMinimumOutput() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(rewardToken), 3e18);
        AWKUniswapV3SwapAdapter.SwapRoute memory uniRoute = _uniswapRoute(address(rewardToken), address(usdc));
        AWKAerodromeV2SwapAdapter.SwapRoute memory v2Route = _aerodromeV2Route(address(rewardToken), address(usdc));
        AWKAerodromeCLSwapAdapter.SwapRoute memory clRoute = _aerodromeCLRoute(address(rewardToken), address(usdc));

        bytes memory uniData = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), uniRoute, uint256(0), uint256(0)));
        bytes memory zeroAmount = abi.encodeWithSelector(AWKErrors.ZeroAmount.selector);
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), uniData, zeroAmount);
        bytes memory v2Data = abi.encodeCall(aerodromeV2SwapAdapter.swap, (address(rewardToken), address(usdc), v2Route, uint256(0), uint256(0)));
        _executeExpectRevert(wallet, address(aerodromeV2SwapAdapter), address(aerodromeV2Router), v2Data, zeroAmount);
        bytes memory clData = abi.encodeCall(aerodromeCLSwapAdapter.swap, (address(rewardToken), address(usdc), clRoute, uint256(0), uint256(0)));
        _executeExpectRevert(wallet, address(aerodromeCLSwapAdapter), address(aerodromeCLRouter), clData, zeroAmount);
        uniData = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), uniRoute, uint256(1e18), uint256(0)));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), uniData, zeroAmount);

        uniswapV3Router.setBuyAmount(1);
        uniData = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), uniRoute, uint256(1e18), uint256(2)));
        bytes memory insufficientOutput = abi.encodeWithSelector(InsufficientOutput.selector, uint256(1), uint256(2));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), uniData, insufficientOutput);
        aerodromeV2Router.setBuyAmount(1);
        v2Data = abi.encodeCall(aerodromeV2SwapAdapter.swap, (address(rewardToken), address(usdc), v2Route, uint256(1e18), uint256(2)));
        _executeExpectRevert(wallet, address(aerodromeV2SwapAdapter), address(aerodromeV2Router), v2Data, insufficientOutput);
        aerodromeCLRouter.setBuyAmount(1);
        clData = abi.encodeCall(aerodromeCLSwapAdapter.swap, (address(rewardToken), address(usdc), clRoute, uint256(1e18), uint256(2)));
        _executeExpectRevert(wallet, address(aerodromeCLSwapAdapter), address(aerodromeCLRouter), clData, insufficientOutput);

        assertEq(rewardToken.balanceOf(address(wallet)), 3e18);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    function testBorrowProfileUsesDifferentRulesForSharedAdapterAndDoesNotChargeSwapFees() public {
        AgentWallet vaultWallet = _createVaultWallet(owner, 1);
        AgentWallet borrowWallet = _createBorrowWallet(owner, 2);
        uint256 amountIn = 100e6;
        _fundWallet(borrowWallet, address(usdc), amountIn);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(usdc), address(weth));
        bytes memory data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(usdc), address(weth), route, amountIn, uint256(1)));
        bytes memory invalidBorrowSwap = abi.encodeWithSelector(SwapNotAllowed.selector, address(usdc), address(weth));
        _executeExpectRevert(borrowWallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data, invalidBorrowSwap);

        uint256 borrowedAmount = _oracleFloor(amountIn);
        _borrowWeth(borrowWallet, 1_000e6, borrowedAmount);
        vm.prank(owner);
        borrowWallet.withdrawAllAssetToUser(owner, address(weth));
        _fundWallet(vaultWallet, address(usdc), amountIn);
        uint256 minimum = _oracleFloor(amountIn);
        uint256 collectorBefore = _feesCollected(address(usdc));
        uniswapV3Router.setBuyAmount(minimum);
        bytes memory invalidVaultSwap = abi.encodeWithSelector(SwapNotAllowed.selector, address(usdc), address(weth));
        _executeExpectRevert(vaultWallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data, invalidVaultSwap);

        bytes memory result = _execute(borrowWallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data);
        assertEq(_decodeUint(result), minimum);
        assertEq(usdc.balanceOf(address(borrowWallet)), 0);
        assertEq(weth.balanceOf(address(borrowWallet)), minimum);
        assertEq(_feesCollected(address(usdc)), collectorBefore);
        assertEq(borrowYieldFeeModule.feesOwed(address(borrowWallet)), 0);

        _execute(borrowWallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, type(uint256).max)));
        assertEq(borrowFeeModule.tokenDebt(address(borrowWallet), address(weth)), 0);
        assertEq(weth.balanceOf(address(borrowWallet)), 0);
    }

    function testBorrowSwapBelowOracleFloorRevertsWithoutMovingBalances() public {
        AgentWallet wallet = _createBorrowWallet(owner, 1);
        _borrowWeth(wallet, 1_000e6, 1e18);
        uint256 amountIn = 100e6;
        _fundWallet(wallet, address(usdc), amountIn);
        uint256 minimum = _oracleFloor(amountIn);
        uint256 output = minimum - 1;
        uint256 wethBefore = weth.balanceOf(address(wallet));
        uniswapV3Router.setBuyAmount(output);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(usdc), address(weth));
        bytes memory data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(usdc), address(weth), route, amountIn, uint256(1)));
        bytes memory floorError = abi.encodeWithSelector(SwapBelowOraclePrice.selector, output, minimum);
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data, floorError);
        assertEq(usdc.balanceOf(address(wallet)), amountIn);
        assertEq(weth.balanceOf(address(wallet)), wethBefore);
    }

    function testBorrowPolicyRejectsSellingBorrowedTokensAndBuyingUnborrowedTokens() public {
        AgentWallet wallet = _createBorrowWallet(owner, 1);
        _borrowWeth(wallet, 1_000e6, 1e18);
        _fundWallet(wallet, address(rewardToken), 10e18);
        AWKUniswapV3SwapAdapter.SwapRoute memory sellBorrowed = _uniswapRoute(address(weth), address(usdc));
        bytes memory sellBorrowedData = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(weth), address(usdc), sellBorrowed, uint256(1e17), uint256(1)));
        bytes memory borrowedNotSellable = abi.encodeWithSelector(SwapNotAllowed.selector, address(weth), address(usdc));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), sellBorrowedData, borrowedNotSellable);

        AWKUniswapV3SwapAdapter.SwapRoute memory buyUnborrowed = _uniswapRoute(address(usdc), address(rewardToken));
        bytes memory buyUnborrowedData = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(usdc), address(rewardToken), buyUnborrowed, uint256(1e6), uint256(1)));
        bytes memory unborrowedNotBuyable = abi.encodeWithSelector(SwapNotAllowed.selector, address(usdc), address(rewardToken));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), buyUnborrowedData, unborrowedNotBuyable);

        assertEq(weth.balanceOf(address(wallet)), 1e18);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(rewardToken.balanceOf(address(wallet)), 10e18);
    }

    function testBorrowSwapCannotLeaveHeldBalanceAboveDebt() public {
        AgentWallet wallet = _createBorrowWallet(owner, 1);
        uint256 debt = 1e18;
        _borrowWeth(wallet, 3_000e6, debt);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(weth));

        uint256 amountIn = 2_000e6;
        _fundWallet(wallet, address(usdc), amountIn);
        uint256 held = debt + 1;
        uniswapV3Router.setBuyAmount(held);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(usdc), address(weth));
        bytes memory data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(usdc), address(weth), route, amountIn, uint256(1)));
        bytes memory aboveDebt = abi.encodeWithSelector(SwapAboveDebt.selector, held, debt);
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data, aboveDebt);

        assertEq(weth.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), amountIn);
        assertEq(borrowFeeModule.tokenDebt(address(wallet), address(weth)), debt);

        vm.prank(owner);
        weth.transfer(address(wallet), debt);
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, type(uint256).max)));
        assertEq(borrowFeeModule.tokenDebt(address(wallet), address(weth)), 0);
    }

    function testBorrowSwapUpToDebtCanRepayInFull() public {
        AgentWallet wallet = _createBorrowWallet(owner, 1);
        uint256 debt = 1e18;
        _borrowWeth(wallet, 3_000e6, debt);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(weth));

        uint256 amountIn = 2_000e6;
        _fundWallet(wallet, address(usdc), amountIn);
        uniswapV3Router.setBuyAmount(debt);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(usdc), address(weth));
        bytes memory data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(usdc), address(weth), route, amountIn, uint256(1)));
        _execute(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data);
        assertEq(weth.balanceOf(address(wallet)), debt);
        assertEq(borrowFeeModule.tokenDebt(address(wallet), address(weth)), debt);

        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, type(uint256).max)));
        assertEq(aaveV3VariableDebtToken.balanceOf(address(wallet)), 0);
        assertEq(borrowFeeModule.tokenDebt(address(wallet), address(weth)), 0);
        assertEq(weth.balanceOf(address(wallet)), 0);
    }

    function testBorrowSwapAfterFullRepayRevertsWithoutDebt() public {
        AgentWallet wallet = _createBorrowWallet(owner, 1);
        uint256 debt = 1e18;
        _borrowWeth(wallet, 3_000e6, debt);
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, type(uint256).max)));
        assertEq(borrowFeeModule.tokenDebt(address(wallet), address(weth)), 0);

        uint256 amountIn = 20e6;
        uint256 bought = 1e16;
        _fundWallet(wallet, address(usdc), amountIn);
        uniswapV3Router.setBuyAmount(bought);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(usdc), address(weth));
        bytes memory data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(usdc), address(weth), route, amountIn, uint256(1)));
        bytes memory aboveDebt = abi.encodeWithSelector(SwapAboveDebt.selector, bought, uint256(0));
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data, aboveDebt);
        assertEq(usdc.balanceOf(address(wallet)), amountIn);
        assertEq(weth.balanceOf(address(wallet)), 0);
    }

    function testBorrowSwapCapIncludesAccruedInterestAfterCheckpoint() public {
        AgentWallet wallet = _createBorrowWallet(owner, 1);
        uint256 principal = 1e18;
        uint256 interest = 0.1e18;
        _borrowWeth(wallet, 3_000e6, principal);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(weth));

        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 30 days);
        uint256 timestamp = vm.getBlockTimestamp();
        usdcPriceFeed.setPrice(1e8, timestamp);
        wethPriceFeed.setPrice(2000e8, timestamp);
        aaveV3LendingPool.growDebt(address(weth), address(wallet), interest);
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));
        uint256 debt = principal + interest;
        assertEq(borrowFeeModule.tokenDebt(address(wallet), address(weth)), debt);

        uint256 feesOwed = borrowFeeModule.feesOwed(address(wallet));
        assertGt(feesOwed, 0);
        _fundWallet(wallet, address(usdc), feesOwed);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 0);

        uint256 amountIn = 2_200e6;
        _fundWallet(wallet, address(usdc), amountIn);
        uniswapV3Router.setBuyAmount(debt);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(usdc), address(weth));
        bytes memory data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(usdc), address(weth), route, amountIn, uint256(1)));
        _execute(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data);
        assertEq(weth.balanceOf(address(wallet)), debt);

        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, type(uint256).max)));
        assertEq(aaveV3VariableDebtToken.balanceOf(address(wallet)), 0);
        assertEq(borrowFeeModule.tokenDebt(address(wallet), address(weth)), 0);
    }

    function testUpdatedBorrowPolicyTakesEffectOnlyAfterWalletSync() public {
        AgentWallet wallet = _createBorrowWallet(owner, 1);
        uint256 amountIn = 100e6;
        uint256 quote = priceOracle.quote(address(usdc), address(weth), amountIn);
        uint256 oldMinimum = quote * (10_000 - BORROW_SWAP_MAX_SLIPPAGE_BPS) / 10_000;
        uint256 debt = 2 * oldMinimum;
        _borrowWeth(wallet, 1_000e6, debt);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(weth));
        _fundWallet(wallet, address(usdc), 3 * amountIn);
        uniswapV3Router.setBuyAmount(oldMinimum);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(usdc), address(weth));
        bytes memory data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(usdc), address(weth), route, amountIn, uint256(1)));

        bytes memory result = _execute(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data);
        assertEq(_decodeUint(result), oldMinimum);

        YieldSeekerBorrowSwapPolicy strictPolicy = new YieldSeekerBorrowSwapPolicy(swapSellPolicy, IYieldSeekerPriceOracle(address(priceOracle)), 0);
        factory.setSwapPolicy(BORROW_AGENT_PROFILE, strictPolicy);
        result = _execute(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data);
        assertEq(_decodeUint(result), oldMinimum);
        bytes memory strictFloorError = abi.encodeWithSelector(SwapBelowOraclePrice.selector, oldMinimum, quote);

        vm.prank(owner);
        wallet.syncFromFactory();
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data, strictFloorError);
        assertEq(usdc.balanceOf(address(wallet)), amountIn);
        assertEq(weth.balanceOf(address(wallet)), debt);
        assertEq(borrowFeeModule.tokenDebt(address(wallet), address(weth)), debt);

        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, type(uint256).max)));
        assertEq(borrowFeeModule.tokenDebt(address(wallet), address(weth)), 0);
    }

    function testWalletWithoutSwapPolicyCannotSwap() public {
        factory.setAdapterRegistry(NO_SWAP_POLICY_PROFILE, vaultRegistry);
        factory.setFeeTracker(NO_SWAP_POLICY_PROFILE, vaultFeeTracker);
        FeePlanChoice[] memory noFeePlans = new FeePlanChoice[](0);
        vm.prank(operator);
        AgentWallet wallet = AgentWallet(payable(address(factory.createAgentWallet(owner, 1, address(usdc), NO_SWAP_POLICY_PROFILE, noFeePlans))));
        _fundWallet(wallet, address(rewardToken), 10e18);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(rewardToken), address(usdc));
        bytes memory data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        bytes memory noPolicy = abi.encodeWithSelector(NoSwapPolicy.selector);
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data, noPolicy);
        assertEq(rewardToken.balanceOf(address(wallet)), 10e18);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    function testWalletRejectsAdapterTargetNotMappedToAdapter() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(rewardToken), address(usdc));
        bytes memory data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), route, uint256(1e18), uint256(1)));
        bytes memory expectedError = abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(uniswapV3SwapAdapter));
        vm.expectRevert(expectedError);
        vm.prank(operator);
        wallet.executeViaAdapter(address(uniswapV3SwapAdapter), address(aerodromeV2Router), data);
    }

    function testBaseSaleRevertsWhileBorrowFeesRemainOwedAndSucceedsWhenItsReportPaysThem() public {
        AgentWallet wallet = _createBorrowWallet(owner, 1);
        uint256 borrowedAmount = 1e18;
        _borrowWeth(wallet, 3_000e6, borrowedAmount);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(weth));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        uint256 timestamp = vm.getBlockTimestamp();
        usdcPriceFeed.setPrice(1e8, timestamp);
        wethPriceFeed.setPrice(2000e8, timestamp);
        bytes memory checkpoint = abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market));
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), checkpoint);
        uint256 owed = borrowFeeModule.feesOwed(address(wallet));
        assertGt(owed, 0);
        uint256 collectorBefore = usdc.balanceOf(feeCollector);

        uint256 amountIn = 100e6;
        _fundWallet(wallet, address(usdc), amountIn);
        uint256 output = priceOracle.quote(address(usdc), address(weth), amountIn);
        uniswapV3Router.setBuyAmount(output);
        AWKUniswapV3SwapAdapter.SwapRoute memory route = _uniswapRoute(address(usdc), address(weth));
        bytes memory data = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(usdc), address(weth), route, amountIn, uint256(1)));
        bytes memory unpaidFees = abi.encodeWithSelector(FeesOwed.selector, owed);
        _executeExpectRevert(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data, unpaidFees);
        assertEq(usdc.balanceOf(address(wallet)), amountIn);
        assertEq(weth.balanceOf(address(wallet)), 0);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), owed);

        _fundWallet(wallet, address(usdc), owed);
        _execute(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), data);

        assertEq(weth.balanceOf(address(wallet)), output);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, owed);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 0);
    }

    function testBatchSwapsAcrossAllThreeDexesSettleEachRewardFee() public {
        AgentWallet wallet = _createVaultWallet(owner, 1);
        _fundWallet(wallet, address(rewardToken), 300e18);
        uniswapV3Router.setBuyAmount(120e6);
        aerodromeV2Router.setBuyAmount(130e6);
        aerodromeCLRouter.setBuyAmount(140e6);
        AWKUniswapV3SwapAdapter.SwapRoute memory uniRoute = _uniswapRoute(address(rewardToken), address(usdc));
        AWKAerodromeV2SwapAdapter.SwapRoute memory v2Route = _aerodromeV2Route(address(rewardToken), address(usdc));
        AWKAerodromeCLSwapAdapter.SwapRoute memory clRoute = _aerodromeCLRoute(address(rewardToken), address(usdc));
        address[] memory adapters = new address[](3);
        address[] memory targets = new address[](3);
        bytes[] memory datas = new bytes[](3);
        adapters[0] = address(uniswapV3SwapAdapter);
        adapters[1] = address(aerodromeV2SwapAdapter);
        adapters[2] = address(aerodromeCLSwapAdapter);
        targets[0] = address(uniswapV3Router);
        targets[1] = address(aerodromeV2Router);
        targets[2] = address(aerodromeCLRouter);
        datas[0] = abi.encodeCall(uniswapV3SwapAdapter.swap, (address(rewardToken), address(usdc), uniRoute, uint256(100e18), uint256(100e6)));
        datas[1] = abi.encodeCall(aerodromeV2SwapAdapter.swap, (address(rewardToken), address(usdc), v2Route, uint256(100e18), uint256(100e6)));
        datas[2] = abi.encodeCall(aerodromeCLSwapAdapter.swap, (address(rewardToken), address(usdc), clRoute, uint256(100e18), uint256(100e6)));
        uint256 feesBefore = _feesCollected(address(usdc));
        bytes[] memory results = _executeBatch(wallet, adapters, targets, datas);
        assertEq(_decodeUint(results[0]), 120e6);
        assertEq(_decodeUint(results[1]), 130e6);
        assertEq(_decodeUint(results[2]), 140e6);
        assertEq(rewardToken.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 351e6);
        assertEq(_feesCollected(address(usdc)) - feesBefore, 39e6);
    }

    function _borrowWeth(AgentWallet wallet, uint256 collateralAmount, uint256 borrowedAmount) private {
        _fundWallet(wallet, address(usdc), collateralAmount);
        bytes memory supply = abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, collateralAmount));
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), supply);
        bytes memory borrow = abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, borrowedAmount));
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), borrow);
    }

    function _oracleFloor(uint256 amountIn) private view returns (uint256) {
        return priceOracle.quote(address(usdc), address(weth), amountIn) * (10_000 - BORROW_SWAP_MAX_SLIPPAGE_BPS) / 10_000;
    }

    function _executeBatch(AgentWallet wallet, address[] memory adapters, address[] memory targets, bytes[] memory datas) private returns (bytes[] memory results) {
        vm.prank(operator);
        results = wallet.executeViaAdapterBatch(adapters, targets, datas);
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
        route.stables[0] = false;
    }

    function _aerodromeCLRoute(address from, address to) private pure returns (AWKAerodromeCLSwapAdapter.SwapRoute memory route) {
        route.path = new address[](2);
        route.path[0] = from;
        route.path[1] = to;
        route.tickSpacings = new int24[](1);
        route.tickSpacings[0] = 100;
    }
}
