// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../../src/FeeTracker.sol";
import {AssetNotAllowed} from "../../../src/adapters/Adapter.sol";
import {YieldSeekerCompoundV3Adapter} from "../../../src/adapters/CompoundV3Adapter.sol";
import {AWKErrors} from "../../../src/agentwalletkit/AWKErrors.sol";
import {MockCompoundV3Comet} from "../../mocks/MockCompoundV3.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {AdapterWalletHarness} from "./AdapterHarness.t.sol";
import {Test} from "forge-std/Test.sol";

contract CompoundV3AdapterTest is Test {
    YieldSeekerCompoundV3Adapter adapter;
    YieldSeekerFeeTracker feeTracker;
    AdapterWalletHarness wallet;
    MockERC20 baseAsset;
    MockERC20 altAsset;
    MockCompoundV3Comet comet;

    function _decodeUint(bytes memory data) internal pure returns (uint256) {
        return abi.decode(abi.decode(data, (bytes)), (uint256));
    }

    function setUp() public {
        baseAsset = new MockERC20("Mock USDC", "mUSDC");
        altAsset = new MockERC20("Alt", "ALT");
        feeTracker = new YieldSeekerFeeTracker(address(this));
        feeTracker.setFeeConfig(1000, address(0xBEEF)); // 10% fee
        wallet = new AdapterWalletHarness(baseAsset, feeTracker);
        adapter = new YieldSeekerCompoundV3Adapter();
        comet = new MockCompoundV3Comet(address(baseAsset));
        baseAsset.mint(address(wallet), 1_000_000e6);
    }

    function test_Execute_Deposit_Succeeds() public {
        uint256 amount = 1_000e6;
        bytes memory result = wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.deposit.selector, amount));
        uint256 shares = _decodeUint(result);
        assertEq(shares, amount, "Should receive 1:1 shares for Compound V3");
        assertEq(comet.balanceOf(address(wallet)), amount, "Wallet should have Comet balance");
        assertEq(feeTracker.agentVaultCostBasis(address(wallet), address(comet)), amount, "Cost basis should be recorded");
        assertEq(feeTracker.agentVaultShares(address(wallet), address(comet)), amount, "Shares should be recorded");
    }

    function test_Execute_DepositPercentage_UsesBalance() public {
        uint256 initialBalance = baseAsset.balanceOf(address(wallet));
        bytes memory result = wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.depositPercentage.selector, uint256(5000)));
        uint256 shares = _decodeUint(result);
        uint256 expectedAmount = (initialBalance * 5000) / 10_000;
        assertEq(shares, expectedAmount, "Should receive expected shares");
        assertEq(baseAsset.balanceOf(address(wallet)), initialBalance - expectedAmount, "Wallet balance should decrease");
    }

    function test_Execute_DepositZeroAmount_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.deposit.selector, 0));
    }

    function test_Execute_Deposit_InvalidAsset_Reverts() public {
        MockCompoundV3Comet badComet = new MockCompoundV3Comet(address(altAsset));
        vm.expectRevert(abi.encodeWithSelector(AssetNotAllowed.selector));
        wallet.executeAdapter(address(adapter), address(badComet), abi.encodeWithSelector(adapter.deposit.selector, 1e6));
    }

    function test_Execute_Withdraw_Succeeds() public {
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.deposit.selector, 2_000e6));
        uint256 walletBalanceBefore = baseAsset.balanceOf(address(wallet));
        bytes memory result = wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.withdraw.selector, uint256(1_200e6)));
        uint256 assetsReceived = _decodeUint(result);
        assertEq(assetsReceived, 1_200e6, "Should receive correct assets");
        assertEq(baseAsset.balanceOf(address(wallet)), walletBalanceBefore + assetsReceived, "Wallet balance should increase");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(costBasis, 800e6, "Cost basis should be updated");
        assertEq(shares, 800e6, "Shares should be updated");
    }

    function test_Execute_WithdrawZeroShares_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.withdraw.selector, uint256(0)));
    }

    function test_FeeAccrual_PartialWithdraw_NoYield() public {
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.deposit.selector, 1_000e6));
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.withdraw.selector, uint256(500e6)));
        assertEq(feeTracker.agentFeesCharged(address(wallet)), 0, "Should not charge fee when no profit");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(costBasis, 500e6, "Cost basis should be halved after 50% withdrawal");
        assertEq(shares, 500e6, "Shares should be halved after 50% withdrawal");
    }

    function test_SequentialDeposits_AccumulateCostBasis() public {
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.deposit.selector, 1_000e6));
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.deposit.selector, 2_000e6));
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(costBasis, 3_000e6, "Cost basis should accumulate");
        assertEq(shares, 3_000e6, "Shares should accumulate");
    }

    function test_PartialWithdraw_ProportionalCostBasis() public {
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.deposit.selector, 2_000e6));
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.withdraw.selector, uint256(1_000e6)));
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(costBasis, 1_000e6, "Cost basis should be reduced proportionally");
        assertEq(shares, 1_000e6, "Shares should be reduced");
    }

    function test_FullWithdraw_ClearsCostBasis() public {
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.deposit.selector, 1_000e6));
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.withdraw.selector, uint256(1_000e6)));
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(costBasis, 0, "Cost basis should be zero after full withdrawal");
        assertEq(shares, 0, "Shares should be zero after full withdrawal");
    }

    function test_VirtualShares_YieldAccrual_FeeCharged() public {
        uint256 depositAmount = 1_000e6;
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        (uint256 costBasisBefore, uint256 sharesBefore) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(costBasisBefore, depositAmount, "Cost basis should match deposit");
        assertEq(sharesBefore, depositAmount, "Virtual shares should match deposit");
        uint256 yieldAmount = 100e6;
        comet.addYield(address(wallet), yieldAmount);
        baseAsset.mint(address(comet), yieldAmount);
        assertEq(comet.balanceOf(address(wallet)), depositAmount + yieldAmount, "Comet balance should include yield");
        uint256 fullBalance = depositAmount + yieldAmount;
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.withdraw.selector, fullBalance));
        uint256 profit = fullBalance - depositAmount;
        uint256 expectedFee = (profit * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "Should charge 10% fee on yield");
        (uint256 costBasisAfter, uint256 sharesAfter) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(costBasisAfter, 0, "Cost basis should be zero after full withdrawal");
        assertEq(sharesAfter, 0, "Shares should be zero after full withdrawal");
    }

    function test_VirtualShares_PartialWithdraw_WithYield() public {
        uint256 depositAmount = 1_000e6;
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        uint256 yieldAmount = 100e6;
        comet.addYield(address(wallet), yieldAmount);
        baseAsset.mint(address(comet), yieldAmount);
        uint256 totalBalance = depositAmount + yieldAmount;
        uint256 withdrawAmount = 550e6;
        bytes memory result = wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.withdraw.selector, withdrawAmount));
        uint256 assetsReceived = _decodeUint(result);
        assertEq(assetsReceived, withdrawAmount, "Should receive requested amount");
        uint256 proportionalCost = (depositAmount * withdrawAmount) / totalBalance;
        uint256 profit = assetsReceived - proportionalCost;
        uint256 expectedFee = (profit * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "Should charge correct fee");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(costBasis, depositAmount - proportionalCost, "Cost basis should be reduced proportionally");
        assertEq(shares, depositAmount - proportionalCost, "Shares should be reduced proportionally");
    }

    // ============ Audit Fix: Rebasing fee conversion uses 1:1 rate (Issue 1) ============

    function test_RebasingFeeConversion_NotInflated() public {
        uint256 depositAmount = 100e6;
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        vm.prank(address(wallet));
        feeTracker.recordAgentYieldTokenEarned(address(comet), 10e6);
        comet.addYield(address(wallet), 10e6);
        baseAsset.mint(address(comet), 10e6);
        uint256 feesBefore = feeTracker.agentFeesCharged(address(wallet));
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.withdraw.selector, uint256(50e6)));
        uint256 feesAfter = feeTracker.agentFeesCharged(address(wallet));
        uint256 feesCharged = feesAfter - feesBefore;
        uint256 expectedFeeTokenSettled = uint256(1e6) * uint256(50e6) / uint256(110e6);
        uint256 proportionalCost = (depositAmount * uint256(50e6)) / uint256(110e6);
        uint256 netAssets = uint256(50e6) - expectedFeeTokenSettled;
        uint256 expectedProfitFee = netAssets > proportionalCost ? ((netAssets - proportionalCost) * 1000) / 10_000 : 0;
        uint256 expectedTotalFees = expectedFeeTokenSettled + expectedProfitFee;
        assertEq(feesCharged, expectedTotalFees, "CompoundV3 fees should not be inflated for rebasing tokens");
    }

    // ============ Audit Fix: Deposit records actual amount, not type(uint256).max (Issue 4) ============

    function test_DepositRecordsAssetsDeposited() public {
        uint256 depositAmount = 500e6;
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(costBasis, depositAmount, "Cost basis should be actual deposited amount");
        assertEq(shares, depositAmount, "Shares should be actual deposited amount");
        comet.addYield(address(wallet), 50e6);
        baseAsset.mint(address(comet), 50e6);
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.withdraw.selector, uint256(250e6)));
        (uint256 costBasisAfter, uint256 sharesAfter) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertTrue(costBasisAfter < costBasis, "Cost basis should decrease after partial withdrawal");
        assertTrue(sharesAfter < shares, "Shares should decrease after partial withdrawal");
    }

    function test_MultiplePartialWithdraws_NoOverflow() public {
        uint256 depositAmount = 1_000e6;
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        comet.addYield(address(wallet), 100e6);
        baseAsset.mint(address(comet), 100e6);
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.withdraw.selector, uint256(300e6)));
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.withdraw.selector, uint256(300e6)));
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.withdraw.selector, uint256(300e6)));
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertTrue(costBasis < depositAmount, "Cost basis should be reduced");
        assertTrue(shares < depositAmount, "Shares should be reduced");
    }

    // ============ Audit Fix: Full lifecycle ============

    function test_FullLifecycle_CorrectFees() public {
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.deposit.selector, uint256(1_000e6)));
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(costBasis, 1_000e6, "Cost basis should be actual amount");
        assertEq(shares, 1_000e6, "Shares should be actual amount");
        comet.addYield(address(wallet), 100e6);
        baseAsset.mint(address(comet), 100e6);
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.withdraw.selector, uint256(550e6)));
        uint256 remaining = comet.balanceOf(address(wallet));
        wallet.executeAdapter(address(adapter), address(comet), abi.encodeWithSelector(adapter.withdraw.selector, remaining));
        (uint256 costBasisAfter, uint256 sharesAfter) = feeTracker.getAgentVaultPosition(address(wallet), address(comet));
        assertEq(costBasisAfter, 0);
        assertEq(sharesAfter, 0);
        uint256 totalFees = feeTracker.agentFeesCharged(address(wallet));
        uint256 expectedFee = (100e6 * 1000) / 10_000;
        assertEq(totalFees, expectedFee, "Total fees should equal 10% of 100 USDC yield");
    }
}
