// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InvalidFeeRate} from "../../src/FeeTracker.sol";
import {YieldSeekerFeeTracker} from "../../src/FeeTracker.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {MockFeeTracker} from "../mocks/MockFeeTracker.sol";
import {Test} from "forge-std/Test.sol";

/// @title FeeTracker Unit Tests
/// @notice Isolated unit tests for fee calculation logic with complete isolation
contract FeeTrackerTest is Test {
    MockFeeTracker feeTracker;

    address admin = makeAddr("admin");
    address nonAdmin = makeAddr("nonAdmin");
    address collector = makeAddr("collector");
    address agent1 = makeAddr("agent1");
    address agent2 = makeAddr("agent2");

    uint256 constant BASIS_POINTS = 10000;
    uint256 constant DEFAULT_FEE_RATE = 1000; // 10%

    event FeeConfigUpdated(uint256 indexed feeRate, address indexed collector);
    event YieldRecorded(address indexed agent, uint256 yield, uint256 feeAmount);

    function setUp() public {
        vm.prank(admin);
        feeTracker = new MockFeeTracker(DEFAULT_FEE_RATE, collector);
    }

    // ============ Fee Configuration Tests ============

    function test_SetFeeConfig_Success() public {
        uint256 newFeeRate = 500; // 5%
        address newCollector = makeAddr("newCollector");

        vm.expectEmit(true, true, false, false);
        emit FeeConfigUpdated(newFeeRate, newCollector);

        vm.prank(admin);
        feeTracker.setFeeConfig(newFeeRate, newCollector);

        (uint256 feeRate, address feeCollector) = feeTracker.getFeeConfig();
        assertEq(feeRate, newFeeRate);
        assertEq(feeCollector, newCollector);
    }

    function test_SetFeeConfig_OnlyAdmin() public {
        uint256 newFeeRate = 500;
        address newCollector = makeAddr("newCollector");

        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, nonAdmin));
        feeTracker.setFeeConfig(newFeeRate, newCollector);
    }

    function test_SetFeeConfig_ZeroCollector() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        feeTracker.setFeeConfig(500, address(0));
    }

    function test_SetFeeConfig_MaxFeeRate() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(InvalidFeeRate.selector));
        feeTracker.setFeeConfig(BASIS_POINTS + 1, collector); // Over 100%
    }

    function test_GetFeeConfig_Correct() public view {
        (uint256 feeRate, address feeCollector) = feeTracker.getFeeConfig();
        assertEq(feeRate, DEFAULT_FEE_RATE);
        assertEq(feeCollector, collector);
    }

    // ============ Yield Recording Tests ============

    function test_RecordYield_ValidAmount() public {
        uint256 yieldAmount = 1000e6; // 1000 USDC
        uint256 expectedFee = (yieldAmount * DEFAULT_FEE_RATE) / BASIS_POINTS;

        vm.expectEmit(true, false, false, true);
        emit YieldRecorded(agent1, yieldAmount, expectedFee);

        vm.prank(admin);
        feeTracker.recordYield(agent1, yieldAmount);

        uint256 feesOwed = feeTracker.getFeesOwed(agent1);
        assertEq(feesOwed, expectedFee);
    }

    function test_RecordYield_ZeroAmount() public {
        vm.prank(admin);
        feeTracker.recordYield(agent1, 0);

        uint256 feesOwed = feeTracker.getFeesOwed(agent1);
        assertEq(feesOwed, 0);
    }

    function test_RecordYield_OnlyAdmin() public {
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, nonAdmin));
        feeTracker.recordYield(agent1, 1000e6);
    }

    function test_RecordYield_MultipleAgents() public {
        uint256 yield1 = 1000e6;
        uint256 yield2 = 2000e6;

        vm.prank(admin);
        feeTracker.recordYield(agent1, yield1);

        vm.prank(admin);
        feeTracker.recordYield(agent2, yield2);

        uint256 fees1 = feeTracker.getFeesOwed(agent1);
        uint256 fees2 = feeTracker.getFeesOwed(agent2);

        assertEq(fees1, (yield1 * DEFAULT_FEE_RATE) / BASIS_POINTS);
        assertEq(fees2, (yield2 * DEFAULT_FEE_RATE) / BASIS_POINTS);
    }

    function test_RecordYield_Accumulation() public {
        uint256 yield1 = 1000e6;
        uint256 yield2 = 500e6;

        vm.prank(admin);
        feeTracker.recordYield(agent1, yield1);

        vm.prank(admin);
        feeTracker.recordYield(agent1, yield2);

        uint256 totalYield = yield1 + yield2;
        uint256 expectedTotalFees = (totalYield * DEFAULT_FEE_RATE) / BASIS_POINTS;
        uint256 actualFees = feeTracker.getFeesOwed(agent1);

        assertEq(actualFees, expectedTotalFees);
    }

    // ============ Fee Calculation Tests ============

    function test_CalculateFeeAmount_StandardRate() public view {
        uint256 yieldAmount = 1000e6;
        uint256 expectedFee = (yieldAmount * DEFAULT_FEE_RATE) / BASIS_POINTS;

        uint256 actualFee = feeTracker.calculateFeeAmount(yieldAmount);
        assertEq(actualFee, expectedFee);
    }

    function test_CalculateFeeAmount_ZeroFeeRate() public {
        vm.prank(admin);
        feeTracker.setFeeConfig(0, collector);

        uint256 yieldAmount = 1000e6;
        uint256 fee = feeTracker.calculateFeeAmount(yieldAmount);
        assertEq(fee, 0);
    }

    function test_CalculateFeeAmount_MaxFeeRate() public {
        vm.prank(admin);
        feeTracker.setFeeConfig(BASIS_POINTS, collector); // 100%

        uint256 yieldAmount = 1000e6;
        uint256 fee = feeTracker.calculateFeeAmount(yieldAmount);
        assertEq(fee, yieldAmount); // All yield goes to fees
    }

    function test_CalculateFeeAmount_RoundingEdgeCases() public view {
        // Test small amounts that might have rounding issues
        uint256 smallYield = 3; // Very small amount
        uint256 fee = feeTracker.calculateFeeAmount(smallYield);

        // With 10% fee rate, fee should be 0 due to rounding down
        uint256 expectedFee = (smallYield * DEFAULT_FEE_RATE) / BASIS_POINTS;
        assertEq(fee, expectedFee);
    }

    // ============ State Management Tests ============

    function test_GetFeesOwed_NewAgent() public view {
        uint256 fees = feeTracker.getFeesOwed(agent1);
        assertEq(fees, 0);
    }

    function test_GetFeesOwed_AfterRecording() public {
        uint256 yieldAmount = 1000e6;

        vm.prank(admin);
        feeTracker.recordYield(agent1, yieldAmount);

        uint256 fees = feeTracker.getFeesOwed(agent1);
        uint256 expectedFee = (yieldAmount * DEFAULT_FEE_RATE) / BASIS_POINTS;
        assertEq(fees, expectedFee);
    }

    function test_AgentFeesTracking_MultipleAgentsIndependent() public {
        uint256 yield1 = 1000e6;
        uint256 yield2 = 2000e6;

        vm.prank(admin);
        feeTracker.recordYield(agent1, yield1);

        vm.prank(admin);
        feeTracker.recordYield(agent2, yield2);

        // Agents should have independent fee tracking
        uint256 fees1 = feeTracker.getFeesOwed(agent1);
        uint256 fees2 = feeTracker.getFeesOwed(agent2);

        assertEq(fees1, (yield1 * DEFAULT_FEE_RATE) / BASIS_POINTS);
        assertEq(fees2, (yield2 * DEFAULT_FEE_RATE) / BASIS_POINTS);
        assertTrue(fees1 != fees2);
    }

    // ============ Edge Cases & Precision Tests ============

    function test_CalculateYield_MaxPrecision() public view {
        // Test maximum precision scenarios
        uint256 maxYield = type(uint256).max / BASIS_POINTS; // Avoid overflow
        uint256 fee = feeTracker.calculateFeeAmount(maxYield);

        uint256 expectedFee = (maxYield * DEFAULT_FEE_RATE) / BASIS_POINTS;
        assertEq(fee, expectedFee);
    }

    function test_FeeConfig_UpdateAffectsCalculations() public {
        uint256 yieldAmount = 1000e6;

        // Record with initial fee rate
        vm.prank(admin);
        feeTracker.recordYield(agent1, yieldAmount);

        uint256 initialFees = feeTracker.getFeesOwed(agent1);

        // Change fee rate and record more yield
        vm.prank(admin);
        feeTracker.setFeeConfig(2000, collector); // 20%

        vm.prank(admin);
        feeTracker.recordYield(agent1, yieldAmount);

        uint256 finalFees = feeTracker.getFeesOwed(agent1);

        // New fees should use new rate
        uint256 expectedNewFees = (yieldAmount * 2000) / BASIS_POINTS;
        uint256 expectedTotalFees = initialFees + expectedNewFees;

        assertEq(finalFees, expectedTotalFees);
    }

    // ============ Vault Position Math Tests ============

    function test_VaultPositionMath_BasicDeposit() public {
        address vault = makeAddr("vault");
        uint256 assetsDeposited = 1000e6;
        uint256 sharesReceived = 1000e18;

        vm.prank(admin);
        feeTracker.recordAgentVaultShareDeposit(agent1, vault, assetsDeposited, sharesReceived);

        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(agent1, vault);
        assertEq(costBasis, assetsDeposited);
        assertEq(shares, sharesReceived);
    }

    function test_VaultPositionMath_WithdrawProfit() public {
        address vault = makeAddr("vault");
        uint256 assetsDeposited = 1000e6;
        uint256 sharesReceived = 1000e18;

        // Deposit
        vm.prank(admin);
        feeTracker.recordAgentVaultShareDeposit(agent1, vault, assetsDeposited, sharesReceived);

        // Withdraw with profit (received more than deposited)
        uint256 sharesSpent = 1000e18;
        uint256 assetsReceived = 1100e6; // 100 USDC profit

        uint256 initialFees = feeTracker.getFeesOwed(agent1);

        vm.prank(admin);
        feeTracker.recordAgentVaultShareWithdraw(agent1, vault, sharesSpent, assetsReceived);

        uint256 finalFees = feeTracker.getFeesOwed(agent1);
        uint256 profit = assetsReceived - assetsDeposited;
        uint256 expectedFee = (profit * DEFAULT_FEE_RATE) / BASIS_POINTS;

        assertEq(finalFees - initialFees, expectedFee);
    }

    function test_VaultPositionMath_WithdrawLoss() public {
        address vault = makeAddr("vault");
        uint256 assetsDeposited = 1000e6;
        uint256 sharesReceived = 1000e18;

        // Deposit
        vm.prank(admin);
        feeTracker.recordAgentVaultShareDeposit(agent1, vault, assetsDeposited, sharesReceived);

        // Withdraw with loss (received less than deposited)
        uint256 sharesSpent = 1000e18;
        uint256 assetsReceived = 900e6; // 100 USDC loss

        uint256 initialFees = feeTracker.getFeesOwed(agent1);

        vm.prank(admin);
        feeTracker.recordAgentVaultShareWithdraw(agent1, vault, sharesSpent, assetsReceived);

        uint256 finalFees = feeTracker.getFeesOwed(agent1);

        // No additional fees should be charged on a loss
        assertEq(finalFees, initialFees);
    }

    function test_VaultPositionMath_PartialWithdraw() public {
        address vault = makeAddr("vault");
        uint256 assetsDeposited = 1000e6;
        uint256 sharesReceived = 1000e18;

        // Deposit
        vm.prank(admin);
        feeTracker.recordAgentVaultShareDeposit(agent1, vault, assetsDeposited, sharesReceived);

        // Partial withdraw (50%)
        uint256 sharesSpent = 500e18;
        uint256 assetsReceived = 550e6; // 50 USDC profit on half

        vm.prank(admin);
        feeTracker.recordAgentVaultShareWithdraw(agent1, vault, sharesSpent, assetsReceived);

        // Check remaining position
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(agent1, vault);
        assertEq(costBasis, 500e6); // Half of original cost basis
        assertEq(shares, 500e18); // Half of original shares
    }

    function test_VaultPositionMath_ZeroInitialDeposit() public {
        address vault = makeAddr("vault");

        // Try to withdraw from vault with no position
        uint256 sharesSpent = 100e18;
        uint256 assetsReceived = 100e6;

        uint256 initialFees = feeTracker.getFeesOwed(agent1);

        vm.prank(admin);
        feeTracker.recordAgentVaultShareWithdraw(agent1, vault, sharesSpent, assetsReceived);

        uint256 finalFees = feeTracker.getFeesOwed(agent1);

        // Should not revert, just early return with no fee changes
        assertEq(finalFees, initialFees);
    }

    function test_VaultPositionMath_MaxPrecision() public {
        address vault = makeAddr("vault");

        // Use very large numbers to test precision
        uint256 assetsDeposited = type(uint128).max;
        uint256 sharesReceived = type(uint128).max;

        vm.prank(admin);
        feeTracker.recordAgentVaultShareDeposit(agent1, vault, assetsDeposited, sharesReceived);

        // Withdraw all with slight profit
        uint256 sharesSpent = sharesReceived;
        uint256 assetsReceived = assetsDeposited + 1000e6;

        vm.prank(admin);
        feeTracker.recordAgentVaultShareWithdraw(agent1, vault, sharesSpent, assetsReceived);

        // Should handle large numbers without overflow
        uint256 fees = feeTracker.getFeesOwed(agent1);
        uint256 profit = assetsReceived - assetsDeposited;
        uint256 expectedFee = (profit * DEFAULT_FEE_RATE) / BASIS_POINTS;
        assertEq(fees, expectedFee);
    }

    // ============ Multi-Agent State Management Tests ============

    function test_StateManagement_MultipleAgentsIndependentVaults() public {
        address vault = makeAddr("vault");
        uint256 assets1 = 1000e6;
        uint256 shares1 = 1000e18;
        uint256 assets2 = 2000e6;
        uint256 shares2 = 2000e18;

        // Agent1 deposits
        vm.prank(admin);
        feeTracker.recordAgentVaultShareDeposit(agent1, vault, assets1, shares1);

        // Agent2 deposits
        vm.prank(admin);
        feeTracker.recordAgentVaultShareDeposit(agent2, vault, assets2, shares2);

        // Check positions are independent
        (uint256 costBasis1, uint256 sharesHeld1) = feeTracker.getAgentVaultPosition(agent1, vault);
        (uint256 costBasis2, uint256 sharesHeld2) = feeTracker.getAgentVaultPosition(agent2, vault);

        assertEq(costBasis1, assets1);
        assertEq(sharesHeld1, shares1);
        assertEq(costBasis2, assets2);
        assertEq(sharesHeld2, shares2);
    }

    function test_StateManagement_MultipleVaultsPerAgent() public {
        address vault1 = makeAddr("vault1");
        address vault2 = makeAddr("vault2");

        // Agent deposits to vault1
        vm.prank(admin);
        feeTracker.recordAgentVaultShareDeposit(agent1, vault1, 1000e6, 1000e18);

        // Agent deposits to vault2
        vm.prank(admin);
        feeTracker.recordAgentVaultShareDeposit(agent1, vault2, 2000e6, 2000e18);

        // Check both positions exist independently
        (uint256 cost1, uint256 shares1) = feeTracker.getAgentVaultPosition(agent1, vault1);
        (uint256 cost2, uint256 shares2) = feeTracker.getAgentVaultPosition(agent1, vault2);

        assertEq(cost1, 1000e6);
        assertEq(shares1, 1000e18);
        assertEq(cost2, 2000e6);
        assertEq(shares2, 2000e18);
    }

    function test_StateManagement_AccumulatedDeposits() public {
        address vault = makeAddr("vault");

        // First deposit
        vm.prank(admin);
        feeTracker.recordAgentVaultShareDeposit(agent1, vault, 1000e6, 1000e18);

        // Second deposit
        vm.prank(admin);
        feeTracker.recordAgentVaultShareDeposit(agent1, vault, 500e6, 500e18);

        // Should accumulate
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(agent1, vault);
        assertEq(costBasis, 1500e6);
        assertEq(shares, 1500e18);
    }

    // ============ Yield Token Fee Tracking Tests ============

    function test_YieldTokenFees_RecordEarnings() public {
        address yieldToken = makeAddr("yieldToken");
        uint256 yieldAmount = 100e18;

        vm.prank(admin);
        feeTracker.recordAgentYieldTokenEarned(agent1, yieldToken, yieldAmount);

        uint256 feesOwed = feeTracker.getAgentYieldTokenFeesOwed(agent1, yieldToken);
        uint256 expectedFees = (yieldAmount * DEFAULT_FEE_RATE) / BASIS_POINTS;
        assertEq(feesOwed, expectedFees);
    }

    function test_YieldTokenFees_SwapToBaseAsset() public {
        address yieldToken = makeAddr("yieldToken");
        uint256 yieldAmount = 100e18;

        // Record yield in token
        vm.prank(admin);
        feeTracker.recordAgentYieldTokenEarned(agent1, yieldToken, yieldAmount);

        // Swap all yield tokens to base asset
        uint256 baseAssetReceived = 100e6;
        uint256 initialBaseFees = feeTracker.getFeesOwed(agent1);

        vm.prank(admin);
        feeTracker.recordAgentTokenSwap(agent1, yieldToken, yieldAmount, baseAssetReceived);

        // Token fees should be converted to base asset fees
        uint256 tokenFees = feeTracker.getAgentYieldTokenFeesOwed(agent1, yieldToken);
        assertEq(tokenFees, 0); // Token fees should be cleared

        uint256 finalBaseFees = feeTracker.getFeesOwed(agent1);
        uint256 expectedFee = (yieldAmount * DEFAULT_FEE_RATE) / BASIS_POINTS;
        uint256 feeInBaseAsset = (baseAssetReceived * expectedFee) / yieldAmount;
        assertEq(finalBaseFees - initialBaseFees, feeInBaseAsset);
    }

    function test_YieldTokenFees_PartialSwap() public {
        address yieldToken = makeAddr("yieldToken");
        uint256 yieldAmount = 100e18;

        // Record yield in token (creates 10e18 fee at 10% rate)
        vm.prank(admin);
        feeTracker.recordAgentYieldTokenEarned(agent1, yieldToken, yieldAmount);

        uint256 initialTokenFees = feeTracker.getAgentYieldTokenFeesOwed(agent1, yieldToken);
        assertEq(initialTokenFees, 10e18); // 10% of 100e18

        // Swap only 5e18 tokens (less than the 10e18 fee owed)
        uint256 swapAmount = 5e18;
        uint256 baseAssetReceived = 5e6;

        vm.prank(admin);
        feeTracker.recordAgentTokenSwap(agent1, yieldToken, swapAmount, baseAssetReceived);

        // Since we swapped 5e18 and the fee owed was 10e18, we should have 5e18 remaining
        uint256 remainingTokenFees = feeTracker.getAgentYieldTokenFeesOwed(agent1, yieldToken);
        assertEq(remainingTokenFees, 5e18);
    }

    function test_YieldTokenFees_SwapMoreThanFeeOwed() public {
        address yieldToken = makeAddr("yieldToken");
        uint256 yieldAmount = 100e18;

        // Record yield in token (creates 10e18 fee at 10% rate)
        vm.prank(admin);
        feeTracker.recordAgentYieldTokenEarned(agent1, yieldToken, yieldAmount);

        uint256 initialTokenFees = feeTracker.getAgentYieldTokenFeesOwed(agent1, yieldToken);
        assertEq(initialTokenFees, 10e18);

        // Swap 50e18 (more than the 10e18 fee owed)
        uint256 swapAmount = 50e18;
        uint256 baseAssetReceived = 50e6;

        vm.prank(admin);
        feeTracker.recordAgentTokenSwap(agent1, yieldToken, swapAmount, baseAssetReceived);

        // All fee tokens should be cleared since we swapped more than fee owed
        uint256 remainingTokenFees = feeTracker.getAgentYieldTokenFeesOwed(agent1, yieldToken);
        assertEq(remainingTokenFees, 0);
    }

    // ============ Access Control Tests ============

    function test_AccessControl_VaultDeposit_OnlyAdmin() public {
        address vault = makeAddr("vault");

        // Non-admin cannot record vault deposits
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, nonAdmin));
        feeTracker.recordAgentVaultShareDeposit(agent1, vault, 1000e6, 1000e18);
    }

    function test_AccessControl_VaultWithdraw_OnlyAdmin() public {
        address vault = makeAddr("vault");

        // Setup position
        vm.prank(admin);
        feeTracker.recordAgentVaultShareDeposit(agent1, vault, 1000e6, 1000e18);

        // Non-admin cannot record withdrawals
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, nonAdmin));
        feeTracker.recordAgentVaultShareWithdraw(agent1, vault, 500e18, 550e6);
    }

    function test_AccessControl_AdminOnly_SetFeeConfig() public {
        // Already tested in earlier tests, but adding explicit security test
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, nonAdmin));
        feeTracker.setFeeConfig(500, collector);
    }

    // ============ Edge Case Tests ============

    function test_TokenSwap_ZeroSwappedAmount_DoesNotRevert() public {
        address yieldToken = makeAddr("yieldToken");
        uint256 yieldAmount = 100e18;

        // Record yield in token
        vm.prank(admin);
        feeTracker.recordAgentYieldTokenEarned(agent1, yieldToken, yieldAmount);

        // Verify fees are tracked
        uint256 tokenFees = feeTracker.getAgentYieldTokenFeesOwed(agent1, yieldToken);
        uint256 expectedFee = (yieldAmount * DEFAULT_FEE_RATE) / BASIS_POINTS;
        assertEq(tokenFees, expectedFee);

        // Attempt swap with zero swappedAmount (e.g., paused/broken token)
        // This should not revert, allowing transaction to proceed
        vm.prank(admin);
        feeTracker.recordAgentTokenSwap(agent1, yieldToken, 0, 100e6);

        // Token fees should remain unchanged (no fee conversion happened)
        uint256 tokenFeesAfter = feeTracker.getAgentYieldTokenFeesOwed(agent1, yieldToken);
        assertEq(tokenFeesAfter, expectedFee, "Token fees should not change");

        // Base asset fees should not increase
        uint256 baseFees = feeTracker.getFeesOwed(agent1);
        assertEq(baseFees, 0, "No base fees should be charged");
    }
}

