// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../src/FeeTracker.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeeModuleAlreadySet, InvalidFeeRate, PlanRateIncrease, UnknownFeeType, UnknownPlan} from "../../src/fees/FeePlans.sol";
import {VAULT_FEE} from "../../src/fees/VaultFeeModule.sol";
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
    YieldSeekerFeeTracker internal module;
    YieldSeekerBorrowFeeModule internal borrowModule;

    function setUp() public {
        baseAsset = new MockERC20("Base", "BASE");
        wallet = new MockFeeWallet(ownerA, baseAsset);
        module = new YieldSeekerFeeTracker(admin, planManager, collector, 2_000, 1_000);
        borrowModule = new YieldSeekerBorrowFeeModule(module, 500);
        vm.startPrank(admin);
        module.addFeeModule(BORROW_FEE, borrowModule);
        module.setPlanRate(0, BORROW_FEE, 300);
        vm.stopPrank();
    }

    function testAdminSetsRatesThroughMaximumAndRejectsHigherRate() public {
        uint256 maximumRate = module.maxFeeRateBps(VAULT_FEE);
        vm.prank(admin);
        module.setPlanRate(1, VAULT_FEE, maximumRate);
        vm.expectRevert(InvalidFeeRate.selector);
        vm.prank(admin);
        module.setPlanRate(1, VAULT_FEE, maximumRate + 1);

        vm.prank(admin);
        module.assignPlan(ownerA, 1);
        wallet.execute(address(module), abi.encodeCall(module.recordAgentYieldEarned, (10_000)));
        assertEq(module.agentFeesCharged(address(wallet)), 2_000);
    }

    function testPlanManagerMayAssignEqualOrCheaperRateButNotMoreExpensive() public {
        vm.startPrank(admin);
        module.setPlanRate(1, VAULT_FEE, 750);
        module.setPlanRate(1, BORROW_FEE, 300);
        module.setPlanRate(2, VAULT_FEE, 750);
        module.setPlanRate(2, BORROW_FEE, 300);
        module.setPlanRate(3, VAULT_FEE, 500);
        module.setPlanRate(3, BORROW_FEE, 301);
        vm.stopPrank();

        vm.startPrank(planManager);
        module.assignPlan(ownerA, 1);
        module.assignPlan(ownerA, 2);
        vm.expectRevert(abi.encodeWithSelector(PlanRateIncrease.selector, VAULT_FEE, 750, 1_000));
        module.assignPlan(ownerA, 0);
        vm.expectRevert(abi.encodeWithSelector(PlanRateIncrease.selector, BORROW_FEE, 300, 301));
        module.assignPlan(ownerA, 3);
        vm.stopPrank();

        assertEq(module.planOf(ownerA), 2);
    }

    function testAdminMayAssignHigherRateAndUnknownPlansAreRejected() public {
        vm.prank(admin);
        module.setPlanRate(1, VAULT_FEE, 1_500);

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
        module.setPlanRate(1, VAULT_FEE, 500);
        vm.prank(planManager);
        module.assignPlan(ownerA, 1);

        wallet.execute(address(module), abi.encodeCall(module.recordAgentYieldEarned, (10e6)));

        assertEq(module.agentFeesCharged(address(wallet)), 500_000);
        assertEq(module.getFeesOwed(address(wallet)), 500_000);
    }

    function testFeeModulesAreAddOnlyAndRatesUseEachTypeMaximum() public {
        vm.startPrank(admin);
        module.setPlanRate(1, VAULT_FEE, 2_000);
        module.setPlanRate(1, BORROW_FEE, 500);
        vm.expectRevert(InvalidFeeRate.selector);
        module.setPlanRate(1, BORROW_FEE, 501);
        bytes32 unknownFeeType = keccak256("unknown");
        vm.expectRevert(abi.encodeWithSelector(UnknownFeeType.selector, unknownFeeType));
        module.setPlanRate(1, unknownFeeType, 0);

        YieldSeekerBorrowFeeModule replacement = new YieldSeekerBorrowFeeModule(module, 500);
        vm.expectRevert(abi.encodeWithSelector(FeeModuleAlreadySet.selector, BORROW_FEE));
        module.addFeeModule(BORROW_FEE, replacement);
        vm.stopPrank();
    }
}

