// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BORROW_FEE, FeePaidExceedsOwed, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {VAULT_FEE, YieldSeekerVaultFeeModule} from "../../src/fees/VaultFeeModule.sol";
import {MockERC20WithDecimals} from "../mocks/MockERC20.sol";
import {MockFeeWallet} from "../mocks/MockFeeWallet.sol";
import {Test} from "forge-std/Test.sol";

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
    YieldSeekerVaultFeeModule internal vaultModule;

    function setUp() public {
        baseAsset = new MockERC20WithDecimals("Base", "BASE", 18);
        debtToken = new MockERC20WithDecimals("Debt", "DEBT", 6);
        unrelatedToken = new MockERC20WithDecimals("Other", "OTHER", 18);
        wallet = new MockFeeWallet(owner, baseAsset);
        tracker = new YieldSeekerFeeTracker(admin, planManager, collector);
        module = new YieldSeekerBorrowFeeModule(tracker, 1_000);
        vaultModule = new YieldSeekerVaultFeeModule(tracker, 5_000);
        vm.startPrank(admin);
        tracker.setFeeModule(BORROW_FEE, module);
        tracker.setFeeModule(VAULT_FEE, vaultModule);
        tracker.setPlanRate(0, BORROW_FEE, 1_000);
        tracker.setPlanRate(0, VAULT_FEE, 1_000);
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

        _checkpoint(MARKET_A, 0);

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

        vm.expectRevert(abi.encodeWithSelector(FeePaidExceedsOwed.selector, 100, 101));
        wallet.execute(address(module), abi.encodeCall(module.recordFeePaid, (address(debtToken), 101, address(baseAsset), 101)));

        wallet.execute(address(module), abi.encodeCall(module.recordFeePaid, (address(debtToken), 40, address(baseAsset), 40)));
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

    function testRewardHooksDoNotCreateBorrowFees() public {
        wallet.execute(address(vaultModule), abi.encodeCall(vaultModule.recordYield, (100)));

        assertEq(vaultModule.feesOwed(address(wallet)), 10);
        assertEq(module.feesOwed(address(wallet), address(debtToken)), 0);
    }

    function _recordBorrow(bytes32 market, uint256 amount, uint256 debtBefore) internal {
        wallet.execute(address(module), abi.encodeCall(module.recordBorrow, (market, address(debtToken), amount, debtBefore)));
    }

    function _recordRepay(bytes32 market, uint256 repaid, uint256 debtBefore) internal {
        wallet.execute(address(module), abi.encodeCall(module.recordRepay, (market, address(debtToken), repaid, debtBefore)));
    }

    function _checkpoint(bytes32 market, uint256 currentDebt) internal {
        wallet.execute(address(module), abi.encodeCall(module.checkpoint, (market, address(debtToken), currentDebt)));
    }

    function _accrueOneYearFee() internal {
        _recordBorrow(MARKET_A, 1_000, 0);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        _checkpoint(MARKET_A, 1_000);
    }
}
