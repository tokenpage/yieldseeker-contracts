// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {YieldSeekerAaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

interface IAaveAToken {
    function balanceOf(address account) external view returns (uint256);
}

contract AaveV3ForkTest is ForkBase {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant A_BAS_USDC = 0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB;

    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;

    function test_AaveUSDC_WithdrawalAccruesInterestAndChargesFee() public {
        assertEq(block.chainid, 8453, "Run this test against a Base fork");

        IERC20Metadata asset = IERC20Metadata(USDC);
        IAaveAToken aToken = IAaveAToken(A_BAS_USDC);

        AgentWallet wallet = _createVaultWallet(USDC, 1);
        YieldSeekerAaveV3Adapter adapter = new YieldSeekerAaveV3Adapter();
        _registerAdapter(address(adapter), A_BAS_USDC);
        deal(USDC, address(wallet), DEPOSIT_AMOUNT);

        bytes memory depositResult = _execute(wallet, address(adapter), A_BAS_USDC, abi.encodeWithSelector(adapter.deposit.selector, DEPOSIT_AMOUNT));
        (uint256 shares, uint256 assetsDeposited) = abi.decode(abi.decode(depositResult, (bytes)), (uint256, uint256));
        assertEq(assetsDeposited, DEPOSIT_AMOUNT, "Aave deposit must consume the full requested amount");
        assertApproxEqAbs(shares, DEPOSIT_AMOUNT, 10, "Aave aTokens must mint ~1:1 with deposited assets");
        assertEq(aToken.balanceOf(address(wallet)), shares, "aToken balance must match minted shares");
        uint256 costBasis = vaultYieldFeeModule.costBasis(address(wallet), A_BAS_USDC);
        assertEq(costBasis, DEPOSIT_AMOUNT, "Cost basis must match deposit");

        vm.warp(vm.getBlockTimestamp() + 90 days);
        vm.roll(block.number + 1);

        uint256 totalVaultBalanceBefore = aToken.balanceOf(address(wallet));
        assertGt(totalVaultBalanceBefore, DEPOSIT_AMOUNT, "Aave aToken balance should have accrued interest");

        uint256 feeCollectorBalanceBefore = asset.balanceOf(feeCollector);
        bytes memory withdrawResult = _execute(wallet, address(adapter), A_BAS_USDC, abi.encodeWithSelector(adapter.withdraw.selector, totalVaultBalanceBefore));
        uint256 assetsReceived = abi.decode(abi.decode(withdrawResult, (bytes)), (uint256));
        assertEq(assetsReceived, totalVaultBalanceBefore, "Full redemption must return the live aToken balance");
        assertEq(aToken.balanceOf(address(wallet)), 0, "Live aToken balance should be fully withdrawn");

        uint256 expectedProfit = totalVaultBalanceBefore - DEPOSIT_AMOUNT;
        uint256 expectedFee = (expectedProfit * YIELD_FEE_BPS) / 10_000;
        costBasis = vaultYieldFeeModule.costBasis(address(wallet), A_BAS_USDC);
        assertEq(costBasis, 0, "Cost basis should clear after full withdrawal");
        assertEq(asset.balanceOf(feeCollector) - feeCollectorBalanceBefore, expectedFee, "Live Aave interest fee mismatch");
        uint256 ownerBalanceBefore = asset.balanceOf(owner);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, USDC);
        assertEq(asset.balanceOf(owner) - ownerBalanceBefore, totalVaultBalanceBefore - expectedFee);
        assertEq(asset.balanceOf(address(wallet)), 0);
    }
}