contract FeeTrackerPlansTest is Test {
    address internal admin = makeAddr("admin");
    address internal planManager = makeAddr("planManager");
    address internal collector = makeAddr("collector");
    address internal ownerA = makeAddr("ownerA");
    address internal ownerB = makeAddr("ownerB");

    MockERC20 internal baseAsset;
    MockERC20 internal rewardToken;
    MockFeeWallet internal walletA;
    MockFeeWallet internal walletB;
    YieldSeekerFeeTracker internal module;
    address internal vault = makeAddr("vault");

    function setUp() public {
        baseAsset = new MockERC20("Base", "BASE");
        rewardToken = new MockERC20("Reward", "RWD");
        walletA = new MockFeeWallet(ownerA, baseAsset);
        walletB = new MockFeeWallet(ownerB, baseAsset);
        module = new YieldSeekerFeeTracker(admin, planManager, collector, 2_000, 1_000);

        vm.prank(admin);
        module.setPlanRate(1, VAULT_FEE, 500);
        vm.prank(planManager);
        module.assignPlan(ownerA, 1);
    }

    function testShareWithdrawalsChargeEachOwnersRateOnlyOnProfit() public {
        _recordShareDeposit(walletA, 1_000e6, 1_000e18);
        _recordShareDeposit(walletB, 1_000e6, 1_000e18);

        walletA.execute(address(module), abi.encodeCall(module.recordAgentVaultShareWithdraw, (vault, 1_000e18, 1_100e6)));
        walletB.execute(address(module), abi.encodeCall(module.recordAgentVaultShareWithdraw, (vault, 1_000e18, 1_100e6)));

        assertEq(module.agentFeesCharged(address(walletA)), 5e6);
        assertEq(module.agentFeesCharged(address(walletB)), 10e6);

        MockFeeWallet noProfitWallet = new MockFeeWallet(makeAddr("noProfitOwner"), baseAsset);
        _recordShareDeposit(noProfitWallet, 1_000e6, 1_000e18);
        noProfitWallet.execute(address(module), abi.encodeCall(module.recordAgentVaultShareWithdraw, (vault, 1_000e18, 900e6)));
        assertEq(module.agentFeesCharged(address(noProfitWallet)), 0);
    }

    function testAssetWithdrawalsChargeEachOwnersRateOnlyOnProfit() public {
        _recordShareDeposit(walletA, 1_000e6, 1_000e18);
        _recordShareDeposit(walletB, 1_000e6, 1_000e18);

        walletA.execute(address(module), abi.encodeCall(module.recordAgentVaultAssetWithdraw, (vault, 1_100e6, 1_100e6, 1e18)));
        walletB.execute(address(module), abi.encodeCall(module.recordAgentVaultAssetWithdraw, (vault, 1_100e6, 1_100e6, 1e18)));

        assertEq(module.agentFeesCharged(address(walletA)), 5e6);
        assertEq(module.agentFeesCharged(address(walletB)), 10e6);
    }

    function testYieldTokenFeesConvertWhenSwappedWithoutBeingChargedAgain() public {
        walletB.execute(address(module), abi.encodeCall(module.recordAgentYieldTokenEarned, (address(rewardToken), 100e6)));
        assertEq(module.getAgentYieldTokenFeesOwed(address(walletB), address(rewardToken)), 10e6);

        walletB.execute(address(module), abi.encodeCall(module.recordAgentTokenSwap, (address(rewardToken), 5e6, 5e6)));
        assertEq(module.getAgentYieldTokenFeesOwed(address(walletB), address(rewardToken)), 5e6);
        assertEq(module.agentFeesCharged(address(walletB)), 5e6);

        walletB.execute(address(module), abi.encodeCall(module.recordAgentTokenSwap, (address(rewardToken), 95e6, 95e6)));
        assertEq(module.getAgentYieldTokenFeesOwed(address(walletB), address(rewardToken)), 0);
        assertEq(module.agentFeesCharged(address(walletB)), 10e6);
    }

    function testFeePaymentReducesOwedAndOnlyBaseAssetIsWithdrawable() public {
        walletA.execute(address(module), abi.encodeCall(module.recordAgentYieldEarned, (100e6)));

        assertEq(module.getFeesOwed(address(walletA)), 5e6);
        (bool baseAllowed, uint256 baseReserved) = module.withdrawReserve(address(walletA), address(baseAsset));
        (bool rewardAllowed,) = module.withdrawReserve(address(walletA), address(rewardToken));
        assertTrue(baseAllowed);
        assertEq(baseReserved, 5e6);
        assertFalse(rewardAllowed);

        walletA.execute(address(module), abi.encodeCall(module.recordFeePaid, (2e6)));
        assertEq(module.agentFeesPaid(address(walletA)), 2e6);
        (, baseReserved) = module.withdrawReserve(address(walletA), address(baseAsset));
        assertEq(baseReserved, 3e6);

        walletA.execute(address(module), abi.encodeCall(module.recordFeePaid, (10e6)));
        assertEq(module.agentFeesPaid(address(walletA)), 12e6);
        assertEq(module.getFeesOwed(address(walletA)), 0);
    }

    function _recordShareDeposit(MockFeeWallet wallet, uint256 assets, uint256 shares) internal {
        wallet.execute(address(module), abi.encodeCall(module.recordAgentVaultShareDeposit, (vault, assets, shares)));
    }
}
