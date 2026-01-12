// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../../src/FeeTracker.sol";
import {InvalidBaseAsset} from "../../../src/adapters/Adapter.sol";
import {YieldSeekerCompoundV2Adapter} from "../../../src/adapters/CompoundV2Adapter.sol";
import {AWKErrors} from "../../../src/agentwalletkit/AWKErrors.sol";
import {MockCToken} from "../../mocks/MockCompoundV2.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {AdapterWalletHarness} from "./AdapterHarness.t.sol";
import {Test} from "forge-std/Test.sol";

contract CompoundV2AdapterTest is Test {
    YieldSeekerCompoundV2Adapter adapter;
    YieldSeekerFeeTracker feeTracker;
    AdapterWalletHarness wallet;
    MockERC20 baseAsset;
    MockERC20 altAsset;
    MockCToken cToken;

    function _decodeUint(bytes memory data) internal pure returns (uint256) {
        return abi.decode(abi.decode(data, (bytes)), (uint256));
    }

    function setUp() public {
        baseAsset = new MockERC20("Mock USDC", "mUSDC");
        altAsset = new MockERC20("Alt", "ALT");
        feeTracker = new YieldSeekerFeeTracker(address(this));
        feeTracker.setFeeConfig(1000, address(0xBEEF)); // 10% fee
        wallet = new AdapterWalletHarness(baseAsset, feeTracker);
        adapter = new YieldSeekerCompoundV2Adapter();
        cToken = new MockCToken(address(baseAsset), "Mock mUSDC", "mUSDC");
        baseAsset.mint(address(wallet), 1_000_000e6);
    }

    function test_Execute_Deposit_Succeeds() public {
        uint256 amount = 1_000e6;
        bytes memory result = wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, amount));
        uint256 shares = _decodeUint(result);
        assertEq(shares, amount, "Should receive 1:1 shares at initial exchange rate");
        assertEq(cToken.balanceOf(address(wallet)), amount, "Wallet should have cTokens");
        assertEq(feeTracker.agentVaultCostBasis(address(wallet), address(cToken)), amount, "Cost basis should be recorded");
        assertEq(feeTracker.agentVaultShares(address(wallet), address(cToken)), amount, "Shares should be recorded");
    }

    function test_Execute_DepositPercentage_UsesBalance() public {
        uint256 initialBalance = baseAsset.balanceOf(address(wallet));
        bytes memory result = wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.depositPercentage.selector, uint256(2500)));
        uint256 shares = _decodeUint(result);
        uint256 expectedAmount = (initialBalance * 2500) / 10_000;
        assertEq(shares, expectedAmount, "Should receive expected shares");
        assertEq(baseAsset.balanceOf(address(wallet)), initialBalance - expectedAmount, "Wallet balance should decrease");
    }

    function test_Execute_DepositZeroAmount_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 0));
    }

    function test_Execute_Deposit_InvalidAsset_Reverts() public {
        MockCToken badCToken = new MockCToken(address(altAsset), "Bad", "BAD");
        vm.expectRevert(abi.encodeWithSelector(InvalidBaseAsset.selector));
        wallet.executeAdapter(address(adapter), address(badCToken), abi.encodeWithSelector(adapter.deposit.selector, 1e6));
    }

    function test_Execute_Withdraw_Succeeds() public {
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 2_000e6));
        uint256 walletBalanceBefore = baseAsset.balanceOf(address(wallet));
        bytes memory result = wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, uint256(1_200e6)));
        uint256 assetsReceived = _decodeUint(result);
        assertEq(assetsReceived, 1_200e6, "Should receive correct assets");
        assertEq(baseAsset.balanceOf(address(wallet)), walletBalanceBefore + assetsReceived, "Wallet balance should increase");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasis, 800e6, "Cost basis should be updated");
        assertEq(shares, 800e6, "Shares should be updated");
    }

    function test_Execute_WithdrawZeroShares_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, uint256(0)));
    }

    function test_FeeAccrual_PartialWithdraw_NoYield() public {
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 1_000e6));
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, uint256(500e6)));
        assertEq(feeTracker.agentFeesCharged(address(wallet)), 0, "Should not charge fee when no profit");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasis, 500e6, "Cost basis should be halved after 50% withdrawal");
        assertEq(shares, 500e6, "Shares should be halved after 50% withdrawal");
    }

    function test_SequentialDeposits_AccumulateCostBasis() public {
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 1_000e6));
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 2_000e6));
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasis, 3_000e6, "Cost basis should accumulate");
        assertEq(shares, 3_000e6, "Shares should accumulate");
    }

    function test_PartialWithdraw_ProportionalCostBasis() public {
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 2_000e6));
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, uint256(1_000e6)));
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasis, 1_000e6, "Cost basis should be reduced proportionally");
        assertEq(shares, 1_000e6, "Shares should be reduced");
    }

    function test_FullWithdraw_ClearsCostBasis() public {
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 1_000e6));
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, uint256(1_000e6)));
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasis, 0, "Cost basis should be zero after full withdrawal");
        assertEq(shares, 0, "Shares should be zero after full withdrawal");
    }

    function test_ExchangeRate_AffectsShareCalculation() public {
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 1_000e6));
        cToken.addYield(5000);
        baseAsset.mint(address(cToken), 500e6);
        bytes memory result = wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 1_000e6));
        uint256 shares = _decodeUint(result);
        assertLt(shares, 1_000e6, "Should receive fewer shares at higher exchange rate");
    }

    function test_VirtualShares_YieldAccrual_FeeCharged() public {
        uint256 depositAmount = 1_000e6;
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        (uint256 costBasisBefore, uint256 sharesBefore) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasisBefore, depositAmount, "Cost basis should match deposit");
        assertEq(sharesBefore, depositAmount, "Virtual shares should match deposit");
        uint256 yieldBps = 1000;
        cToken.addYield(yieldBps);
        baseAsset.mint(address(cToken), (depositAmount * yieldBps) / 10_000);
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, depositAmount));
        uint256 expectedAssets = (depositAmount * (10_000 + yieldBps)) / 10_000;
        uint256 profit = expectedAssets - depositAmount;
        uint256 expectedFee = (profit * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "Should charge 10% fee on yield");
        (uint256 costBasisAfter, uint256 sharesAfter) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasisAfter, 0, "Cost basis should be zero after full withdrawal");
        assertEq(sharesAfter, 0, "Shares should be zero after full withdrawal");
    }

    function test_VirtualShares_PartialWithdraw_WithYield() public {
        uint256 depositAmount = 1_000e6;
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        uint256 yieldBps = 1000;
        cToken.addYield(yieldBps);
        baseAsset.mint(address(cToken), (depositAmount * yieldBps) / 10_000);
        uint256 withdrawVirtualShares = 500e6;
        bytes memory result = wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, withdrawVirtualShares));
        uint256 assetsReceived = _decodeUint(result);
        uint256 totalValue = (depositAmount * (10_000 + yieldBps)) / 10_000;
        uint256 expectedAssets = (totalValue * withdrawVirtualShares) / depositAmount;
        assertEq(assetsReceived, expectedAssets, "Should receive proportional assets including yield");
        uint256 proportionalCost = (depositAmount * withdrawVirtualShares) / depositAmount;
        uint256 profit = assetsReceived - proportionalCost;
        uint256 expectedFee = (profit * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "Should charge correct fee");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasis, depositAmount - proportionalCost, "Cost basis should be reduced proportionally");
        assertEq(shares, depositAmount - withdrawVirtualShares, "Shares should be reduced by withdrawn amount");
    }
}
