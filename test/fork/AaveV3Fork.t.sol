// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerAaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {AdapterWalletHarness} from "../unit/adapters/AdapterHarness.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

interface IAaveAToken {
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Fork test against the live Base Aave V3 USDC market. Run with:
///   forge test --fork-url http://127.0.0.1:8545 --match-path test/fork/AaveV3Fork.t.sol -vv
contract AaveV3ForkTest is Test {
    function setUp() public {
        if (block.chainid != 8453) vm.skip(true);
    }

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant A_BAS_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

    uint256 internal constant FEE_RATE_BPS = 1000;
    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;

    function test_AaveUSDC_WithdrawalAccruesInterestAndChargesFee() public {
        assertEq(block.chainid, 8453, "Run this test against a Base fork");

        IERC20Metadata asset = IERC20Metadata(USDC);
        IAaveAToken aToken = IAaveAToken(A_BAS_USDC);

        YieldSeekerFeeTracker feeTracker = new YieldSeekerFeeTracker(address(this));
        feeTracker.setFeeConfig(FEE_RATE_BPS, address(this));
        AdapterWalletHarness wallet = new AdapterWalletHarness(asset, feeTracker);
        YieldSeekerAaveV3Adapter adapter = new YieldSeekerAaveV3Adapter();
        deal(USDC, address(wallet), DEPOSIT_AMOUNT);

        bytes memory depositResult = wallet.executeAdapter(address(adapter), A_BAS_USDC, abi.encodeWithSelector(adapter.deposit.selector, DEPOSIT_AMOUNT));
        (uint256 shares, uint256 assetsDeposited) = abi.decode(abi.decode(depositResult, (bytes)), (uint256, uint256));
        assertEq(assetsDeposited, DEPOSIT_AMOUNT, "Aave deposit must consume the full requested amount");
        assertApproxEqAbs(shares, DEPOSIT_AMOUNT, 1, "Aave aTokens must mint ~1:1 with deposited assets");
        assertEq(aToken.balanceOf(address(wallet)), shares, "aToken balance must match minted shares");
        assertEq(feeTracker.agentVaultCostBasis(address(wallet), A_BAS_USDC), DEPOSIT_AMOUNT, "Cost basis must match deposit");

        // Advance time on the fork so the rebasing aToken balance accrues real interest.
        vm.warp(block.timestamp + 90 days);
        vm.roll(block.number + 1);

        uint256 totalVaultBalanceBefore = aToken.balanceOf(address(wallet));
        assertGt(totalVaultBalanceBefore, DEPOSIT_AMOUNT, "Aave aToken balance should have accrued interest");

        bytes memory withdrawResult = wallet.executeAdapter(address(adapter), A_BAS_USDC, abi.encodeWithSelector(adapter.withdraw.selector, totalVaultBalanceBefore));
        uint256 assetsReceived = abi.decode(abi.decode(withdrawResult, (bytes)), (uint256));
        assertEq(assetsReceived, totalVaultBalanceBefore, "Full redemption must return the live aToken balance");
        assertEq(aToken.balanceOf(address(wallet)), 0, "Live aToken balance should be fully withdrawn");

        uint256 expectedProfit = totalVaultBalanceBefore - DEPOSIT_AMOUNT;
        uint256 expectedFee = (expectedProfit * FEE_RATE_BPS) / 10_000;
        assertEq(feeTracker.agentVaultCostBasis(address(wallet), A_BAS_USDC), 0, "Cost basis should clear after full withdrawal");
        assertEq(feeTracker.agentVaultShares(address(wallet), A_BAS_USDC), 0, "Tracked shares should clear after full withdrawal");
        assertEq(feeTracker.agentFeesCharged(address(wallet)), expectedFee, "Live Aave interest fee mismatch");
    }
}
