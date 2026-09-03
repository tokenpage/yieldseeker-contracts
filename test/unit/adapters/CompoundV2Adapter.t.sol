// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../../src/FeeTracker.sol";
import {AssetNotAllowed} from "../../../src/adapters/Adapter.sol";
import {YieldSeekerCompoundV2Adapter} from "../../../src/adapters/CompoundV2Adapter.sol";
import {AWKErrors} from "../../../src/agentwalletkit/AWKErrors.sol";
import {MockCNativeToken, MockCToken} from "../../mocks/MockCompoundV2.sol";
import {MockERC20, MockERC20WithDecimals} from "../../mocks/MockERC20.sol";
import {MockWETH} from "../../mocks/MockWETH.sol";
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

    function _sharesForAssets(uint256 assets) internal view returns (uint256) {
        return (assets * 1e18) / cToken.exchangeRateCurrent();
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
        uint256 expectedShares = _sharesForAssets(amount);
        assertEq(shares, expectedShares, "Should receive exchange-rate-adjusted shares");
        assertEq(cToken.balanceOf(address(wallet)), expectedShares, "Wallet should have cTokens");
        assertEq(feeTracker.agentVaultCostBasis(address(wallet), address(cToken)), amount, "Cost basis should be recorded");
        assertEq(feeTracker.agentVaultShares(address(wallet), address(cToken)), expectedShares, "Shares should be recorded");
    }

    function test_Execute_DepositPercentage_UsesBalance() public {
        uint256 initialBalance = baseAsset.balanceOf(address(wallet));
        bytes memory result = wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.depositPercentage.selector, uint256(2500)));
        uint256 shares = _decodeUint(result);
        uint256 expectedAmount = (initialBalance * 2500) / 10_000;
        assertEq(shares, _sharesForAssets(expectedAmount), "Should receive exchange-rate-adjusted shares");
        assertEq(baseAsset.balanceOf(address(wallet)), initialBalance - expectedAmount, "Wallet balance should decrease");
    }

    function test_Execute_DepositZeroAmount_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 0));
    }

    function test_Execute_Deposit_InvalidAsset_Reverts() public {
        MockCToken badCToken = new MockCToken(address(altAsset), "Bad", "BAD");
        vm.expectRevert(abi.encodeWithSelector(AssetNotAllowed.selector));
        wallet.executeAdapter(address(adapter), address(badCToken), abi.encodeWithSelector(adapter.deposit.selector, 1e6));
    }

    function test_Execute_Withdraw_Succeeds() public {
        uint256 depositAmount = 2_000e6;
        uint256 withdrawAmount = 1_200e6;
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        uint256 walletBalanceBefore = baseAsset.balanceOf(address(wallet));
        bytes memory result = wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, withdrawAmount));
        uint256 assetsReceived = _decodeUint(result);
        assertEq(assetsReceived, withdrawAmount, "Should receive correct assets");
        assertEq(baseAsset.balanceOf(address(wallet)), walletBalanceBefore + assetsReceived, "Wallet balance should increase");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasis, depositAmount - withdrawAmount, "Cost basis should be updated");
        assertEq(shares, _sharesForAssets(depositAmount - withdrawAmount), "Shares should be updated");
    }

    function test_Execute_WithdrawZeroShares_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, uint256(0)));
    }

    function test_FeeAccrual_PartialWithdraw_NoYield() public {
        uint256 depositAmount = 1_000e6;
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, uint256(500e6)));
        assertEq(feeTracker.agentFeesCharged(address(wallet)), 0, "Should not charge fee when no profit");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasis, 500e6, "Cost basis should be halved after 50% withdrawal");
        assertEq(shares, _sharesForAssets(500e6), "Shares should be halved after 50% withdrawal");
    }

    function test_SequentialDeposits_AccumulateCostBasis() public {
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 1_000e6));
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 2_000e6));
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasis, 3_000e6, "Cost basis should accumulate");
        assertEq(shares, _sharesForAssets(3_000e6), "Shares should accumulate");
    }

    function test_PartialWithdraw_ProportionalCostBasis() public {
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 2_000e6));
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, uint256(1_000e6)));
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasis, 1_000e6, "Cost basis should be reduced proportionally");
        assertEq(shares, _sharesForAssets(1_000e6), "Shares should be reduced");
    }

    function test_FullWithdraw_ClearsCostBasis() public {
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 1_000e6));
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, uint256(1_000e6)));
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasis, 0, "Cost basis should be zero after full withdrawal");
        assertEq(shares, 0, "Shares should be zero after full withdrawal");
    }

    function test_ExchangeRate_AffectsShareCalculation() public {
        uint256 initialShares = _sharesForAssets(1_000e6);
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 1_000e6));
        cToken.addYield(5000);
        baseAsset.mint(address(cToken), 500e6);
        bytes memory result = wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, 1_000e6));
        uint256 shares = _decodeUint(result);
        assertLt(shares, initialShares, "Should receive fewer shares at higher exchange rate");
    }

    function test_VirtualShares_YieldAccrual_FeeCharged() public {
        uint256 depositAmount = 1_000e6;
        uint256 initialShares = _sharesForAssets(depositAmount);
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        (uint256 costBasisBefore, uint256 sharesBefore) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasisBefore, depositAmount, "Cost basis should match deposit");
        assertEq(sharesBefore, initialShares, "Shares should match cToken balance");
        uint256 yieldBps = 1000;
        cToken.addYield(yieldBps);
        baseAsset.mint(address(cToken), (depositAmount * yieldBps) / 10_000);
        uint256 fullBalance = (depositAmount * (10_000 + yieldBps)) / 10_000;
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, fullBalance));
        uint256 profit = fullBalance - depositAmount;
        uint256 expectedFee = (profit * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "Should charge 10% fee on yield");
        (uint256 costBasisAfter, uint256 sharesAfter) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasisAfter, 0, "Cost basis should be zero after full withdrawal");
        assertEq(sharesAfter, 0, "Shares should be zero after full withdrawal");
    }

    function test_VirtualShares_PartialWithdraw_WithYield() public {
        uint256 depositAmount = 1_000e6;
        uint256 initialShares = _sharesForAssets(depositAmount);
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        uint256 yieldBps = 1000;
        cToken.addYield(yieldBps);
        baseAsset.mint(address(cToken), (depositAmount * yieldBps) / 10_000);
        uint256 totalBalance = (depositAmount * (10_000 + yieldBps)) / 10_000;
        uint256 withdrawAmount = 550e6;
        bytes memory result = wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, withdrawAmount));
        uint256 assetsReceived = _decodeUint(result);
        assertEq(assetsReceived, withdrawAmount, "Should receive requested amount");
        uint256 proportionalCost = (depositAmount * withdrawAmount) / totalBalance;
        uint256 proportionalShares = (initialShares * withdrawAmount) / totalBalance;
        uint256 profit = assetsReceived - proportionalCost;
        uint256 expectedFee = (profit * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "Should charge correct fee");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(cToken));
        assertEq(costBasis, depositAmount - proportionalCost, "Cost basis should be reduced proportionally");
        assertEq(shares, initialShares - proportionalShares, "Shares should be reduced proportionally");
    }

    // ============ Audit Fix: Uses exchangeRateCurrent (Issue 3) ============

    function test_ExchangeRateCurrent_CorrectFees() public {
        uint256 depositAmount = 1_000e6;
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        cToken.addYield(1000);
        baseAsset.mint(address(cToken), 100e6);
        uint256 fullBalance = (depositAmount * 11000) / 10000;
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, fullBalance));
        uint256 profit = fullBalance - depositAmount;
        uint256 expectedFee = (profit * 1000) / 10_000;
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "Should charge correct fee with current exchange rate");
    }

    function test_CompoundV2_WithVaultTokenFees_UsesExchangeRate() public {
        uint256 depositAmount = 1_000e6;
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        cToken.addYield(1000);
        baseAsset.mint(address(cToken), 100e6);
        vm.prank(address(wallet));
        feeTracker.recordAgentYieldTokenEarned(address(cToken), 50e6);
        uint256 feesBefore = feeTracker.agentFeesCharged(address(wallet));
        wallet.executeAdapter(address(adapter), address(cToken), abi.encodeWithSelector(adapter.withdraw.selector, uint256(550e6)));
        uint256 feesAfter = feeTracker.agentFeesCharged(address(wallet));
        assertTrue(feesAfter > feesBefore, "CompoundV2 should charge fees using the exchange rate");
    }

    function test_DecimalVariant_CbBTC() public {
        _testDecimalVariant(8, 1e8);
    }

    function test_DecimalVariant_WETH() public {
        _testDecimalVariant(18, 1e18);
    }

    function _testDecimalVariant(uint8 decimals_, uint256 amount) internal {
        MockERC20WithDecimals asset = new MockERC20WithDecimals("Variant", "VAR", decimals_);
        MockCToken variantCToken = new MockCToken(address(asset), "Variant cToken", "vVAR");
        AdapterWalletHarness variantWallet = new AdapterWalletHarness(asset, feeTracker);
        asset.mint(address(variantWallet), amount);

        bytes memory depositResult = variantWallet.executeAdapter(address(adapter), address(variantCToken), abi.encodeWithSelector(adapter.deposit.selector, amount));
        uint256 expectedShares = (amount * 1e18) / variantCToken.exchangeRateCurrent();
        assertEq(_decodeUint(depositResult), expectedShares);
        assertEq(variantCToken.decimals(), 8);
        assertEq(variantCToken.balanceOf(address(variantWallet)), expectedShares);

        uint256 yieldAmount = amount / 10;
        variantCToken.addYield(1000);
        asset.mint(address(variantCToken), yieldAmount);
        bytes memory withdrawResult = variantWallet.executeAdapter(address(adapter), address(variantCToken), abi.encodeWithSelector(adapter.withdraw.selector, amount + yieldAmount));

        assertEq(_decodeUint(withdrawResult), amount + yieldAmount);
        assertEq(feeTracker.agentFeesCharged(address(variantWallet)), yieldAmount / 10);
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(variantWallet), address(variantCToken));
        assertEq(costBasis, 0);
        assertEq(shares, 0);
    }

    function test_PartialWithdraw_NativeETHMarket_WrapsToWETH() public {
        MockWETH weth = new MockWETH();
        MockCNativeToken nativeCToken = new MockCNativeToken(payable(address(weth)), "Native mWETH", "mWETH");
        AdapterWalletHarness nativeWallet = new AdapterWalletHarness(weth, feeTracker);
        vm.deal(address(this), 10e18);
        weth.deposit{value: 10e18}();
        require(weth.transfer(address(nativeWallet), 10e18), "Transfer failed");

        uint256 depositAmount = 10e18;
        uint256 withdrawAmount = 4e18;
        nativeWallet.executeAdapter(address(adapter), address(nativeCToken), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        bytes memory withdrawResult = nativeWallet.executeAdapter(address(adapter), address(nativeCToken), abi.encodeWithSelector(adapter.withdraw.selector, withdrawAmount));
        uint256 assetsReceived = _decodeUint(withdrawResult);

        assertEq(assetsReceived, withdrawAmount, "Should report the requested underlying amount");
        assertEq(weth.balanceOf(address(nativeWallet)), withdrawAmount, "Native ETH must be wrapped back into WETH");
        assertEq(address(nativeWallet).balance, 0, "Wallet must not be left holding native ETH");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(nativeWallet), address(nativeCToken));
        assertEq(costBasis, depositAmount - withdrawAmount, "Cost basis should be reduced proportionally");
        assertGt(shares, 0, "Remaining shares should still be tracked after a partial withdrawal");
    }

    function test_FullWithdraw_NativeETHMarket_WrapsToWETH() public {
        MockWETH weth = new MockWETH();
        MockCNativeToken nativeCToken = new MockCNativeToken(payable(address(weth)), "Native mWETH", "mWETH");
        AdapterWalletHarness nativeWallet = new AdapterWalletHarness(weth, feeTracker);
        vm.deal(address(this), 5e18);
        weth.deposit{value: 5e18}();
        require(weth.transfer(address(nativeWallet), 5e18), "Transfer failed");

        uint256 depositAmount = 5e18;
        nativeWallet.executeAdapter(address(adapter), address(nativeCToken), abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        bytes memory withdrawResult = nativeWallet.executeAdapter(address(adapter), address(nativeCToken), abi.encodeWithSelector(adapter.withdraw.selector, depositAmount));
        uint256 assetsReceived = _decodeUint(withdrawResult);

        assertEq(assetsReceived, depositAmount, "Should report the full underlying amount");
        assertEq(weth.balanceOf(address(nativeWallet)), depositAmount, "Native ETH must be wrapped back into WETH");
        assertEq(address(nativeWallet).balance, 0, "Wallet must not be left holding native ETH");
        assertEq(nativeCToken.balanceOf(address(nativeWallet)), 0, "cToken balance should be fully withdrawn");
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(nativeWallet), address(nativeCToken));
        assertEq(costBasis, 0, "Cost basis should clear after full withdrawal");
        assertEq(shares, 0, "Shares should clear after full withdrawal");
    }
}
