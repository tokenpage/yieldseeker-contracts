// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {Test} from "forge-std/Test.sol";

contract AdapterRegistrySecurityTest is Test {
    AdapterRegistry registry;
    address admin = address(0xAD);
    address adapter = address(0x11);
    address target = address(0x22);

    function setUp() public {
        registry = new AdapterRegistry(admin, admin);
        vm.startPrank(admin);
        // Etch some code so it passes the NotAContract check
        vm.etch(adapter, hex"00");
        registry.registerAdapter(adapter);
        registry.setTargetAdapter(target, adapter);
        vm.stopPrank();
    }

    function test_GetAllTargetsFiltersUnregisteredAdapters() public {
        // Initially target should be there
        address[] memory targets = registry.getAllTargets();
        assertEq(targets.length, 1);
        assertEq(targets[0], target);

        // Unregister adapter
        vm.prank(admin);
        registry.unregisterAdapter(adapter);

        // Target should be gone from getAllTargets
        targets = registry.getAllTargets();
        assertEq(targets.length, 0);

        // getTargetAdapter should also return 0
        assertEq(registry.getTargetAdapter(target), address(0));

        // Re-register adapter
        vm.prank(admin);
        registry.registerAdapter(adapter);

        // Target should be back
        targets = registry.getAllTargets();
        assertEq(targets.length, 1);
        assertEq(targets[0], target);
    }

    function test_GetAllTargetsMultipleTargets() public {
        address target2 = address(0x33);
        address adapter2 = address(0x44);
        vm.etch(adapter2, hex"00");

        vm.startPrank(admin);
        registry.registerAdapter(adapter2);
        registry.setTargetAdapter(target2, adapter2);
        vm.stopPrank();

        address[] memory targets = registry.getAllTargets();
        assertEq(targets.length, 2);

        // Unregister one adapter
        vm.prank(admin);
        registry.unregisterAdapter(adapter);

        targets = registry.getAllTargets();
        assertEq(targets.length, 1);
        assertEq(targets[0], target2);
    }
}
