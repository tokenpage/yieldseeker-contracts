// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry} from "../../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory} from "../../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3} from "../../../src/AgentWalletV3.sol";
import {IPriceFeed, YieldSeekerPriceOracle} from "../../../src/PriceOracle.sol";
import {YieldSeekerAaveV3LendingAdapter} from "../../../src/adapters/AaveV3LendingAdapter.sol";
import {YieldSeekerAaveV4LendingAdapter} from "../../../src/adapters/AaveV4LendingAdapter.sol";
import {AssetNotAllowed} from "../../../src/adapters/Adapter.sol";
import {YieldSeekerMorphoBlueLendingAdapter} from "../../../src/adapters/MorphoBlueLendingAdapter.sol";
import {AdapterExecutionFailed} from "../../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "../../../src/agentwalletkit/AWKErrors.sol";
import {MarketTargetMismatch} from "../../../src/agentwalletkit/adapters/AWKLendingAdapter.sol";
import {IMorphoBlue} from "../../../src/agentwalletkit/adapters/AWKMorphoBlueLendingAdapter.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../../src/fees/BorrowFeeModule.sol";
import {YieldSeekerFeeTracker} from "../../../src/fees/FeeTracker.sol";
import {MockERC20, MockERC20WithDecimals} from "../../mocks/MockERC20.sol";
import {MockLendingAaveV3Pool, MockLendingAaveV4Spoke, MockLendingMorpho} from "../../mocks/MockLendingMarkets.sol";
import {MockLendingPriceFeed} from "../../mocks/MockLendingPriceFeed.sol";
import {AdapterFeeSetup} from "./AdapterHarness.t.sol";
import {Test} from "forge-std/Test.sol";

