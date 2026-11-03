pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {YieldSeekerAaveV4LendingAdapter as AaveV4LendingAdapter} from "../../src/adapters/AaveV4LendingAdapter.sol";
import {IAaveV4Oracle, IAaveV4Spoke} from "../../src/agentwalletkit/adapters/AWKAaveV4LendingAdapter.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeePlanChoice, YieldSeekerFeeTracker as FeeTracker} from "../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {MockERC20WithDecimals} from "../mocks/MockERC20.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IAaveV4SpokeFork is IAaveV4Spoke {
    function getReserveCount() external view returns (uint256);
    function getUserReserveStatus(uint256 reserveId, address user) external view returns (bool, bool);
    function getUserDebt(uint256 reserveId, address user) external view returns (uint256, uint256);
    function getUserPremiumDebtRay(uint256 reserveId, address user) external view returns (uint256);
}

interface IAaveV4HubFork {
    function getAssetLiquidity(uint256 assetId) external view returns (uint256);
}

contract AaveV4ForkTest is ForkBase {
    address internal constant COLLATERAL_ASSET = 0xb2000000000000000000007b9fcbd005511aCBd5;
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant HUB = 0xa4d5947Eb727A052bae69C593FfC84247EC9864E;
    address internal constant AAVE_V4_SPOKE = 0x17905Db0e4A3514467539956c084180616AE7B8D;
    uint256 internal constant COLLATERAL_RESERVE_ID = 8;
    uint256 internal constant DEBT_RESERVE_ID = 7;
    uint256 internal constant COLLATERAL_AMOUNT = 10e8;
    uint256 internal constant BORROW_AMOUNT = 100e6;
    uint256 internal constant REPAY_SURPLUS = 50e6;
    uint256 internal constant BORROW_RATE_BPS = 50;
    uint256 internal constant YEAR = 365 days;
    bytes32 internal constant BORROW_AGENT_PROFILE = keccak256("borrow");

    IAaveV4SpokeFork internal spoke;
    AdapterRegistry internal borrowRegistry;
    FeeTracker internal borrowTracker;
    YieldSeekerBorrowFeeModule internal borrowFeeModule;
    YieldSeekerYieldFeeModule internal borrowYieldFeeModule;
    AaveV4LendingAdapter internal adapter;
    AgentWallet internal wallet;
    bytes internal market;

    function setUp() public override {
        super.setUp();
        MockERC20WithDecimals collateralTokenCode = new MockERC20WithDecimals("SpaceX", "SPCXC", 8);
        vm.etch(COLLATERAL_ASSET, address(collateralTokenCode).code);
        deal(COLLATERAL_ASSET, HUB, IAaveV4HubFork(HUB).getAssetLiquidity(COLLATERAL_RESERVE_ID));
        spoke = IAaveV4SpokeFork(AAVE_V4_SPOKE);
        borrowTracker = new FeeTracker(address(this), feeCollector);
        borrowYieldFeeModule = new YieldSeekerYieldFeeModule(borrowTracker, 5000);
        borrowTracker.setFeeModule(YIELD_FEE, borrowYieldFeeModule);
        borrowTracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: YIELD_FEE_BPS})));
        borrowFeeModule = new YieldSeekerBorrowFeeModule(borrowTracker, 200);
        borrowTracker.setFeeModule(BORROW_FEE, borrowFeeModule);
        borrowTracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: BORROW_RATE_BPS})));
        borrowTracker.setWalletFactory(address(factory));
        borrowRegistry = new AdapterRegistry(address(this), address(this));
        factory.setAdapterRegistry(BORROW_AGENT_PROFILE, borrowRegistry);
        factory.setFeeTracker(BORROW_AGENT_PROFILE, borrowTracker);
        adapter = new AaveV4LendingAdapter();
        market = abi.encode(AAVE_V4_SPOKE, COLLATERAL_RESERVE_ID, DEBT_RESERVE_ID);
        _register(borrowRegistry, address(adapter), adapter.marketTarget(market));
        FeePlanChoice[] memory noFeePlans = new FeePlanChoice[](0);
        vm.prank(operator);
        wallet = factory.createAgentWallet(owner, 0, COLLATERAL_ASSET, BORROW_AGENT_PROFILE, noFeePlans);
    }

    function test_AaveV4ReserveLayoutMatchesEveryReserve() public {
        address[9] memory expectedAssets = [
            address(0xb200000000000000000000C2e324d24d7eEcd1fb),
            address(0xb200000000000000000000d9192b6B456483C2E8),
            address(0xb2000000000000000000002D0BA3164cc74f58B7),
            address(0xb2000000000000000000008bC8786B856E61707C),
            address(0xB200000000000000000000Ab99cFa739E253872B),
            address(0xb20000000000000000000078ee7ce2fE4908108C),
            address(0xb2000000000000000000001e800a7f5189430cD0),
            USDC,
            COLLATERAL_ASSET
        ];
        assertEq(spoke.getReserveCount(), expectedAssets.length);
        for (uint256 reserveId; reserveId < expectedAssets.length; ++reserveId) {
            IAaveV4Spoke.Reserve memory reserve = spoke.getReserve(reserveId);
            assertEq(reserve.underlying, expectedAssets[reserveId]);
            assertEq(reserve.hub, 0xa4d5947Eb727A052bae69C593FfC84247EC9864E);
            assertEq(reserve.assetId, reserveId);
            assertEq(reserve.decimals, reserveId == DEBT_RESERVE_ID ? 6 : 8);
            assertEq(reserve.dynamicConfigKey, 0);
        }
    }

    function test_AaveV4BorrowRepayWithdrawChargesMarketPricedBorrowAndCollateralYieldFees() public {
        _supplyAndBorrow();
        uint256 borrowReportedAt = block.timestamp;
        vm.warp(borrowReportedAt + YEAR);
        vm.roll(block.number + 1);

        uint256 debt = spoke.getUserTotalDebt(DEBT_RESERVE_ID, address(wallet));
        uint256 suppliedAssets = spoke.getUserSuppliedAssets(COLLATERAL_RESERVE_ID, address(wallet));
        (uint256 drawnDebt, uint256 premiumDebt) = spoke.getUserDebt(DEBT_RESERVE_ID, address(wallet));
        uint256 premiumDebtRay = spoke.getUserPremiumDebtRay(DEBT_RESERVE_ID, address(wallet));
        assertEq(debt, drawnDebt + premiumDebt);
        assertGt(premiumDebt, 0);
        assertEq(premiumDebt, premiumDebtRay / 1e27 + (premiumDebtRay % 1e27 == 0 ? 0 : 1));
        assertGe(debt, BORROW_AMOUNT);
        assertGe(suppliedAssets, COLLATERAL_AMOUNT);
        assertEq(suppliedAssets, COLLATERAL_AMOUNT);
        deal(USDC, address(wallet), debt + REPAY_SURPLUS);

        uint256 expectedDebtFee = Math.mulDiv(BORROW_AMOUNT, BORROW_RATE_BPS * YEAR, YEAR * 10_000, Math.Rounding.Ceil);
        uint256 debtPriceInBaseAsset = _debtPriceInCollateral();
        uint256 expectedBorrowFee = Math.mulDiv(expectedDebtFee, debtPriceInBaseAsset, 1e36, Math.Rounding.Ceil);
        uint256 feeCollectorBalanceBefore = IERC20(COLLATERAL_ASSET).balanceOf(feeCollector);
        uint256 repaid = abi.decode(_execute(adapter, adapter.marketTarget(market), abi.encodeCall(adapter.repay, (market, type(uint256).max))), (uint256));

        assertEq(repaid, debt);
        assertEq(spoke.getUserTotalDebt(DEBT_RESERVE_ID, address(wallet)), 0);
        assertEq(spoke.getUserPremiumDebtRay(DEBT_RESERVE_ID, address(wallet)), 0);
        assertEq(IERC20(USDC).balanceOf(address(wallet)), REPAY_SURPLUS);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), expectedBorrowFee);
        assertGt(expectedBorrowFee, 0);

        uint256 withdrawn = abi.decode(_execute(adapter, adapter.marketTarget(market), abi.encodeCall(adapter.withdrawCollateral, (market, type(uint256).max))), (uint256));
        assertEq(withdrawn, suppliedAssets);
        uint256 expectedYieldFee = withdrawn > COLLATERAL_AMOUNT ? Math.mulDiv(withdrawn - COLLATERAL_AMOUNT, YIELD_FEE_BPS, 10_000, Math.Rounding.Ceil) : 0;
        uint256 expectedTotalFee = expectedBorrowFee + expectedYieldFee;
        assertEq(expectedYieldFee, 0);
        assertEq(spoke.getUserSuppliedAssets(COLLATERAL_RESERVE_ID, address(wallet)), 0);
        assertEq(IERC20(COLLATERAL_ASSET).balanceOf(address(wallet)), withdrawn - expectedTotalFee);
        assertEq(IERC20(COLLATERAL_ASSET).balanceOf(feeCollector) - feeCollectorBalanceBefore, expectedTotalFee);
        assertEq(borrowYieldFeeModule.costBasis(address(wallet), adapter.marketTarget(market)), 0);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 0);

        uint256 ownerCollateralBefore = IERC20(COLLATERAL_ASSET).balanceOf(owner);
        uint256 ownerDebtAssetBefore = IERC20(USDC).balanceOf(owner);
        vm.startPrank(owner);
        wallet.withdrawAllAssetToUser(owner, COLLATERAL_ASSET);
        wallet.withdrawAllAssetToUser(owner, USDC);
        vm.stopPrank();
        assertEq(IERC20(COLLATERAL_ASSET).balanceOf(owner) - ownerCollateralBefore, withdrawn - expectedTotalFee);
        assertEq(IERC20(USDC).balanceOf(owner) - ownerDebtAssetBefore, REPAY_SURPLUS);
        assertEq(IERC20(COLLATERAL_ASSET).balanceOf(address(wallet)), 0);
        assertEq(IERC20(USDC).balanceOf(address(wallet)), 0);
    }

    function test_AaveV4CollateralFlagCanBeSetTwice() public {
        _supplyAndBorrow();
        (bool usingAsCollateral,) = spoke.getUserReserveStatus(COLLATERAL_RESERVE_ID, address(wallet));
        assertTrue(usingAsCollateral);
        vm.prank(address(wallet));
        spoke.setUsingAsCollateral(COLLATERAL_RESERVE_ID, true, address(wallet));
        (usingAsCollateral,) = spoke.getUserReserveStatus(COLLATERAL_RESERVE_ID, address(wallet));
        assertTrue(usingAsCollateral);
    }

    function test_AaveV4UnrelatedEoaCannotRepayOnBehalfAndBorrowPeriodStillCharges() public {
        _supplyAndBorrow();
        vm.warp(block.timestamp + YEAR);
        vm.roll(block.number + 1);
        uint256 debt = spoke.getUserTotalDebt(DEBT_RESERVE_ID, address(wallet));
        address thirdParty = makeAddr("thirdParty");
        vm.prank(thirdParty);
        vm.expectRevert();
        spoke.repay(DEBT_RESERVE_ID, debt, address(wallet));
        assertEq(spoke.getUserTotalDebt(DEBT_RESERVE_ID, address(wallet)), debt);

        deal(USDC, address(wallet), debt + REPAY_SURPLUS);
        _execute(adapter, adapter.marketTarget(market), abi.encodeCall(adapter.repay, (market, type(uint256).max)));
        assertEq(spoke.getUserTotalDebt(DEBT_RESERVE_ID, address(wallet)), 0);
        assertGt(borrowFeeModule.feesOwed(address(wallet)), 0);
    }

    function _supplyAndBorrow() internal {
        deal(COLLATERAL_ASSET, address(wallet), COLLATERAL_AMOUNT);
        _execute(adapter, adapter.marketTarget(market), abi.encodeCall(adapter.supplyCollateral, (market, COLLATERAL_AMOUNT)));
        assertEq(IERC20(COLLATERAL_ASSET).balanceOf(address(wallet)), 0);
        assertEq(spoke.getUserSuppliedAssets(COLLATERAL_RESERVE_ID, address(wallet)), COLLATERAL_AMOUNT);
        _execute(adapter, adapter.marketTarget(market), abi.encodeCall(adapter.borrow, (market, BORROW_AMOUNT)));
        assertEq(IERC20(USDC).balanceOf(address(wallet)), BORROW_AMOUNT);
    }

    function _debtPriceInCollateral() internal view returns (uint256) {
        IAaveV4Oracle oracle = spoke.ORACLE();
        uint256 debtValue = oracle.getReservePrice(DEBT_RESERVE_ID) * 10 ** spoke.getReserve(COLLATERAL_RESERVE_ID).decimals;
        uint256 collateralValue = oracle.getReservePrice(COLLATERAL_RESERVE_ID) * 10 ** spoke.getReserve(DEBT_RESERVE_ID).decimals;
        return Math.mulDiv(debtValue, 1e36, collateralValue);
    }

    function _register(AdapterRegistry registry, address adapterAddress, address target) internal {
        if (!registry.isRegisteredAdapter(adapterAddress)) registry.registerAdapter(adapterAddress);
        registry.setTargetAdapter(target, adapterAddress);
    }

    function _execute(AaveV4LendingAdapter lendingAdapter, address target, bytes memory data) internal returns (bytes memory) {
        vm.prank(operator);
        return abi.decode(wallet.executeViaAdapter(address(lendingAdapter), target, data), (bytes));
    }
}