/// @title YieldSeekerFeeTracker Integration Tests
/// @notice Tests for the real FeeTracker contract with vault yield token fee scenarios
contract YieldSeekerFeeTrackerTest is Test {
    YieldSeekerFeeTracker feeTracker;

    address admin = makeAddr("admin");
    address collector = makeAddr("collector");
    address agent1 = makeAddr("agent1");

    uint256 constant BASIS_POINTS = 10000;
    uint256 constant DEFAULT_FEE_RATE = 1000; // 10%

    event YieldRecorded(address indexed wallet, uint256 yield, uint256 fee);

    function setUp() public {
        vm.prank(admin);
        feeTracker = new YieldSeekerFeeTracker(admin);
        vm.prank(admin);
        feeTracker.setFeeConfig(DEFAULT_FEE_RATE, collector);
    }

    function test_RecordAgentVaultShareWithdraw_DoubleChargingOnUntrackedSharesWithFeeOwed() public {
        // Scenario: User has tracked shares with fee-owed yield token fees.
        // They withdraw untracked shares (e.g., airdrops) and should not double-charge fees.
        //
        // Setup:
        // - 100 tracked shares at 100e6 USDC cost basis
        // - 10 fee-owed vault share tokens (at 1e18 token = 1 share unit)
        // - Withdraw all 110 shares for 121e6 USDC (10% appreciation)
        //
        // Expected behavior:
        // - Block 1: Charge fee on 10 fee-owed tokens when converting to base asset
        // - Block 2: Charge fee on remaining profit after fee deduction
        // - Should not double-count the fee-owed shares value

        address vault = makeAddr("vault");

        // Step 1: Record initial tracked deposit (100e6 USDC -> 100e18 shares)
        vm.prank(agent1);
        feeTracker.recordAgentVaultShareDeposit(vault, 100e6, 100e18);

        // Step 2: Record yield earned in vault token (10e18 shares of yield)
        // This simulates receiving yield in vault share tokens
        vm.prank(agent1);
        feeTracker.recordAgentYieldTokenEarned(vault, 10e18);

        // Verify initial state
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(agent1, vault);
        assertEq(costBasis, 100e6, "Cost basis should be 100e6");
        assertEq(shares, 100e18, "Tracked shares should only include deposit shares");

        uint256 feeOwnedShares = feeTracker.getAgentYieldTokenFeesOwed(agent1, vault);
        assertEq(feeOwnedShares, 1e18, "Fee-owed shares should be 1e18 (10% of 10e18)");

        // Step 3: Withdraw all 110e18 shares (100 tracked + 10 untracked reward)
        // for 121e6 USDC total (vault appreciated ~10%)
        uint256 sharesWithdrawn = 110e18;
        uint256 assetsReceived = 121e6;

        uint256 feesBefore = feeTracker.getFeesOwed(agent1);

        vm.prank(agent1);
        feeTracker.recordAgentVaultShareWithdraw(vault, sharesWithdrawn, assetsReceived);

        // Step 4: Verify correct fee calculation (no double-charging)
        uint256 feesAfter = feeTracker.getFeesOwed(agent1);
        uint256 feesCharged = feesAfter - feesBefore;

        // Expected calculation:
        // Block 1: feeInBaseAsset = (121e6 * 1e18) / 110e18 ≈ 1.1e6
        // Block 2: profit = 121e6 - 100e6 - feeInBaseAsset (if assetsReceived > costBasis + feeInBaseAsset)
        //          fee = profit * 10%
        // The key assertion: fees should be reasonable and not double the profit

        // The maximum profit is the difference between assets received and cost basis
        uint256 maxProfit = assetsReceived - costBasis; // 21e6

        // If we double-charged, we'd get roughly 4.2e6 (2.1e6 + 2.1e6)
        // This is an absolute upper bound that should never be reached
        uint256 maxIfDoubleCharged = (maxProfit * DEFAULT_FEE_RATE * 2) / BASIS_POINTS;
        assertLt(feesCharged, maxIfDoubleCharged, "Fees should not be double-charged");

        // Verify position is cleared
        (uint256 costBasisAfter, uint256 sharesAfter) = feeTracker.getAgentVaultPosition(agent1, vault);
        assertEq(costBasisAfter, 0, "Cost basis should be cleared");
        assertEq(sharesAfter, 0, "Shares should be cleared");

        // Verify fee-owed shares are cleared
        uint256 feeOwnedSharesAfter = feeTracker.getAgentYieldTokenFeesOwed(agent1, vault);
        assertEq(feeOwnedSharesAfter, 0, "All fee-owed shares should be cleared");
    }

    function test_VaultWithdrawal_SimpleYieldCalculation() public {
        // Simple scenario without vault token fees:
        // User deposits 10 USDC -> gets 10 shares
        // Later withdraws 10 shares -> gets 11 USDC
        // Yield earned: 1 USDC
        // Fees owed at 10%: 0.1 USDC

        address vault = makeAddr("vault");

        // Step 1: Deposit 10 USDC for 10 shares
        vm.prank(agent1);
        feeTracker.recordAgentVaultShareDeposit(vault, 10e6, 10e18);

        (uint256 costBasis1, uint256 shares1) = feeTracker.getAgentVaultPosition(agent1, vault);
        assertEq(costBasis1, 10e6);
        assertEq(shares1, 10e18);

        // Step 2: Withdraw all 10 shares for 11 USDC
        uint256 feesBefore = feeTracker.getFeesOwed(agent1);
        assertEq(feesBefore, 0, "No fees owed initially");

        // Expect the yield event
        vm.expectEmit(true, false, false, true);
        emit YieldRecorded(agent1, 1e6, 0.1e6); // profit=1, fee=0.1

        vm.prank(agent1);
        feeTracker.recordAgentVaultShareWithdraw(vault, 10e18, 11e6);

        // Step 3: Verify fees charged
        uint256 feesAfter = feeTracker.getFeesOwed(agent1);

        // Profit = 11 - 10 = 1 USDC
        // Fee = 1 * 10% = 0.1 USDC
        uint256 expectedFee = 0.1e6;
        assertEq(feesAfter, expectedFee, "Should charge 0.1 USDC fee on 1 USDC profit");

        // Step 4: Verify position is cleared
        (uint256 costBasisAfter, uint256 sharesAfter) = feeTracker.getAgentVaultPosition(agent1, vault);
        assertEq(costBasisAfter, 0);
        assertEq(sharesAfter, 0);
    }

    function test_VaultWithdrawal_WithYieldTokenFees() public {
        // Scenario with vault token fees:
        // User deposits 10 USDC -> gets 10 shares (cost basis 10)
        // Receives 2 yield shares (recordAgentYieldTokenEarned called with 2 shares)
        // Withdraws all 12 shares for 13.2 USDC (vault appreciated 10%)
        // Expected:
        // - Yield token fee: 0.2 shares owed (10% of 2)
        // - When withdrawing: 0.2 * (13.2 / 12) = 0.22 USDC charged as fee
        // - Remaining assets: 13.2 - 0.22 = 12.98
        // - Profit: 12.98 - 10 = 2.98
        // - Fee on profit: 2.98 * 10% = 0.298

        address vault = makeAddr("vault");

        // Step 1: Deposit 10 USDC for 10 shares
        vm.prank(agent1);
        feeTracker.recordAgentVaultShareDeposit(vault, 10e6, 10e18);

        // Step 2: Record yield earned in vault tokens (2 shares)
        vm.prank(agent1);
        feeTracker.recordAgentYieldTokenEarned(vault, 2e18);

        uint256 feeOwnedShares = feeTracker.getAgentYieldTokenFeesOwed(agent1, vault);
        assertEq(feeOwnedShares, 0.2e18, "Should have 0.2 shares owed (10% of 2)");

        // Step 3: Withdraw all 12 shares for 13.2 USDC
        uint256 feesBefore = feeTracker.getFeesOwed(agent1);

        vm.prank(agent1);
        feeTracker.recordAgentVaultShareWithdraw(vault, 12e18, 13.2e6);

        // Step 4: Verify total fees
        uint256 feesAfter = feeTracker.getFeesOwed(agent1);
        uint256 totalFees = feesAfter - feesBefore;

        // New calculation: only charge profit on deposit shares portion
        // feeInBaseAsset = (13.2 * 0.2) / 12 = 0.22 USDC (fee on yield token)
        // depositSharesValue = (13.2 * 10) / 12 = 11.0 USDC
        // profit on deposit = 11.0 - 10.0 = 1.0 USDC
        // profit fee = 1.0 * 10% = 0.1 USDC
        // Total = 0.22 + 0.1 = 0.32 USDC
        uint256 expectedTotal = 0.32e6;

        assertApproxEqAbs(totalFees, expectedTotal, 1e3, "Total fees should match calculation");
    }

    // ============ Audit Fix: Safety cap on feeInBaseAsset (Issue 2) ============

    function test_VaultAssetWithdraw_FeeInBaseAsset_CappedAtAssetsReceived() public {
        address vault = makeAddr("vault");
        // Deposit 50 USDC → 50 shares
        vm.prank(agent1);
        feeTracker.recordAgentVaultShareDeposit(vault, 50e6, 50e6);
        // Record massive reward: 1000 tokens → 100 token fee owed
        vm.prank(agent1);
        feeTracker.recordAgentYieldTokenEarned(vault, 1000e6);
        uint256 feeOwed = feeTracker.getAgentYieldTokenFeesOwed(agent1, vault);
        assertEq(feeOwed, 100e6, "Should owe 100 tokens in fees");
        // Withdraw 200 USDC from a vault with totalBalance = 1050
        // Without the cap, the old buggy formula would compute a fee > 200 and underflow
        // With the fix, the fee is capped and this should not revert
        vm.prank(agent1);
        feeTracker.recordAgentVaultAssetWithdraw(vault, 200e6, 1050e6, 1e18);
        // Verify fee was capped at assetsReceived (200e6)
        uint256 feesCharged = feeTracker.agentFeesCharged(agent1);
        assertTrue(feesCharged <= 200e6, "Fee should be capped at assets received");
        assertTrue(feesCharged > 0, "Fee should be non-zero");
    }

    function test_VaultAssetWithdraw_RebasingRate_CorrectFee() public {
        address vault = makeAddr("vault");
        vm.prank(agent1);
        feeTracker.recordAgentVaultShareDeposit(vault, 100e6, 100e6);
        vm.prank(agent1);
        feeTracker.recordAgentYieldTokenEarned(vault, 10e6);
        // Withdraw 50 from totalVaultBalance=110, rate=1e18 (rebasing)
        vm.prank(agent1);
        feeTracker.recordAgentVaultAssetWithdraw(vault, 50e6, 110e6, 1e18);
        uint256 expectedFeeTokenSettled = uint256(1e6) * uint256(50e6) / uint256(110e6);
        // With 1e18 rate, feeInBaseAsset = feeTokenSettled (1:1)
        uint256 feesCharged = feeTracker.agentFeesCharged(agent1);
        // The vaultToken fee portion should be exactly feeTokenSettled
        // Plus potential profit fee on the remaining netAssets
        assertTrue(feesCharged >= expectedFeeTokenSettled, "Fee should include at least the token fee portion");
    }

    function test_VaultAssetWithdraw_ExchangeRate_CorrectConversion() public {
        address vault = makeAddr("vault");
        // Simulate CompoundV2: deposit 1000 USDC → 1000 cTokens at 1e18 rate
        vm.prank(agent1);
        feeTracker.recordAgentVaultShareDeposit(vault, 1000e6, 1000e6);
        // Record token fee: 10 cTokens owed
        vm.prank(agent1);
        feeTracker.recordAgentYieldTokenEarned(vault, 100e6);
        uint256 feeOwed = feeTracker.getAgentYieldTokenFeesOwed(agent1, vault);
        assertEq(feeOwed, 10e6);
        // Exchange rate = 1.1e18 (10% appreciation)
        // Withdraw 550 USDC from total 1100 USDC balance
        vm.prank(agent1);
        feeTracker.recordAgentVaultAssetWithdraw(vault, 550e6, 1100e6, 1.1e18);
        // feeTokenSettled = (10e6 * 550e6) / 1100e6 = 5e6
        // feeInBaseAsset = (5e6 * 1.1e18) / 1e18 = 5.5e6
        uint256 feesCharged = feeTracker.agentFeesCharged(agent1);
        assertTrue(feesCharged >= 5.5e6, "Should apply exchange rate for non-rebasing tokens");
    }
}
