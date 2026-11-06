// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAdapterRegistry} from "../../src/AdapterRegistry.sol";
import {TargetNotRegistered} from "../../src/agentwalletkit/AWKAdapterRegistry.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
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
        bytes memory unauthorizedError = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, registry.DEFAULT_ADMIN_ROLE());

        vm.expectRevert(unauthorizedError);
        vm.prank(nonAdmin);
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

        bytes memory unauthorizedError = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, registry.DEFAULT_ADMIN_ROLE());
        vm.expectRevert(unauthorizedError);
        vm.prank(nonAdmin);
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

    // ============ Emergency Controls ============

    function test_Pause_OnlyEmergencyRole() public {
        bytes memory unauthorizedError = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, registry.EMERGENCY_ROLE());
        vm.expectRevert(unauthorizedError);
        vm.prank(nonAdmin);
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
        vm.expectRevert(Pausable.EnforcedPause.selector);
        registry.getTargetAdapter(target);
    }

    function test_Unpause_OnlyAdminRole() public {
        bytes memory unauthorizedError = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, registry.DEFAULT_ADMIN_ROLE());
        vm.prank(emergencyAdmin);
        registry.pause();

        vm.expectRevert(unauthorizedError);
        vm.prank(nonAdmin);
        registry.unpause();
    }

    // ============ Unregister Adapter Tests ============

    function test_UnregisterAdapter_Success() public {
        address adapter = address(new MockAdapter());

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

        bytes memory unauthorizedError = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, registry.EMERGENCY_ROLE());
        vm.expectRevert(unauthorizedError);
        vm.prank(nonAdmin);
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

        bytes memory unauthorizedError = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, nonAdmin, registry.EMERGENCY_ROLE());
        vm.expectRevert(unauthorizedError);
        vm.prank(nonAdmin);
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

    // ============ GetAllTargets Tests ============

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

    function test_RenounceRole_Success() public {
        assertTrue(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));

        vm.startPrank(admin);
        registry.renounceRole(registry.DEFAULT_ADMIN_ROLE(), admin);
        vm.stopPrank();

        assertFalse(registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), admin));

        address adapter = address(new MockAdapter());
        bytes memory unauthorizedError = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, registry.DEFAULT_ADMIN_ROLE());
        vm.expectRevert(unauthorizedError);
        vm.prank(admin);
        registry.registerAdapter(adapter);
    }

    function test_RoleManagement_RoleAdminRelationships() public view {
        // Test role admin relationships
        bytes32 adminRole = registry.DEFAULT_ADMIN_ROLE();
        bytes32 emergencyRole = registry.EMERGENCY_ROLE();

        // Check role admin relationships
        assertEq(registry.getRoleAdmin(adminRole), adminRole); // Admin role is its own admin
        assertEq(registry.getRoleAdmin(emergencyRole), adminRole); // Admin role administers emergency role
    }
}

/// @dev Simple mock adapter contract for testing
contract MockAdapter {}
