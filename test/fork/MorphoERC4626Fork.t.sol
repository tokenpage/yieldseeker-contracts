// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {YieldSeekerERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MorphoERC4626ForkTest is ForkBase {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address internal constant MOONWELL_FLAGSHIP_USDC = 0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca;
    address internal constant STEAKHOUSE_USDC = 0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183;

    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;

    function test_MoonwellFlagshipUSDC_WithdrawalAccruesYieldAndChargesFee() public {
        _testVault(MOONWELL_FLAGSHIP_USDC);
    }

    function test_SteakhouseUSDC_WithdrawalAccruesYieldAndChargesFee() public {
        _testVault(STEAKHOUSE_USDC);
    }

    function _testVault(address vaultAddress) internal {
        assertEq(block.chainid, 8453, "Run this test against a Base fork");

        IERC20Metadata asset = IERC20Metadata(USDC);
        IERC4626 vault = IERC4626(vaultAddress);
        assertEq(vault.asset(), USDC, "Vault asset must be USDC");

        AgentWallet wallet = _createVaultWallet(USDC, 1);
        YieldSeekerERC4626Adapter adapter = new YieldSeekerERC4626Adapter();
        _registerAdapter(address(adapter), vaultAddress);
        deal(USDC, address(wallet), DEPOSIT_AMOUNT);

        bytes memory depositResult = _execute(wallet, address(adapter), vaultAddress, abi.encodeWithSelector(adapter.deposit.selector, DEPOSIT_AMOUNT));
        (uint256 shares, uint256 assetsDeposited) = abi.decode(abi.decode(depositResult, (bytes)), (uint256, uint256));
        assertEq(assetsDeposited, DEPOSIT_AMOUNT, "Vault deposit must consume the full requested amount");
        assertGt(shares, 0, "Deposit returned no vault shares");
        assertEq(vault.balanceOf(address(wallet)), shares, "Wallet shares must match minted shares");
        uint256 costBasis = vaultYieldFeeModule.costBasis(address(wallet), vaultAddress);
        assertEq(costBasis, DEPOSIT_AMOUNT, "Cost basis must match deposit");

        vm.warp(vm.getBlockTimestamp() + 90 days);
        vm.roll(block.number + 1);

        uint256 previewedAssets = vault.previewRedeem(shares);
        assertGt(previewedAssets, DEPOSIT_AMOUNT, "Vault share value should have accrued yield");

        uint256 feeCollectorBalanceBefore = asset.balanceOf(feeCollector);
        bytes memory withdrawResult = _execute(wallet, address(adapter), vaultAddress, abi.encodeWithSelector(adapter.withdraw.selector, shares));
        uint256 assetsReceived = abi.decode(abi.decode(withdrawResult, (bytes)), (uint256));
        assertEq(assetsReceived, previewedAssets, "Redeemed assets must match previewed value");
        assertEq(vault.balanceOf(address(wallet)), 0, "Live vault share balance should be fully withdrawn");

        uint256 expectedProfit = assetsReceived - DEPOSIT_AMOUNT;
        uint256 expectedFee = Math.mulDiv(expectedProfit, YIELD_FEE_BPS, 10_000, Math.Rounding.Ceil);
        costBasis = vaultYieldFeeModule.costBasis(address(wallet), vaultAddress);
        assertEq(costBasis, 0, "Cost basis should clear after full withdrawal");
        assertEq(asset.balanceOf(feeCollector) - feeCollectorBalanceBefore, expectedFee, "Live Morpho vault yield fee mismatch");
        uint256 ownerBalanceBefore = asset.balanceOf(owner);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, USDC);
        assertEq(asset.balanceOf(owner) - ownerBalanceBefore, assetsReceived - expectedFee);
        assertEq(asset.balanceOf(address(wallet)), 0);
    }
}
