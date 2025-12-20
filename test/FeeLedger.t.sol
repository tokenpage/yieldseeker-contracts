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
        ledger = new FeeLedger(admin);
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
        vm.expectRevert(FeeLedger.ZeroAddress.selector);
        new FeeLedger(address(0));
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

    // ============ Yield Recording Tests ============

    function test_RecordYield() public {
        vm.prank(wallet1);
        ledger.recordYield(100e6);
        assertEq(ledger.agentFeesCharged(wallet1), 10e6); // 10% of 100e6
    }

    function test_RecordYield_Accumulates() public {
        vm.startPrank(wallet1);
        ledger.recordYield(100e6);
        ledger.recordYield(50e6);
        vm.stopPrank();
        assertEq(ledger.agentFeesCharged(wallet1), 15e6); // 10% of 150e6
    }

    function test_RecordYield_IsolatedPerWallet() public {
        vm.prank(wallet1);
        ledger.recordYield(100e6);
        vm.prank(wallet2);
        ledger.recordYield(50e6);
        assertEq(ledger.agentFeesCharged(wallet1), 10e6);
        assertEq(ledger.agentFeesCharged(wallet2), 5e6);
    }

    // ============ Fee Payment Tests ============

    function test_RecordFeePaid() public {
        vm.startPrank(wallet1);
        ledger.recordYield(100e6);
        ledger.recordFeePaid(5e6);
        vm.stopPrank();
        assertEq(ledger.agentFeesPaid(wallet1), 5e6);
        assertEq(ledger.getFeesOwed(wallet1), 5e6); // 10e6 - 5e6
    }

    function test_RecordFeePaid_FullPayment() public {
        vm.startPrank(wallet1);
        ledger.recordYield(100e6);
        ledger.recordFeePaid(10e6);
        vm.stopPrank();
        assertEq(ledger.agentFeesPaid(wallet1), 10e6);
        assertEq(ledger.getFeesOwed(wallet1), 0);
    }

    // ============ Fee Calculation Tests ============

    function test_GetFeesOwed_NoYield() public view {
        assertEq(ledger.getFeesOwed(wallet1), 0);
    }

    function test_GetFeesOwed_WithYield() public {
        vm.startPrank(wallet1);
        ledger.recordYield(100e6);
        vm.stopPrank();
        uint256 feesOwed = ledger.getFeesOwed(wallet1);
        assertEq(feesOwed, 10e6);
    }

    function test_GetFeesOwed_AfterPartialPayment() public {
        vm.startPrank(wallet1);
        ledger.recordYield(100e6);
        ledger.recordFeePaid(5e6);
        vm.stopPrank();
        uint256 feesOwed = ledger.getFeesOwed(wallet1);
        assertEq(feesOwed, 5e6); // 10e6 charged - 5e6 paid
    }

    function test_GetFeesOwed_AfterFullPayment() public {
        vm.startPrank(wallet1);
        ledger.recordYield(100e6);
        ledger.recordFeePaid(10e6);
        vm.stopPrank();
        assertEq(ledger.getFeesOwed(wallet1), 0);
    }

    function test_GetFeesOwed_OverpaymentReturnsZero() public {
        vm.startPrank(wallet1);
        ledger.recordYield(100e6);
        ledger.recordFeePaid(15e6);
        vm.stopPrank();
        assertEq(ledger.getFeesOwed(wallet1), 0);
    }

    // ============ Fee Rate Change Tests ============

    function test_FeeRateChange_DoesNotAffectOutstanding() public {
        vm.prank(wallet1);
        ledger.recordYield(100e6);
        assertEq(ledger.getFeesOwed(wallet1), 10e6);
        vm.prank(admin);
        ledger.setFeeConfig(2000, feeCollector);
        assertEq(ledger.getFeesOwed(wallet1), 10e6); // Still 10e6 because it was recorded at 10%
    }

    // ============ Wallet Stats Tests ============

    function test_GetWalletStats() public {
        vm.startPrank(wallet1);
        ledger.recordYield(200e6);
        ledger.recordFeePaid(10e6);
        vm.stopPrank();
        (uint256 agentFeesCharged_, uint256 agentFeesPaid_, uint256 owed) = ledger.getWalletStats(wallet1);
        assertEq(agentFeesCharged_, 20e6);
        assertEq(agentFeesPaid_, 10e6);
        assertEq(owed, 10e6);
    }

    // ============ Complex Scenario Tests ============

    function test_ComplexScenario_MultipleYields() public {
        vm.startPrank(wallet1);
        ledger.recordYield(100e6);
        ledger.recordYield(50e6);
        ledger.recordYield(75e6);
        vm.stopPrank();
        assertEq(ledger.agentFeesCharged(wallet1), 22500000); // 10% of 225e6
        assertEq(ledger.getFeesOwed(wallet1), 22500000);
    }

    function test_ComplexScenario_YieldsAndPayments() public {
        vm.startPrank(wallet1);
        ledger.recordYield(100e6);
        ledger.recordFeePaid(5e6);
        ledger.recordYield(50e6);
        ledger.recordFeePaid(5e6);
        vm.stopPrank();
        assertEq(ledger.agentFeesCharged(wallet1), 15e6); // 10e6 + 5e6
        assertEq(ledger.agentFeesPaid(wallet1), 10e6);
        assertEq(ledger.getFeesOwed(wallet1), 5e6);
    }
}

// Note: Integration tests that involve vault position tracking have been removed
// as position tracking is now handled by AgentWallet, not FeeLedger.
// See AgentWallet tests for vault position tracking integration tests.
