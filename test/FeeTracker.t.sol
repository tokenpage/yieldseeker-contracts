// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerErrors} from "../src/Errors.sol";
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
        vm.expectRevert(YieldSeekerErrors.ZeroAddress.selector);
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
        vm.expectRevert(YieldSeekerErrors.ZeroAddress.selector);
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
     * @notice Test proportional cost basis accounting with a loss scenario
     * @dev With proportional cost basis, losses are NOT carried forward to remaining shares.
     *      Each withdrawal's profit/loss is calculated independently based on its proportional cost.
     *
     * Scenario:
     * 1. Deposit 100 assets → receive 100 shares (costBasis=100)
     * 2. Withdraw 50 shares → receive 40 assets (10 asset loss on this withdrawal)
     * 3. Withdraw 50 shares → receive 60 assets (10 asset profit on this withdrawal)
     * Total: Deposited 100, withdrew 100 (break-even)
     *
     * With proportional cost basis:
     * - Withdrawal 1: proportionalCost=50, assets=40, loss=10 (no fee)
     * - Withdrawal 2: proportionalCost=50, assets=60, profit=10 (fee=1)
     * - Net result: Break-even overall, but fees charged on second withdrawal's profit
     *
     * This is CORRECT behavior - we charge fees on realized profits per withdrawal.
     */
    function test_ProportionalCostBasis_LossScenario() public {
        vm.startPrank(wallet1);

        // Step 1: Deposit 100 assets for 100 shares
        tracker.recordAgentVaultShareDeposit(vault1, 100e6, 100e18);
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 100e6);
        assertEq(tracker.agentVaultShares(wallet1, vault1), 100e18);
        assertEq(tracker.agentFeesCharged(wallet1), 0);

        // Step 2: Withdraw 50 shares, receive 40 assets
        // proportionalCost = (100 * 50) / 100 = 50
        // loss = 10 (no fee charged)
        tracker.recordAgentVaultShareWithdraw(vault1, 50e18, 40e6);
        // remainingCostBasis = 100 - 50 = 50 (proportional cost deducted)
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 50e6, "Cost basis reduced by proportional cost");
        assertEq(tracker.agentVaultShares(wallet1, vault1), 50e18);
        assertEq(tracker.agentFeesCharged(wallet1), 0, "No fees on loss");

        // Step 3: Withdraw remaining 50 shares, receive 60 assets
        // proportionalCost = (50 * 50) / 50 = 50
        // profit = 60 - 50 = 10
        // fee = 10 * 10% = 1
        tracker.recordAgentVaultShareWithdraw(vault1, 50e18, 60e6);
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 0);
        assertEq(tracker.agentVaultShares(wallet1, vault1), 0);
        // Fee charged on second withdrawal's realized profit
        assertEq(tracker.agentFeesCharged(wallet1), 1e6, "Fee on second withdrawal profit");

        vm.stopPrank();
    }

    /**
     * @notice Test proportional cost basis with profit after loss
     * @dev Verifies fees are charged correctly on each withdrawal's realized profit
     */
    function test_ProportionalCostBasis_ProfitAfterLoss() public {
        vm.startPrank(wallet1);

        // Deposit 100 assets for 100 shares
        tracker.recordAgentVaultShareDeposit(vault1, 100e6, 100e18);

        // Withdraw 50 shares at loss: receive 40 assets
        // proportionalCost = (100 * 50) / 100 = 50
        // loss = 10 (no fee)
        tracker.recordAgentVaultShareWithdraw(vault1, 50e18, 40e6);
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 50e6); // 100 - 50 (proportional)
        assertEq(tracker.agentFeesCharged(wallet1), 0);

        // Withdraw remaining 50 shares at profit: receive 70 assets
        // proportionalCost = (50 * 50) / 50 = 50
        // profit = 70 - 50 = 20
        // fee = 20 * 10% = 2
        tracker.recordAgentVaultShareWithdraw(vault1, 50e18, 70e6);
        // Net: Deposited 100, Withdrew 40+70=110, Net profit 10
        // But we charge on realized profit of 20 from second withdrawal
        assertEq(tracker.agentFeesCharged(wallet1), 2e6, "Fee on second withdrawal's 20 profit");

        vm.stopPrank();
    }

    /**
     * @notice Test multiple partial withdrawals with proportional cost basis
     * @dev Verifies that proportional cost basis is consistent across multiple withdrawals
     */
    function test_ProportionalCostBasis_MultiplePartialWithdrawals() public {
        vm.startPrank(wallet1);

        // Deposit 100 assets for 100 shares
        tracker.recordAgentVaultShareDeposit(vault1, 100e6, 100e18);

        // First withdrawal: 50 shares → 40 assets
        // proportionalCost = (100 * 50) / 100 = 50
        // loss = 10 (no fee)
        tracker.recordAgentVaultShareWithdraw(vault1, 50e18, 40e6);
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 50e6); // 100 - 50
        assertEq(tracker.agentVaultShares(wallet1, vault1), 50e18);
        assertEq(tracker.agentFeesCharged(wallet1), 0);

        // Second withdrawal: 25 shares → 35 assets
        // proportionalCost = (50 * 25) / 50 = 25
        // profit = 35 - 25 = 10
        // fee = 10 * 10% = 1
        tracker.recordAgentVaultShareWithdraw(vault1, 25e18, 35e6);
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 25e6); // 50 - 25
        assertEq(tracker.agentVaultShares(wallet1, vault1), 25e18);
        assertEq(tracker.agentFeesCharged(wallet1), 1e6); // 10% of 10

        // Third withdrawal: 25 shares → 25 assets
        // proportionalCost = (25 * 25) / 25 = 25
        // break-even (no fee)
        tracker.recordAgentVaultShareWithdraw(vault1, 25e18, 25e6);
        // Net total: Deposited 100, withdrew 40+35+25=100 → break-even overall
        // Total fees: 1 (from second withdrawal only)
        assertEq(tracker.agentFeesCharged(wallet1), 1e6, "Total fees only from second withdrawal");

        vm.stopPrank();
    }

    /**
     * @notice Regression test for audit finding: Fee overcharging due to inconsistent cost-basis accounting
     * @dev This is the EXACT scenario described by the auditor:
     *      1. Deposit 1000 baseAsset → 1000 shares
     *      2. Share price doubles (500 shares = 1000 baseAsset)
     *      3. Withdraw 500 shares → 1000 baseAsset (profit=500)
     *      4. Withdraw 500 shares → 1000 baseAsset (should also be profit=500)
     *
     * Expected: Total fees on 1000 profit (500+500)
     * Bug would have: Total fees on 1500 (500 + 1000) due to cost basis being zeroed
     */
    function test_AuditorScenario_MultipleWithdrawals_ProportionalCostBasis() public {
        vm.startPrank(wallet1);

        // Step 1: Deposit 1000 baseAsset → 1000 shares
        tracker.recordAgentVaultShareDeposit(vault1, 1000e6, 1000e18);
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 1000e6);
        assertEq(tracker.agentVaultShares(wallet1, vault1), 1000e18);

        // Step 2: Share price doubles - 500 shares now worth 1000 baseAsset
        // First withdrawal: 500 shares → 1000 baseAsset
        tracker.recordAgentVaultShareWithdraw(vault1, 500e18, 1000e6);

        // Verify profit calculation:
        // proportionalCost = (1000 * 500) / 1000 = 500
        // profit = 1000 - 500 = 500
        // fee = 500 * 10% = 50
        assertEq(tracker.agentFeesCharged(wallet1), 50e6, "First withdrawal: 10% fee on 500 profit");

        // Verify remaining cost basis uses proportional cost:
        // remainingCostBasis = 1000 - 500 = 500 (NOT 1000 - 1000 = 0)
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 500e6, "Cost basis should be 500, not 0");
        assertEq(tracker.agentVaultShares(wallet1, vault1), 500e18);

        // Step 3: Second withdrawal: 500 shares → 1000 baseAsset
        tracker.recordAgentVaultShareWithdraw(vault1, 500e18, 1000e6);

        // Verify profit calculation:
        // proportionalCost = (500 * 500) / 500 = 500
        // profit = 1000 - 500 = 500 (NOT 1000 - 0 = 1000)
        // fee = 500 * 10% = 50
        assertEq(tracker.agentFeesCharged(wallet1), 100e6, "Total fees: 10% on 1000 total profit");

        // Final state
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 0);
        assertEq(tracker.agentVaultShares(wallet1, vault1), 0);

        vm.stopPrank();
    }

    /**
     * @notice Test that verifies fees are never charged on principal
     * @dev Extreme case: multiple withdrawals with varying profits
     *      Total deposited: 1000, Total profit: 200, Total withdrawn: 1200
     *      Expected fees: 10% of 200 = 20
     */
    function test_FeesOnlyOnProfit_NeverOnPrincipal() public {
        vm.startPrank(wallet1);

        // Deposit 1000 → 1000 shares
        tracker.recordAgentVaultShareDeposit(vault1, 1000e6, 1000e18);

        // Withdraw 1: 250 shares → 300 (profit=50)
        // proportionalCost = (1000 * 250) / 1000 = 250
        // profit = 300 - 250 = 50, fee = 5
        tracker.recordAgentVaultShareWithdraw(vault1, 250e18, 300e6);
        assertEq(tracker.agentFeesCharged(wallet1), 5e6);
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 750e6); // 1000 - 250

        // Withdraw 2: 250 shares → 300 (profit=50)
        // proportionalCost = (750 * 250) / 750 = 250
        // profit = 300 - 250 = 50, fee = 5
        tracker.recordAgentVaultShareWithdraw(vault1, 250e18, 300e6);
        assertEq(tracker.agentFeesCharged(wallet1), 10e6);
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 500e6); // 750 - 250

        // Withdraw 3: 250 shares → 300 (profit=50)
        // proportionalCost = (500 * 250) / 500 = 250
        // profit = 300 - 250 = 50, fee = 5
        tracker.recordAgentVaultShareWithdraw(vault1, 250e18, 300e6);
        assertEq(tracker.agentFeesCharged(wallet1), 15e6);
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 250e6); // 500 - 250

        // Withdraw 4: 250 shares → 300 (profit=50)
        // proportionalCost = (250 * 250) / 250 = 250
        // profit = 300 - 250 = 50, fee = 5
        tracker.recordAgentVaultShareWithdraw(vault1, 250e18, 300e6);
        assertEq(tracker.agentFeesCharged(wallet1), 20e6);
        assertEq(tracker.agentVaultCostBasis(wallet1, vault1), 0); // 250 - 250

        // Total: Deposited 1000, Withdrew 1200, Profit 200, Fees 20 (10% of profit)
        vm.stopPrank();
    }
}

// Note: Integration tests that involve vault position tracking have been removed
// as position tracking is now handled by AgentWallet, not FeeTracker.
// See AgentWallet tests for vault position tracking integration tests.
