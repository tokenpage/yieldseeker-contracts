// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker as YieldSeekerVaultFeeModule} from "../../src/FeeTracker.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {InvalidFeeRate, PlanRateIncrease, UnknownPlan} from "../../src/fees/FeePlans.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeWallet} from "../mocks/MockFeeWallet.sol";
import {Test} from "forge-std/Test.sol";

contract FeePlansTest is Test {
    address internal admin = makeAddr("admin");
    address internal planManager = makeAddr("planManager");
    address internal collector = makeAddr("collector");
    address internal ownerA = makeAddr("ownerA");

    MockERC20 internal baseAsset;
    MockFeeWallet internal wallet;
    YieldSeekerVaultFeeModule internal module;

    function setUp() public {
        baseAsset = new MockERC20("Base", "BASE");
        wallet = new MockFeeWallet(ownerA, baseAsset);
        module = new YieldSeekerVaultFeeModule(admin, planManager, collector, 2_000, 1_000);
    }

    function testAdminSetsRatesThroughMaximumAndRejectsHigherRate() public {
        uint256 maximumRate = module.MAX_FEE_RATE_BPS();
        vm.prank(admin);
        module.setPlanRate(1, maximumRate);
        vm.expectRevert(InvalidFeeRate.selector);
        vm.prank(admin);
        module.setPlanRate(1, maximumRate + 1);

        vm.prank(admin);
        module.assignPlan(ownerA, 1);
        wallet.execute(address(module), abi.encodeCall(module.recordAgentYieldEarned, (10_000)));
        assertEq(module.agentFeesCharged(address(wallet)), 2_000);
    }

    function testPlanManagerMayAssignEqualOrCheaperRateButNotMoreExpensive() public {
        vm.startPrank(admin);
        module.setPlanRate(1, 750);
        module.setPlanRate(2, 750);
        vm.stopPrank();

        vm.startPrank(planManager);
        module.assignPlan(ownerA, 1);
        module.assignPlan(ownerA, 2);
        vm.expectRevert(abi.encodeWithSelector(PlanRateIncrease.selector, 750, 1_000));
        module.assignPlan(ownerA, 0);
        vm.stopPrank();

        assertEq(module.planOf(ownerA), 2);
    }

    function testAdminMayAssignHigherRateAndUnknownPlansAreRejected() public {
        vm.prank(admin);
        module.setPlanRate(1, 1_500);

        vm.prank(admin);
        module.assignPlan(ownerA, 1);
        wallet.execute(address(module), abi.encodeCall(module.recordAgentYieldEarned, (10_000)));
        assertEq(module.agentFeesCharged(address(wallet)), 1_500);

        vm.expectRevert(abi.encodeWithSelector(UnknownPlan.selector, 99));
        vm.prank(planManager);
        module.assignPlan(ownerA, 99);
    }

    function testUnprivilegedCallerCannotAssignAPlan() public {
        address stranger = makeAddr("stranger");

        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, stranger));
        vm.prank(stranger);
        module.assignPlan(ownerA, 0);
    }

    function testWalletYieldUsesItsOwnersAssignedPlanRate() public {
        vm.prank(admin);
        module.setPlanRate(1, 500);
        vm.prank(planManager);
        module.assignPlan(ownerA, 1);

        wallet.execute(address(module), abi.encodeCall(module.recordAgentYieldEarned, (10e6)));

        assertEq(module.agentFeesCharged(address(wallet)), 500_000);
        assertEq(module.getFeesOwed(address(wallet)), 500_000);
    }
}
