// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {AaveV3Adapter} from "../src/adapters/AaveV3Adapter.sol";
import {ActionRegistry} from "../src/ActionRegistry.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockAavePool, MockAToken} from "./mocks/MockAavePool.sol";

/**
 * @title AaveV3AdapterTest
 * @notice Unit tests for AaveV3Adapter validation logic
 * @dev The adapter is designed to be called via DELEGATECALL from wallet context.
 *      These tests focus on validation logic and view functions.
 *      Full integration tests would require wallet + router setup.
 */
contract AaveV3AdapterTest is Test {
    AaveV3Adapter public adapter;
    ActionRegistry public registry;
    MockERC20 public usdc;
    MockAavePool public pool;
    MockAavePool public pool2;
    MockAToken public aUsdc;
    address public admin = address(0x1);
    address public wallet = address(0x2);

    function setUp() public {
        vm.startPrank(admin);
        usdc = new MockERC20("USDC", "USDC");
        pool = new MockAavePool();
        pool2 = new MockAavePool();
        aUsdc = new MockAToken(address(usdc), "aUSDC", "aUSDC");
        aUsdc.setPool(address(pool));
        pool.setAToken(address(usdc), address(aUsdc));
        usdc.mint(address(pool), 1_000_000e6);
        registry = new ActionRegistry(admin);
        adapter = new AaveV3Adapter(address(registry));
        registry.registerAdapter(address(adapter));
        registry.registerTarget(address(pool), address(adapter));
        vm.stopPrank();
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsRegistry() public view {
        assertEq(address(adapter.registry()), address(registry));
    }

    function test_Constructor_SetsSelf() public view {
        assertEq(adapter.self(), address(adapter));
    }

    // ============ supply Validation Tests ============

    function test_Supply_RevertsOnZeroAmount() public {
        vm.prank(wallet);
        vm.expectRevert(AaveV3Adapter.ZeroAmount.selector);
        adapter.supply(address(pool), address(usdc), 0);
    }

    function test_Supply_RevertsIfPoolNotRegistered() public {
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.PoolNotRegistered.selector, address(pool2)));
        adapter.supply(address(pool2), address(usdc), 100e6);
    }

    function test_Supply_RevertsIfWrongAdapter() public {
        vm.startPrank(admin);
        AaveV3Adapter adapter2 = new AaveV3Adapter(address(registry));
        registry.registerAdapter(address(adapter2));
        registry.registerTarget(address(pool2), address(adapter2));
        vm.stopPrank();
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.WrongAdapter.selector, address(pool2), address(adapter2)));
        adapter.supply(address(pool2), address(usdc), 100e6);
    }

    function test_Supply_FailsAfterTargetRemoved() public {
        vm.prank(admin);
        registry.removeTarget(address(pool));
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.PoolNotRegistered.selector, address(pool)));
        adapter.supply(address(pool), address(usdc), 500e6);
    }

    function test_Supply_FailsAfterAdapterUnregistered() public {
        vm.prank(admin);
        registry.unregisterAdapter(address(adapter));
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.PoolNotRegistered.selector, address(pool)));
        adapter.supply(address(pool), address(usdc), 500e6);
    }

    // ============ withdraw Validation Tests ============

    function test_Withdraw_RevertsOnZeroAmount() public {
        vm.prank(wallet);
        vm.expectRevert(AaveV3Adapter.ZeroAmount.selector);
        adapter.withdraw(address(pool), address(usdc), 0);
    }

    function test_Withdraw_RevertsIfPoolNotRegistered() public {
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.PoolNotRegistered.selector, address(pool2)));
        adapter.withdraw(address(pool2), address(usdc), 100e6);
    }

    function test_Withdraw_RevertsIfWrongAdapter() public {
        vm.startPrank(admin);
        AaveV3Adapter adapter2 = new AaveV3Adapter(address(registry));
        registry.registerAdapter(address(adapter2));
        registry.registerTarget(address(pool2), address(adapter2));
        vm.stopPrank();
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.WrongAdapter.selector, address(pool2), address(adapter2)));
        adapter.withdraw(address(pool2), address(usdc), 100e6);
    }

    function test_Withdraw_FailsAfterTargetRemoved() public {
        vm.prank(admin);
        registry.removeTarget(address(pool));
        vm.prank(wallet);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.PoolNotRegistered.selector, address(pool)));
        adapter.withdraw(address(pool), address(usdc), 500e6);
    }

    // ============ View Function Tests ============

    function test_GetATokenBalance_ReturnsZeroInitially() public view {
        assertEq(adapter.getATokenBalance(address(aUsdc), wallet), 0);
    }

    function test_GetATokenBalance_ReturnsCorrectBalance() public {
        usdc.mint(wallet, 500e6);
        vm.startPrank(wallet);
        usdc.approve(address(pool), 500e6);
        pool.supply(address(usdc), 500e6, wallet, 0);
        vm.stopPrank();
        assertEq(adapter.getATokenBalance(address(aUsdc), wallet), 500e6);
    }

    // ============ Adapter Re-registration Edge Case ============

    function test_Supply_WorksAfterAdapterReregistered() public {
        vm.startPrank(admin);
        registry.unregisterAdapter(address(adapter));
        registry.registerAdapter(address(adapter));
        vm.stopPrank();
        (bool valid, address registeredAdapter) = registry.isValidTarget(address(pool));
        assertTrue(valid);
        assertEq(registeredAdapter, address(adapter));
    }
}