contract LendingAdaptersTest is Test {
    bytes32 private constant AGENT_PROFILE = keccak256("borrow");
    address private constant OWNER = address(0xA11CE);
    address private constant OPERATOR = address(0xB0B);
    address private constant FEE_COLLECTOR = address(0xFEE);
    uint256 private constant YEAR = 365 days;
    uint256 private constant COLLATERAL = 10e18;
    uint256 private constant BORROW_AMOUNT = 100e6;

    YieldSeekerFeeTracker private feeTracker;
    YieldSeekerAgentWalletFactory private factory;
    YieldSeekerAgentWalletV3 private wallet;
    YieldSeekerAdapterRegistry private registry;
    YieldSeekerBorrowFeeModule private feeModule;
    YieldSeekerPriceOracle private oracle;
    MockLendingPriceFeed private wethFeed;
    MockLendingPriceFeed private usdcFeed;
    MockERC20WithDecimals private weth;
    MockERC20WithDecimals private usdc;
    MockERC20WithDecimals private unsupportedAsset;
    MockLendingAaveV3Pool private aavePool;
    MockLendingMorpho private morpho;
    MockLendingAaveV4Spoke private aaveV4Spoke;
    YieldSeekerAaveV3LendingAdapter private aaveV3Adapter;
    YieldSeekerMorphoBlueLendingAdapter private morphoAdapter;
    YieldSeekerAaveV4LendingAdapter private aaveV4Adapter;
    MockERC20 private aWeth;
    MockERC20 private variableDebtUsdc;

    function setUp() public {
        vm.warp(10_000_000);
        weth = new MockERC20WithDecimals("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20WithDecimals("USD Coin", "USDC", 6);
        unsupportedAsset = new MockERC20WithDecimals("Unsupported Asset", "BAD", 6);

        uint256 now_ = vm.getBlockTimestamp();
        MockLendingPriceFeed sequencerFeed = new MockLendingPriceFeed(0, 0);
        sequencerFeed.setRoundData(0, now_ - 2 days, now_ - 2 days);
        oracle = new YieldSeekerPriceOracle(address(this), address(this), IPriceFeed(address(sequencerFeed)));
        wethFeed = new MockLendingPriceFeed(8, int256(2_000e8));
        usdcFeed = new MockLendingPriceFeed(8, int256(1e8));
        oracle.setSource(address(weth), IPriceFeed(address(wethFeed)), 1 days);
        oracle.setSource(address(usdc), IPriceFeed(address(usdcFeed)), 1 days);

        feeTracker = new YieldSeekerFeeTracker(address(this), address(this), FEE_COLLECTOR);
        AdapterFeeSetup.addVaultModule(feeTracker, 10_000, 0);
        feeModule = new YieldSeekerBorrowFeeModule(feeTracker, 10_000);
        feeTracker.addFeeModule(BORROW_FEE, feeModule);
        feeTracker.setPlanRate(0, BORROW_FEE, 50);
        factory = new YieldSeekerAgentWalletFactory(address(this), OPERATOR);
        YieldSeekerAgentWalletV3 implementation = new YieldSeekerAgentWalletV3(address(factory));
        factory.setAgentWalletImplementation(implementation);
        registry = new YieldSeekerAdapterRegistry(address(this), address(this));
        factory.setAdapterRegistry(AGENT_PROFILE, registry);
        factory.setFeeTracker(feeTracker);

        aavePool = new MockLendingAaveV3Pool();
        morpho = new MockLendingMorpho();
        aaveV4Spoke = new MockLendingAaveV4Spoke();
        aWeth = new MockERC20("Aave WETH", "aWETH");
        variableDebtUsdc = new MockERC20("Variable Debt USDC", "vdUSDC");
        aavePool.setReserve(address(weth), address(aWeth), address(0));
        aavePool.setReserve(address(usdc), address(0), address(variableDebtUsdc));
        aavePool.setFeeCollector(feeTracker.feeCollector());
        aaveV4Spoke.setReserve(1, address(weth), 18);
        aaveV4Spoke.setReserve(2, address(usdc), 6);

        aaveV3Adapter = new YieldSeekerAaveV3LendingAdapter(oracle);
        morphoAdapter = new YieldSeekerMorphoBlueLendingAdapter(oracle);
        aaveV4Adapter = new YieldSeekerAaveV4LendingAdapter(oracle);
        registry.registerAdapter(address(aaveV3Adapter));
        registry.registerAdapter(address(morphoAdapter));
        registry.registerAdapter(address(aaveV4Adapter));

        vm.prank(OPERATOR);
        wallet = factory.createAgentWallet(OWNER, 1, address(weth), AGENT_PROFILE);
    }

    function test_UnregisteredMarketCannotReachTheAdapter() public {
        bytes memory market = _aaveMarket(aavePool, address(weth), address(usdc), 9);
        address target = aaveV3Adapter.marketTarget(market);
        bytes memory callData = _lendingCall(aaveV3Adapter.borrow.selector, market, 1e6);

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(aaveV3Adapter)));
        _execute(OPERATOR, address(aaveV3Adapter), target, callData);
    }

    function test_RegisteredMarketTargetCannotBeReusedWithDifferentMarketBytes() public {
        bytes memory registeredMarket = _aaveMarket(aavePool, address(weth), address(usdc), 0);
        bytes memory substitutedMarket = _aaveMarket(aavePool, address(weth), address(usdc), 1);
        _registerAaveV3Market(registeredMarket);
        address target = aaveV3Adapter.marketTarget(registeredMarket);
        address expected = aaveV3Adapter.marketTarget(substitutedMarket);
        bytes memory callData = _lendingCall(aaveV3Adapter.supplyCollateral.selector, substitutedMarket, 1e18);

        vm.expectRevert(_adapterError(abi.encodeWithSelector(MarketTargetMismatch.selector, target, expected)));
        _execute(OPERATOR, address(aaveV3Adapter), target, callData);
    }

    function test_MorphoMarketCannotChangeItsRegisteredOracle() public {
        bytes memory registeredMarket = _morphoMarket(address(0x1111));
        bytes memory substitutedMarket = _morphoMarket(address(0x2222));
        _registerMorphoMarket(registeredMarket);
        address target = morphoAdapter.marketTarget(registeredMarket);
        address expected = morphoAdapter.marketTarget(substitutedMarket);
        bytes memory callData = _lendingCall(morphoAdapter.borrow.selector, substitutedMarket, 1e6);

        vm.expectRevert(_adapterError(abi.encodeWithSelector(MarketTargetMismatch.selector, target, expected)));
        _execute(OPERATOR, address(morphoAdapter), target, callData);
    }

    function test_CollateralMustBeTheWalletBaseAsset() public {
        bytes memory market = _aaveMarket(aavePool, address(unsupportedAsset), address(usdc), 0);
        _registerAaveV3Market(market);

        address target = aaveV3Adapter.marketTarget(market);
        vm.expectRevert(_adapterError(abi.encodeWithSelector(AssetNotAllowed.selector)));
        _execute(OPERATOR, address(aaveV3Adapter), target, _lendingCall(aaveV3Adapter.supplyCollateral.selector, market, 1e18));
    }

    function test_BorrowAccountingKeepsSeparateMarketPrincipals() public {
        MockLendingAaveV3Pool secondPool = new MockLendingAaveV3Pool();
        MockERC20 secondAToken = new MockERC20("Second Aave WETH", "aWETH2");
        MockERC20 secondDebtToken = new MockERC20("Second Variable Debt USDC", "vdUSDC2");
        secondPool.setReserve(address(weth), address(secondAToken), address(0));
        secondPool.setReserve(address(usdc), address(0), address(secondDebtToken));

        bytes memory firstMarket = _aaveMarket(aavePool, address(weth), address(usdc), 0);
        bytes memory secondMarket = _aaveMarket(secondPool, address(weth), address(usdc), 0);
        _registerAaveV3Market(firstMarket);
        _registerAaveV3Market(secondMarket);
        weth.mint(address(wallet), 3e18);
        _execute(OPERATOR, address(aaveV3Adapter), aaveV3Adapter.marketTarget(firstMarket), _lendingCall(aaveV3Adapter.supplyCollateral.selector, firstMarket, 1e18));
        _execute(OPERATOR, address(aaveV3Adapter), aaveV3Adapter.marketTarget(firstMarket), _lendingCall(aaveV3Adapter.borrow.selector, firstMarket, 20e6));
        _execute(OPERATOR, address(aaveV3Adapter), aaveV3Adapter.marketTarget(secondMarket), _lendingCall(aaveV3Adapter.supplyCollateral.selector, secondMarket, 2e18));
        _execute(OPERATOR, address(aaveV3Adapter), aaveV3Adapter.marketTarget(secondMarket), _lendingCall(aaveV3Adapter.borrow.selector, secondMarket, 30e6));

        (uint128 firstPrincipal,,, uint16 firstRate) = feeModule.debtPositions(address(wallet), keccak256(firstMarket));
        (uint128 secondPrincipal,,, uint16 secondRate) = feeModule.debtPositions(address(wallet), keccak256(secondMarket));
        assertEq(firstPrincipal, 20e6);
        assertEq(secondPrincipal, 30e6);
        assertEq(firstRate, 50);
        assertEq(secondRate, 50);
        assertEq(variableDebtUsdc.balanceOf(address(wallet)), 20e6);
        assertEq(secondDebtToken.balanceOf(address(wallet)), 30e6);
    }

    function test_YearlyRepayPaysFeeFirstAndCapsRepaymentAtPostFeeBalance() public {
        bytes memory market = _aaveMarket(aavePool, address(weth), address(usdc), 0);
        _fundAndSupplyAave(COLLATERAL, market);
        _execute(OPERATOR, address(aaveV3Adapter), aaveV3Adapter.marketTarget(market), _lendingCall(aaveV3Adapter.borrow.selector, market, BORROW_AMOUNT));

        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        aavePool.growDebt(address(usdc), address(wallet), 20e6);
        _execute(OPERATOR, address(aaveV3Adapter), aaveV3Adapter.marketTarget(market), _lendingCall(aaveV3Adapter.repay.selector, market, type(uint256).max));

        assertEq(feeModule.feesCharged(address(wallet), address(usdc)), 500_000);
        assertEq(feeModule.feesPaid(address(wallet), address(usdc)), 500_000);
        assertEq(usdc.balanceOf(feeTracker.feeCollector()), 500_000);
        assertEq(aavePool.collectorBalanceAtRepay(), 500_000);
        assertEq(aavePool.lastRepayAmount(), BORROW_AMOUNT - 500_000);
        assertEq(variableDebtUsdc.balanceOf(address(wallet)), 20_500_000);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        (uint128 principal, uint128 lastDebt,,) = feeModule.debtPositions(address(wallet), keccak256(market));
        assertEq(principal, 20_500_000);
        assertEq(lastDebt, 20_500_000);
    }

    function test_ExternalDebtReductionStillAccruesOnPreviousReportedDebt() public {
        bytes memory market = _aaveMarket(aavePool, address(weth), address(usdc), 0);
        _fundAndSupplyAave(COLLATERAL, market);
        _execute(OPERATOR, address(aaveV3Adapter), aaveV3Adapter.marketTarget(market), _lendingCall(aaveV3Adapter.borrow.selector, market, BORROW_AMOUNT));

        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        aavePool.reduceDebt(address(usdc), address(wallet), 60e6);
        _execute(OPERATOR, address(aaveV3Adapter), aaveV3Adapter.marketTarget(market), _lendingCall(aaveV3Adapter.withdrawCollateral.selector, market, 1e18));

        assertEq(feeModule.feesCharged(address(wallet), address(usdc)), 500_000);
        assertEq(feeModule.feesPaid(address(wallet), address(usdc)), 500_000);
        assertEq(usdc.balanceOf(feeTracker.feeCollector()), 500_000);
        assertEq(variableDebtUsdc.balanceOf(address(wallet)), 40e6);
        (uint128 principal, uint128 lastDebt,,) = feeModule.debtPositions(address(wallet), keccak256(market));
        assertEq(principal, 40e6);
        assertEq(lastDebt, 40e6);
    }

    function test_DebtFreeCollateralWithdrawalPaysOwedFeeInWethAtOraclePrice() public {
        bytes memory market = _prepareDebtFreeOwedFee();
        wethFeed.setAnswer(int256(2_000e8));
        usdcFeed.setAnswer(int256(1e8));
        uint256 collateralFee = 250_000_000_000_000;

        _execute(OPERATOR, address(aaveV3Adapter), aaveV3Adapter.marketTarget(market), _lendingCall(aaveV3Adapter.withdrawCollateral.selector, market, type(uint256).max));

        assertEq(weth.balanceOf(feeTracker.feeCollector()), collateralFee);
        assertEq(feeModule.feesPaid(address(wallet), address(usdc)), 500_000);
        assertEq(feeModule.feesOwed(address(wallet), address(usdc)), 0);
        assertEq(weth.balanceOf(address(wallet)), COLLATERAL - collateralFee);
    }

    function test_LeavingDustDebtDoesNotLetCollateralLeaveWithoutTheFee() public {
        bytes memory market = _aaveMarket(aavePool, address(weth), address(usdc), 0);
        address target = aaveV3Adapter.marketTarget(market);
        _fundAndSupplyAave(COLLATERAL, market);
        _execute(OPERATOR, address(aaveV3Adapter), target, _lendingCall(aaveV3Adapter.borrow.selector, market, BORROW_AMOUNT));
        usdc.burn(address(wallet), BORROW_AMOUNT);
        vm.warp(vm.getBlockTimestamp() + YEAR);
        aavePool.reduceDebt(address(usdc), address(wallet), BORROW_AMOUNT - 1);
        wethFeed.setAnswer(int256(2_000e8));
        usdcFeed.setAnswer(int256(1e8));

        _execute(OWNER, address(aaveV3Adapter), target, _lendingCall(aaveV3Adapter.withdrawCollateral.selector, market, COLLATERAL / 2));

        assertEq(feeModule.feesOwed(address(wallet), address(usdc)), 0);
        assertEq(weth.balanceOf(feeTracker.feeCollector()), 250_000_000_000_000);
    }

    function test_StaleOracleSkipsCollateralFeePaymentAndDoesNotBlockExit() public {
        bytes memory market = _prepareDebtFreeOwedFee();

        _execute(OPERATOR, address(aaveV3Adapter), aaveV3Adapter.marketTarget(market), _lendingCall(aaveV3Adapter.withdrawCollateral.selector, market, type(uint256).max));

        assertEq(weth.balanceOf(feeTracker.feeCollector()), 0);
        assertEq(feeModule.feesOwed(address(wallet), address(usdc)), 500_000);
        assertEq(weth.balanceOf(address(wallet)), COLLATERAL);
        vm.prank(OWNER);
        wallet.withdrawAllAssetToUser(OWNER, address(weth));
        assertEq(weth.balanceOf(OWNER), COLLATERAL);
    }

    function test_OwnerCanRepayWithdrawCollateralAndWithdrawBaseAndLeftoverDebtToken() public {
        bytes memory market = _aaveMarket(aavePool, address(weth), address(usdc), 0);
        _fundAndSupplyAave(3e18, market);
        _execute(OPERATOR, address(aaveV3Adapter), aaveV3Adapter.marketTarget(market), _lendingCall(aaveV3Adapter.borrow.selector, market, 3e6));
        usdc.mint(address(wallet), 1e6);

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, OPERATOR));
        vm.prank(OPERATOR);
        wallet.withdrawAssetToUser(OWNER, address(usdc), 1);

        _execute(OWNER, address(aaveV3Adapter), aaveV3Adapter.marketTarget(market), _lendingCall(aaveV3Adapter.repay.selector, market, type(uint256).max));
        _execute(OWNER, address(aaveV3Adapter), aaveV3Adapter.marketTarget(market), _lendingCall(aaveV3Adapter.withdrawCollateral.selector, market, type(uint256).max));
        vm.prank(OWNER);
        wallet.withdrawAssetToUser(OWNER, address(weth), 3e18);
        vm.prank(OWNER);
        wallet.withdrawAssetToUser(OWNER, address(usdc), 1e6);

        assertEq(weth.balanceOf(OWNER), 3e18);
        assertEq(usdc.balanceOf(OWNER), 1e6);
        assertEq(variableDebtUsdc.balanceOf(address(wallet)), 0);
        assertEq(aWeth.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(weth.balanceOf(address(wallet)), 0);
    }

    function test_MorphoSupplyBorrowRepayAndWithdrawAll() public {
        IMorphoBlue.MarketParams memory params = _morphoParams(address(0x1111));
        bytes memory market = abi.encode(address(morpho), params);
        _registerMorphoMarket(market);
        weth.mint(address(wallet), 5e18);

        _execute(OPERATOR, address(morphoAdapter), morphoAdapter.marketTarget(market), _lendingCall(morphoAdapter.supplyCollateral.selector, market, 5e18));
        _execute(OPERATOR, address(morphoAdapter), morphoAdapter.marketTarget(market), _lendingCall(morphoAdapter.borrow.selector, market, 20e6));
        bytes32 marketId = keccak256(abi.encode(params));
        (, uint128 borrowShares, uint128 collateral) = morpho.position(marketId, address(wallet));
        assertEq(collateral, 5e18);
        assertGt(borrowShares, 0);
        (uint128 principal,,,) = feeModule.debtPositions(address(wallet), keccak256(market));
        assertEq(principal, 20e6);

        _execute(OPERATOR, address(morphoAdapter), morphoAdapter.marketTarget(market), _lendingCall(morphoAdapter.repay.selector, market, type(uint256).max));
        _execute(OPERATOR, address(morphoAdapter), morphoAdapter.marketTarget(market), _lendingCall(morphoAdapter.withdrawCollateral.selector, market, type(uint256).max));
        (, borrowShares, collateral) = morpho.position(marketId, address(wallet));
        assertEq(borrowShares, 0);
        assertEq(collateral, 0);
        (principal,,,) = feeModule.debtPositions(address(wallet), keccak256(market));
        assertEq(principal, 0);
        assertEq(weth.balanceOf(address(wallet)), 5e18);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    function test_AaveV4SupplyBorrowRepayAndWithdrawAll() public {
        bytes memory market = abi.encode(address(aaveV4Spoke), uint256(1), uint256(2));
        _registerAaveV4Market(market);
        weth.mint(address(wallet), 5e18);

        _execute(OPERATOR, address(aaveV4Adapter), aaveV4Adapter.marketTarget(market), _lendingCall(aaveV4Adapter.supplyCollateral.selector, market, 5e18));
        _execute(OPERATOR, address(aaveV4Adapter), aaveV4Adapter.marketTarget(market), _lendingCall(aaveV4Adapter.borrow.selector, market, 20e6));
        assertTrue(aaveV4Spoke.usingAsCollateral(1, address(wallet)));
        assertEq(aaveV4Spoke.getUserTotalDebt(2, address(wallet)), 20e6);
        (uint128 principal,,,) = feeModule.debtPositions(address(wallet), keccak256(market));
        assertEq(principal, 20e6);

        _execute(OPERATOR, address(aaveV4Adapter), aaveV4Adapter.marketTarget(market), _lendingCall(aaveV4Adapter.repay.selector, market, type(uint256).max));
        _execute(OPERATOR, address(aaveV4Adapter), aaveV4Adapter.marketTarget(market), _lendingCall(aaveV4Adapter.withdrawCollateral.selector, market, type(uint256).max));
        assertEq(aaveV4Spoke.getUserSuppliedAssets(1, address(wallet)), 0);
        assertEq(aaveV4Spoke.getUserTotalDebt(2, address(wallet)), 0);
        (principal,,,) = feeModule.debtPositions(address(wallet), keccak256(market));
        assertEq(principal, 0);
        assertEq(weth.balanceOf(address(wallet)), 5e18);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    function _prepareDebtFreeOwedFee() private returns (bytes memory market) {
        market = _aaveMarket(aavePool, address(weth), address(usdc), 0);
        _fundAndSupplyAave(COLLATERAL, market);
        _execute(OPERATOR, address(aaveV3Adapter), aaveV3Adapter.marketTarget(market), _lendingCall(aaveV3Adapter.borrow.selector, market, BORROW_AMOUNT));
        usdc.burn(address(wallet), BORROW_AMOUNT);

        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        _execute(OPERATOR, address(aaveV3Adapter), aaveV3Adapter.marketTarget(market), _lendingCall(aaveV3Adapter.withdrawCollateral.selector, market, 1e18));
        assertEq(feeModule.feesOwed(address(wallet), address(usdc)), 500_000);
        aavePool.reduceDebt(address(usdc), address(wallet), BORROW_AMOUNT);
        assertEq(variableDebtUsdc.balanceOf(address(wallet)), 0);
    }

    function _fundAndSupplyAave(uint256 amount, bytes memory market) private {
        _registerAaveV3Market(market);
        weth.mint(address(wallet), amount);
        _execute(OPERATOR, address(aaveV3Adapter), aaveV3Adapter.marketTarget(market), _lendingCall(aaveV3Adapter.supplyCollateral.selector, market, amount));
    }

    function _registerAaveV3Market(bytes memory market) private {
        registry.setTargetAdapter(aaveV3Adapter.marketTarget(market), address(aaveV3Adapter));
    }

    function _registerMorphoMarket(bytes memory market) private {
        registry.setTargetAdapter(morphoAdapter.marketTarget(market), address(morphoAdapter));
    }

    function _registerAaveV4Market(bytes memory market) private {
        registry.setTargetAdapter(aaveV4Adapter.marketTarget(market), address(aaveV4Adapter));
    }

    function _execute(address caller, address adapter, address target, bytes memory data) private {
        vm.prank(caller);
        wallet.executeViaAdapter(adapter, target, data);
    }

    function _lendingCall(bytes4 selector, bytes memory market, uint256 amount) private pure returns (bytes memory) {
        return abi.encodeWithSelector(selector, market, amount);
    }

    function _aaveMarket(MockLendingAaveV3Pool pool, address collateral, address debt, uint8 eMode) private pure returns (bytes memory) {
        return abi.encode(address(pool), collateral, debt, eMode);
    }

    function _morphoMarket(address marketOracle) private view returns (bytes memory) {
        return abi.encode(address(morpho), _morphoParams(marketOracle));
    }

    function _morphoParams(address marketOracle) private view returns (IMorphoBlue.MarketParams memory) {
        return IMorphoBlue.MarketParams({loanToken: address(usdc), collateralToken: address(weth), oracle: marketOracle, irm: address(0x2222), lltv: 8e17});
    }

    function _adapterError(bytes memory reason) private pure returns (bytes memory) {
        return abi.encodeWithSelector(AdapterExecutionFailed.selector, reason);
    }
}
