// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerErrors} from "../../src/Errors.sol";
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
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.Unauthorized.selector, nonAdmin));
        feeTracker.setFeeConfig(newFeeRate, newCollector);
    }

    function test_SetFeeConfig_ZeroCollector() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.ZeroAddress.selector));
        feeTracker.setFeeConfig(500, address(0));
    }

    function test_SetFeeConfig_MaxFeeRate() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.InvalidFeeRate.selector));
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
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.Unauthorized.selector, nonAdmin));
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
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.Unauthorized.selector, nonAdmin));
        feeTracker.recordAgentVaultShareDeposit(agent1, vault, 1000e6, 1000e18);
    }

    function test_AccessControl_VaultWithdraw_OnlyAdmin() public {
        address vault = makeAddr("vault");

        // Setup position
        vm.prank(admin);
        feeTracker.recordAgentVaultShareDeposit(agent1, vault, 1000e6, 1000e18);

        // Non-admin cannot record withdrawals
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.Unauthorized.selector, nonAdmin));
        feeTracker.recordAgentVaultShareWithdraw(agent1, vault, 500e18, 550e6);
    }

    function test_AccessControl_AdminOnly_SetFeeConfig() public {
        // Already tested in earlier tests, but adding explicit security test
        vm.prank(nonAdmin);
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerErrors.Unauthorized.selector, nonAdmin));
        feeTracker.setFeeConfig(500, collector);
    }
}
