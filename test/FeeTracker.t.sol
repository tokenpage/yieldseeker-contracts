// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker as FeeTracker} from "../src/FeeTracker.sol";
import {Test} from "forge-std/Test.sol";

contract FeeTrackerTest is Test {
    FeeTracker public tracker;
    FeeTracker public trackerImpl;

    address public admin = address(0x1);
    address public wallet1 = address(0x100);
    address public wallet2 = address(0x200);
    address public vault1 = address(0x1000);
    address public vault2 = address(0x2000);
    address public feeCollector = address(0x9999);

    function setUp() public {
        tracker = new FeeTracker(admin);
        vm.prank(admin);
        tracker.setFeeConfig(1000, feeCollector); // 10% fee
    }

    // ============ Initialization Tests ============

    function test_Initialize() public view {
        assertEq(tracker.feeRateBps(), 1000);
        assertEq(tracker.feeCollector(), feeCollector);
        assertTrue(tracker.hasRole(tracker.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Initialize_RevertsOnZeroAdmin() public {
        vm.expectRevert(FeeTracker.ZeroAddress.selector);
        new FeeTracker(address(0));
    }

    // ============ Fee Config Tests ============

    function test_SetFeeConfig() public {
        vm.prank(admin);
        tracker.setFeeConfig(2000, address(0x8888));
        assertEq(tracker.feeRateBps(), 2000);
        assertEq(tracker.feeCollector(), address(0x8888));
    }

    function test_SetFeeConfig_RevertsOnExcessiveRate() public {
        vm.prank(admin);
        vm.expectRevert(FeeTracker.InvalidFeeRate.selector);
        tracker.setFeeConfig(5001, feeCollector);
    }

    function test_SetFeeConfig_RevertsOnZeroCollector() public {
        vm.prank(admin);
        vm.expectRevert(FeeTracker.ZeroAddress.selector);
        tracker.setFeeConfig(1000, address(0));
    }

    function test_SetFeeConfig_OnlyAdmin() public {
        vm.prank(wallet1);
        vm.expectRevert();
        tracker.setFeeConfig(500, feeCollector);
    }

    // ============ Yield Recording Tests ============

    function test_RecordYield() public {
        vm.prank(wallet1);
        tracker.recordYield(100e6);
        assertEq(tracker.agentFeesCharged(wallet1), 10e6); // 10% of 100e6
    }

    function test_RecordYield_Accumulates() public {
        vm.startPrank(wallet1);
        tracker.recordYield(100e6);
        tracker.recordYield(50e6);
        vm.stopPrank();
        assertEq(tracker.agentFeesCharged(wallet1), 15e6); // 10% of 150e6
    }

    function test_RecordYield_IsolatedPerWallet() public {
        vm.prank(wallet1);
        tracker.recordYield(100e6);
        vm.prank(wallet2);
        tracker.recordYield(50e6);
        assertEq(tracker.agentFeesCharged(wallet1), 10e6);
        assertEq(tracker.agentFeesCharged(wallet2), 5e6);
    }

    // ============ Fee Payment Tests ============

    function test_RecordFeePaid() public {
        vm.startPrank(wallet1);
        tracker.recordYield(100e6);
        tracker.recordFeePaid(5e6);
        vm.stopPrank();
        assertEq(tracker.agentFeesPaid(wallet1), 5e6);
        assertEq(tracker.getFeesOwed(wallet1), 5e6); // 10e6 - 5e6
    }

    function test_RecordFeePaid_FullPayment() public {
        vm.startPrank(wallet1);
        tracker.recordYield(100e6);
        tracker.recordFeePaid(10e6);
        vm.stopPrank();
        assertEq(tracker.agentFeesPaid(wallet1), 10e6);
        assertEq(tracker.getFeesOwed(wallet1), 0);
    }

    // ============ Fee Calculation Tests ============

    function test_GetFeesOwed_NoYield() public view {
        assertEq(tracker.getFeesOwed(wallet1), 0);
    }

    function test_GetFeesOwed_WithYield() public {
        vm.startPrank(wallet1);
        tracker.recordYield(100e6);
        vm.stopPrank();
        uint256 feesOwed = tracker.getFeesOwed(wallet1);
        assertEq(feesOwed, 10e6);
    }

    function test_GetFeesOwed_AfterPartialPayment() public {
        vm.startPrank(wallet1);
        tracker.recordYield(100e6);
        tracker.recordFeePaid(5e6);
        vm.stopPrank();
        uint256 feesOwed = tracker.getFeesOwed(wallet1);
        assertEq(feesOwed, 5e6); // 10e6 charged - 5e6 paid
    }

    function test_GetFeesOwed_AfterFullPayment() public {
        vm.startPrank(wallet1);
        tracker.recordYield(100e6);
        tracker.recordFeePaid(10e6);
        vm.stopPrank();
        assertEq(tracker.getFeesOwed(wallet1), 0);
    }

    function test_GetFeesOwed_OverpaymentReturnsZero() public {
        vm.startPrank(wallet1);
        tracker.recordYield(100e6);
        tracker.recordFeePaid(15e6);
        vm.stopPrank();
        assertEq(tracker.getFeesOwed(wallet1), 0);
    }

    // ============ Fee Rate Change Tests ============

    function test_FeeRateChange_DoesNotAffectOutstanding() public {
        vm.prank(wallet1);
        tracker.recordYield(100e6);
        assertEq(tracker.getFeesOwed(wallet1), 10e6);
        vm.prank(admin);
        tracker.setFeeConfig(2000, feeCollector);
        assertEq(tracker.getFeesOwed(wallet1), 10e6); // Still 10e6 because it was recorded at 10%
    }

    // ============ Wallet Stats Tests ============

    function test_GetWalletStats() public {
        vm.startPrank(wallet1);
        tracker.recordYield(200e6);
        tracker.recordFeePaid(10e6);
        vm.stopPrank();
        (uint256 agentFeesCharged_, uint256 agentFeesPaid_, uint256 owed) = tracker.getWalletStats(wallet1);
        assertEq(agentFeesCharged_, 20e6);
        assertEq(agentFeesPaid_, 10e6);
        assertEq(owed, 10e6);
    }

    // ============ Complex Scenario Tests ============

    function test_ComplexScenario_MultipleYields() public {
        vm.startPrank(wallet1);
        tracker.recordYield(100e6);
        tracker.recordYield(50e6);
        tracker.recordYield(75e6);
        vm.stopPrank();
        assertEq(tracker.agentFeesCharged(wallet1), 22500000); // 10% of 225e6
        assertEq(tracker.getFeesOwed(wallet1), 22500000);
    }

    function test_ComplexScenario_YieldsAndPayments() public {
        vm.startPrank(wallet1);
        tracker.recordYield(100e6);
        tracker.recordFeePaid(5e6);
        tracker.recordYield(50e6);
        tracker.recordFeePaid(5e6);
        vm.stopPrank();
        assertEq(tracker.agentFeesCharged(wallet1), 15e6); // 10e6 + 5e6
        assertEq(tracker.agentFeesPaid(wallet1), 10e6);
        assertEq(tracker.getFeesOwed(wallet1), 5e6);
    }

    // ============ Vault Position Tracking Tests ============

    /**
     * @notice Test that realized losses adjust cost basis and prevent fees on loss recovery
     * @dev This test verifies the fix for the audit finding:
     *      "FeeLedger does not adjust remaining cost basis on realized losses"
     *
     * Scenario:
     * 1. Deposit 100 assets → receive 100 shares (costBasis=100)
     * 2. Withdraw 50 shares → receive 40 assets (10 asset loss)
     * 3. Withdraw 50 shares → receive 60 assets (recovery)
     * Total: Deposited 100, withdrew 100 (break-even)
     *
     * Expected: No fees charged (net P&L is zero)
     * Bug would have: Charged fees on "10 yield" in step 3
     */
    function test_RealizedLoss_AdjustsCostBasis_NoFeesOnRecovery() public {
        vm.startPrank(wallet1);

        // Step 1: Deposit 100 assets for 100 shares
        tracker.recordAgentVaultShareDeposit(vault1, 100e6, 100e18);
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 100e6);
        assertEq(tracker.agentVaultShares(wallet1, vault1), 100e18);
        assertEq(tracker.agentFeesCharged(wallet1), 0);

        // Step 2: Withdraw 50 shares, receive 40 assets (realized loss of 10)
        tracker.recordAgentVaultShareWithdraw(vault1, 50e18, 40e6);
        // Cost basis should be: 100 - 40 = 60 (adjusted for realized loss)
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 60e6, "Cost basis should be 60 after loss");
        assertEq(tracker.agentVaultShares(wallet1, vault1), 50e18);
        assertEq(tracker.agentFeesCharged(wallet1), 0, "No fees on loss");

        // Step 3: Withdraw remaining 50 shares, receive 60 assets (recovery)
        tracker.recordAgentVaultShareWithdraw(vault1, 50e18, 60e6);
        // Cost basis should be: 60 - 60 = 0
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 0);
        assertEq(tracker.agentVaultShares(wallet1, vault1), 0);
        // Net: Deposited 100, withdrew 40+60=100 → break-even, no fees
        assertEq(tracker.agentFeesCharged(wallet1), 0, "No fees on break-even scenario");

        vm.stopPrank();
    }

    /**
     * @notice Test vault position with profit after loss recovery
     * @dev Ensures fees are only charged on net profit after accounting for losses
     */
    function test_RealizedLoss_FeesOnlyOnNetProfit() public {
        vm.startPrank(wallet1);

        // Deposit 100 assets for 100 shares
        tracker.recordAgentVaultShareDeposit(vault1, 100e6, 100e18);

        // Withdraw 50 shares at loss: receive 40 assets (10 loss)
        tracker.recordAgentVaultShareWithdraw(vault1, 50e18, 40e6);
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 60e6);
        assertEq(tracker.agentFeesCharged(wallet1), 0);

        // Withdraw remaining 50 shares at profit: receive 70 assets (10 gain)
        tracker.recordAgentVaultShareWithdraw(vault1, 50e18, 70e6);
        // Net: Deposited 100, withdrew 40+70=110 → 10 net profit
        // Expected fees: 10% of 10 = 1
        assertEq(tracker.agentFeesCharged(wallet1), 1e6, "Fees only on 10 net profit");

        vm.stopPrank();
    }

    /**
     * @notice Test multiple partial withdrawals with mixed losses and gains
     */
    function test_RealizedLoss_MultiplePartialWithdrawals() public {
        vm.startPrank(wallet1);

        // Deposit 100 assets for 100 shares
        tracker.recordAgentVaultShareDeposit(vault1, 100e6, 100e18);

        // First withdrawal: 50 shares → 40 assets (10 loss)
        tracker.recordAgentVaultShareWithdraw(vault1, 50e18, 40e6);
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 60e6); // 100 - 40
        assertEq(tracker.agentVaultShares(wallet1, vault1), 50e18);
        assertEq(tracker.agentFeesCharged(wallet1), 0);

        // Second withdrawal: 25 shares → 35 assets (profit on this portion)
        // Proportional cost = 60 * 25 / 50 = 30
        // Profit = 35 - 30 = 5
        // Fee = 5 * 10% = 0.5
        tracker.recordAgentVaultShareWithdraw(vault1, 25e18, 35e6);
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 25e6); // 60 - 35
        assertEq(tracker.agentVaultShares(wallet1, vault1), 25e18);
        assertEq(tracker.agentFeesCharged(wallet1), 0.5e6); // 10% of 5

        // Third withdrawal: 25 shares → 25 assets (break-even for this portion)
        tracker.recordAgentVaultShareWithdraw(vault1, 25e18, 25e6);
        // Net total: Deposited 100, withdrew 40+35+25=100 → break-even overall
        // But we already charged fees on the second withdrawal's profit
        assertEq(tracker.agentFeesCharged(wallet1), 0.5e6, "Total fees only from second withdrawal");

        vm.stopPrank();
    }
}

// Note: Integration tests that involve vault position tracking have been removed
// as position tracking is now handled by AgentWallet, not FeeTracker.
// See AgentWallet tests for vault position tracking integration tests.
