// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {IPriceFeed, YieldSeekerPriceOracle} from "../../src/PriceOracle.sol";
import {YieldSeekerWalletLinkRegistry} from "../../src/WalletLinkRegistry.sol";
import {YieldSeekerAaveV3LendingAdapter} from "../../src/adapters/AaveV3LendingAdapter.sol";
import {YieldSeekerAgentTransferAdapter} from "../../src/adapters/AgentTransferAdapter.sol";
import {YieldSeekerMorphoBlueLendingAdapter} from "../../src/adapters/MorphoBlueLendingAdapter.sol";
import {YieldSeekerSwapSellPolicy} from "../../src/adapters/SwapSellPolicy.sol";
import {YieldSeekerUniswapV3SwapAdapter} from "../../src/adapters/UniswapV3SwapAdapter.sol";
import {IAaveV3LendingPool, IAaveV3Oracle} from "../../src/agentwalletkit/adapters/AWKAaveV3LendingAdapter.sol";
import {IMorphoBlue, IMorphoOracle} from "../../src/agentwalletkit/adapters/AWKMorphoBlueLendingAdapter.sol";
import {AWKUniswapV3SwapAdapter} from "../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeePlanChoice, YieldSeekerFeeTracker as FeeTracker} from "../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {YieldSeekerBorrowSwapPolicy} from "../../src/swaps/BorrowSwapPolicy.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract BorrowForkTest is ForkBase {
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant AAVE_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant MORPHO = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant UNISWAP_V3_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;
    address internal constant ETH_USD_FEED = 0x71041dddad3595F9CEd3DcCFBe3D1F4b0a16Bb70;
    address internal constant USDC_USD_FEED = 0x7e860098F58bBFC8648a4311b374B1D669a2bc6B;
    address internal constant SEQUENCER_UPTIME_FEED = 0xBCF85224fc0756B9Fa45aA7892530B47e10b6433;
    bytes32 internal constant MORPHO_WETH_USDC_MARKET_ID = 0x8793cf302b8ffd655ab97bd1c695dbd967807e8367a65cb2f4edaf1380ba1bda;
    bytes32 internal constant BORROW_AGENT_PROFILE = keccak256("borrow");

    AdapterRegistry internal borrowRegistry;
    FeeTracker internal feeTracker;
    YieldSeekerBorrowFeeModule internal borrowFeeModule;
    YieldSeekerPriceOracle internal oracle;
    YieldSeekerWalletLinkRegistry internal linkRegistry;
    YieldSeekerAaveV3LendingAdapter internal aaveAdapter;
    YieldSeekerMorphoBlueLendingAdapter internal morphoAdapter;
    YieldSeekerUniswapV3SwapAdapter internal swapAdapter;
    YieldSeekerAgentTransferAdapter internal transferAdapter;
    AgentWallet internal wallet;

    function setUp() public override {
        super.setUp();
        oracle = new YieldSeekerPriceOracle(address(this), address(this), IPriceFeed(SEQUENCER_UPTIME_FEED));
        oracle.setSource(WETH, IPriceFeed(ETH_USD_FEED), 1 hours);
        oracle.setSource(USDC, IPriceFeed(USDC_USD_FEED), 25 hours);
        feeTracker = new FeeTracker(address(this), feeCollector);
        YieldSeekerYieldFeeModule borrowYieldFees = new YieldSeekerYieldFeeModule(feeTracker, 5000);
        feeTracker.setFeeModule(YIELD_FEE, borrowYieldFees);
        feeTracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 1000})));
        borrowFeeModule = new YieldSeekerBorrowFeeModule(feeTracker, 200);
        feeTracker.setFeeModule(BORROW_FEE, borrowFeeModule);
        feeTracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 50})));
        feeTracker.setWalletFactory(address(factory));
        borrowRegistry = new AdapterRegistry(address(this), address(this));
        factory.setAdapterRegistry(BORROW_AGENT_PROFILE, borrowRegistry);
        factory.setFeeTracker(BORROW_AGENT_PROFILE, feeTracker);
        aaveAdapter = new YieldSeekerAaveV3LendingAdapter();
        morphoAdapter = new YieldSeekerMorphoBlueLendingAdapter();
        YieldSeekerSwapSellPolicy rewardSellPolicy = new YieldSeekerSwapSellPolicy(address(this), address(this), false);
        factory.setSwapPolicy(BORROW_AGENT_PROFILE, new YieldSeekerBorrowSwapPolicy(rewardSellPolicy, oracle, 100));
        swapAdapter = new YieldSeekerUniswapV3SwapAdapter(UNISWAP_V3_ROUTER);
        linkRegistry = new YieldSeekerWalletLinkRegistry();
        transferAdapter = new YieldSeekerAgentTransferAdapter(linkRegistry);
        _register(borrowRegistry, address(aaveAdapter), aaveAdapter.marketTarget(_aaveMarket()));
        _register(borrowRegistry, address(morphoAdapter), morphoAdapter.marketTarget(_morphoMarket()));
        _register(borrowRegistry, address(swapAdapter), UNISWAP_V3_ROUTER);
        _register(borrowRegistry, address(transferAdapter), address(linkRegistry));
        _register(vaultRegistry, address(transferAdapter), address(linkRegistry));
        vm.prank(operator);
        wallet = factory.createAgentWallet(owner, 0, WETH, BORROW_AGENT_PROFILE, new FeePlanChoice[](0));
        deal(WETH, address(wallet), 1 ether);
    }

    function _register(AdapterRegistry registry, address adapter, address target) internal {
        if (!registry.isRegisteredAdapter(adapter)) registry.registerAdapter(adapter);
        registry.setTargetAdapter(target, adapter);
    }

    function _execute(address adapter, address target, bytes memory data) internal returns (bytes memory) {
        vm.prank(operator);
        return abi.decode(wallet.executeViaAdapter(adapter, target, data), (bytes));
    }

    function _aaveMarket() internal pure returns (bytes memory) {
        return abi.encode(AAVE_POOL, WETH, USDC, uint8(0));
    }

    function _morphoParams() internal pure returns (IMorphoBlue.MarketParams memory) {
        return IMorphoBlue.MarketParams({loanToken: USDC, collateralToken: WETH, oracle: 0xFEa2D58cEfCb9fcb597723c6bAE66fFE4193aFE4, irm: 0x46415998764C29aB2a25CbeA6254146D50D22687, lltv: 860000000000000000});
    }

    function _morphoMarket() internal pure returns (bytes memory) {
        return abi.encode(MORPHO, _morphoParams());
    }

    function _marketDebtPriceInBaseAsset(address adapter, bytes memory market) internal view returns (uint256) {
        if (adapter == address(aaveAdapter)) {
            (IAaveV3LendingPool pool, address collateralToken, address debtToken,) = abi.decode(market, (IAaveV3LendingPool, address, address, uint8));
            IAaveV3Oracle marketOracle = pool.ADDRESSES_PROVIDER().getPriceOracle();
            uint256 debtValue = marketOracle.getAssetPrice(debtToken) * 10 ** IERC20Metadata(collateralToken).decimals();
            uint256 collateralValue = marketOracle.getAssetPrice(collateralToken) * 10 ** IERC20Metadata(debtToken).decimals();
            return Math.mulDiv(debtValue, 1e36, collateralValue);
        }

        (, IMorphoBlue.MarketParams memory params) = abi.decode(market, (IMorphoBlue, IMorphoBlue.MarketParams));
        return Math.mulDiv(1e36, 1e36, IMorphoOracle(params.oracle).price());
    }

    function _runBorrowCycle(address adapter, bytes memory market) internal {
        address target = aaveAdapter.marketTarget(market);
        _execute(adapter, target, abi.encodeWithSelector(aaveAdapter.supplyCollateral.selector, market, 1 ether));
        assertEq(IERC20(WETH).balanceOf(address(wallet)), 0, "collateral supplied");
        _execute(adapter, target, abi.encodeWithSelector(aaveAdapter.borrow.selector, market, 1_000e6));
        assertEq(IERC20(USDC).balanceOf(address(wallet)), 1_000e6, "borrowed cash in wallet");

        vm.warp(vm.getBlockTimestamp() + 365 days);
        vm.roll(block.number + 1);
        deal(USDC, address(wallet), 100_000e6);

        uint256 expectedDebtFee = Math.mulDiv(1_000e6, 50, 10_000, Math.Rounding.Ceil);
        uint256 debtPriceInBaseAsset = _marketDebtPriceInBaseAsset(adapter, market);
        uint256 expectedBaseAssetFee = Math.mulDiv(expectedDebtFee, debtPriceInBaseAsset, 1e36, Math.Rounding.Ceil);
        oracle.removeSource(WETH);
        oracle.removeSource(USDC);

        _execute(adapter, target, abi.encodeWithSelector(aaveAdapter.repay.selector, market, type(uint256).max));
        assertEq(IERC20(USDC).balanceOf(feeCollector), 0, "Borrow fee is not paid in debt token at repay");
        (uint256 principal,,,) = borrowFeeModule.debtPositions(address(wallet), keccak256(market));
        assertEq(principal, 0, "principal cleared");
        assertEq(borrowFeeModule.feesOwed(address(wallet)), expectedBaseAssetFee, "Borrow fee is owed in the collateral asset");

        uint256 feeCollectorWethBefore = IERC20(WETH).balanceOf(feeCollector);
        uint256 withdrawn = abi.decode(_execute(adapter, target, abi.encodeWithSelector(aaveAdapter.withdrawCollateral.selector, market, type(uint256).max)), (uint256));
        uint256 expectedYieldFee;
        if (adapter == address(aaveAdapter) && withdrawn > 1 ether) {
            expectedYieldFee = Math.mulDiv(withdrawn - 1 ether, 1_000, 10_000, Math.Rounding.Ceil);
        }
        uint256 expectedTotalFee = expectedBaseAssetFee + expectedYieldFee;
        uint256 collateralLeft = IERC20(WETH).balanceOf(address(wallet));
        assertEq(collateralLeft, withdrawn - expectedTotalFee, "Collateral pays the yield and market-priced borrow fees");
        assertEq(IERC20(WETH).balanceOf(feeCollector) - feeCollectorWethBefore, expectedTotalFee, "Fee collector receives both collateral and borrow fees");
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 0, "Collateral withdrawal pays the borrow fee");

        uint256 usdcLeft = IERC20(USDC).balanceOf(address(wallet));
        vm.startPrank(owner);
        wallet.withdrawAllAssetToUser(owner, WETH);
        wallet.withdrawAllAssetToUser(owner, USDC);
        vm.stopPrank();
        assertEq(IERC20(WETH).balanceOf(owner), collateralLeft, "Owner exits with net collateral");
        assertEq(IERC20(USDC).balanceOf(owner), usdcLeft, "owner exits with leftover cash");
    }

    function test_AaveV3_BorrowRepayWithdrawChargesBorrowFee() public {
        _runBorrowCycle(address(aaveAdapter), _aaveMarket());
    }

    function test_AaveV3CollateralInterestIsChargedWhenWithdrawn() public {
        bytes memory market = _aaveMarket();
        address target = aaveAdapter.marketTarget(market);
        uint256 requestedSupply = 1 ether;
        uint256 supplied = abi.decode(_execute(address(aaveAdapter), target, abi.encodeWithSelector(aaveAdapter.supplyCollateral.selector, market, requestedSupply)), (uint256));
        assertEq(supplied, requestedSupply);

        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 30 days);
        vm.roll(block.number + 1);
        uint256 collectorBalanceBefore = IERC20(WETH).balanceOf(feeCollector);
        uint256 walletBalanceBefore = IERC20(WETH).balanceOf(address(wallet));
        uint256 withdrawn = abi.decode(_execute(address(aaveAdapter), target, abi.encodeWithSelector(aaveAdapter.withdrawCollateral.selector, market, type(uint256).max)), (uint256));

        assertGt(withdrawn, supplied);
        uint256 expectedFee = Math.mulDiv(withdrawn - supplied, 1_000, 10_000, Math.Rounding.Ceil);
        assertEq(IERC20(WETH).balanceOf(address(wallet)) - walletBalanceBefore, withdrawn - expectedFee);
        assertEq(IERC20(WETH).balanceOf(feeCollector) - collectorBalanceBefore, expectedFee);
        YieldSeekerYieldFeeModule yieldFees = YieldSeekerYieldFeeModule(address(feeTracker.feeModules(YIELD_FEE)));
        assertEq(yieldFees.costBasis(address(wallet), target), 0);
    }

    function test_MorphoBlue_BorrowRepayWithdrawChargesBorrowFee() public {
        assertEq(keccak256(abi.encode(_morphoParams())), MORPHO_WETH_USDC_MARKET_ID, "market params match the live market id");
        _runBorrowCycle(address(morphoAdapter), _morphoMarket());
    }

    function _runExternalRepayRegression(address adapter, bytes memory market) internal {
        address target = aaveAdapter.marketTarget(market);
        _execute(adapter, target, abi.encodeWithSelector(aaveAdapter.supplyCollateral.selector, market, 1 ether));
        _execute(adapter, target, abi.encodeWithSelector(aaveAdapter.borrow.selector, market, 1_000e6));

        bytes32 marketHash = keccak256(market);
        (uint128 principal, uint128 lastDebt,, uint192 lastPrice) = borrowFeeModule.debtPositions(address(wallet), marketHash);
        assertGt(lastPrice, 0);
        uint256 expectedDebtFee = Math.mulDiv(Math.min(principal, lastDebt), 50 * 365 days, 365 days * 10_000, Math.Rounding.Ceil);
        uint256 expectedBorrowFee = Math.mulDiv(expectedDebtFee, lastPrice, 1e36, Math.Rounding.Ceil);
        address externalRepayer = makeAddr("external protocol repayer");
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + 365 days);
        vm.roll(block.number + 1);

        IMorphoBlue.MarketParams memory morphoParams;
        bytes32 morphoMarketId;
        if (adapter == address(aaveAdapter)) {
            _repayAaveExternally(externalRepayer);
        } else {
            (, morphoParams) = abi.decode(market, (IMorphoBlue, IMorphoBlue.MarketParams));
            morphoMarketId = keccak256(abi.encode(morphoParams));
            _repayMorphoExternally(externalRepayer, morphoParams);
            (, uint128 remainingBorrowShares,) = IMorphoBlue(MORPHO).position(morphoMarketId, address(wallet));
            assertEq(remainingBorrowShares, 0);
        }

        uint256 feeCollectorBefore = IERC20(WETH).balanceOf(feeCollector);
        uint256 walletBalanceBefore = IERC20(WETH).balanceOf(address(wallet));
        bytes memory result = _execute(adapter, target, abi.encodeWithSelector(aaveAdapter.withdrawCollateral.selector, market, type(uint256).max));
        uint256 withdrawn = abi.decode(result, (uint256));
        uint256 expectedYieldFee;
        if (adapter == address(aaveAdapter) && withdrawn > 1 ether) {
            expectedYieldFee = Math.mulDiv(withdrawn - 1 ether, 1_000, 10_000, Math.Rounding.Ceil);
        }
        uint256 expectedTotalFee = expectedBorrowFee + expectedYieldFee;
        assertEq(IERC20(WETH).balanceOf(feeCollector) - feeCollectorBefore, expectedTotalFee);
        assertEq(IERC20(WETH).balanceOf(address(wallet)) - walletBalanceBefore, withdrawn - expectedTotalFee);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 0);
    }

    function _repayAaveExternally(address externalRepayer) internal {
        IAaveV3LendingPool pool = IAaveV3LendingPool(AAVE_POOL);
        uint256 debt = IERC20(pool.getReserveVariableDebtToken(USDC)).balanceOf(address(wallet));
        deal(USDC, externalRepayer, debt);
        vm.prank(externalRepayer);
        IERC20(USDC).approve(AAVE_POOL, debt);
        vm.prank(externalRepayer);
        pool.repay(USDC, debt, 2, address(wallet));
        assertEq(IERC20(pool.getReserveVariableDebtToken(USDC)).balanceOf(address(wallet)), 0);
    }

    function _repayMorphoExternally(address externalRepayer, IMorphoBlue.MarketParams memory marketParams) internal {
        IMorphoBlue morpho = IMorphoBlue(MORPHO);
        bytes32 marketId = keccak256(abi.encode(marketParams));
        morpho.accrueInterest(marketParams);
        (, uint128 borrowShares,) = morpho.position(marketId, address(wallet));
        (,, uint128 totalBorrowAssets, uint128 totalBorrowShares,,) = morpho.market(marketId);
        uint256 debt = Math.mulDiv(borrowShares, uint256(totalBorrowAssets) + 1, uint256(totalBorrowShares) + 1e6, Math.Rounding.Ceil);
        deal(USDC, externalRepayer, debt);
        vm.prank(externalRepayer);
        IERC20(USDC).approve(MORPHO, debt);
        vm.prank(externalRepayer);
        morpho.repay(marketParams, 0, borrowShares, address(wallet), "");
    }

    function test_AaveV3_ExternalRepayUsesLastReportedPrice() public {
        _runExternalRepayRegression(address(aaveAdapter), _aaveMarket());
    }

    function test_MorphoBlue_ExternalRepayUsesLastReportedPrice() public {
        assertEq(keccak256(abi.encode(_morphoParams())), MORPHO_WETH_USDC_MARKET_ID, "market params match the live market id");
        _runExternalRepayRegression(address(morphoAdapter), _morphoMarket());
    }

    function test_PairSwap_SellsCollateralForBorrowedTokenWithinOracleBound() public {
        bytes memory market = _aaveMarket();
        address target = aaveAdapter.marketTarget(market);
        _execute(address(aaveAdapter), target, abi.encodeWithSelector(aaveAdapter.supplyCollateral.selector, market, 0.5 ether));
        _execute(address(aaveAdapter), target, abi.encodeWithSelector(aaveAdapter.borrow.selector, market, 100e6));
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = USDC;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 500;
        AWKUniswapV3SwapAdapter.SwapRoute memory route = AWKUniswapV3SwapAdapter.SwapRoute({path: path, fees: fees});
        bytes memory result = _execute(address(swapAdapter), UNISWAP_V3_ROUTER, abi.encodeWithSelector(swapAdapter.swap.selector, WETH, USDC, route, 0.1 ether, 1));
        uint256 bought = abi.decode(result, (uint256));
        assertGe(bought, (oracle.quote(WETH, USDC, 0.1 ether) * 99) / 100, "swap output within the oracle bound");
        assertEq(IERC20(USDC).balanceOf(address(wallet)), 100e6 + bought, "borrowed token received");
    }

    function test_Transfer_MovesBorrowedCashToLinkedVaultAgent() public {
        vm.prank(operator);
        AgentWallet vaultWallet = factory.createAgentWallet(owner, 1, USDC, VAULT_AGENT_PROFILE, new FeePlanChoice[](0));
        bytes memory market = _aaveMarket();
        address target = aaveAdapter.marketTarget(market);
        _execute(address(aaveAdapter), target, abi.encodeWithSelector(aaveAdapter.supplyCollateral.selector, market, 1 ether));
        _execute(address(aaveAdapter), target, abi.encodeWithSelector(aaveAdapter.borrow.selector, market, 500e6));
        vm.prank(owner);
        linkRegistry.setLinked(address(wallet), address(vaultWallet), true);
        _execute(address(transferAdapter), address(linkRegistry), abi.encodeWithSelector(transferAdapter.transfer.selector, USDC, address(vaultWallet), 500e6));
        assertEq(IERC20(USDC).balanceOf(address(vaultWallet)), 500e6, "vault agent received the borrowed cash");
        assertEq(IERC20(USDC).balanceOf(address(wallet)), 0, "borrow agent sent it all");
    }
}
