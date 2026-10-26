// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IYieldSeekerPriceOracle} from "../../src/PriceOracle.sol";
import {BORROW_FEE, FeePaidExceedsDue, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {MockERC20WithDecimals} from "../mocks/MockERC20.sol";
import {MockFeeWallet} from "../mocks/MockFeeWallet.sol";
import {Test} from "forge-std/Test.sol";

contract MockBorrowFeePriceOracle is IYieldSeekerPriceOracle {
    mapping(address => uint256) public quoteMultiplier;
    mapping(address => bool) public quoteReverts;

    function setQuoteMultiplier(address token, uint256 multiplier) external {
        quoteMultiplier[token] = multiplier;
    }

    function setQuoteReverts(address token, bool shouldRevert) external {
        quoteReverts[token] = shouldRevert;
    }

    function getPrice(address) external pure override returns (uint256) {
        return 1e18;
    }

    function quote(address fromToken, address, uint256 amount) external view override returns (uint256) {
        if (quoteReverts[fromToken]) revert();
        return amount * quoteMultiplier[fromToken];
    }
}

contract BorrowFeeModuleTest is Test {
    uint256 internal constant YEAR = 365 days;
    bytes32 internal constant MARKET_A = keccak256("market-a");
    bytes32 internal constant MARKET_B = keccak256("market-b");

    address internal admin = makeAddr("admin");
    address internal planManager = makeAddr("planManager");
    address internal collector = makeAddr("collector");
    address internal owner = makeAddr("owner");

    MockERC20WithDecimals internal baseAsset;
    MockERC20WithDecimals internal debtToken;
    MockERC20WithDecimals internal unrelatedToken;
    MockFeeWallet internal wallet;
    YieldSeekerFeeTracker internal tracker;
    YieldSeekerBorrowFeeModule internal module;
    MockBorrowFeePriceOracle internal oracle;
    YieldSeekerYieldFeeModule internal vaultModule;

    function setUp() public {
        baseAsset = new MockERC20WithDecimals("Base", "BASE", 18);
        debtToken = new MockERC20WithDecimals("Debt", "DEBT", 6);
        unrelatedToken = new MockERC20WithDecimals("Other", "OTHER", 18);
        wallet = new MockFeeWallet(owner, baseAsset);
        tracker = new YieldSeekerFeeTracker(admin, planManager, collector);
        oracle = new MockBorrowFeePriceOracle();
        oracle.setQuoteMultiplier(address(debtToken), 1);
        module = new YieldSeekerBorrowFeeModule(tracker, oracle, 1_000);
        vaultModule = new YieldSeekerYieldFeeModule(tracker, 5_000);
        vm.startPrank(admin);
        tracker.setFeeModule(BORROW_FEE, module);
        tracker.setFeeModule(YIELD_FEE, vaultModule);
        tracker.setPlanRate(0, BORROW_FEE, 1_000);
        tracker.setPlanRate(0, YIELD_FEE, 1_000);
        vm.stopPrank();
    }

    function testLinearAccrualIsMarketIsolatedAndPendingUntilCheckpoint() public {
        _recordBorrow(MARKET_A, 1_000, 0);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR / 2);

        assertEq(module.pendingFee(address(wallet), MARKET_A), 50);
        _checkpoint(MARKET_B, 0);
        (uint128 principalA,,,) = module.debtPositions(address(wallet), MARKET_A);
        assertEq(principalA, 1_000);
        assertEq(module.pendingFee(address(wallet), MARKET_A), 50);
        assertEq(module.feesOwed(address(wallet), address(debtToken)), 0);

        vm.warp(start + YEAR);
        assertEq(module.pendingFee(address(wallet), MARKET_A), 100);
        _checkpoint(MARKET_A, 1_000);
        assertEq(module.feesOwed(address(wallet), address(debtToken)), 100);
        assertEq(module.pendingFee(address(wallet), MARKET_A), 0);
    }

    function testExternalRepayReportedAtCheckpointStillAccruesPreviousDebt() public {
        _recordBorrow(MARKET_A, 1_000, 0);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);

        _recordRepay(MARKET_A, 1_000, 1_000);

        assertEq(module.feesOwed(address(wallet), address(debtToken)), 100);
        (uint128 principal,,,) = module.debtPositions(address(wallet), MARKET_A);
        assertEq(principal, 0);
    }

    function testLiquidationReductionCapsPrincipalForLaterPeriods() public {
        _recordBorrow(MARKET_A, 1_000, 0);
        uint256 start = vm.getBlockTimestamp();

        vm.warp(start + YEAR);
        _checkpoint(MARKET_A, 400);
        (uint128 principal,,,) = module.debtPositions(address(wallet), MARKET_A);
        assertEq(principal, 400);
        assertEq(module.feesOwed(address(wallet), address(debtToken)), 100);

        vm.warp(start + 2 * YEAR);
        _checkpoint(MARKET_A, 400);
        assertEq(module.feesOwed(address(wallet), address(debtToken)), 140);
    }

    function testRepaymentPaysInterestBeforePrincipalAndFullRepayClearsPrincipal() public {
        _recordBorrow(MARKET_A, 100, 0);
        _recordRepay(MARKET_A, 50, 110);
        (uint128 principal,,,) = module.debtPositions(address(wallet), MARKET_A);
        assertEq(principal, 60);

        _recordRepay(MARKET_A, 60, 60);
        (principal,,,) = module.debtPositions(address(wallet), MARKET_A);
        assertEq(principal, 0);
    }

    function testRateChangeTakesEffectAfterTheNextCheckpoint() public {
        _recordBorrow(MARKET_A, 1_000, 0);
        uint256 start = vm.getBlockTimestamp();

        vm.startPrank(admin);
        tracker.setPlanRate(1, BORROW_FEE, 500);
        tracker.assignPlan(owner, 1);
        vm.stopPrank();
        vm.warp(start + YEAR);
        assertEq(module.pendingFee(address(wallet), MARKET_A), 100);
        _checkpoint(MARKET_A, 1_000);
        assertEq(module.feesOwed(address(wallet), address(debtToken)), 100);
        (,,, uint16 savedRate) = module.debtPositions(address(wallet), MARKET_A);
        assertEq(savedRate, 500);

        vm.warp(start + 2 * YEAR);
        assertEq(module.pendingFee(address(wallet), MARKET_A), 50);
        _checkpoint(MARKET_A, 1_000);
        assertEq(module.feesOwed(address(wallet), address(debtToken)), 150);
    }

    function testFeePaymentIsCappedAndWithdrawableBalancesRespectAssetRules() public {
        _accrueOneYearFee();

        uint256 due = module.feesDue(address(wallet));
        uint256 overpayment = due + 1;
        vm.expectRevert(abi.encodeWithSelector(FeePaidExceedsDue.selector, due, overpayment));
        wallet.execute(address(module), abi.encodeCall(module.recordFeePaid, (overpayment)));

        wallet.execute(address(module), abi.encodeCall(module.recordFeePaid, (40)));
        assertEq(module.feesOwed(address(wallet), address(debtToken)), 60);
        (bool baseAllowed, uint256 baseReserved) = tracker.withdrawReserve(address(wallet), address(baseAsset));
        (bool debtAllowed, uint256 debtReserved) = tracker.withdrawReserve(address(wallet), address(debtToken));
        (bool unrelatedAllowed,) = tracker.withdrawReserve(address(wallet), address(unrelatedToken));
        assertTrue(baseAllowed);
        assertEq(baseReserved, 0);
        assertTrue(debtAllowed);
        assertEq(debtReserved, 0);
        assertFalse(unrelatedAllowed);
    }

    function testFeesDueQuotesTokensInOrderAndSkipsRevertingQuotes() public {
        MockERC20WithDecimals secondDebtToken = new MockERC20WithDecimals("Second", "SECOND", 6);
        MockERC20WithDecimals staleDebtToken = new MockERC20WithDecimals("Stale", "STALE", 6);
        oracle.setQuoteMultiplier(address(debtToken), 2);
        oracle.setQuoteMultiplier(address(secondDebtToken), 4);
        oracle.setQuoteMultiplier(address(staleDebtToken), 7);
        oracle.setQuoteReverts(address(staleDebtToken), true);

        _recordBorrow(MARKET_A, 1_000, 0);
        _recordDebtChange(MARKET_B, address(secondDebtToken), 0, 1_000, 0);
        bytes32 staleMarket = keccak256("stale-market");
        _recordDebtChange(staleMarket, address(staleDebtToken), 0, 1_000, 0);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        _recordDebtChange(MARKET_A, address(debtToken), 1_000, 0, 0);
        _recordDebtChange(MARKET_B, address(secondDebtToken), 1_000, 0, 0);
        _recordDebtChange(staleMarket, address(staleDebtToken), 1_000, 0, 0);

        assertEq(module.feesOwed(address(wallet), address(debtToken)), 100);
        assertEq(module.feesOwed(address(wallet), address(secondDebtToken)), 100);
        assertEq(module.feesOwed(address(wallet), address(staleDebtToken)), 100);
        uint256 due = module.feesDue(address(wallet));
        assertEq(due, 600);

        wallet.execute(address(module), abi.encodeCall(module.recordFeePaid, (300)));

        assertEq(module.feesPaid(address(wallet), address(debtToken)), 100);
        assertEq(module.feesPaid(address(wallet), address(secondDebtToken)), 25);
        assertEq(module.feesPaid(address(wallet), address(staleDebtToken)), 0);
        assertEq(module.feesOwed(address(wallet), address(secondDebtToken)), 75);
        assertEq(module.feesOwed(address(wallet), address(staleDebtToken)), 100);
        due = module.feesDue(address(wallet));
        assertEq(due, 300);
        uint256 overpayment = due + 1;
        vm.expectRevert(abi.encodeWithSelector(FeePaidExceedsDue.selector, due, overpayment));
        wallet.execute(address(module), abi.encodeCall(module.recordFeePaid, (overpayment)));
        assertEq(module.feesDue(address(wallet)), due);
    }

    function testRewardHooksDoNotCreateBorrowFees() public {
        wallet.execute(address(vaultModule), abi.encodeCall(vaultModule.onClaim, (address(baseAsset), 100)));

        assertEq(vaultModule.feesDue(address(wallet)), 10);
        assertEq(module.feesOwed(address(wallet), address(debtToken)), 0);
    }

    function _recordBorrow(bytes32 market, uint256 amount, uint256 debtBefore) internal {
        _recordDebtChange(market, address(debtToken), debtBefore, amount, 0);
    }

    function _recordRepay(bytes32 market, uint256 repaid, uint256 debtBefore) internal {
        _recordDebtChange(market, address(debtToken), debtBefore, 0, repaid);
    }

    function _checkpoint(bytes32 market, uint256 currentDebt) internal {
        _recordDebtChange(market, address(debtToken), currentDebt, 0, 0);
    }

    function _recordDebtChange(bytes32 market, address token, uint256 debtBefore, uint256 borrowed, uint256 repaid) internal {
        wallet.execute(address(module), abi.encodeCall(module.onDebtChange, (market, token, debtBefore, borrowed, repaid)));
    }

    function _accrueOneYearFee() internal {
        _recordBorrow(MARKET_A, 1_000, 0);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        _checkpoint(MARKET_A, 1_000);
    }
}
