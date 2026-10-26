// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {AdapterWalletHarness} from "../unit/adapters/AdapterHarness.t.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Test} from "forge-std/Test.sol";

/// @notice Fork test against live Base Morpho (MetaMorpho) ERC4626 USDC vaults. Run with:
///   forge test --fork-url http://127.0.0.1:8545 --match-path test/fork/MorphoERC4626Fork.t.sol -vv
contract MorphoERC4626ForkTest is Test {
    function setUp() public {
        if (block.chainid != 8453) vm.skip(true);
    }

    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    address internal constant MOONWELL_FLAGSHIP_USDC = 0xc1256Ae5FF1cf2719D4937adb3bbCCab2E00A2Ca;
    address internal constant STEAKHOUSE_USDC = 0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183;

    uint256 internal constant FEE_RATE_BPS = 1000;
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

        YieldSeekerFeeTracker feeTracker = new YieldSeekerFeeTracker(address(this), address(this), address(this));
        YieldSeekerYieldFeeModule vaultFees = new YieldSeekerYieldFeeModule(feeTracker, 5000);
        feeTracker.setFeeModule(YIELD_FEE, vaultFees);
        feeTracker.setPlanRate(0, YIELD_FEE, FEE_RATE_BPS);
        AdapterWalletHarness wallet = new AdapterWalletHarness(asset, feeTracker);
        YieldSeekerERC4626Adapter adapter = new YieldSeekerERC4626Adapter();
        deal(USDC, address(wallet), DEPOSIT_AMOUNT);

        bytes memory depositResult = wallet.executeAdapter(address(adapter), vaultAddress, abi.encodeWithSelector(adapter.deposit.selector, DEPOSIT_AMOUNT));
        (uint256 shares, uint256 assetsDeposited) = abi.decode(abi.decode(depositResult, (bytes)), (uint256, uint256));
        assertEq(assetsDeposited, DEPOSIT_AMOUNT, "Vault deposit must consume the full requested amount");
        assertGt(shares, 0, "Deposit returned no vault shares");
        assertEq(vault.balanceOf(address(wallet)), shares, "Wallet shares must match minted shares");
        uint256 costBasis = vaultFees.costBasis(address(wallet), vaultAddress);
        assertEq(costBasis, DEPOSIT_AMOUNT, "Cost basis must match deposit");

        // Advance time on the fork so the vault's price-per-share accrues real yield.
        vm.warp(vm.getBlockTimestamp() + 90 days);
        vm.roll(block.number + 1);

        uint256 previewedAssets = vault.previewRedeem(shares);
        assertGt(previewedAssets, DEPOSIT_AMOUNT, "Vault share value should have accrued yield");

        bytes memory withdrawResult = wallet.executeAdapter(address(adapter), vaultAddress, abi.encodeWithSelector(adapter.withdraw.selector, shares));
        uint256 assetsReceived = abi.decode(abi.decode(withdrawResult, (bytes)), (uint256));
        assertEq(assetsReceived, previewedAssets, "Redeemed assets must match previewed value");
        assertEq(vault.balanceOf(address(wallet)), 0, "Live vault share balance should be fully withdrawn");

        uint256 expectedProfit = assetsReceived - DEPOSIT_AMOUNT;
        uint256 expectedFee = (expectedProfit * FEE_RATE_BPS) / 10_000;
        costBasis = vaultFees.costBasis(address(wallet), vaultAddress);
        assertEq(costBasis, 0, "Cost basis should clear after full withdrawal");
        assertEq(vaultFees.feesCharged(address(wallet)), expectedFee, "Live Morpho vault yield fee mismatch");
    }
}
