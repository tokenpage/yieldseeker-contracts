// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {ActionRegistry} from "../src/ActionRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";

/**
 * @title ERC4626AdapterTest
 * @notice Unit tests for ERC4626Adapter validation logic
 * @dev The adapter is designed to be called via DELEGATECALL from wallet context.
 *      These tests focus on validation logic and view functions.
 *      Integration tests with full wallet flow are in AgentWallet.t.sol.
 */
contract ERC4626AdapterTest is Test {
    ERC4626Adapter public adapter;
    ActionRegistry public registry;
    MockERC20 public usdc;
    MockERC4626 public vault;
    MockERC4626 public vault2;
    address public admin = address(0x1);
    address public wallet = address(0x2);

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockERC20("USDC", "USDC");
        vault = new MockERC4626(address(usdc));
        vault2 = new MockERC4626(address(usdc));
        registry = new ActionRegistry(admin);
        adapter = new ERC4626Adapter(address(registry));
        registry.registerAdapter(address(adapter));
        registry.registerTarget(address(vault), address(adapter));
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsRegistry() public view {
        assertEq(address(adapter.registry()), address(registry));
    }

    function test_Constructor_SetsSelf() public view {
        assertEq(adapter.self(), address(adapter));
    }

    // ============ Validation Tests (deposit) ============

    function test_Deposit_RevertsOnZeroAmount() public {
        vm.prank(wallet);
        vm.expectRevert(ERC4626Adapter.ZeroAmount.selector);
        adapter.deposit(address(vault), 0);
    }

    function test_Deposit_RevertsIfVaultNotRegistered() public {
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Adapter.VaultNotRegistered.selector, address(vault2)));
        adapter.deposit(address(vault2), 100e6);
    }

    function test_Deposit_RevertsIfWrongAdapter() public {
        vm.startPrank(admin);
        ERC4626Adapter adapter2 = new ERC4626Adapter(address(registry));
        registry.registerAdapter(address(adapter2));
        registry.registerTarget(address(vault2), address(adapter2));
        vm.stopPrank();
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Adapter.WrongAdapter.selector, address(vault2), address(adapter2)));
        adapter.deposit(address(vault2), 100e6);
    }

    function test_Deposit_FailsAfterTargetRemoved() public {
        vm.prank(admin);
        registry.removeTarget(address(vault));
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Adapter.VaultNotRegistered.selector, address(vault)));
        adapter.deposit(address(vault), 500e6);
    }

    function test_Deposit_FailsAfterAdapterUnregistered() public {
        vm.prank(admin);
        registry.unregisterAdapter(address(adapter));
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Adapter.VaultNotRegistered.selector, address(vault)));
        adapter.deposit(address(vault), 500e6);
    }

    // ============ Validation Tests (withdraw) ============

    function test_Withdraw_RevertsOnZeroAmount() public {
        vm.prank(wallet);
        vm.expectRevert(ERC4626Adapter.ZeroAmount.selector);
        adapter.withdraw(address(vault), 0);
    }

    function test_Withdraw_RevertsIfVaultNotRegistered() public {
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Adapter.VaultNotRegistered.selector, address(vault2)));
        adapter.withdraw(address(vault2), 100e6);
    }

    function test_Withdraw_RevertsIfWrongAdapter() public {
        vm.startPrank(admin);
        ERC4626Adapter adapter2 = new ERC4626Adapter(address(registry));
        registry.registerAdapter(address(adapter2));
        registry.registerTarget(address(vault2), address(adapter2));
        vm.stopPrank();
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Adapter.WrongAdapter.selector, address(vault2), address(adapter2)));
        adapter.withdraw(address(vault2), 100e6);
    }

    function test_Withdraw_FailsAfterTargetRemoved() public {
        vm.prank(admin);
        registry.removeTarget(address(vault));
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(ERC4626Adapter.VaultNotRegistered.selector, address(vault)));
        adapter.withdraw(address(vault), 500e6);
    }

    // ============ View Function Tests ============

    function test_GetAsset_ReturnsCorrectAsset() public view {
        assertEq(adapter.getAsset(address(vault)), address(usdc));
    }

    function test_GetShareBalance_ReturnsZeroInitially() public view {
        assertEq(adapter.getShareBalance(address(vault), wallet), 0);
    }

    function test_GetShareBalance_ReturnsCorrectBalance() public {
        usdc.mint(wallet, 500e6);
        vm.startPrank(wallet);
        usdc.approve(address(vault), 500e6);
        vault.deposit(500e6, wallet);
        vm.stopPrank();
        assertEq(adapter.getShareBalance(address(vault), wallet), 500e6);
    }

    // ============ Adapter Re-registration Edge Case ============

    function test_Deposit_WorksAfterAdapterReregistered() public {
        vm.startPrank(admin);
        registry.unregisterAdapter(address(adapter));
        registry.registerAdapter(address(adapter));
        vm.stopPrank();
        (bool valid, address registeredAdapter) = registry.isValidTarget(address(vault));
        assertTrue(valid);
        assertEq(registeredAdapter, address(adapter));
    }
}
