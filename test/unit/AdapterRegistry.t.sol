// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry} from "../../src/AdapterRegistry.sol";
import {TargetNotRegistered} from "../../src/agentwalletkit/AWKAdapterRegistry.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {Test} from "forge-std/Test.sol";

/// @title AdapterRegistry Unit Tests
/// @notice Isolated unit tests for adapter registration and query logic
contract AdapterRegistryTest is Test {
    YieldSeekerAdapterRegistry registry;

    address admin = makeAddr("admin");
    address emergencyAdmin = makeAddr("emergencyAdmin");
    address nonAdmin = makeAddr("nonAdmin");

    event AdapterRegistered(address indexed adapter);
    event AdapterUnregistered(address indexed adapter);
    event TargetRegistered(address indexed target, address indexed adapter);
    event TargetRemoved(address indexed target, address indexed previousAdapter);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    function setUp() public {
        registry = new YieldSeekerAdapterRegistry(admin, emergencyAdmin);
    }

    // ============ Core Registration Logic ============

    function test_RegisterAdapter_Success() public {
        address adapter = address(new MockAdapter());

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit AdapterRegistered(adapter);
        registry.registerAdapter(adapter);

        assertTrue(registry.isRegisteredAdapter(adapter));
    }

    function test_RegisterAdapter_OnlyAdmin() public {
        address adapter = address(new MockAdapter());

        vm.prank(nonAdmin);
        vm.expectRevert();
        registry.registerAdapter(adapter);
    }

    function test_RegisterAdapter_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        registry.registerAdapter(address(0));
    }

    function test_RegisterAdapter_EOA() public {
        address eoa = makeAddr("eoa");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.NotAContract.selector, eoa));
        registry.registerAdapter(eoa);
    }

    function test_RegisterAdapter_AlreadyRegistered() public {
        address adapter = address(new MockAdapter());

        vm.startPrank(admin);
        registry.registerAdapter(adapter);

        // Should not revert - idempotent operation
        vm.expectEmit(true, false, false, false);
        emit AdapterRegistered(adapter);
        registry.registerAdapter(adapter);
        vm.stopPrank();

        assertTrue(registry.isRegisteredAdapter(adapter));
    }

    function test_IsRegistered_Correct() public {
        address adapter = address(new MockAdapter());

        // Initially not registered
        assertFalse(registry.isRegisteredAdapter(adapter));

        // After registration
        vm.prank(admin);
        registry.registerAdapter(adapter);
        assertTrue(registry.isRegisteredAdapter(adapter));
    }

    // ============ Target-Adapter Mapping ============

    function test_SetTargetAdapter_Success() public {
        address adapter = address(new MockAdapter());
        address target = makeAddr("target");

        vm.startPrank(admin);
        registry.registerAdapter(adapter);

        vm.expectEmit(true, true, false, false);
        emit TargetRegistered(target, adapter);
        registry.setTargetAdapter(target, adapter);
        vm.stopPrank();

        assertEq(registry.getTargetAdapter(target), adapter);
    }

    function test_SetTargetAdapter_OnlyAdmin() public {
        address adapter = address(new MockAdapter());
        address target = makeAddr("target");

        vm.prank(admin);
        registry.registerAdapter(adapter);

        vm.prank(nonAdmin);
        vm.expectRevert();
        registry.setTargetAdapter(target, adapter);
    }

    function test_SetTargetAdapter_ZeroTarget() public {
        address adapter = address(new MockAdapter());

        vm.startPrank(admin);
        registry.registerAdapter(adapter);

        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        registry.setTargetAdapter(address(0), adapter);
        vm.stopPrank();
    }

    function test_SetTargetAdapter_UnregisteredAdapter() public {
        address adapter = address(new MockAdapter());
        address target = makeAddr("target");

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, adapter));
        registry.setTargetAdapter(target, adapter);
    }

    function test_GetTargetAdapter_ValidMapping() public {
        address adapter = address(new MockAdapter());
        address target = makeAddr("target");

        vm.startPrank(admin);
        registry.registerAdapter(adapter);
        registry.setTargetAdapter(target, adapter);
        vm.stopPrank();

        assertEq(registry.getTargetAdapter(target), adapter);
    }

    function test_GetTargetAdapter_NoMapping() public {
        address target = makeAddr("target");

        assertEq(registry.getTargetAdapter(target), address(0));
    }

    // ============ Emergency Controls ============

    function test_Pause_OnlyEmergency() public {
        vm.prank(emergencyAdmin);
        registry.pause();
        assertTrue(registry.paused());
    }

    function test_Pause_OnlyEmergencyRole() public {
        vm.prank(nonAdmin);
        vm.expectRevert();
        registry.pause();
    }

    function test_QueryDuringPause_Blocked() public {
        address adapter = address(new MockAdapter());
        address target = makeAddr("target");

        // Set up mapping first
        vm.startPrank(admin);
        registry.registerAdapter(adapter);
        registry.setTargetAdapter(target, adapter);
        vm.stopPrank();

        // Pause registry
        vm.prank(emergencyAdmin);
        registry.pause();

        // Queries should revert when paused (OpenZeppelin Pausable behavior)
        vm.expectRevert();
        registry.getTargetAdapter(target);
    }

    function test_Unpause_OnlyAdmin() public {
        vm.prank(emergencyAdmin);
        registry.pause();

        vm.prank(admin);
        registry.unpause();
        assertFalse(registry.paused());
    }

    function test_Unpause_OnlyAdminRole() public {
        vm.prank(emergencyAdmin);
        registry.pause();

        vm.prank(nonAdmin);
        vm.expectRevert();
        registry.unpause();
    }

    // ============ Unregister Adapter Tests ============

    function test_UnregisterAdapter_Success() public {
        address adapter = address(new MockAdapter());

        vm.startPrank(emergencyAdmin);
        // First register the adapter (only admin can do this)
        vm.stopPrank();
        vm.prank(admin);
        registry.registerAdapter(adapter);

        vm.prank(emergencyAdmin);
        vm.expectEmit(true, false, false, false);
        emit AdapterUnregistered(adapter);
        registry.unregisterAdapter(adapter);

        assertFalse(registry.isRegisteredAdapter(adapter));
    }

    function test_UnregisterAdapter_NotRegistered() public {
        address adapter = address(new MockAdapter());

        vm.prank(emergencyAdmin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, adapter));
        registry.unregisterAdapter(adapter);
    }

    function test_UnregisterAdapter_OnlyEmergency() public {
        address adapter = address(new MockAdapter());

        vm.prank(admin);
        registry.registerAdapter(adapter);

        vm.prank(nonAdmin);
        vm.expectRevert();
        registry.unregisterAdapter(adapter);
    }

    function test_UnregisterAdapter_AffectsGetTargetAdapter() public {
        address adapter = address(new MockAdapter());
        address target = makeAddr("target");

        vm.startPrank(admin);
        registry.registerAdapter(adapter);
        registry.setTargetAdapter(target, adapter);
        vm.stopPrank();

        // Should return adapter before unregistration
        assertEq(registry.getTargetAdapter(target), adapter);

        // Unregister adapter
        vm.prank(emergencyAdmin);
        registry.unregisterAdapter(adapter);

        // Should return zero after unregistration
        assertEq(registry.getTargetAdapter(target), address(0));
    }

    // ============ Remove Target Tests ============

    function test_RemoveTarget_Success() public {
        address adapter = address(new MockAdapter());
        address target = makeAddr("target");

        vm.startPrank(admin);
        registry.registerAdapter(adapter);
        registry.setTargetAdapter(target, adapter);
        vm.stopPrank();

        vm.prank(emergencyAdmin);
        vm.expectEmit(true, true, false, false);
        emit TargetRemoved(target, adapter);
        registry.removeTarget(target);

        assertEq(registry.getTargetAdapter(target), address(0));
    }

    function test_RemoveTarget_NotRegistered() public {
        address target = makeAddr("target");

        vm.prank(emergencyAdmin);
        vm.expectRevert(abi.encodeWithSelector(TargetNotRegistered.selector, target));
        registry.removeTarget(target);
    }

    function test_RemoveTarget_OnlyEmergency() public {
        address adapter = address(new MockAdapter());
        address target = makeAddr("target");

        vm.startPrank(admin);
        registry.registerAdapter(adapter);
        registry.setTargetAdapter(target, adapter);
        vm.stopPrank();

        vm.prank(nonAdmin);
        vm.expectRevert();
        registry.removeTarget(target);
    }

    // ============ Set Target Mapping Edge Cases ============

    function test_SetTargetAdapter_UpdateExisting() public {
        address adapter1 = address(new MockAdapter());
        address adapter2 = address(new MockAdapter());
        address target = makeAddr("target");

        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerAdapter(adapter2);

        // Set initial mapping
        registry.setTargetAdapter(target, adapter1);
        assertEq(registry.getTargetAdapter(target), adapter1);

        // Update to different adapter - should emit both events
        vm.expectEmit(true, true, false, false);
        emit TargetRemoved(target, adapter1);
        vm.expectEmit(true, true, false, false);
        emit TargetRegistered(target, adapter2);
        registry.setTargetAdapter(target, adapter2);
        vm.stopPrank();

        assertEq(registry.getTargetAdapter(target), adapter2);
    }

    function test_SetTargetAdapter_SameAdapter() public {
        address adapter = address(new MockAdapter());
        address target = makeAddr("target");

        vm.startPrank(admin);
        registry.registerAdapter(adapter);
        registry.setTargetAdapter(target, adapter);

        // Setting same adapter should be no-op (no events emitted)
        registry.setTargetAdapter(target, adapter);
        vm.stopPrank();

        assertEq(registry.getTargetAdapter(target), adapter);
    }

    // ============ GetAllTargets Tests ============

    function test_GetAllTargets_Empty() public view {
        address[] memory targets = registry.getAllTargets();
        assertEq(targets.length, 0);
    }

    function test_GetAllTargets_FilterUnregistered() public {
        address adapter1 = address(new MockAdapter());
        address adapter2 = address(new MockAdapter());
        address target1 = makeAddr("target1");
        address target2 = makeAddr("target2");

        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        registry.registerAdapter(adapter2);
        registry.setTargetAdapter(target1, adapter1);
        registry.setTargetAdapter(target2, adapter2);
        vm.stopPrank();

        // Should return both targets
        address[] memory targets = registry.getAllTargets();
        assertEq(targets.length, 2);

        // Unregister one adapter
        vm.prank(emergencyAdmin);
        registry.unregisterAdapter(adapter1);

        // Should only return target with registered adapter
        targets = registry.getAllTargets();
        assertEq(targets.length, 1);
        assertEq(targets[0], target2);
    }

    function test_GetAllTargets_MultipleTargets() public {
        address adapter = address(new MockAdapter());
        address target1 = makeAddr("target1");
        address target2 = makeAddr("target2");
        address target3 = makeAddr("target3");

        vm.startPrank(admin);
        registry.registerAdapter(adapter);
        registry.setTargetAdapter(target1, adapter);
        registry.setTargetAdapter(target2, adapter);
        registry.setTargetAdapter(target3, adapter);
        vm.stopPrank();

        address[] memory targets = registry.getAllTargets();
        assertEq(targets.length, 3);

        // Verify all targets are present (order may vary)
        bool found1 = false;
        bool found2 = false;
        bool found3 = false;

        for (uint256 i = 0; i < targets.length; i++) {
            if (targets[i] == target1) found1 = true;
            if (targets[i] == target2) found2 = true;
            if (targets[i] == target3) found3 = true;
        }

        assertTrue(found1);
        assertTrue(found2);
        assertTrue(found3);
    }

    function test_GetAllTargets_AfterRemoval() public {
        address adapter = address(new MockAdapter());
        address target1 = makeAddr("target1");
        address target2 = makeAddr("target2");

        vm.startPrank(admin);
        registry.registerAdapter(adapter);
        registry.setTargetAdapter(target1, adapter);
        registry.setTargetAdapter(target2, adapter);
        vm.stopPrank();

        // Should return both targets
        address[] memory targets = registry.getAllTargets();
        assertEq(targets.length, 2);

        // Remove one target
        vm.prank(emergencyAdmin);
        registry.removeTarget(target1);

        // Should only return remaining target
        targets = registry.getAllTargets();
        assertEq(targets.length, 1);
        assertEq(targets[0], target2);
    }

    // ============ Access Control Edge Cases ============

    function test_AdminRole_CanRegisterAdapters() public {
        address adapter = address(new MockAdapter());

        // Admin should be able to register adapters
        vm.prank(admin);
        registry.registerAdapter(adapter);

        assertTrue(registry.isRegisteredAdapter(adapter));
    }

    function test_EmergencyRole_CanPauseAndUnregister() public {
        address adapter = address(new MockAdapter());

        // Register adapter first
        vm.prank(admin);
        registry.registerAdapter(adapter);

        // Emergency admin should be able to pause
        vm.prank(emergencyAdmin);
        registry.pause();
        assertTrue(registry.paused());

        // Emergency admin should be able to unregister adapters
        vm.prank(emergencyAdmin);
        registry.unregisterAdapter(adapter);
        assertFalse(registry.isRegisteredAdapter(adapter));
    }

    // ============ Missing Event Tests ============

    function test_RegisterAdapter_EmitsEvent() public {
        address adapter = address(new MockAdapter());

        vm.prank(admin);
        vm.expectEmit(true, false, false, false);
        emit AdapterRegistered(adapter);
        registry.registerAdapter(adapter);
    }

    // ============ Role Management Tests ============

    function test_RenounceRole_Success() public {
        // First verify admin has the role
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));

        // Admin can renounce their own role - must be called with same address as msg.sender
        vm.startPrank(admin);
        registry.renounceRole(registry.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();

        // Should no longer have admin role
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));

        // Should no longer be able to register adapters
        address adapter = address(new MockAdapter());
        vm.prank(admin);
        vm.expectRevert(); // Generic expectRevert since address varies
        registry.registerAdapter(adapter);
    }

    function test_AdminRole_Verification() public view {
        // Verify admin has the admin role
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));

        // Verify emergency admin has emergency role
        assertTrue(registry.hasRole(registry.EMERGENCY_ROLE(), emergencyAdmin));

        // Verify nonAdmin doesn't have admin role
        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), nonAdmin));
    }

    function test_RoleManagement_AdminCanPerformAdminActions() public {
        // Test that admin can perform admin-only functions
        address adapter = address(new MockAdapter());
        address target = makeAddr("target");

        vm.startPrank(admin);

        // Admin can register adapters
        registry.registerAdapter(adapter);
        assertTrue(registry.isRegisteredAdapter(adapter));

        // Admin can set target adapters
        registry.setTargetAdapter(target, adapter);
        assertEq(registry.getTargetAdapter(target), adapter);

        // Admin can unpause if paused
        vm.stopPrank();

        // Emergency admin pauses first
        vm.prank(emergencyAdmin);
        registry.pause();
        assertTrue(registry.paused());

        // Admin can unpause
        vm.prank(admin);
        registry.unpause();
        assertFalse(registry.paused());
    }

    function test_RoleManagement_EmergencyCanPerformEmergencyActions() public {
        // Set up initial state
        address adapter = address(new MockAdapter());
        address target = makeAddr("target");

        vm.prank(admin);
        registry.registerAdapter(adapter);
        vm.prank(admin);
        registry.setTargetAdapter(target, adapter);

        vm.startPrank(emergencyAdmin);

        // Emergency admin can pause
        registry.pause();
        assertTrue(registry.paused());

        // Emergency admin can unregister adapters
        registry.unregisterAdapter(adapter);
        assertFalse(registry.isRegisteredAdapter(adapter));

        vm.stopPrank();

        // Unpause to test remove target
        vm.prank(admin);
        registry.unpause();

        // Re-register adapter for target removal test
        vm.prank(admin);
        registry.registerAdapter(adapter);

        // Emergency admin can remove targets
        vm.prank(emergencyAdmin);
        registry.removeTarget(target);
        assertEq(registry.getTargetAdapter(target), address(0));
    }

    function test_RoleManagement_NonAdminCannotPerformAdminActions() public {
        address adapter = address(new MockAdapter());
        address target = makeAddr("target");

        vm.startPrank(nonAdmin);

        // Non-admin cannot register adapters
        vm.expectRevert();
        registry.registerAdapter(adapter);

        // Non-admin cannot set target adapters
        vm.expectRevert();
        registry.setTargetAdapter(target, adapter);

        // Non-admin cannot unpause
        vm.expectRevert();
        registry.unpause();

        vm.stopPrank();
    }

    function test_RoleManagement_NonEmergencyCannotPerformEmergencyActions() public {
        address adapter = address(new MockAdapter());
        address target = makeAddr("target");

        // Set up initial state
        vm.prank(admin);
        registry.registerAdapter(adapter);
        vm.prank(admin);
        registry.setTargetAdapter(target, adapter);

        vm.startPrank(nonAdmin);

        // Non-emergency cannot pause
        vm.expectRevert();
        registry.pause();

        // Non-emergency cannot unregister adapters
        vm.expectRevert();
        registry.unregisterAdapter(adapter);

        // Non-emergency cannot remove targets
        vm.expectRevert();
        registry.removeTarget(target);

        vm.stopPrank();
    }

    function test_RoleManagement_RoleQueries() public view {
        // Test role query functions
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        bytes32 emergencyRole = registry.EMERGENCY_ROLE();

        // Check correct role assignments from constructor
        assertTrue(registry.hasRole(adminRole, admin));
        assertTrue(registry.hasRole(emergencyRole, emergencyAdmin));
        assertFalse(registry.hasRole(adminRole, nonAdmin));
        assertFalse(registry.hasRole(emergencyRole, nonAdmin));
        assertFalse(registry.hasRole(adminRole, emergencyAdmin));
        assertFalse(registry.hasRole(emergencyRole, admin));
    }

    function test_RoleManagement_RoleAdminRelationships() public view {
        // Test role admin relationships
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        bytes32 emergencyRole = registry.EMERGENCY_ROLE();

        // Check role admin relationships
        assertEq(registry.getRoleAdmin(adminRole), adminRole); // Admin role is its own admin
        assertEq(registry.getRoleAdmin(emergencyRole), adminRole); // Admin role administers emergency role
    }

    // ============ Edge Cases & Validation ============

    function test_BatchOperations_AtomicFailure() public {
        // Test that if we try to set multiple targets in sequence and one fails,
        // the previous operations should still be valid (no atomic rollback)
        address adapter1 = address(new MockAdapter());
        address adapter2 = address(new MockAdapter());
        address target1 = makeAddr("target1");
        address target2 = makeAddr("target2");

        vm.startPrank(admin);
        registry.registerAdapter(adapter1);
        // Don't register adapter2 - this will cause failure

        // First operation should succeed
        registry.setTargetAdapter(target1, adapter1);
        assertEq(registry.getTargetAdapter(target1), adapter1);

        // Second operation should fail due to unregistered adapter
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, adapter2));
        registry.setTargetAdapter(target2, adapter2);
        vm.stopPrank();

        // First operation should still be valid (no rollback)
        assertEq(registry.getTargetAdapter(target1), adapter1);
        assertEq(registry.getTargetAdapter(target2), address(0));
    }
}

/// @dev Simple mock adapter contract for testing
contract MockAdapter {
    // Empty contract that has code (not EOA)

    }
