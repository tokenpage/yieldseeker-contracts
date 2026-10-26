// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeeModuleAlreadySet, InvalidFeeRate, PlanRateIncrease, UnknownFeeType, UnknownPlan, YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {VAULT_FEE, YieldSeekerVaultFeeModule} from "../../src/fees/VaultFeeModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeWallet} from "../mocks/MockFeeWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract FeeTrackerTest is Test {
    uint256 internal constant YEAR = 365 days;

    address internal admin = makeAddr("admin");
    address internal planManager = makeAddr("planManager");
    address internal collector = makeAddr("collector");
    address internal ownerA = makeAddr("ownerA");

    MockERC20 internal baseAsset;
    MockERC20 internal debtToken;
    MockFeeWallet internal wallet;
    YieldSeekerFeeTracker internal tracker;
    YieldSeekerVaultFeeModule internal vaultModule;
    YieldSeekerBorrowFeeModule internal borrowModule;

    function setUp() public {
        baseAsset = new MockERC20("Base", "BASE");
        debtToken = new MockERC20("Debt", "DEBT");
        wallet = new MockFeeWallet(ownerA, IERC20(address(baseAsset)));
        tracker = new YieldSeekerFeeTracker(admin, planManager, collector);
        vaultModule = new YieldSeekerVaultFeeModule(tracker, 2_000);
        borrowModule = new YieldSeekerBorrowFeeModule(tracker, 500);

        vm.startPrank(admin);
        tracker.addFeeModule(BORROW_FEE, borrowModule);
        tracker.addFeeModule(VAULT_FEE, vaultModule);
        tracker.setPlanRate(0, BORROW_FEE, 300);
        tracker.setPlanRate(0, VAULT_FEE, 1_000);
        vm.stopPrank();
    }

    function testAdminSetsRatesThroughMaximumAndRejectsHigherRate() public {
        uint256 maximumRate = tracker.maxFeeRateBps(VAULT_FEE);
        vm.prank(admin);
        tracker.setPlanRate(1, VAULT_FEE, maximumRate);
        vm.expectRevert(InvalidFeeRate.selector);
        vm.prank(admin);
        tracker.setPlanRate(1, VAULT_FEE, maximumRate + 1);

        vm.prank(admin);
        tracker.assignPlan(ownerA, 1);
        wallet.execute(address(vaultModule), abi.encodeCall(vaultModule.recordAgentYieldEarned, (10_000)));
        assertEq(vaultModule.agentFeesCharged(address(wallet)), 2_000);
    }

    function testPlanManagerMayAssignEqualOrCheaperRateButNotMoreExpensive() public {
        vm.startPrank(admin);
        tracker.setPlanRate(1, VAULT_FEE, 750);
        tracker.setPlanRate(1, BORROW_FEE, 300);
        tracker.setPlanRate(2, VAULT_FEE, 750);
        tracker.setPlanRate(2, BORROW_FEE, 300);
        tracker.setPlanRate(3, VAULT_FEE, 500);
        tracker.setPlanRate(3, BORROW_FEE, 301);
        vm.stopPrank();

        vm.startPrank(planManager);
        tracker.assignPlan(ownerA, 1);
        tracker.assignPlan(ownerA, 2);
        vm.expectRevert(abi.encodeWithSelector(PlanRateIncrease.selector, VAULT_FEE, 750, 1_000));
        tracker.assignPlan(ownerA, 0);
        vm.expectRevert(abi.encodeWithSelector(PlanRateIncrease.selector, BORROW_FEE, 300, 301));
        tracker.assignPlan(ownerA, 3);
        vm.stopPrank();

        assertEq(tracker.planOf(ownerA), 2);
    }

    function testAdminMayAssignHigherRateAndUnknownPlansAreRejected() public {
        vm.prank(admin);
        tracker.setPlanRate(1, VAULT_FEE, 1_500);

        vm.prank(admin);
        tracker.assignPlan(ownerA, 1);
        wallet.execute(address(vaultModule), abi.encodeCall(vaultModule.recordAgentYieldEarned, (10_000)));
        assertEq(vaultModule.agentFeesCharged(address(wallet)), 1_500);

        vm.expectRevert(abi.encodeWithSelector(UnknownPlan.selector, 99));
        vm.prank(planManager);
        tracker.assignPlan(ownerA, 99);
    }

    function testUnprivilegedCallerCannotAssignAPlan() public {
        address stranger = makeAddr("stranger");

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        tracker.assignPlan(ownerA, 0);
    }

    function testWalletYieldUsesItsOwnersAssignedPlanRate() public {
        vm.prank(admin);
        tracker.setPlanRate(1, VAULT_FEE, 500);
        vm.prank(planManager);
        tracker.assignPlan(ownerA, 1);

        wallet.execute(address(vaultModule), abi.encodeCall(vaultModule.recordAgentYieldEarned, (10e6)));

        assertEq(vaultModule.agentFeesCharged(address(wallet)), 500_000);
        assertEq(vaultModule.getFeesOwed(address(wallet)), 500_000);
    }

    function testFeeModulesAreAddOnlyAndRatesUseEachTypeMaximum() public {
        vm.startPrank(admin);
        tracker.setPlanRate(1, VAULT_FEE, 2_000);
        tracker.setPlanRate(1, BORROW_FEE, 500);
        vm.expectRevert(InvalidFeeRate.selector);
        tracker.setPlanRate(1, BORROW_FEE, 501);
        bytes32 unknownFeeType = keccak256("unknown");
        vm.expectRevert(abi.encodeWithSelector(UnknownFeeType.selector, unknownFeeType));
        tracker.setPlanRate(1, unknownFeeType, 0);

        YieldSeekerBorrowFeeModule replacement = new YieldSeekerBorrowFeeModule(tracker, 500);
        vm.expectRevert(abi.encodeWithSelector(FeeModuleAlreadySet.selector, BORROW_FEE));
        tracker.addFeeModule(BORROW_FEE, replacement);
        vm.stopPrank();
    }

    function testWithdrawReserveAggregatesRegisteredFeeModules() public {
        wallet.execute(address(vaultModule), abi.encodeCall(vaultModule.recordAgentYieldEarned, (100e6)));

        wallet.execute(address(borrowModule), abi.encodeCall(borrowModule.recordBorrow, (keccak256("market"), address(debtToken), 1_000, 0)));
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        wallet.execute(address(borrowModule), abi.encodeCall(borrowModule.checkpoint, (keccak256("market"), address(debtToken), 1_000)));

        (bool baseAllowed, uint256 baseReserved) = tracker.withdrawReserve(address(wallet), address(baseAsset));
        (bool debtAllowed, uint256 debtReserved) = tracker.withdrawReserve(address(wallet), address(debtToken));
        (bool otherAllowed, uint256 otherReserved) = tracker.withdrawReserve(address(wallet), address(0xBEEF));
        assertTrue(baseAllowed);
        assertEq(baseReserved, 10e6);
        assertTrue(debtAllowed);
        assertEq(debtReserved, 30);
        assertFalse(otherAllowed);
        assertEq(otherReserved, 0);
    }

    function testFeeCollectorCanBeUpdatedByAdmin() public {
        address newCollector = makeAddr("newCollector");
        vm.prank(admin);
        tracker.setFeeCollector(newCollector);
        assertEq(tracker.feeCollector(), newCollector);
    }
}
