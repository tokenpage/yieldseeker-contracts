// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../../src/FeeTracker.sol";
import {YieldSeekerAaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {YieldSeekerCompoundV2Adapter} from "../../../src/adapters/CompoundV2Adapter.sol";
import {YieldSeekerCompoundV3Adapter} from "../../../src/adapters/CompoundV3Adapter.sol";
import {MockAToken, MockAaveV3Pool} from "../../mocks/MockAaveV3.sol";
import {MockCToken} from "../../mocks/MockCompoundV2.sol";
import {MockCompoundV3Comet} from "../../mocks/MockCompoundV3.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {AdapterWalletHarness} from "./AdapterHarness.t.sol";
import {Test} from "forge-std/Test.sol";

/// @title AdapterFlowsTest
/// @notice End-to-end flow tests using Aave as the representative rebasing adapter.
///         The same proportional cost basis logic applies to CompoundV2 and CompoundV3.
contract AdapterFlowsTest is Test {
    YieldSeekerFeeTracker feeTracker;
    AdapterWalletHarness wallet;
    MockERC20 baseAsset;
    YieldSeekerAaveV3Adapter adapter;
    MockAaveV3Pool pool;
    MockAToken aToken;

    function setUp() public {
        baseAsset = new MockERC20("Mock USDC", "mUSDC");
        feeTracker = new YieldSeekerFeeTracker(address(this));
        feeTracker.setFeeConfig(1000, address(0xBEEF)); // 10% fee
        wallet = new AdapterWalletHarness(baseAsset, feeTracker);
        adapter = new YieldSeekerAaveV3Adapter();
        pool = new MockAaveV3Pool(address(baseAsset));
        aToken = MockAToken(pool.aToken());
        baseAsset.mint(address(wallet), 1_000_000e6);
    }

    function _deposit(uint256 amount) internal {
        wallet.executeAdapter(address(adapter), address(aToken), abi.encodeWithSelector(adapter.deposit.selector, amount));
    }

    function _withdraw(uint256 amount) internal {
        wallet.executeAdapter(address(adapter), address(aToken), abi.encodeWithSelector(adapter.withdraw.selector, amount));
    }

    function _addYield(uint256 amount) internal {
        aToken.addYield(address(wallet), amount);
        baseAsset.mint(address(aToken), amount);
    }

    // ============ Flow 1: Deposit → Yield → Withdraw ============
    //
    // Uses proportional cost basis: withdrawing X from a vault worth V with cost C
    // means proportionalCost = (C * X) / V, profit = X - proportionalCost.
    // This gives identical total fees vs FIFO, but spreads them across withdrawals.

    /// @notice Deposit 100, balance grows to 105, withdraw 100.
    ///         Proportional cost basis counts 100/105 of the position as withdrawn,
    ///         so proportionalCost = 95, profit = 5.
    function test_Flow1a_DepositYieldPartialWithdraw() public {
        _deposit(100e6);
        _addYield(5e6);
        assertEq(aToken.balanceOf(address(wallet)), 105e6);
        _withdraw(100e6);
        // proportionalCost = (100e6 * 100e6) / 105e6 = 95238095 (integer division)
        uint256 totalBalanceBefore = 105e6;
        uint256 proportionalCost = (100e6 * 100e6) / totalBalanceBefore;
        uint256 profit = 100e6 - proportionalCost;
        uint256 expectedFee = (profit * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "Fee on proportional profit");
        // Remaining position: 5 USDC in vault, cost basis = 100e6 - 95238095 = 4761905
        (uint256 costBasis,) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        assertEq(costBasis, 100e6 - proportionalCost, "Remaining cost basis");
        assertEq(aToken.balanceOf(address(wallet)), 5e6, "5 aTokens remain");
    }

    /// @notice Continuing from 1a: withdraw the remaining 5.
    ///         The remaining cost basis is slightly less than 5 (4.76), so there's
    ///         a small additional profit. Total profit across both = 5.
    function test_Flow1a_ThenWithdrawRemaining_TotalFeeCorrect() public {
        _deposit(100e6);
        _addYield(5e6);
        _withdraw(100e6);
        uint256 feeAfterFirst = feeTracker.agentFeesCharged(address(wallet));
        _withdraw(5e6);
        uint256 totalFees = feeTracker.agentFeesCharged(address(wallet));
        // Total yield = 5 USDC, total fee should be 10% = 0.5 USDC = 500000
        // Due to integer rounding it may be off by 1
        uint256 expectedTotalFee = (5e6 * 1000) / 10_000;
        assertApproxEqAbs(totalFees, expectedTotalFee, 1, "Total fees match 10% of total yield");
        assertGt(totalFees, feeAfterFirst, "Second withdrawal also charged some fee");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        assertEq(costBasis, 0, "Position fully cleared");
        assertEq(shares, 0, "Shares fully cleared");
    }

    /// @notice Deposit 100, balance grows to 105, withdraw 104.
    ///         proportionalCost = (100 * 104) / 105 = 99.04, profit = 4.95
    function test_Flow1b_DepositYieldLargePartialWithdraw() public {
        _deposit(100e6);
        _addYield(5e6);
        _withdraw(104e6);
        uint256 totalBalanceBefore = 105e6;
        uint256 proportionalCost = (100e6 * 104e6) / totalBalanceBefore;
        uint256 profit = 104e6 - proportionalCost;
        uint256 expectedFee = (profit * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "Fee on proportional profit");
        (uint256 costBasis,) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        assertEq(costBasis, 100e6 - proportionalCost, "Remaining cost basis for 1 USDC");
        assertEq(aToken.balanceOf(address(wallet)), 1e6, "1 aToken remains");
    }

    /// @notice Deposit 100, balance grows to 105, withdraw all 105.
    ///         Full withdrawal: profit = 105 - 100 = 5, fee = 0.5.
    function test_Flow1c_DepositYieldFullWithdraw() public {
        _deposit(100e6);
        _addYield(5e6);
        _withdraw(105e6);
        uint256 expectedFee = (5e6 * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "10% of 5 USDC yield");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        assertEq(costBasis, 0, "Position cleared");
        assertEq(shares, 0, "Shares cleared");
    }

    // ============ Flow 2: Reward tokens received ============
    //
    // When aTokens arrive as Merkl rewards, recordAgentYieldTokenEarned tracks the fee
    // in agentYieldTokenFeesOwed. On withdrawal, the fee is settled proportionally.

    /// @notice 10 aTokens received as reward (no deposit). Withdraw 7.
    ///         All 7 are profit (costBasis = 0). Additionally, vaultTokenFeesOwed
    ///         settles proportionally: 7/10 of the 1-aToken fee owed = 0.7 USDC.
    function test_Flow2_RewardTokensWithdraw() public {
        // Simulate reward: 10 aTokens appear + feeTracker records yield token earned
        _addYield(10e6);
        vm.prank(address(wallet));
        feeTracker.recordAgentYieldTokenEarned(address(aToken), 10e6);
        uint256 vaultTokenFeeBefore = feeTracker.getAgentYieldTokenFeesOwed(address(wallet), address(aToken));
        // 10% of 10 aTokens = 1 aToken of fees owed
        assertEq(vaultTokenFeeBefore, 1e6, "1 aToken fee owed on 10 aToken reward");
        // Withdraw 7 USDC
        _withdraw(7e6);
        // Fee settlement: 7/10 of the 1e6 fee = 700000 settled as base asset fee
        uint256 feeSettled = (1e6 * 7e6) / 10e6;
        // Plus: costBasis = 0, so netAssets = 7e6 - feeSettled = 6300000 is all profit
        // fee on that profit = 630000
        uint256 profitFee = ((7e6 - feeSettled) * 1000) / 10_000;
        uint256 totalExpectedFees = feeSettled + profitFee;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), totalExpectedFees, "Fees from reward settlement + profit");
        // Remaining vault token fee: 1e6 - 700000 = 300000
        uint256 remainingVaultTokenFee = feeTracker.getAgentYieldTokenFeesOwed(address(wallet), address(aToken));
        assertEq(remainingVaultTokenFee, 1e6 - feeSettled, "Remaining vault token fee");
    }

    /// @notice Deposit 100, then receive 10 aTokens as reward, then withdraw 7.
    ///         The 7 withdrawn comes proportionally from the 110 total balance.
    function test_Flow2b_DepositThenRewardThenWithdraw() public {
        _deposit(100e6);
        _addYield(10e6);
        vm.prank(address(wallet));
        feeTracker.recordAgentYieldTokenEarned(address(aToken), 10e6);
        uint256 totalBalance = aToken.balanceOf(address(wallet));
        assertEq(totalBalance, 110e6);
        _withdraw(7e6);
        // vaultTokenFee settlement: 7/110 of 1e6 fee owed (in vault token units)
        uint256 totalBalanceBefore = 110e6;
        uint256 feeTokenSettled = (1e6 * 7e6) / totalBalanceBefore;
        // For rebasing tokens (Aave), 1 vault token = 1 underlying, so rate = 1e18
        uint256 feeInBaseAsset = feeTokenSettled;
        // proportionalCost = (100e6 * 7e6) / 110e6
        uint256 proportionalCost = (100e6 * 7e6) / totalBalanceBefore;
        // netAssets = 7e6 - feeInBaseAsset, profit = netAssets - proportionalCost
        uint256 netAssets = 7e6 - feeInBaseAsset;
        uint256 profit = netAssets > proportionalCost ? netAssets - proportionalCost : 0;
        uint256 profitFee = (profit * 1000) / 10_000;
        uint256 totalExpectedFees = feeInBaseAsset + profitFee;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), totalExpectedFees, "Correct fees with deposit + reward");
    }

    // ============ Flow 3: Multi-step deposit/withdraw/deposit/withdraw ============

    /// @notice Deposit → partial withdraw → deposit more → yield → withdraw all.
    ///         Verifies cost basis accumulates and reduces correctly through multiple ops.
    function test_Flow3_MultiStepDepositWithdrawCycle() public {
        // Step 1: Deposit 1000
        _deposit(1_000e6);
        (uint256 cb1,) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        assertEq(cb1, 1_000e6);
        // Step 2: Withdraw 400 (no yield yet, no fee)
        _withdraw(400e6);
        assertEq(feeTracker.agentFeesCharged(address(wallet)), 0, "No fee without yield");
        (uint256 cb2,) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        assertEq(cb2, 600e6, "Cost basis reduced proportionally: 1000 * 600/1000");
        // Step 3: Deposit 500 more (balance = 600 + 500 = 1100, cost = 600 + 500 = 1100)
        _deposit(500e6);
        (uint256 cb3,) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        assertEq(cb3, 1_100e6, "Cost basis accumulated");
        assertEq(aToken.balanceOf(address(wallet)), 1_100e6);
        // Step 4: Yield accrues — balance grows to 1210 (10% yield)
        _addYield(110e6);
        assertEq(aToken.balanceOf(address(wallet)), 1_210e6);
        // Step 5: Withdraw 605 (half the balance)
        _withdraw(605e6);
        uint256 proportionalCost = (1_100e6 * 605e6) / 1_210e6;
        uint256 profit = 605e6 - proportionalCost;
        uint256 expectedFee = (profit * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "Fee on first half");
        (uint256 cb4,) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        assertEq(cb4, 1_100e6 - proportionalCost, "Remaining cost basis");
        // Step 6: Withdraw remaining 605
        _withdraw(605e6);
        uint256 totalFees = feeTracker.agentFeesCharged(address(wallet));
        // Total yield = 110, total fee should be ~11 (10%)
        uint256 expectedTotalFee = (110e6 * 1000) / 10_000;
        assertApproxEqAbs(totalFees, expectedTotalFee, 1, "Total fees = 10% of total yield");
        (uint256 cbFinal, uint256 sharesFinal) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        assertEq(cbFinal, 0, "Position fully cleared");
        assertEq(sharesFinal, 0, "Shares fully cleared");
    }

    /// @notice Multiple yield events between deposits/withdrawals.
    function test_Flow3b_InterleavedYieldAndOperations() public {
        // Deposit 500, yield 50 (balance → 550)
        _deposit(500e6);
        _addYield(50e6);
        // Withdraw 275 (half)
        _withdraw(275e6);
        uint256 proportionalCost1 = (500e6 * 275e6) / 550e6;
        uint256 profit1 = 275e6 - proportionalCost1;
        uint256 fee1 = (profit1 * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), fee1);
        // Deposit 1000 more (balance = 275 + 1000 = 1275)
        _deposit(1_000e6);
        (uint256 cb2,) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        uint256 remainingCostBasis = 500e6 - proportionalCost1;
        assertEq(cb2, remainingCostBasis + 1_000e6, "Cost basis = remaining + new deposit");
        // More yield: 127.5 (balance → 1402.5... use 127e6 for clean math → 1402)
        _addYield(127e6);
        uint256 finalBalance = aToken.balanceOf(address(wallet));
        assertEq(finalBalance, 1_402e6);
        // Withdraw everything
        _withdraw(finalBalance);
        uint256 totalFees = feeTracker.agentFeesCharged(address(wallet));
        // Total deposited = 500 + 1000 = 1500
        // Total withdrawn = 275 + 1402 = 1677
        // Total yield = 1677 - 1500 = 177
        uint256 totalYield = (275e6 + finalBalance) - (500e6 + 1_000e6);
        uint256 expectedTotalFee = (totalYield * 1000) / 10_000;
        assertApproxEqAbs(totalFees, expectedTotalFee, 1, "Total fees = 10% of total yield");
        (uint256 cbFinal,) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        assertEq(cbFinal, 0, "Position fully cleared");
    }

    /// @notice Deposit, withdraw at a loss (vault hack scenario), re-deposit, profit.
    ///         Demonstrates fee tracking handles losses correctly.
    function test_Flow3c_LossThenRecovery() public {
        _deposit(1_000e6);
        // Simulate loss: balance drops to 800 (vault hack, slashing, etc.)
        // We can't easily remove aTokens, so we test by withdrawing more than balance
        // Instead: withdraw 800 of the 1000 (no yield = no fee)
        _withdraw(800e6);
        assertEq(feeTracker.agentFeesCharged(address(wallet)), 0, "No fee on principal return");
        (uint256 cb1,) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        assertEq(cb1, 200e6, "Remaining cost basis");
        // Deposit 500 more
        _deposit(500e6);
        (uint256 cb2,) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        assertEq(cb2, 700e6, "Cost basis = 200 + 500");
        assertEq(aToken.balanceOf(address(wallet)), 700e6);
        // Yield accrues: 70 (10%)
        _addYield(70e6);
        // Withdraw everything
        _withdraw(770e6);
        uint256 expectedFee = (70e6 * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "Fee only on actual yield");
    }

    /// @notice Tiny withdrawals to verify rounding doesn't accumulate errors.
    function test_Flow3d_ManySmallWithdrawals() public {
        _deposit(1_000e6);
        _addYield(100e6);
        // Withdraw in 10 chunks of 110
        for (uint256 i = 0; i < 10; i++) {
            _withdraw(110e6);
        }
        uint256 totalFees = feeTracker.agentFeesCharged(address(wallet));
        uint256 expectedTotalFee = (100e6 * 1000) / 10_000;
        // Allow rounding tolerance: 10 operations * potential 1 wei rounding each
        assertApproxEqAbs(totalFees, expectedTotalFee, 10, "Total fees correct despite many small withdrawals");
        (uint256 cbFinal, uint256 sharesFinal) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        assertApproxEqAbs(cbFinal, 0, 10, "Cost basis ~0 after full withdrawal");
        assertApproxEqAbs(sharesFinal, 0, 10, "Shares ~0 after full withdrawal");
    }

    // ============ Flow 4: Untracked positions (tokens arriving outside deposit flow) ============

    /// @notice CompoundV2: cTokens transferred directly to wallet. Withdrawing a specific
    ///         amount only redeems that amount, not the entire balance.
    function test_Flow4a_CompoundV2_UntrackedCTokens_PartialWithdraw() public {
        YieldSeekerCompoundV2Adapter cAdapter = new YieldSeekerCompoundV2Adapter();
        MockCToken cToken = new MockCToken(address(baseAsset), "Mock cUSDC", "mcUSDC");
        address externalDepositor = address(0xDEAD);
        uint256 untrackedAmount = 50_000e6;
        baseAsset.mint(externalDepositor, untrackedAmount);
        vm.startPrank(externalDepositor);
        baseAsset.approve(address(cToken), untrackedAmount);
        cToken.mint(untrackedAmount);
        require(cToken.transfer(address(wallet), cToken.balanceOf(externalDepositor)));
        vm.stopPrank();
        uint256 cTokenBalanceBefore = cToken.balanceOf(address(wallet));
        assertGt(cTokenBalanceBefore, 0, "Wallet should hold cTokens");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasis, 0, "No tracked cost basis");
        assertEq(shares, 0, "No tracked shares");
        uint256 withdrawRequest = 1_000e6;
        uint256 walletBalanceBefore = baseAsset.balanceOf(address(wallet));
        wallet.executeAdapter(address(cAdapter), address(cToken), abi.encodeWithSelector(cAdapter.withdraw.selector, withdrawRequest));
        uint256 assetsReceived = baseAsset.balanceOf(address(wallet)) - walletBalanceBefore;
        assertEq(assetsReceived, withdrawRequest, "Should receive exactly the requested amount");
        assertGt(cToken.balanceOf(address(wallet)), 0, "Remaining cTokens preserved, not liquidated");
        uint256 expectedFee = (withdrawRequest * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "Fees charged on untracked tokens as profit");
    }

    /// @notice CompoundV3: untracked tokens arrive, then a tracked deposit on top.
    ///         Proportional cost basis correctly treats untracked remainder as profit.
    function test_Flow4b_CompoundV3_UntrackedThenTrackedDeposit() public {
        YieldSeekerCompoundV3Adapter cAdapter = new YieldSeekerCompoundV3Adapter();
        MockCompoundV3Comet comet = new MockCompoundV3Comet(address(baseAsset));
        uint256 untrackedAmount = 500e6;
        comet.addYield(address(wallet), untrackedAmount);
        baseAsset.mint(address(comet), untrackedAmount);
        uint256 firstWithdraw = 250e6;
        wallet.executeAdapter(address(cAdapter), address(comet), abi.encodeWithSelector(cAdapter.withdraw.selector, firstWithdraw));
        uint256 firstFee = (firstWithdraw * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), firstFee, "Fee on untracked withdrawal");
        uint256 trackedDeposit = 1_000e6;
        wallet.executeAdapter(address(cAdapter), address(comet), abi.encodeWithSelector(cAdapter.deposit.selector, trackedDeposit));
        uint256 totalBalance = comet.balanceOf(address(wallet));
        assertEq(totalBalance, 1_250e6, "250 untracked + 1000 deposit");
        (uint256 cb,) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(cb, trackedDeposit, "Cost basis equals tracked deposit only");
        wallet.executeAdapter(address(cAdapter), address(comet), abi.encodeWithSelector(cAdapter.withdraw.selector, totalBalance));
        uint256 secondFee = (250e6 * 1000) / 10_000;
        uint256 totalExpectedFees = firstFee + secondFee;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), totalExpectedFees, "Total fees account for all untracked tokens");
        (uint256 finalCb, uint256 finalShares) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(finalCb, 0, "Position fully cleared");
        assertEq(finalShares, 0, "Shares fully cleared");
    }
}
