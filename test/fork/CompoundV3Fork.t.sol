// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerCompoundV3Adapter} from "../../src/adapters/CompoundV3Adapter.sol";
import {AdapterWalletHarness} from "../unit/adapters/AdapterHarness.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

interface IComet {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Fork test against the live Base Compound V3 (Comet) USDC market. Run with:
///   forge test --fork-url http://127.0.0.1:8545 --match-path test/fork/CompoundV3Fork.t.sol -vv
contract CompoundV3ForkTest is Test {
    function setUp() public {
        if (block.chainid != 8453) vm.skip(true);
    }

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant COMET_USDC = 0xb125E6687d4313864e53df431d5425969c15Eb2F;

    uint256 internal constant FEE_RATE_BPS = 1000;
    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;

    function test_CompoundV3USDC_WithdrawalAccruesInterestAndChargesFee() public {
        assertEq(block.chainid, 8453, "Run this test against a Base fork");

        IERC20Metadata asset = IERC20Metadata(USDC);
        IComet comet = IComet(COMET_USDC);

        YieldSeekerFeeTracker feeTracker = new YieldSeekerFeeTracker(address(this));
        feeTracker.setFeeConfig(FEE_RATE_BPS, address(this));
        AdapterWalletHarness wallet = new AdapterWalletHarness(asset, feeTracker);
        YieldSeekerCompoundV3Adapter adapter = new YieldSeekerCompoundV3Adapter();
        deal(USDC, address(wallet), DEPOSIT_AMOUNT);

        bytes memory depositResult = wallet.executeAdapter(address(adapter), COMET_USDC, abi.encodeWithSelector(adapter.deposit.selector, DEPOSIT_AMOUNT));
        (uint256 shares, uint256 assetsDeposited) = abi.decode(abi.decode(depositResult, (bytes)), (uint256, uint256));
        assertEq(assetsDeposited, DEPOSIT_AMOUNT, "Compound V3 deposit must consume the full requested amount");
        assertApproxEqAbs(shares, DEPOSIT_AMOUNT, 1, "Compound V3 balance must increase ~1:1 with deposited assets");
        assertEq(comet.balanceOf(address(wallet)), shares, "Comet balance must match minted shares");
        assertEq(feeTracker.agentVaultCostBasis(address(wallet), COMET_USDC), DEPOSIT_AMOUNT, "Cost basis must match deposit");

        // Advance time on the fork so the rebasing Comet balance accrues real interest.
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + 1);

        uint256 totalVaultBalanceBefore = comet.balanceOf(address(wallet));
        assertGt(totalVaultBalanceBefore, DEPOSIT_AMOUNT, "Comet balance should have accrued interest");

        bytes memory withdrawResult = wallet.executeAdapter(address(adapter), COMET_USDC, abi.encodeWithSelector(adapter.withdraw.selector, totalVaultBalanceBefore));
        uint256 assetsReceived = abi.decode(abi.decode(withdrawResult, (bytes)), (uint256));
        assertEq(assetsReceived, totalVaultBalanceBefore, "Full redemption must return the live Comet balance");
        assertEq(comet.balanceOf(address(wallet)), 0, "Live Comet balance should be fully withdrawn");

        uint256 expectedProfit = totalVaultBalanceBefore - DEPOSIT_AMOUNT;
        uint256 expectedFee = (expectedProfit * FEE_RATE_BPS) / 10_000;
        assertEq(feeTracker.agentVaultCostBasis(address(wallet), COMET_USDC), 0, "Cost basis should clear after full withdrawal");
        assertEq(feeTracker.agentVaultShares(address(wallet), COMET_USDC), 0, "Tracked shares should clear after full withdrawal");
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "Live Compound V3 interest fee mismatch");
    }
}
