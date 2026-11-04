// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {YieldSeekerCompoundV3Adapter} from "../../src/adapters/CompoundV3Adapter.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

interface IComet {
    function balanceOf(address account) external view returns (uint256);
}

contract CompoundV3ForkTest is ForkBase {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant COMET_USDC = 0xb125E6687d4313864e53df431d5425969c15Eb2F;

    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;

    function test_CompoundV3USDC_WithdrawalAccruesInterestAndChargesFee() public {
        assertEq(block.chainid, 8453, "Run this test against a Base fork");

        IERC20Metadata asset = IERC20Metadata(USDC);
        IComet comet = IComet(COMET_USDC);

        AgentWallet wallet = _createVaultWallet(USDC, 1);
        YieldSeekerCompoundV3Adapter adapter = new YieldSeekerCompoundV3Adapter();
        _registerAdapter(address(adapter), COMET_USDC);
        deal(USDC, address(wallet), DEPOSIT_AMOUNT);

        bytes memory depositResult = _execute(wallet, address(adapter), COMET_USDC, abi.encodeWithSelector(adapter.deposit.selector, DEPOSIT_AMOUNT));
        (uint256 shares, uint256 assetsDeposited) = abi.decode(abi.decode(depositResult, (bytes)), (uint256, uint256));
        assertEq(assetsDeposited, DEPOSIT_AMOUNT, "Compound V3 deposit must consume the full requested amount");
        assertApproxEqAbs(shares, DEPOSIT_AMOUNT, 2, "Compound V3 balance must increase ~1:1 with deposited assets");
        assertEq(comet.balanceOf(address(wallet)), shares, "Comet balance must match minted shares");
        uint256 costBasis = vaultYieldFeeModule.costBasis(address(wallet), COMET_USDC);
        assertEq(costBasis, DEPOSIT_AMOUNT, "Cost basis must match deposit");

        vm.warp(vm.getBlockTimestamp() + 90 days);
        vm.roll(block.number + 1);

        uint256 totalVaultBalanceBefore = comet.balanceOf(address(wallet));
        assertGt(totalVaultBalanceBefore, DEPOSIT_AMOUNT, "Comet balance should have accrued interest");

        uint256 feeCollectorBalanceBefore = asset.balanceOf(feeCollector);
        bytes memory withdrawResult = _execute(wallet, address(adapter), COMET_USDC, abi.encodeWithSelector(adapter.withdraw.selector, totalVaultBalanceBefore));
        uint256 assetsReceived = abi.decode(abi.decode(withdrawResult, (bytes)), (uint256));
        assertEq(assetsReceived, totalVaultBalanceBefore, "Full redemption must return the live Comet balance");
        assertEq(comet.balanceOf(address(wallet)), 0, "Live Comet balance should be fully withdrawn");

        uint256 expectedProfit = totalVaultBalanceBefore - DEPOSIT_AMOUNT;
        uint256 expectedFee = Math.mulDiv(expectedProfit, YIELD_FEE_BPS, 10_000, Math.Rounding.Ceil);
        costBasis = vaultYieldFeeModule.costBasis(address(wallet), COMET_USDC);
        assertEq(costBasis, 0, "Cost basis should clear after full withdrawal");
        assertEq(asset.balanceOf(feeCollector) - feeCollectorBalanceBefore, expectedFee, "Live Compound V3 interest fee mismatch");
        uint256 ownerBalanceBefore = asset.balanceOf(owner);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, USDC);
        assertEq(asset.balanceOf(owner) - ownerBalanceBefore, totalVaultBalanceBefore - expectedFee);
        assertEq(asset.balanceOf(address(wallet)), 0);
    }

    function test_CompoundV3USDC_DepositOfMaxSuppliesNothingAndLeavesNoApproval() public {
        AgentWallet wallet = _createVaultWallet(USDC, 2);
        YieldSeekerCompoundV3Adapter adapter = new YieldSeekerCompoundV3Adapter();
        _registerAdapter(address(adapter), COMET_USDC);
        deal(USDC, address(wallet), DEPOSIT_AMOUNT);

        _execute(wallet, address(adapter), COMET_USDC, abi.encodeWithSelector(adapter.deposit.selector, type(uint256).max));

        assertEq(IERC20Metadata(USDC).balanceOf(address(wallet)), DEPOSIT_AMOUNT, "Comet reads max as the wallet's (zero) borrow balance");
        assertEq(IERC20Metadata(USDC).allowance(address(wallet), COMET_USDC), 0, "no approval is left");
    }
}
