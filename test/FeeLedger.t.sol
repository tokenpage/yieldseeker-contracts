// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeLedger as FeeLedger} from "../src/FeeLedger.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Test} from "forge-std/Test.sol";

contract FeeLedgerTest is Test {
    FeeLedger public ledger;
    FeeLedger public ledgerImpl;

    address public admin = address(0x1);
    address public wallet1 = address(0x100);
    address public wallet2 = address(0x200);
    address public vault1 = address(0x1000);
    address public vault2 = address(0x2000);
    address public feeCollector = address(0x9999);

    function setUp() public {
        ledgerImpl = new FeeLedger();
        ERC1967Proxy proxy = new ERC1967Proxy(address(ledgerImpl), abi.encodeWithSelector(FeeLedger.initialize.selector, admin));
        ledger = FeeLedger(address(proxy));
        vm.prank(admin);
        ledger.setFeeConfig(1000, feeCollector); // 10% fee
    }

    // ============ Initialization Tests ============

    function test_Initialize() public view {
        assertEq(ledger.feeRateBps(), 1000);
        assertEq(ledger.feeCollector(), feeCollector);
        assertTrue(ledger.hasRole(ledger.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_Initialize_RevertsOnZeroAdmin() public {
        FeeLedger impl = new FeeLedger();
        vm.expectRevert(FeeLedger.ZeroAddress.selector);
        new ERC1967Proxy(address(impl), abi.encodeWithSelector(FeeLedger.initialize.selector, address(0)));
    }

    function test_CannotReinitialize() public {
        vm.expectRevert();
        ledger.initialize(address(0x999));
    }

    // ============ Fee Config Tests ============

    function test_SetFeeConfig() public {
        vm.prank(admin);
        ledger.setFeeConfig(2000, address(0x8888));
        assertEq(ledger.feeRateBps(), 2000);
        assertEq(ledger.feeCollector(), address(0x8888));
    }

    function test_SetFeeConfig_RevertsOnExcessiveRate() public {
        vm.prank(admin);
        vm.expectRevert(FeeLedger.InvalidFeeRate.selector);
        ledger.setFeeConfig(5001, feeCollector);
    }

    function test_SetFeeConfig_RevertsOnZeroCollector() public {
        vm.prank(admin);
        vm.expectRevert(FeeLedger.ZeroAddress.selector);
        ledger.setFeeConfig(1000, address(0));
    }

    function test_SetFeeConfig_OnlyAdmin() public {
        vm.prank(wallet1);
        vm.expectRevert();
        ledger.setFeeConfig(500, feeCollector);
    }

    // ============ Deposit Recording Tests ============

    function test_RecordVaultShareDeposit() public {
        vm.prank(wallet1);
        ledger.recordVaultShareDeposit(vault1, 1000e6, 1000e18);
        (uint256 costBasis, uint256 shares) = ledger.getVaultPosition(wallet1, vault1);
        assertEq(costBasis, 1000e6);
        assertEq(shares, 1000e18);
    }

    function test_RecordVaultShareDeposit_MultipleDeposits() public {
        vm.startPrank(wallet1);
        ledger.recordVaultShareDeposit(vault1, 1000e6, 1000e18);
        ledger.recordVaultShareDeposit(vault1, 500e6, 400e18);
        vm.stopPrank();
        (uint256 costBasis, uint256 shares) = ledger.getVaultPosition(wallet1, vault1);
        assertEq(costBasis, 1500e6);
        assertEq(shares, 1400e18);
    }

    function test_RecordVaultShareDeposit_MultipleVaults() public {
        vm.startPrank(wallet1);
        ledger.recordVaultShareDeposit(vault1, 1000e6, 1000e18);
        ledger.recordVaultShareDeposit(vault2, 2000e6, 1800e18);
        vm.stopPrank();
        (uint256 costBasis1, uint256 shares1) = ledger.getVaultPosition(wallet1, vault1);
        (uint256 costBasis2, uint256 shares2) = ledger.getVaultPosition(wallet1, vault2);
        assertEq(costBasis1, 1000e6);
        assertEq(shares1, 1000e18);
        assertEq(costBasis2, 2000e6);
        assertEq(shares2, 1800e18);
    }

    function test_RecordVaultShareDeposit_IsolatedPerWallet() public {
        vm.prank(wallet1);
        ledger.recordVaultShareDeposit(vault1, 1000e6, 1000e18);
        vm.prank(wallet2);
        ledger.recordVaultShareDeposit(vault1, 500e6, 500e18);
        (uint256 costBasis1,) = ledger.getVaultPosition(wallet1, vault1);
        (uint256 costBasis2,) = ledger.getVaultPosition(wallet2, vault1);
        assertEq(costBasis1, 1000e6);
        assertEq(costBasis2, 500e6);
    }

    // ============ Withdraw Recording Tests ============

    function test_RecordVaultShareWithdraw_NoYield() public {
        vm.startPrank(wallet1);
        ledger.recordVaultShareDeposit(vault1, 1000e6, 1000e18);
        ledger.recordVaultShareWithdraw(vault1, 500e18, 500e6);
        vm.stopPrank();
        (uint256 costBasis, uint256 shares) = ledger.getVaultPosition(wallet1, vault1);
        assertEq(costBasis, 500e6);
        assertEq(shares, 500e18);
        assertEq(ledger.realizedYield(wallet1), 0);
    }

    function test_RecordVaultShareWithdraw_WithYield() public {
        vm.startPrank(wallet1);
        ledger.recordVaultShareDeposit(vault1, 1000e6, 1000e18);
        ledger.recordVaultShareWithdraw(vault1, 500e18, 600e6);
        vm.stopPrank();
        (uint256 costBasis, uint256 shares) = ledger.getVaultPosition(wallet1, vault1);
        assertEq(costBasis, 500e6);
        assertEq(shares, 500e18);
        assertEq(ledger.realizedYield(wallet1), 100e6);
    }

    function test_RecordVaultShareWithdraw_FullWithdraw() public {
        vm.startPrank(wallet1);
        ledger.recordVaultShareDeposit(vault1, 1000e6, 1000e18);
        ledger.recordVaultShareWithdraw(vault1, 1000e18, 1200e6);
        vm.stopPrank();
        (uint256 costBasis, uint256 shares) = ledger.getVaultPosition(wallet1, vault1);
        assertEq(costBasis, 0);
        assertEq(shares, 0);
        assertEq(ledger.realizedYield(wallet1), 200e6);
    }

    function test_RecordVaultShareWithdraw_Loss() public {
        vm.startPrank(wallet1);
        ledger.recordVaultShareDeposit(vault1, 1000e6, 1000e18);
        ledger.recordVaultShareWithdraw(vault1, 500e18, 400e6);
        vm.stopPrank();
        assertEq(ledger.realizedYield(wallet1), 0);
    }

    function test_RecordVaultShareWithdraw_RevertsOnZeroShares() public {
        vm.prank(wallet1);
        vm.expectRevert(FeeLedger.InvalidShares.selector);
        ledger.recordVaultShareWithdraw(vault1, 100e18, 100e6);
    }

    function test_RecordVaultShareWithdraw_RevertsOnExcessShares() public {
        vm.startPrank(wallet1);
        ledger.recordVaultShareDeposit(vault1, 1000e6, 1000e18);
        vm.expectRevert(FeeLedger.InvalidShares.selector);
        ledger.recordVaultShareWithdraw(vault1, 1001e18, 1000e6);
        vm.stopPrank();
    }

    // ============ Reward Claim Tests ============

    function test_RecordRewardClaim() public {
        vm.prank(wallet1);
        ledger.recordRewardClaim(50e6);
        assertEq(ledger.realizedYield(wallet1), 50e6);
    }

    function test_RecordRewardClaim_Accumulates() public {
        vm.startPrank(wallet1);
        ledger.recordRewardClaim(50e6);
        ledger.recordRewardClaim(30e6);
        vm.stopPrank();
        assertEq(ledger.realizedYield(wallet1), 80e6);
    }

    // ============ Fee Calculation Tests ============

    function test_GetFeesOwed_NoYield() public view {
        assertEq(ledger.getFeesOwed(wallet1), 0);
    }

    function test_GetFeesOwed_WithYield() public {
        vm.startPrank(wallet1);
        ledger.recordVaultShareDeposit(vault1, 1000e6, 1000e18);
        ledger.recordVaultShareWithdraw(vault1, 1000e18, 1100e6);
        vm.stopPrank();
        uint256 feesOwed = ledger.getFeesOwed(wallet1);
        assertEq(feesOwed, 10e6);
    }

    function test_GetFeesOwed_AfterPartialPayment() public {
        vm.startPrank(wallet1);
        ledger.recordRewardClaim(100e6);
        ledger.recordFeePaid(5e6);
        vm.stopPrank();
        uint256 feesOwed = ledger.getFeesOwed(wallet1);
        assertEq(feesOwed, 5e6);
    }

    function test_GetFeesOwed_AfterFullPayment() public {
        vm.startPrank(wallet1);
        ledger.recordRewardClaim(100e6);
        ledger.recordFeePaid(10e6);
        vm.stopPrank();
        assertEq(ledger.getFeesOwed(wallet1), 0);
    }

    function test_GetFeesOwed_OverpaymentReturnsZero() public {
        vm.startPrank(wallet1);
        ledger.recordRewardClaim(100e6);
        ledger.recordFeePaid(15e6);
        vm.stopPrank();
        assertEq(ledger.getFeesOwed(wallet1), 0);
    }

    // ============ Fee Rate Change Tests ============

    function test_FeeRateChange_AffectsOutstanding() public {
        vm.prank(wallet1);
        ledger.recordRewardClaim(100e6);
        assertEq(ledger.getFeesOwed(wallet1), 10e6);
        vm.prank(admin);
        ledger.setFeeConfig(2000, feeCollector);
        assertEq(ledger.getFeesOwed(wallet1), 20e6);
    }

    // ============ Wallet Stats Tests ============

    function test_GetWalletStats() public {
        vm.startPrank(wallet1);
        ledger.recordVaultShareDeposit(vault1, 1000e6, 1000e18);
        ledger.recordVaultShareWithdraw(vault1, 1000e18, 1200e6);
        ledger.recordFeePaid(10e6);
        vm.stopPrank();
        (uint256 totalYield, uint256 totalPaid, uint256 owed) = ledger.getWalletStats(wallet1);
        assertEq(totalYield, 200e6);
        assertEq(totalPaid, 10e6);
        assertEq(owed, 10e6);
    }

    // ============ Complex Scenario Tests ============

    function test_ComplexScenario_MultipleDepositsWithdrawals() public {
        vm.startPrank(wallet1);
        ledger.recordVaultShareDeposit(vault1, 1000e6, 1000e18);
        ledger.recordVaultShareWithdraw(vault1, 500e18, 600e6);
        ledger.recordVaultShareDeposit(vault1, 500e6, 400e18);
        ledger.recordVaultShareWithdraw(vault1, 900e18, 1100e6);
        vm.stopPrank();
        assertEq(ledger.realizedYield(wallet1), 200e6);
        assertEq(ledger.getFeesOwed(wallet1), 20e6);
    }

    function test_ComplexScenario_YieldPlusRewards() public {
        vm.startPrank(wallet1);
        ledger.recordVaultShareDeposit(vault1, 1000e6, 1000e18);
        ledger.recordVaultShareWithdraw(vault1, 1000e18, 1100e6);
        ledger.recordRewardClaim(50e6);
        vm.stopPrank();
        assertEq(ledger.realizedYield(wallet1), 150e6);
        assertEq(ledger.getFeesOwed(wallet1), 15e6);
    }

    // ============ Upgrade Tests ============

    function test_Upgrade_OnlyAdmin() public {
        FeeLedger newImpl = new FeeLedger();
        vm.prank(wallet1);
        vm.expectRevert();
        ledger.upgradeToAndCall(address(newImpl), "");
    }

    function test_Upgrade_PreservesState() public {
        vm.prank(wallet1);
        ledger.recordRewardClaim(100e6);
        FeeLedger newImpl = new FeeLedger();
        vm.prank(admin);
        ledger.upgradeToAndCall(address(newImpl), "");
        assertEq(ledger.realizedYield(wallet1), 100e6);
        assertEq(ledger.feeRateBps(), 1000);
    }

    function test_Upgrade_PreservesAllState() public {
        vm.startPrank(wallet1);
        ledger.recordVaultShareDeposit(vault1, 1000e6, 1000e18);
        ledger.recordVaultShareDeposit(vault2, 500e6, 500e18);
        ledger.recordVaultShareWithdraw(vault1, 500e18, 600e6);
        ledger.recordRewardClaim(50e6);
        ledger.recordFeePaid(10e6);
        vm.stopPrank();
        (uint256 costBasis1Before, uint256 shares1Before) = ledger.getVaultPosition(wallet1, vault1);
        (uint256 costBasis2Before, uint256 shares2Before) = ledger.getVaultPosition(wallet1, vault2);
        uint256 yieldBefore = ledger.realizedYield(wallet1);
        uint256 feesPaidBefore = ledger.feesPaid(wallet1);
        FeeLedger newImpl = new FeeLedger();
        vm.prank(admin);
        ledger.upgradeToAndCall(address(newImpl), "");
        (uint256 costBasis1After, uint256 shares1After) = ledger.getVaultPosition(wallet1, vault1);
        (uint256 costBasis2After, uint256 shares2After) = ledger.getVaultPosition(wallet1, vault2);
        assertEq(costBasis1After, costBasis1Before);
        assertEq(shares1After, shares1Before);
        assertEq(costBasis2After, costBasis2Before);
        assertEq(shares2After, shares2Before);
        assertEq(ledger.realizedYield(wallet1), yieldBefore);
        assertEq(ledger.feesPaid(wallet1), feesPaidBefore);
        assertEq(ledger.feeRateBps(), 1000);
        assertEq(ledger.feeCollector(), feeCollector);
    }

    function test_Upgrade_CanCallNewFunctionsAfterUpgrade() public {
        vm.prank(wallet1);
        ledger.recordRewardClaim(100e6);
        FeeLedger newImpl = new FeeLedger();
        vm.prank(admin);
        ledger.upgradeToAndCall(address(newImpl), "");
        vm.prank(wallet1);
        ledger.recordRewardClaim(50e6);
        assertEq(ledger.realizedYield(wallet1), 150e6);
    }

    function test_Upgrade_AdminCanChangeAfterUpgrade() public {
        FeeLedger newImpl = new FeeLedger();
        vm.prank(admin);
        ledger.upgradeToAndCall(address(newImpl), "");
        vm.prank(admin);
        ledger.setFeeConfig(2000, address(0x7777));
        assertEq(ledger.feeRateBps(), 2000);
        assertEq(ledger.feeCollector(), address(0x7777));
    }
}

// ============ Integration Tests ============

contract FeeLedgerIntegrationTest is Test {
    FeeLedger public ledger;
    MockERC4626Vault public vault;
    MockUSDC public usdc;

    address public admin = address(0x1);
    address public wallet = address(0x100);
    address public feeCollector = address(0x9999);

    function setUp() public {
        FeeLedger ledgerImpl = new FeeLedger();
        ERC1967Proxy proxy = new ERC1967Proxy(address(ledgerImpl), abi.encodeWithSelector(FeeLedger.initialize.selector, admin));
        ledger = FeeLedger(address(proxy));
        vm.prank(admin);
        ledger.setFeeConfig(1000, feeCollector);
        usdc = new MockUSDC();
        vault = new MockERC4626Vault(address(usdc));
        usdc.mint(wallet, 10000e6);
    }

    function test_Integration_DepositWithdrawYieldTracking() public {
        vm.startPrank(wallet);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(1000e6, wallet);
        ledger.recordVaultShareDeposit(address(vault), 1000e6, shares);
        vm.stopPrank();
        (uint256 costBasis, uint256 recordedShares) = ledger.getVaultPosition(wallet, address(vault));
        assertEq(costBasis, 1000e6);
        assertEq(recordedShares, shares);
        assertEq(ledger.realizedYield(wallet), 0);
        vault.simulateYield(100e6);
        vm.startPrank(wallet);
        uint256 assets = vault.redeem(shares, wallet, wallet);
        ledger.recordVaultShareWithdraw(address(vault), shares, assets);
        vm.stopPrank();
        assertApproxEqAbs(assets, 1100e6, 2);
        assertApproxEqAbs(ledger.realizedYield(wallet), 100e6, 2);
        assertApproxEqAbs(ledger.getFeesOwed(wallet), 10e6, 1);
    }

    function test_Integration_MultipleVaultsYieldTracking() public {
        MockERC4626Vault vault2 = new MockERC4626Vault(address(usdc));
        vm.startPrank(wallet);
        usdc.approve(address(vault), type(uint256).max);
        usdc.approve(address(vault2), type(uint256).max);
        uint256 shares1 = vault.deposit(1000e6, wallet);
        ledger.recordVaultShareDeposit(address(vault), 1000e6, shares1);
        uint256 shares2 = vault2.deposit(2000e6, wallet);
        ledger.recordVaultShareDeposit(address(vault2), 2000e6, shares2);
        vm.stopPrank();
        vault.simulateYield(50e6);
        vault2.simulateYield(100e6);
        vm.startPrank(wallet);
        uint256 assets1 = vault.redeem(shares1, wallet, wallet);
        ledger.recordVaultShareWithdraw(address(vault), shares1, assets1);
        uint256 assets2 = vault2.redeem(shares2, wallet, wallet);
        ledger.recordVaultShareWithdraw(address(vault2), shares2, assets2);
        vm.stopPrank();
        assertApproxEqAbs(ledger.realizedYield(wallet), 150e6, 3);
        assertApproxEqAbs(ledger.getFeesOwed(wallet), 15e6, 1);
    }

    function test_Integration_PartialWithdrawYieldTracking() public {
        vm.startPrank(wallet);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(1000e6, wallet);
        ledger.recordVaultShareDeposit(address(vault), 1000e6, shares);
        vm.stopPrank();
        vault.simulateYield(100e6);
        vm.startPrank(wallet);
        uint256 halfShares = shares / 2;
        uint256 assets = vault.redeem(halfShares, wallet, wallet);
        ledger.recordVaultShareWithdraw(address(vault), halfShares, assets);
        vm.stopPrank();
        assertApproxEqAbs(assets, 550e6, 2);
        assertApproxEqAbs(ledger.realizedYield(wallet), 50e6, 2);
        (uint256 costBasis, uint256 remainingShares) = ledger.getVaultPosition(wallet, address(vault));
        assertEq(costBasis, 500e6);
        assertEq(remainingShares, halfShares);
    }

    function test_Integration_FeePaymentFlow() public {
        vm.startPrank(wallet);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(1000e6, wallet);
        ledger.recordVaultShareDeposit(address(vault), 1000e6, shares);
        vm.stopPrank();
        vault.simulateYield(100e6);
        vm.startPrank(wallet);
        uint256 assets = vault.redeem(shares, wallet, wallet);
        ledger.recordVaultShareWithdraw(address(vault), shares, assets);
        vm.stopPrank();
        uint256 feesOwed = ledger.getFeesOwed(wallet);
        assertApproxEqAbs(feesOwed, 10e6, 1);
        vm.prank(wallet);
        ledger.recordFeePaid(feesOwed);
        assertEq(ledger.getFeesOwed(wallet), 0);
        assertEq(ledger.feesPaid(wallet), feesOwed);
    }

    function test_Integration_LossScenario() public {
        vm.startPrank(wallet);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(1000e6, wallet);
        ledger.recordVaultShareDeposit(address(vault), 1000e6, shares);
        vm.stopPrank();
        vault.simulateLoss(100e6);
        vm.startPrank(wallet);
        uint256 assets = vault.redeem(shares, wallet, wallet);
        ledger.recordVaultShareWithdraw(address(vault), shares, assets);
        vm.stopPrank();
        assertApproxEqAbs(assets, 900e6, 2);
        assertEq(ledger.realizedYield(wallet), 0);
        assertEq(ledger.getFeesOwed(wallet), 0);
    }

    function test_Integration_RewardClaimAddsToYield() public {
        vm.startPrank(wallet);
        usdc.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(1000e6, wallet);
        ledger.recordVaultShareDeposit(address(vault), 1000e6, shares);
        ledger.recordRewardClaim(25e6);
        vm.stopPrank();
        assertEq(ledger.realizedYield(wallet), 25e6);
        assertEq(ledger.getFeesOwed(wallet), 2500000);
        vault.simulateYield(100e6);
        vm.startPrank(wallet);
        uint256 assets = vault.redeem(shares, wallet, wallet);
        ledger.recordVaultShareWithdraw(address(vault), shares, assets);
        vm.stopPrank();
        assertApproxEqAbs(ledger.realizedYield(wallet), 125e6, 2);
        assertApproxEqAbs(ledger.getFeesOwed(wallet), 12500000, 1);
    }
}

// ============ Mock Contracts for Integration Tests ============

contract MockUSDC is ERC20 {
    constructor() ERC20("USDC", "USDC") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract MockERC4626Vault is ERC4626 {
    constructor(address asset) ERC4626(IERC20(asset)) ERC20("Vault", "vUSDC") {}

    function simulateYield(uint256 amount) external {
        MockUSDC(asset()).mint(address(this), amount);
    }

    function simulateLoss(uint256 amount) external {
        bool success = IERC20(asset()).transfer(address(1), amount);
        require(success, "Transfer failed");
    }
}
