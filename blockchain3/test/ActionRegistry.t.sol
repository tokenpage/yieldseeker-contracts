// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {ActionRegistry} from "../src/ActionRegistry.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract ActionRegistryTest is Test {
    ActionRegistry public registry;
    address public admin = address(0x1);
    address public randomUser = address(0x2);
    address public adapter1 = address(0x100);
    address public adapter2 = address(0x101);
    address public target1 = address(0x200);
    address public target2 = address(0x201);
    address public target3 = address(0x202);

    function setUp() public {
        vm.prank(admin);
        registry = new ActionRegistry(admin);
    }

    // ============ Constructor Tests ============

    function test_Constructor_GrantsRolesToAdmin() public view {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.REGISTRY_ADMIN_ROLE(), admin));
        assertTrue(registry.hasRole(registry.EMERGENCY_ROLE(), admin));
    }

    function test_Constructor_RevertsOnZeroAddress() public {
        vm.expectRevert(ActionRegistry.ZeroAddress.selector);
        new ActionRegistry(address(0));
    }

    // ============ registerAdapter Tests ============

    function test_RegisterAdapter_Success() public {
        vm.prank(admin);
        registry.registerAdapter(adapter1);
        assertTrue(registry.isRegisteredAdapter(adapter1));
    }

    function test_RegisterAdapter_EmitsEvent() public {
        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit ActionRegistry.AdapterRegistered(adapter1);
        registry.registerAdapter(adapter1);
    }

    function test_RegisterAdapter_RevertsOnZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(ActionRegistry.ZeroAddress.selector);
        registry.registerAdapter(address(0));
    }

    function test_RegisterAdapter_RevertsIfNotAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert();
        registry.registerAdapter(adapter1);
    }

    function test_RegisterAdapter_MultipleAdapters() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerAdapter(adapter2);
        vm.stopPrank();
        assertTrue(registry.isRegisteredAdapter(adapter1));
        assertTrue(registry.isRegisteredAdapter(adapter2));
    }

    // ============ registerTarget Tests ============

    function test_RegisterTarget_Success() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        vm.stopPrank();
        assertEq(registry.targetToAdapter(target1), adapter1);
        assertEq(registry.getTargetCount(), 1);
    }

    function test_RegisterTarget_EmitsEvent() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        vm.expectEmit(true, true, false, false);
        emit ActionRegistry.TargetRegistered(target1, adapter1);
        registry.registerTarget(target1, adapter1);
        vm.stopPrank();
    }

    function test_RegisterTarget_RevertsOnZeroAddress() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        vm.expectRevert(ActionRegistry.ZeroAddress.selector);
        registry.registerTarget(address(0), adapter1);
        vm.stopPrank();
    }

    function test_RegisterTarget_RevertsIfAdapterNotRegistered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ActionRegistry.AdapterNotRegistered.selector, adapter1));
        registry.registerTarget(target1, adapter1);
    }

    function test_RegisterTarget_RevertsIfTargetAlreadyRegistered() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        vm.expectRevert(abi.encodeWithSelector(ActionRegistry.TargetAlreadyRegistered.selector, target1));
        registry.registerTarget(target1, adapter1);
        vm.stopPrank();
    }

    function test_RegisterTarget_RevertsIfNotAdmin() public {
        vm.prank(admin);
        registry.registerAdapter(adapter1);
        vm.prank(randomUser);
        vm.expectRevert();
        registry.registerTarget(target1, adapter1);
    }

    function test_RegisterTarget_MultipleTargetsSameAdapter() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        registry.registerTarget(target2, adapter1);
        vm.stopPrank();
        assertEq(registry.targetToAdapter(target1), adapter1);
        assertEq(registry.targetToAdapter(target2), adapter1);
        assertEq(registry.getTargetCount(), 2);
    }

    function test_RegisterTarget_DifferentAdapters() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerAdapter(adapter2);
        registry.registerTarget(target1, adapter1);
        registry.registerTarget(target2, adapter2);
        vm.stopPrank();
        assertEq(registry.targetToAdapter(target1), adapter1);
        assertEq(registry.targetToAdapter(target2), adapter2);
    }

    // ============ updateTargetAdapter Tests ============

    function test_UpdateTargetAdapter_Success() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerAdapter(adapter2);
        registry.registerTarget(target1, adapter1);
        registry.updateTargetAdapter(target1, adapter2);
        vm.stopPrank();
        assertEq(registry.targetToAdapter(target1), adapter2);
    }

    function test_UpdateTargetAdapter_EmitsEvents() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerAdapter(adapter2);
        registry.registerTarget(target1, adapter1);
        vm.expectEmit(true, true, false, false);
        emit ActionRegistry.TargetRemoved(target1, adapter1);
        vm.expectEmit(true, true, false, false);
        emit ActionRegistry.TargetRegistered(target1, adapter2);
        registry.updateTargetAdapter(target1, adapter2);
        vm.stopPrank();
    }

    function test_UpdateTargetAdapter_RevertsIfTargetNotRegistered() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        vm.expectRevert(abi.encodeWithSelector(ActionRegistry.TargetNotRegistered.selector, target1));
        registry.updateTargetAdapter(target1, adapter1);
        vm.stopPrank();
    }

    function test_UpdateTargetAdapter_RevertsIfNewAdapterNotRegistered() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        vm.expectRevert(abi.encodeWithSelector(ActionRegistry.AdapterNotRegistered.selector, adapter2));
        registry.updateTargetAdapter(target1, adapter2);
        vm.stopPrank();
    }

    function test_UpdateTargetAdapter_RevertsIfNotAdmin() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerAdapter(adapter2);
        registry.registerTarget(target1, adapter1);
        vm.stopPrank();
        vm.prank(randomUser);
        vm.expectRevert();
        registry.updateTargetAdapter(target1, adapter2);
    }

    // ============ removeTarget Tests ============

    function test_RemoveTarget_Success() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        registry.removeTarget(target1);
        vm.stopPrank();
        assertEq(registry.targetToAdapter(target1), address(0));
        assertEq(registry.getTargetCount(), 0);
    }

    function test_RemoveTarget_EmitsEvent() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        vm.expectEmit(true, true, false, false);
        emit ActionRegistry.TargetRemoved(target1, adapter1);
        registry.removeTarget(target1);
        vm.stopPrank();
    }

    function test_RemoveTarget_RevertsIfNotRegistered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ActionRegistry.TargetNotRegistered.selector, target1));
        registry.removeTarget(target1);
    }

    function test_RemoveTarget_RevertsIfNotEmergencyRole() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        vm.stopPrank();
        vm.prank(randomUser);
        vm.expectRevert();
        registry.removeTarget(target1);
    }

    function test_RemoveTarget_UpdatesArrayCorrectly_LastElement() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        registry.registerTarget(target2, adapter1);
        registry.registerTarget(target3, adapter1);
        assertEq(registry.getTargetCount(), 3);
        registry.removeTarget(target3);
        assertEq(registry.getTargetCount(), 2);
        address[] memory targets = registry.getAllTargets();
        assertEq(targets[0], target1);
        assertEq(targets[1], target2);
        vm.stopPrank();
    }

    function test_RemoveTarget_UpdatesArrayCorrectly_MiddleElement() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        registry.registerTarget(target2, adapter1);
        registry.registerTarget(target3, adapter1);
        registry.removeTarget(target2);
        assertEq(registry.getTargetCount(), 2);
        address[] memory targets = registry.getAllTargets();
        assertEq(targets[0], target1);
        assertEq(targets[1], target3);
        vm.stopPrank();
    }

    function test_RemoveTarget_UpdatesArrayCorrectly_FirstElement() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        registry.registerTarget(target2, adapter1);
        registry.registerTarget(target3, adapter1);
        registry.removeTarget(target1);
        assertEq(registry.getTargetCount(), 2);
        address[] memory targets = registry.getAllTargets();
        assertEq(targets[0], target3);
        assertEq(targets[1], target2);
        vm.stopPrank();
    }

    // ============ unregisterAdapter Tests ============

    function test_UnregisterAdapter_Success() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        assertTrue(registry.isRegisteredAdapter(adapter1));
        registry.unregisterAdapter(adapter1);
        assertFalse(registry.isRegisteredAdapter(adapter1));
        vm.stopPrank();
    }

    function test_UnregisterAdapter_EmitsEvent() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        vm.expectEmit(true, false, false, false);
        emit ActionRegistry.AdapterUnregistered(adapter1);
        registry.unregisterAdapter(adapter1);
        vm.stopPrank();
    }

    function test_UnregisterAdapter_RevertsIfNotRegistered() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(ActionRegistry.AdapterNotRegistered.selector, adapter1));
        registry.unregisterAdapter(adapter1);
    }

    function test_UnregisterAdapter_RevertsIfNotEmergencyRole() public {
        vm.prank(admin);
        registry.registerAdapter(adapter1);
        vm.prank(randomUser);
        vm.expectRevert();
        registry.unregisterAdapter(adapter1);
    }

    function test_UnregisterAdapter_InvalidatesTargets() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        (bool validBefore, address adapterBefore) = registry.isValidTarget(target1);
        assertTrue(validBefore);
        assertEq(adapterBefore, adapter1);
        registry.unregisterAdapter(adapter1);
        (bool validAfter, address adapterAfter) = registry.isValidTarget(target1);
        assertFalse(validAfter);
        assertEq(adapterAfter, adapter1);
        vm.stopPrank();
    }

    // ============ isValidTarget Tests ============

    function test_IsValidTarget_ReturnsTrue() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        vm.stopPrank();
        (bool valid, address adapter) = registry.isValidTarget(target1);
        assertTrue(valid);
        assertEq(adapter, adapter1);
    }

    function test_IsValidTarget_ReturnsFalse_NotRegistered() public view {
        (bool valid, address adapter) = registry.isValidTarget(target1);
        assertFalse(valid);
        assertEq(adapter, address(0));
    }

    function test_IsValidTarget_ReturnsFalse_AdapterUnregistered() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        registry.unregisterAdapter(adapter1);
        vm.stopPrank();
        (bool valid,) = registry.isValidTarget(target1);
        assertFalse(valid);
    }

    // ============ getAdapter Tests ============

    function test_GetAdapter_ReturnsCorrectAdapter() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        vm.stopPrank();
        assertEq(registry.getAdapter(target1), adapter1);
    }

    function test_GetAdapter_ReturnsZeroIfNotRegistered() public view {
        assertEq(registry.getAdapter(target1), address(0));
    }

    // ============ getAllTargets Tests ============

    function test_GetAllTargets_ReturnsEmptyInitially() public view {
        address[] memory targets = registry.getAllTargets();
        assertEq(targets.length, 0);
    }

    function test_GetAllTargets_ReturnsAllTargets() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        registry.registerTarget(target2, adapter1);
        registry.registerTarget(target3, adapter1);
        vm.stopPrank();
        address[] memory targets = registry.getAllTargets();
        assertEq(targets.length, 3);
        assertEq(targets[0], target1);
        assertEq(targets[1], target2);
        assertEq(targets[2], target3);
    }

    // ============ getTargetCount Tests ============

    function test_GetTargetCount_ReturnsZeroInitially() public view {
        assertEq(registry.getTargetCount(), 0);
    }

    function test_GetTargetCount_IncrementsOnAdd() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        assertEq(registry.getTargetCount(), 1);
        registry.registerTarget(target2, adapter1);
        assertEq(registry.getTargetCount(), 2);
        vm.stopPrank();
    }

    function test_GetTargetCount_DecrementsOnRemove() public {
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        registry.registerTarget(target2, adapter1);
        assertEq(registry.getTargetCount(), 2);
        registry.removeTarget(target1);
        assertEq(registry.getTargetCount(), 1);
        vm.stopPrank();
    }

    // ============ Role Tests ============

    function test_GrantRegistryAdminRole() public {
        address newAdmin = address(0x999);
        vm.startPrank(admin);
        registry.grantRole(registry.REGISTRY_ADMIN_ROLE(), newAdmin);
        vm.stopPrank();
        assertTrue(registry.hasRole(registry.REGISTRY_ADMIN_ROLE(), newAdmin));
        vm.prank(newAdmin);
        registry.registerAdapter(adapter1);
        assertTrue(registry.isRegisteredAdapter(adapter1));
    }

    function test_GrantEmergencyRole() public {
        address emergencyActor = address(0x999);
        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerTarget(target1, adapter1);
        registry.grantRole(registry.EMERGENCY_ROLE(), emergencyActor);
        vm.stopPrank();
        assertTrue(registry.hasRole(registry.EMERGENCY_ROLE(), emergencyActor));
        vm.prank(emergencyActor);
        registry.removeTarget(target1);
        assertEq(registry.getTargetCount(), 0);
    }
}
