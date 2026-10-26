// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerCompoundV2Adapter} from "../../src/adapters/CompoundV2Adapter.sol";
import {YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {VAULT_FEE, YieldSeekerVaultFeeModule} from "../../src/fees/VaultFeeModule.sol";
import {AdapterWalletHarness} from "../unit/adapters/AdapterHarness.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

interface IMoonwellMarket {
    function balanceOf(address account) external view returns (uint256);
    function balanceOfUnderlying(address account) external returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
}

contract MoonwellCompoundV2ForkTest is Test {
    function setUp() public {
        if (block.chainid != 8453) vm.skip(true);
    }
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;

    address internal constant MUSDC = 0xEdc817A28E8B93B03976FBd4a3dDBc9f7D176c22;
    address internal constant MWETH = 0x628ff693426583D9a7FB391E54366292F509D457;
    address internal constant MCBBTC = 0xF877ACaFA28c19b96727966690b2f44d35aD5976;

    uint256 internal constant FEE_RATE_BPS = 1000;

    function test_MoonwellUSDC_WithdrawalUsesLiveExchangeRate() public {
        _testMarket(MUSDC, USDC, 6, 1e6);
    }

    function test_MoonwellCbBTC_WithdrawalUsesLiveExchangeRate() public {
        _testMarket(MCBBTC, CBBTC, 8, 100_000);
    }

    function test_MoonwellWETH_WithdrawalUsesLiveExchangeRate() public {
        _testMarket(MWETH, WETH, 18, 1e15);
    }

    function _testMarket(address marketAddress, address assetAddress, uint8 expectedDecimals, uint256 depositAmount) internal {
        assertEq(block.chainid, 8453, "Run this test against a Base fork");

        IERC20Metadata asset = IERC20Metadata(assetAddress);
        IMoonwellMarket market = IMoonwellMarket(marketAddress);
        assertEq(asset.decimals(), expectedDecimals, "Unexpected underlying decimals");

        YieldSeekerFeeTracker feeTracker = new YieldSeekerFeeTracker(address(this), address(this), address(this));
        YieldSeekerVaultFeeModule vaultFees = new YieldSeekerVaultFeeModule(feeTracker, 5000);
        feeTracker.setFeeModule(VAULT_FEE, vaultFees);
        feeTracker.setPlanRate(0, VAULT_FEE, FEE_RATE_BPS);
        AdapterWalletHarness wallet = new AdapterWalletHarness(asset, feeTracker);
        YieldSeekerCompoundV2Adapter adapter = new YieldSeekerCompoundV2Adapter();
        deal(assetAddress, address(wallet), depositAmount);

        bytes memory depositResult = wallet.executeAdapter(address(adapter), marketAddress, abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        uint256 shares = abi.decode(abi.decode(depositResult, (bytes)), (uint256));
        assertGt(shares, 0, "Deposit returned no cToken shares");
        uint256 liveDepositBalanceBefore = market.balanceOfUnderlying(address(wallet));
        uint256 exchangeRate = market.exchangeRateCurrent();
        uint256 totalVaultBalanceBefore = (shares * exchangeRate) / 1e18;
        assertEq(liveDepositBalanceBefore, totalVaultBalanceBefore, "Live Compound V2 conversion mismatch");

        vm.warp(vm.getBlockTimestamp() + 30 days);
        deal(assetAddress, marketAddress, asset.balanceOf(marketAddress) + depositAmount);
        uint256 heldShares = market.balanceOf(address(wallet));
        uint256 liveBalanceBefore = market.balanceOfUnderlying(address(wallet));
        exchangeRate = market.exchangeRateCurrent();
        totalVaultBalanceBefore = (heldShares * exchangeRate) / 1e18;
        assertEq(liveBalanceBefore, totalVaultBalanceBefore, "Live Compound V2 conversion mismatch");

        bytes memory withdrawResult = wallet.executeAdapter(address(adapter), marketAddress, abi.encodeWithSelector(adapter.withdraw.selector, heldShares));
        uint256 assetsReceived = abi.decode(abi.decode(withdrawResult, (bytes)), (uint256));
        assertApproxEqAbs(assetsReceived, liveBalanceBefore, 1, "Full redemption must return the live underlying balance");
        assertEq(market.balanceOf(address(wallet)), 0, "All redeemed reward shares should leave the wallet");
        uint256 expectedFee = assetsReceived > depositAmount ? ((assetsReceived - depositAmount) * FEE_RATE_BPS) / 10_000 : 0;
        assertEq(vaultFees.costBasis(address(wallet), marketAddress), 0, "Cost basis should clear after withdrawal");
        assertEq(vaultFees.feesCharged(address(wallet)), expectedFee, "Redeemed reward shares are charged as yield");
        assertEq(vaultFees.feesPaid(address(wallet)), expectedFee, "Withdrawal fee should be paid immediately");
    }

    function test_MoonwellWETH_PartialWithdrawalUnwrapsNativeETHToWETH() public {
        assertEq(block.chainid, 8453, "Run this test against a Base fork");

        IERC20Metadata weth = IERC20Metadata(WETH);
        IMoonwellMarket market = IMoonwellMarket(MWETH);

        YieldSeekerFeeTracker feeTracker = new YieldSeekerFeeTracker(address(this), address(this), address(this));
        YieldSeekerVaultFeeModule vaultFees = new YieldSeekerVaultFeeModule(feeTracker, 5000);
        feeTracker.setFeeModule(VAULT_FEE, vaultFees);
        feeTracker.setPlanRate(0, VAULT_FEE, FEE_RATE_BPS);
        AdapterWalletHarness wallet = new AdapterWalletHarness(weth, feeTracker);
        YieldSeekerCompoundV2Adapter adapter = new YieldSeekerCompoundV2Adapter();

        uint256 depositAmount = 2e15;
        deal(WETH, address(wallet), depositAmount);

        wallet.executeAdapter(address(adapter), MWETH, abi.encodeWithSelector(adapter.deposit.selector, depositAmount));
        uint256 shares = market.balanceOf(address(wallet));
        uint256 sharesToWithdraw = shares / 2;
        uint256 exchangeRate = market.exchangeRateCurrent();
        uint256 expectedAssets = (sharesToWithdraw * exchangeRate) / 1e18;
        assertGt(sharesToWithdraw, 0, "Partial withdrawal must redeem cToken shares");
        assertEq(address(wallet).balance, 0, "Wallet should not hold native ETH before withdrawal");

        bytes memory withdrawResult = wallet.executeAdapter(address(adapter), MWETH, abi.encodeWithSelector(adapter.withdraw.selector, sharesToWithdraw));
        uint256 assetsReceived = abi.decode(abi.decode(withdrawResult, (bytes)), (uint256));

        assertApproxEqAbs(assetsReceived, expectedAssets, 1, "Should report assets received for redeemed shares");
        assertApproxEqAbs(weth.balanceOf(address(wallet)), expectedAssets, 1, "Native ETH from live Moonwell mWETH must be wrapped back into WETH");
        assertEq(address(wallet).balance, 0, "Wallet must not be left holding native ETH after withdrawal");
        uint256 remainingShares = market.balanceOf(address(wallet));
        assertGt(remainingShares, 0, "Remaining mWETH position should still be tracked after a partial withdrawal");
        uint256 costBasis = vaultFees.costBasis(address(wallet), MWETH);
        assertGt(costBasis, 0, "Remaining cost basis should still be tracked after a partial withdrawal");
    }
}
