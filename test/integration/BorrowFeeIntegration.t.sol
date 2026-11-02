// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {YieldSeekerAaveV3LendingAdapter} from "../../src/adapters/AaveV3LendingAdapter.sol";
import {IAaveV3LendingPool, IAaveV3Oracle} from "../../src/agentwalletkit/adapters/AWKAaveV3LendingAdapter.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeePlanChoice, YieldSeekerFeeTracker as FeeTracker} from "../../src/fees/FeeTracker.sol";
import {MockERC20, MockERC20WithDecimals} from "../mocks/MockERC20.sol";
import {MockLendingAaveV3Pool} from "../mocks/MockLendingMarkets.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract BorrowFeeIntegrationTest is Test {
    bytes32 private constant AGENT_PROFILE = keccak256("borrow");
    uint256 private constant YEAR = 365 days;
    uint256 private constant FEE_RATE_BPS = 50;
    uint256 private constant COLLATERAL = 1 ether;
    uint256 private constant BORROW_AMOUNT = 100e6;

    address private owner = makeAddr("owner");
    address private operator = makeAddr("operator");
    address private feeCollector = makeAddr("feeCollector");

    FeeTracker private feeTracker;
    YieldSeekerBorrowFeeModule private feeModule;
    AgentWallet private wallet;
    AdapterRegistry private registry;
    YieldSeekerAaveV3LendingAdapter private lendingAdapter;
    MockLendingAaveV3Pool private aavePool;
    MockERC20WithDecimals private weth;
    MockERC20WithDecimals private usdc;
    MockERC20 private aWeth;
    MockERC20 private variableDebtUsdc;
    bytes private market;
    address private marketTarget;

    function setUp() public {
        vm.warp(10_000_000);
        weth = new MockERC20WithDecimals("Wrapped Ether", "WETH", 18);
        usdc = new MockERC20WithDecimals("USD Coin", "USDC", 6);
        aWeth = new MockERC20("Aave WETH", "aWETH");
        variableDebtUsdc = new MockERC20("Variable Debt USDC", "vdUSDC");
        aavePool = new MockLendingAaveV3Pool();
        aavePool.setReserve(address(weth), address(aWeth), address(0));
        aavePool.setReserve(address(usdc), address(0), address(variableDebtUsdc));
        aavePool.setAssetPrice(address(weth), 2_000e8);
        aavePool.setAssetPrice(address(usdc), 1e8);

        feeTracker = new FeeTracker(address(this), feeCollector);
        feeModule = new YieldSeekerBorrowFeeModule(feeTracker, 10_000);
        feeTracker.setFeeModule(BORROW_FEE, feeModule);
        feeTracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: FEE_RATE_BPS})));

        AgentWalletFactory factory = new AgentWalletFactory(address(this), operator);
        registry = new AdapterRegistry(address(this), address(this));
        lendingAdapter = new YieldSeekerAaveV3LendingAdapter();
        factory.setAdapterRegistry(AGENT_PROFILE, registry);
        factory.setFeeTracker(feeTracker);
        factory.setAgentWalletImplementation(new AgentWallet(address(factory)));
        registry.registerAdapter(address(lendingAdapter));

        market = abi.encode(address(aavePool), address(weth), address(usdc), uint8(0));
        marketTarget = lendingAdapter.marketTarget(market);
        registry.setTargetAdapter(marketTarget, address(lendingAdapter));

        vm.prank(operator);
        wallet = factory.createAgentWallet(owner, 0, address(weth), AGENT_PROFILE, new FeePlanChoice[](0));
    }

    function test_BorrowRepayWithdrawAndOwnerExitPayMarketPricedFee() public {
        _supplyAndBorrow();
        vm.warp(vm.getBlockTimestamp() + YEAR);

        uint256 debtFee = Math.mulDiv(BORROW_AMOUNT, FEE_RATE_BPS, 10_000);
        uint256 expectedBaseAssetFee = _feeInBaseAsset(debtFee);
        uint256 collectorBalanceBefore = weth.balanceOf(feeCollector);
        _execute(_lendingCall(lendingAdapter.repay.selector, type(uint256).max));

        assertEq(usdc.balanceOf(feeCollector), 0);
        assertEq(feeModule.feesOwed(address(wallet)), expectedBaseAssetFee);

        _execute(_lendingCall(lendingAdapter.withdrawCollateral.selector, type(uint256).max));
        assertEq(weth.balanceOf(feeCollector) - collectorBalanceBefore, expectedBaseAssetFee);
        assertEq(feeModule.feesOwed(address(wallet)), 0);

        uint256 ownerBalanceBefore = weth.balanceOf(owner);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(weth));
        assertEq(weth.balanceOf(owner) - ownerBalanceBefore, COLLATERAL - expectedBaseAssetFee);
        assertEq(weth.balanceOf(address(wallet)), 0);
    }

    function test_MarketPriceChangesOnlyRevalueLaterAccrualPeriods() public {
        _supplyAndBorrow();
        uint256 debtFeePerYear = Math.mulDiv(BORROW_AMOUNT, FEE_RATE_BPS, 10_000);

        vm.warp(vm.getBlockTimestamp() + YEAR);
        aavePool.setAssetPrice(address(weth), 1_000e8);
        uint256 firstPeriodFee = _feeInBaseAsset(debtFeePerYear);
        _execute(_checkpointCall());
        assertEq(feeModule.feesOwed(address(wallet)), firstPeriodFee);

        aavePool.setAssetPrice(address(weth), 5_000e8);
        assertEq(feeModule.feesOwed(address(wallet)), firstPeriodFee);
        vm.warp(vm.getBlockTimestamp() + YEAR);
        uint256 secondPeriodFee = _feeInBaseAsset(debtFeePerYear);
        _execute(_checkpointCall());
        assertLt(secondPeriodFee, firstPeriodFee);
        assertEq(feeModule.feesOwed(address(wallet)), firstPeriodFee + secondPeriodFee);

        uint256 collectorBalanceBefore = weth.balanceOf(feeCollector);
        _execute(_lendingCall(lendingAdapter.repay.selector, type(uint256).max));
        _execute(_lendingCall(lendingAdapter.withdrawCollateral.selector, type(uint256).max));
        assertEq(weth.balanceOf(feeCollector) - collectorBalanceBefore, firstPeriodFee + secondPeriodFee);
        assertEq(feeModule.feesOwed(address(wallet)), 0);

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(weth));
        assertEq(weth.balanceOf(owner), COLLATERAL - firstPeriodFee - secondPeriodFee);
    }

    function test_CheckpointAfterExternalDebtClearChargesNothing() public {
        _supplyAndBorrow();
        vm.warp(vm.getBlockTimestamp() + YEAR);
        aavePool.reduceDebt(address(usdc), address(wallet), BORROW_AMOUNT);
        assertEq(variableDebtUsdc.balanceOf(address(wallet)), 0);

        _execute(_checkpointCall());
        assertEq(feeModule.feesOwed(address(wallet)), 0);
        assertEq(feeModule.pendingFee(address(wallet), keccak256(market)), 0);

        vm.warp(vm.getBlockTimestamp() + YEAR);
        _execute(_checkpointCall());
        assertEq(feeTracker.feesOwedInBaseAsset(address(wallet)), 0);
        assertEq(weth.balanceOf(feeCollector), 0);

        _execute(_lendingCall(lendingAdapter.withdrawCollateral.selector, type(uint256).max));
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(weth));
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(weth.balanceOf(owner), COLLATERAL);
        assertEq(usdc.balanceOf(owner), BORROW_AMOUNT);
    }

    function _supplyAndBorrow() private {
        weth.mint(address(wallet), COLLATERAL);
        _execute(_lendingCall(lendingAdapter.supplyCollateral.selector, COLLATERAL));
        _execute(_lendingCall(lendingAdapter.borrow.selector, BORROW_AMOUNT));
    }

    function _execute(bytes memory callData) private {
        vm.prank(operator);
        wallet.executeViaAdapter(address(lendingAdapter), marketTarget, callData);
    }

    function _lendingCall(bytes4 selector, uint256 amount) private view returns (bytes memory) {
        return abi.encodeWithSelector(selector, market, amount);
    }

    function _checkpointCall() private view returns (bytes memory) {
        return abi.encodeWithSelector(lendingAdapter.checkpoint.selector, market);
    }

    function _feeInBaseAsset(uint256 debtFee) private view returns (uint256) {
        IAaveV3Oracle marketOracle = IAaveV3LendingPool(address(aavePool)).ADDRESSES_PROVIDER().getPriceOracle();
        uint256 debtValue = marketOracle.getAssetPrice(address(usdc)) * 10 ** weth.decimals();
        uint256 collateralValue = marketOracle.getAssetPrice(address(weth)) * 10 ** usdc.decimals();
        uint256 debtPriceInBaseAsset = Math.mulDiv(debtValue, 1e36, collateralValue);
        return Math.mulDiv(debtFee, debtPriceInBaseAsset, 1e36);
    }
}
