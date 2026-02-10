// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerAaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {YieldSeekerCompoundV2Adapter} from "../../src/adapters/CompoundV2Adapter.sol";
import {YieldSeekerCompoundV3Adapter} from "../../src/adapters/CompoundV3Adapter.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {MockAToken, MockAaveV3Pool} from "../mocks/MockAaveV3.sol";
import {MockCToken} from "../mocks/MockCompoundV2.sol";
import {MockCompoundV3Comet} from "../mocks/MockCompoundV3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {AdapterWalletHarness} from "../unit/adapters/AdapterHarness.t.sol";
import {Test} from "forge-std/Test.sol";

/// @title UntrackedPositionSecurityTest
/// @notice Verifies that the asset-amount-based withdrawal fix correctly handles
///         vault tokens received outside the adapter deposit flow.
///         Previously, virtual share fallbacks caused destructive withdrawals and fee corruption.
contract UntrackedPositionSecurityTest is Test {
    YieldSeekerFeeTracker feeTracker;
    AdapterWalletHarness wallet;
    MockERC20 baseAsset;

    function _decodeUint(bytes memory data) internal pure returns (uint256) {
        return abi.decode(abi.decode(data, (bytes)), (uint256));
    }

    function setUp() public {
        baseAsset = new MockERC20("Mock USDC", "mUSDC");
        feeTracker = new YieldSeekerFeeTracker(address(this));
        feeTracker.setFeeConfig(1000, address(0xBEEF)); // 10% fee
        wallet = new AdapterWalletHarness(baseAsset, feeTracker);
        baseAsset.mint(address(wallet), 1_000_000e6);
    }

    // ============ CompoundV2: No longer liquidates entire balance ============

    /// @notice With the fix, requesting a specific USDC amount from an untracked CompoundV2
    ///         position only redeems that amount (via redeemUnderlying), not the entire balance.
    function test_CompoundV2_UntrackedPosition_WithdrawsOnlyRequestedAmount() public {
        YieldSeekerCompoundV2Adapter adapter = new YieldSeekerCompoundV2Adapter();
        MockCToken cToken = new MockCToken(address(baseAsset), "Mock cUSDC", "mcUSDC");
        address externalDepositor = address(0xDEAD);
        uint256 untrackedAmount = 50_000e6;
        baseAsset.mint(externalDepositor, untrackedAmount);
        vm.startPrank(externalDepositor);
        baseAsset.approve(address(cToken), untrackedAmount);
        cToken.mint(untrackedAmount);
        cToken.transfer(address(wallet), cToken.balanceOf(externalDepositor));
        vm.stopPrank();
        uint256 cTokenBalanceBefore = cToken.balanceOf(address(wallet));
        assertGt(cTokenBalanceBefore, 0, "Wallet should hold cTokens");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasis, 0, "No tracked cost basis");
        assertEq(shares, 0, "No tracked shares");
        uint256 withdrawRequest = 1_000e6;
        uint256 walletBalanceBefore = baseAsset.balanceOf(address(wallet));
        wallet.executeAdapter(
            address(adapter),
            address(cToken),
            abi.encodeWithSelector(adapter.withdraw.selector, withdrawRequest)
        );
        uint256 walletBalanceAfter = baseAsset.balanceOf(address(wallet));
        uint256 assetsReceived = walletBalanceAfter - walletBalanceBefore;
        assertEq(assetsReceived, withdrawRequest, "Should receive exactly the requested amount");
        uint256 cTokenBalanceAfter = cToken.balanceOf(address(wallet));
        assertGt(cTokenBalanceAfter, 0, "FIX: Remaining cTokens preserved, not liquidated");
        uint256 expectedFee = (withdrawRequest * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "FIX: Fees charged on untracked tokens as profit");
    }

    // ============ AaveV3: Direct asset withdrawal with proper fees ============

    /// @notice With the fix, withdrawing from an untracked Aave position correctly
    ///         withdraws the exact requested amount and charges fees on it as profit.
    function test_AaveV3_UntrackedPosition_CorrectWithdrawalAndFees() public {
        YieldSeekerAaveV3Adapter adapter = new YieldSeekerAaveV3Adapter();
        MockAaveV3Pool pool = new MockAaveV3Pool(address(baseAsset));
        MockAToken aToken = MockAToken(pool.aToken());
        uint256 untrackedAmount = 1_050e6;
        aToken.addYield(address(wallet), untrackedAmount);
        baseAsset.mint(address(aToken), untrackedAmount);
        assertEq(aToken.balanceOf(address(wallet)), untrackedAmount, "Wallet should hold aTokens");
        (, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(aToken));
        assertEq(shares, 0, "No tracked shares");
        uint256 withdrawAmount = 500e6;
        uint256 walletBalanceBefore = baseAsset.balanceOf(address(wallet));
        wallet.executeAdapter(
            address(adapter),
            address(aToken),
            abi.encodeWithSelector(adapter.withdraw.selector, withdrawAmount)
        );
        uint256 walletBalanceAfter = baseAsset.balanceOf(address(wallet));
        uint256 assetsReceived = walletBalanceAfter - walletBalanceBefore;
        assertEq(assetsReceived, withdrawAmount, "Should receive exactly the requested amount");
        assertEq(aToken.balanceOf(address(wallet)), untrackedAmount - withdrawAmount, "FIX: Remaining aTokens preserved");
        uint256 expectedFee = (withdrawAmount * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "FIX: Fees charged on untracked tokens as profit");
    }

    // ============ CompoundV3: Direct asset withdrawal with proper fees ============

    /// @notice Same fix applied to CompoundV3 — exact amount withdrawn, fees charged correctly.
    function test_CompoundV3_UntrackedPosition_CorrectWithdrawalAndFees() public {
        YieldSeekerCompoundV3Adapter adapter = new YieldSeekerCompoundV3Adapter();
        MockCompoundV3Comet comet = new MockCompoundV3Comet(address(baseAsset));
        uint256 untrackedAmount = 1_050e6;
        comet.addYield(address(wallet), untrackedAmount);
        baseAsset.mint(address(comet), untrackedAmount);
        assertEq(comet.balanceOf(address(wallet)), untrackedAmount, "Wallet should hold Comet balance");
        (, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(shares, 0, "No tracked shares");
        uint256 withdrawAmount = 500e6;
        uint256 walletBalanceBefore = baseAsset.balanceOf(address(wallet));
        wallet.executeAdapter(
            address(adapter),
            address(comet),
            abi.encodeWithSelector(adapter.withdraw.selector, withdrawAmount)
        );
        uint256 walletBalanceAfter = baseAsset.balanceOf(address(wallet));
        uint256 assetsReceived = walletBalanceAfter - walletBalanceBefore;
        assertEq(assetsReceived, withdrawAmount, "Should receive exactly the requested amount");
        assertEq(comet.balanceOf(address(wallet)), untrackedAmount - withdrawAmount, "FIX: Remaining balance preserved");
        uint256 expectedFee = (withdrawAmount * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "FIX: Fees charged on untracked tokens as profit");
    }

    // ============ Fee accounting consistency across deposit/untracked flows ============

    /// @notice Verifies that untracked tokens followed by a tracked deposit produce correct
    ///         fee accounting. The proportional cost basis computation against actual vault
    ///         balance means untracked tokens are naturally treated as profit.
    function test_CompoundV3_UntrackedThenTracked_CorrectFeeAccounting() public {
        YieldSeekerCompoundV3Adapter adapter = new YieldSeekerCompoundV3Adapter();
        MockCompoundV3Comet comet = new MockCompoundV3Comet(address(baseAsset));
        // Step 1: Untracked tokens arrive
        uint256 untrackedAmount = 500e6;
        comet.addYield(address(wallet), untrackedAmount);
        baseAsset.mint(address(comet), untrackedAmount);
        // Step 2: Withdraw half the untracked tokens — fees charged as pure profit
        uint256 firstWithdraw = 250e6;
        wallet.executeAdapter(
            address(adapter),
            address(comet),
            abi.encodeWithSelector(adapter.withdraw.selector, firstWithdraw)
        );
        uint256 firstFee = (firstWithdraw * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), firstFee, "Fee on first untracked withdrawal");
        // Step 3: Tracked deposit on top of remaining untracked tokens
        uint256 trackedDeposit = 1_000e6;
        wallet.executeAdapter(
            address(adapter),
            address(comet),
            abi.encodeWithSelector(adapter.deposit.selector, trackedDeposit)
        );
        // Balance = 250 (remaining untracked) + 1000 (deposit) = 1250
        uint256 totalBalance = comet.balanceOf(address(wallet));
        assertEq(totalBalance, 1_250e6, "Total balance correct");
        (uint256 costBasis,) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(costBasis, trackedDeposit, "Cost basis equals tracked deposit only");
        // Step 4: Withdraw everything — proportional cost basis correctly attributes the
        //         250 untracked remainder as profit
        wallet.executeAdapter(
            address(adapter),
            address(comet),
            abi.encodeWithSelector(adapter.withdraw.selector, totalBalance)
        );
        // proportionalCost = (1000 * 1250) / 1250 = 1000 (full cost basis)
        // profit = 1250 - 1000 = 250 (the untracked remainder)
        // fee on profit = 250 * 10% = 25
        uint256 secondFee = (250e6 * 1000) / 10_000;
        uint256 totalExpectedFees = firstFee + secondFee;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), totalExpectedFees, "FIX: Total fees correctly account for all untracked tokens");
        (uint256 finalCostBasis, uint256 finalShares) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(finalCostBasis, 0, "Cost basis fully cleared");
        assertEq(finalShares, 0, "Shares fully cleared");
    }
}
