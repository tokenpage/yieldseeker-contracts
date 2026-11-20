// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AWKAdapterRegistry} from "../../src/agentwalletkit/AWKAdapterRegistry.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {AWKAaveV3BorrowAdapter} from "../../src/agentwalletkit/adapters/AWKAaveV3BorrowAdapter.sol";
import {AWKAaveV4BorrowAdapter, IAaveV4Spoke} from "../../src/agentwalletkit/adapters/AWKAaveV4BorrowAdapter.sol";
import {AWKAerodromeCLSwapAdapter, AWKAerodromeCLSwapAdapterCore} from "../../src/agentwalletkit/adapters/AWKAerodromeCLSwapAdapter.sol";
import {AWKAerodromeV2SwapAdapter, AWKAerodromeV2SwapAdapterCore, IAerodromeV2Router} from "../../src/agentwalletkit/adapters/AWKAerodromeV2SwapAdapter.sol";
import {AWKMerklAdapter} from "../../src/agentwalletkit/adapters/AWKMerklAdapter.sol";
import {AWKMorphoBlueBorrowAdapter, IMorphoBlue, MarketParams} from "../../src/agentwalletkit/adapters/AWKMorphoBlueBorrowAdapter.sol";
import {AWKUniswapV3SwapAdapter, AWKUniswapV3SwapAdapterCore} from "../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {MockV3SelfManagedWallet} from "../mocks/MockV3TestHelpers.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice The kit's own wallet and standalone adapters, with no YieldSeeker rules on top
contract KitAdaptersTest is IntegrationBase {
    uint256 private constant COLLATERAL = 1_000e6;
    uint256 private constant BORROWED_WETH = 1e18;

    AWKAdapterRegistry private kitRegistry;
    MockV3SelfManagedWallet private kitWallet;

    function setUp() public override {
        super.setUp();
        kitRegistry = new AWKAdapterRegistry(admin, admin);
        MockV3SelfManagedWallet implementation = new MockV3SelfManagedWallet();
        kitWallet = MockV3SelfManagedWallet(payable(address(new ERC1967Proxy(address(implementation), abi.encodeWithSignature("initialize(address,uint256,bytes32)", owner, 0, bytes32(0))))));
        address[] memory operators = new address[](1);
        operators[0] = operator;
        vm.startPrank(owner);
        kitWallet.setAdapterRegistry(kitRegistry);
        kitWallet.setAgentOperators(operators);
        vm.stopPrank();
    }

    function testAaveV3BorrowAdapterEntersTheMarketsEModeOnceAndResetsApprovals() public {
        AWKAaveV3BorrowAdapter adapter = new AWKAaveV3BorrowAdapter();
        bytes memory market = abi.encode(address(aaveV3LendingPool), address(usdc), address(weth), uint8(1));
        address target = adapter.marketTarget(market);
        _register(target, address(adapter));
        _fund(address(usdc), address(kitWallet), 2 * COLLATERAL);

        vm.expectCall(address(usdc), abi.encodeCall(IERC20.approve, (address(aaveV3LendingPool), 0)));
        bytes memory supplied = _kitExecute(address(adapter), target, abi.encodeCall(adapter.supplyCollateral, (market, COLLATERAL)));
        assertEq(abi.decode(supplied, (uint256)), COLLATERAL);
        assertEq(aaveV3LendingPool.getUserEMode(address(kitWallet)), 1);
        assertEq(aaveV3CollateralAToken.balanceOf(address(kitWallet)), COLLATERAL);

        vm.expectCall(address(aaveV3LendingPool), abi.encodeWithSelector(aaveV3LendingPool.setUserEMode.selector), 0);
        _kitExecute(address(adapter), target, abi.encodeCall(adapter.supplyCollateral, (market, COLLATERAL)));

        bytes memory borrowed = _kitExecute(address(adapter), target, abi.encodeCall(adapter.borrow, (market, BORROWED_WETH)));
        assertEq(abi.decode(borrowed, (uint256)), BORROWED_WETH);
        assertEq(abi.decode(_kitExecute(address(adapter), target, abi.encodeCall(adapter.checkpoint, (market))), (uint256)), BORROWED_WETH);

        _fund(address(weth), address(kitWallet), BORROWED_WETH);
        vm.expectCall(address(weth), abi.encodeCall(IERC20.approve, (address(aaveV3LendingPool), 0)));
        bytes memory repaid = _kitExecute(address(adapter), target, abi.encodeCall(adapter.repay, (market, type(uint256).max)));
        assertEq(abi.decode(repaid, (uint256)), BORROWED_WETH);
        assertEq(aaveV3VariableDebtToken.balanceOf(address(kitWallet)), 0);
        assertEq(weth.balanceOf(address(kitWallet)), BORROWED_WETH);

        bytes memory withdrawn = _kitExecute(address(adapter), target, abi.encodeCall(adapter.withdrawCollateral, (market, type(uint256).max)));
        assertEq(abi.decode(withdrawn, (uint256)), 2 * COLLATERAL);
        assertEq(usdc.balanceOf(address(kitWallet)), 2 * COLLATERAL);
    }

    function testAaveV4BorrowAdapterRepaysNoMoreThanTheDebtAndResetsApprovals() public {
        AWKAaveV4BorrowAdapter adapter = new AWKAaveV4BorrowAdapter();
        address target = adapter.marketTarget(aaveV4Market);
        _register(target, address(adapter));
        _fund(address(usdc), address(kitWallet), COLLATERAL);

        _kitExecute(address(adapter), target, abi.encodeCall(adapter.supplyCollateral, (aaveV4Market, COLLATERAL)));
        _kitExecute(address(adapter), target, abi.encodeCall(adapter.borrow, (aaveV4Market, BORROWED_WETH)));
        assertEq(aaveV4Spoke.getUserSuppliedAssets(1, address(kitWallet)), COLLATERAL);
        assertEq(aaveV4Spoke.getUserTotalDebt(2, address(kitWallet)), BORROWED_WETH);

        uint256 partialRepayment = BORROWED_WETH / 4;
        vm.expectCall(address(aaveV4Spoke), abi.encodeCall(IAaveV4Spoke(address(aaveV4Spoke)).repay, (2, partialRepayment, address(kitWallet))));
        _kitExecute(address(adapter), target, abi.encodeCall(adapter.repay, (aaveV4Market, partialRepayment)));
        uint256 remainingDebt = BORROWED_WETH - partialRepayment;
        assertEq(aaveV4Spoke.getUserTotalDebt(2, address(kitWallet)), remainingDebt);

        _fund(address(weth), address(kitWallet), BORROWED_WETH);
        vm.expectCall(address(aaveV4Spoke), abi.encodeCall(IAaveV4Spoke(address(aaveV4Spoke)).repay, (2, remainingDebt, address(kitWallet))));
        vm.expectCall(address(weth), abi.encodeCall(IERC20.approve, (address(aaveV4Spoke), 0)));
        bytes memory repaid = _kitExecute(address(adapter), target, abi.encodeCall(adapter.repay, (aaveV4Market, remainingDebt + 5)));
        assertEq(abi.decode(repaid, (uint256)), remainingDebt);
        assertEq(aaveV4Spoke.getUserTotalDebt(2, address(kitWallet)), 0);

        bytes memory withdrawn = _kitExecute(address(adapter), target, abi.encodeCall(adapter.withdrawCollateral, (aaveV4Market, type(uint256).max)));
        assertEq(abi.decode(withdrawn, (uint256)), COLLATERAL);
        assertEq(usdc.balanceOf(address(kitWallet)), COLLATERAL);
    }

    function testMorphoBorrowAdapterAccruesInterestRepaysByAssetsOrSharesAndResetsApprovals() public {
        AWKMorphoBlueBorrowAdapter adapter = new AWKMorphoBlueBorrowAdapter();
        (, MarketParams memory params) = abi.decode(morphoMarket, (address, MarketParams));
        bytes32 marketId = keccak256(abi.encode(params));
        address target = adapter.marketTarget(morphoMarket);
        _register(target, address(adapter));
        _fund(address(usdc), address(kitWallet), COLLATERAL);

        vm.expectCall(address(usdc), abi.encodeCall(IERC20.approve, (address(morpho), 0)));
        _kitExecute(address(adapter), target, abi.encodeCall(adapter.supplyCollateral, (morphoMarket, COLLATERAL)));
        _kitExecute(address(adapter), target, abi.encodeCall(adapter.borrow, (morphoMarket, BORROWED_WETH)));

        vm.expectCall(address(morpho), abi.encodeCall(IMorphoBlue(address(morpho)).accrueInterest, (params)));
        assertEq(abi.decode(_kitExecute(address(adapter), target, abi.encodeCall(adapter.checkpoint, (morphoMarket))), (uint256)), BORROWED_WETH);

        uint256 partialRepayment = BORROWED_WETH / 4;
        vm.expectCall(address(morpho), abi.encodeCall(IMorphoBlue(address(morpho)).repay, (params, partialRepayment, 0, address(kitWallet), "")));
        bytes memory repaid = _kitExecute(address(adapter), target, abi.encodeCall(adapter.repay, (morphoMarket, partialRepayment)));
        assertEq(abi.decode(repaid, (uint256)), partialRepayment);
        (, uint128 borrowShares,) = morpho.position(marketId, address(kitWallet));
        assertGt(borrowShares, 0);

        _fund(address(weth), address(kitWallet), BORROWED_WETH);
        vm.expectCall(address(morpho), abi.encodeCall(IMorphoBlue(address(morpho)).repay, (params, 0, borrowShares, address(kitWallet), "")));
        vm.expectCall(address(weth), abi.encodeCall(IERC20.approve, (address(morpho), 0)));
        repaid = _kitExecute(address(adapter), target, abi.encodeCall(adapter.repay, (morphoMarket, type(uint256).max)));
        assertEq(abi.decode(repaid, (uint256)), BORROWED_WETH - partialRepayment);
        (, borrowShares,) = morpho.position(marketId, address(kitWallet));
        assertEq(borrowShares, 0);

        bytes memory withdrawn = _kitExecute(address(adapter), target, abi.encodeCall(adapter.withdrawCollateral, (morphoMarket, type(uint256).max)));
        assertEq(abi.decode(withdrawn, (uint256)), COLLATERAL);
        assertEq(usdc.balanceOf(address(kitWallet)), COLLATERAL);
    }

    function testUniswapSwapAdapterAcceptsARouteWithTheMaximumNumberOfHops() public {
        AWKUniswapV3SwapAdapter adapter = new AWKUniswapV3SwapAdapter(address(uniswapV3Router));
        _register(address(uniswapV3Router), address(adapter));
        _fund(address(rewardToken), address(kitWallet), 10e18);
        AWKUniswapV3SwapAdapterCore.SwapRoute memory route = AWKUniswapV3SwapAdapterCore.SwapRoute({path: new address[](5), fees: new uint24[](4)});
        route.path[0] = address(rewardToken);
        route.path[1] = address(weth);
        route.path[2] = address(wellToken);
        route.path[3] = address(weth);
        route.path[4] = address(usdc);
        route.fees[0] = 100;
        route.fees[1] = 500;
        route.fees[2] = 3000;
        route.fees[3] = 10000;

        bytes memory bought = _kitExecute(address(adapter), address(uniswapV3Router), abi.encodeCall(adapter.swap, (address(rewardToken), address(usdc), route, 10e18, 9e6, block.timestamp)));

        assertEq(abi.decode(bought, (uint256)), 9e6);
        assertEq(usdc.balanceOf(address(kitWallet)), 9e6);
        assertEq(rewardToken.balanceOf(address(kitWallet)), 0);
        assertEq(rewardToken.allowance(address(kitWallet), address(uniswapV3Router)), 0);
    }

    function testAerodromeSwapAdaptersSendTheirFactoryAndRouteToTheRouter() public {
        address aerodromeFactory = makeAddr("aerodromeFactory");
        AWKAerodromeV2SwapAdapter v2Adapter = new AWKAerodromeV2SwapAdapter(address(aerodromeV2Router), aerodromeFactory);
        AWKAerodromeCLSwapAdapter clAdapter = new AWKAerodromeCLSwapAdapter(address(aerodromeCLRouter));
        _register(address(aerodromeV2Router), address(v2Adapter));
        _register(address(aerodromeCLRouter), address(clAdapter));
        _fund(address(rewardToken), address(kitWallet), 20e18);

        AWKAerodromeV2SwapAdapterCore.SwapRoute memory v2Route = AWKAerodromeV2SwapAdapterCore.SwapRoute({path: new address[](2), stables: new bool[](1)});
        v2Route.path[0] = address(rewardToken);
        v2Route.path[1] = address(usdc);
        v2Route.stables[0] = true;
        IAerodromeV2Router.Route[] memory routerRoutes = new IAerodromeV2Router.Route[](1);
        routerRoutes[0] = IAerodromeV2Router.Route({from: address(rewardToken), to: address(usdc), stable: true, factory: aerodromeFactory});
        vm.expectCall(address(aerodromeV2Router), abi.encodeCall(IAerodromeV2Router(address(aerodromeV2Router)).swapExactTokensForTokens, (10e18, 9e6, routerRoutes, address(kitWallet), block.timestamp)));
        bytes memory bought = _kitExecute(address(v2Adapter), address(aerodromeV2Router), abi.encodeCall(v2Adapter.swap, (address(rewardToken), address(usdc), v2Route, 10e18, 9e6, block.timestamp)));
        assertEq(abi.decode(bought, (uint256)), 9e6);

        AWKAerodromeCLSwapAdapterCore.SwapRoute memory clRoute = AWKAerodromeCLSwapAdapterCore.SwapRoute({path: new address[](2), tickSpacings: new int24[](1)});
        clRoute.path[0] = address(rewardToken);
        clRoute.path[1] = address(usdc);
        clRoute.tickSpacings[0] = 100;
        bought = _kitExecute(address(clAdapter), address(aerodromeCLRouter), abi.encodeCall(clAdapter.swap, (address(rewardToken), address(usdc), clRoute, 10e18, 8e6, block.timestamp)));
        assertEq(abi.decode(bought, (uint256)), 8e6);
        assertEq(usdc.balanceOf(address(kitWallet)), 17e6);
        assertEq(rewardToken.balanceOf(address(kitWallet)), 0);
    }

    function testSwapAdaptersCannotBeDeployedWithAZeroRouterOrFactory() public {
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        new AWKUniswapV3SwapAdapter(address(0));
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        new AWKAerodromeCLSwapAdapter(address(0));
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        new AWKAerodromeV2SwapAdapter(address(0), address(1));
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        new AWKAerodromeV2SwapAdapter(address(1), address(0));
    }

    function testMerklAdapterClaimsForTheWallet() public {
        AWKMerklAdapter adapter = new AWKMerklAdapter();
        _register(address(merklDistributor), address(adapter));
        address[] memory tokens = new address[](2);
        tokens[0] = address(usdc);
        tokens[1] = address(rewardToken);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 50e6;
        amounts[1] = 7e18;
        bytes32[][] memory proofs = new bytes32[][](2);

        _kitExecute(address(adapter), address(merklDistributor), abi.encodeCall(adapter.claim, (tokens, amounts, proofs)));

        assertEq(usdc.balanceOf(address(kitWallet)), 50e6);
        assertEq(rewardToken.balanceOf(address(kitWallet)), 7e18);
    }

    function testOnlyTheOwnerWithdrawsTokensAndEthFromASelfManagedWallet() public {
        address recipient = makeAddr("recipient");
        _fund(address(usdc), address(kitWallet), 100e6);
        _fund(address(weth), address(kitWallet), 3e18);
        vm.deal(address(kitWallet), 2 ether);
        address[] memory assets = new address[](2);
        assets[0] = address(usdc);
        assets[1] = address(weth);
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 10e6;
        amounts[1] = 1e18;

        bytes memory unauthorized = abi.encodeWithSelector(AWKErrors.Unauthorized.selector, operator);
        vm.startPrank(operator);
        vm.expectRevert(unauthorized);
        kitWallet.withdrawAssetToUser(recipient, address(usdc), 1);
        vm.expectRevert(unauthorized);
        kitWallet.withdrawAllAssetToUser(recipient, address(usdc));
        vm.expectRevert(unauthorized);
        kitWallet.withdrawAssetsToUser(recipient, assets, amounts);
        vm.expectRevert(unauthorized);
        kitWallet.withdrawAllAssetsToUser(recipient, assets);
        vm.expectRevert(unauthorized);
        kitWallet.withdrawEthToUser(recipient, 1);
        vm.expectRevert(unauthorized);
        kitWallet.withdrawAllEthToUser(recipient);
        vm.stopPrank();

        vm.startPrank(owner);
        kitWallet.withdrawAssetToUser(recipient, address(usdc), 40e6);
        assertEq(usdc.balanceOf(recipient), 40e6);
        kitWallet.withdrawAssetsToUser(recipient, assets, amounts);
        assertEq(usdc.balanceOf(recipient), 50e6);
        assertEq(weth.balanceOf(recipient), 1e18);
        kitWallet.withdrawAllAssetToUser(recipient, address(usdc));
        assertEq(usdc.balanceOf(recipient), 100e6);
        assertEq(usdc.balanceOf(address(kitWallet)), 0);
        kitWallet.withdrawAllAssetsToUser(recipient, assets);
        assertEq(weth.balanceOf(recipient), 3e18);
        assertEq(weth.balanceOf(address(kitWallet)), 0);
        kitWallet.withdrawEthToUser(recipient, 0.5 ether);
        assertEq(recipient.balance, 0.5 ether);
        kitWallet.withdrawAllEthToUser(recipient);
        assertEq(recipient.balance, 2 ether);
        assertEq(address(kitWallet).balance, 0);
        vm.stopPrank();
    }

    function _register(address target, address adapter) private {
        kitRegistry.registerAdapter(adapter);
        kitRegistry.setTargetAdapter(target, adapter);
    }

    function _kitExecute(address adapter, address target, bytes memory data) private returns (bytes memory result) {
        vm.record();
        vm.prank(operator);
        result = kitWallet.executeViaAdapter(adapter, target, data);
        (, bytes32[] memory walletStorageWrites) = vm.accesses(address(kitWallet));
        assertEq(walletStorageWrites.length, 0, "an adapter call wrote to the wallet's own storage");
    }
}
