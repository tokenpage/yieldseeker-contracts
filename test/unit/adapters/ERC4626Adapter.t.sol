// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../../src/FeeTracker.sol";
import {InvalidBaseAsset} from "../../../src/adapters/Adapter.sol";
import {YieldSeekerERC4626Adapter} from "../../../src/adapters/ERC4626Adapter.sol";
import {AWKErrors} from "../../../src/agentwalletkit/AWKErrors.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {AdapterWalletHarness} from "./AdapterHarness.t.sol";
import {Test} from "forge-std/Test.sol";

contract ERC4626AdapterTest is Test {
    YieldSeekerERC4626Adapter adapter;
    YieldSeekerFeeTracker feeTracker;
    AdapterWalletHarness wallet;
    MockERC20 baseAsset;
    MockERC20 altAsset;
    MockERC4626 vault;

    function _decodeUint(bytes memory data) internal pure returns (uint256) {
        return abi.decode(abi.decode(data, (bytes)), (uint256));
    }

    function setUp() public {
        baseAsset = new MockERC20("Mock USDC", "mUSDC");
        altAsset = new MockERC20("Alt", "ALT");
        feeTracker = new YieldSeekerFeeTracker(address(this));
        feeTracker.setFeeConfig(1000, address(0xBEEF));
        wallet = new AdapterWalletHarness(baseAsset, feeTracker);
        adapter = new YieldSeekerERC4626Adapter();
        vault = new MockERC4626(address(baseAsset), "Vault", "vUSDC");
        baseAsset.mint(address(wallet), 1_000_000e6);
    }

    function test_Execute_Deposit_Succeeds() public {
        uint256 amount = 1_000e6;
        bytes memory result = wallet.executeAdapter(address(adapter), address(vault), abi.encodeWithSelector(adapter.deposit.selector, amount));
        uint256 shares = _decodeUint(result);
        assertEq(shares, amount);
        assertEq(vault.balanceOf(address(wallet)), amount);
        assertEq(feeTracker.agentVaultCostBasis(address(wallet), address(vault)), amount);
        assertEq(feeTracker.agentVaultShares(address(wallet), address(vault)), amount);
    }

    function test_Execute_DepositPercentage_UsesBalance() public {
        uint256 initialBalance = baseAsset.balanceOf(address(wallet));
        bytes memory result = wallet.executeAdapter(address(adapter), address(vault), abi.encodeWithSelector(adapter.depositPercentage.selector, uint256(2500)));
        uint256 shares = _decodeUint(result);
        uint256 expectedAmount = (initialBalance * 2500) / 10_000;
        assertEq(shares, expectedAmount);
        assertEq(baseAsset.balanceOf(address(wallet)), initialBalance - expectedAmount);
    }

    function test_Execute_DepositZeroAmount_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        wallet.executeAdapter(address(adapter), address(vault), abi.encodeWithSelector(adapter.deposit.selector, 0));
    }

    function test_Execute_Deposit_InvalidAsset_Reverts() public {
        MockERC4626 badVault = new MockERC4626(address(altAsset), "Bad", "bALT");
        vm.expectRevert(abi.encodeWithSelector(InvalidBaseAsset.selector));
        wallet.executeAdapter(address(adapter), address(badVault), abi.encodeWithSelector(adapter.deposit.selector, 1e6));
    }

    function test_Execute_Withdraw_Succeeds() public {
        wallet.executeAdapter(address(adapter), address(vault), abi.encodeWithSelector(adapter.deposit.selector, 2_000e6));
        uint256 walletBalanceBefore = baseAsset.balanceOf(address(wallet));
        bytes memory result = wallet.executeAdapter(address(adapter), address(vault), abi.encodeWithSelector(adapter.withdraw.selector, uint256(1_200e6)));
        uint256 assetsReceived = _decodeUint(result);
        assertEq(assetsReceived, 1_200e6);
        assertEq(baseAsset.balanceOf(address(wallet)), walletBalanceBefore + assetsReceived);
        (uint256 costBasis, uint256 shares) = feeTracker.getAgentVaultPosition(address(wallet), address(vault));
        assertEq(costBasis, 800e6);
        assertEq(shares, 800e6);
    }

    function test_Execute_WithdrawZeroShares_Reverts() public {
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        wallet.executeAdapter(address(adapter), address(vault), abi.encodeWithSelector(adapter.withdraw.selector, uint256(0)));
    }

    function test_FeeAccrual_OnProfitableWithdraw() public {
        wallet.executeAdapter(address(adapter), address(vault), abi.encodeWithSelector(adapter.deposit.selector, 1_000e6));
        baseAsset.mint(address(vault), 500e6);
        wallet.executeAdapter(address(adapter), address(vault), abi.encodeWithSelector(adapter.withdraw.selector, uint256(1_000e6)));
        assertEq(feeTracker.agentFeesCharged(address(wallet)), 50e6);
    }

    function test_Deposit_PrecisionWithExistingShares() public {
        wallet.executeAdapter(address(adapter), address(vault), abi.encodeWithSelector(adapter.deposit.selector, 1_000e6));
        baseAsset.mint(address(vault), 1_000e6);
        bytes memory result = wallet.executeAdapter(address(adapter), address(vault), abi.encodeWithSelector(adapter.deposit.selector, 500e6));
        uint256 shares = _decodeUint(result);
        assertGe(shares, 250e6);
    }

    function test_Withdraw_PrecisionWithExistingShares() public {
        wallet.executeAdapter(address(adapter), address(vault), abi.encodeWithSelector(adapter.deposit.selector, 2_000e6));
        baseAsset.mint(address(vault), 1_000e6);
        bytes memory result = wallet.executeAdapter(address(adapter), address(vault), abi.encodeWithSelector(adapter.withdraw.selector, uint256(1_000e6)));
        uint256 assets = _decodeUint(result);
        assertGt(assets, 1_000e6);
    }
}
