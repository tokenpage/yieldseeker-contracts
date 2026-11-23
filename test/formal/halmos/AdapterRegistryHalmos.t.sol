// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AWKAdapterRegistry} from "../../../src/agentwalletkit/AWKAdapterRegistry.sol";
import {Vm} from "forge-std/Vm.sol";

contract HalmosAdapterStub {}

contract AdapterRegistryHalmos {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant ADMIN = address(0xA11CE);
    address private constant EMERGENCY = address(0xE);
    address private constant TARGET_ONE = address(0x7A01);
    address private constant TARGET_TWO = address(0x7A02);

    AWKAdapterRegistry private registry;
    address private adapterOne;
    address private adapterTwo;

    function setUp() public {
        registry = new AWKAdapterRegistry(ADMIN, EMERGENCY);
        adapterOne = address(new HalmosAdapterStub());
        adapterTwo = address(new HalmosAdapterStub());
    }

    function check_property14_callerWithoutAdminRoleCanOnlyRemove(
        bool registerOne,
        bool registerTwo,
        bool mapOne,
        bool mapTwo,
        bool startPaused,
        address caller,
        bytes4 selector,
        bytes32 firstWord,
        bytes32 secondWord,
        address target,
        address adapter
    )
        external
    {
        _arrange(registerOne, registerTwo, mapOne, mapTwo, startPaused);
        vm.assume(caller != ADMIN);
        address lookupBefore = _lookup(target);
        bool registeredBefore = registry.isRegisteredAdapter(adapter);
        bool pausedBefore = registry.paused();

        vm.prank(caller);
        (bool success,) = address(registry).call(abi.encodePacked(selector, firstWord, secondWord));
        success;

        address lookupAfter = _lookup(target);
        assert(lookupAfter == lookupBefore || lookupAfter == address(0));
        assert(registeredBefore || !registry.isRegisteredAdapter(adapter));
        assert(!pausedBefore || registry.paused());
        assert(!registry.hasRole(registry.DEFAULT_ADMIN_ROLE(), caller));
    }

    function check_property14_lookupOnlyReturnsARegisteredAdapterWhileRunning(
        bool registerOne,
        bool registerTwo,
        bool mapOne,
        bool mapTwo,
        bool startPaused,
        address caller,
        bytes4 selector,
        bytes32 firstWord,
        bytes32 secondWord,
        address target
    )
        external
    {
        _arrange(registerOne, registerTwo, mapOne, mapTwo, startPaused);
        vm.prank(caller);
        (bool success,) = address(registry).call(abi.encodePacked(selector, firstWord, secondWord));
        success;

        address found = _lookup(target);
        assert(found == address(0) || (registry.isRegisteredAdapter(found) && !registry.paused()));
    }

    function check_property14_emergencyRemovalsApplyAtOnce(bool removeTarget, bool unregister, bool pause) external {
        _arrange(true, true, true, true, false);
        vm.assume(removeTarget || unregister || pause);
        vm.startPrank(EMERGENCY);
        if (removeTarget) registry.removeTarget(TARGET_ONE);
        if (unregister) registry.unregisterAdapter(adapterOne);
        if (pause) registry.pause();
        vm.stopPrank();
        assert(_lookup(TARGET_ONE) == address(0));
        assert(pause || _lookup(TARGET_TWO) == adapterTwo);
    }

    function _arrange(bool registerOne, bool registerTwo, bool mapOne, bool mapTwo, bool startPaused) private {
        vm.startPrank(ADMIN);
        if (registerOne) registry.registerAdapter(adapterOne);
        if (registerTwo) registry.registerAdapter(adapterTwo);
        if (registerOne && mapOne) registry.setTargetAdapter(TARGET_ONE, adapterOne);
        if (registerTwo && mapTwo) registry.setTargetAdapter(TARGET_TWO, adapterTwo);
        vm.stopPrank();
        if (startPaused) {
            vm.prank(EMERGENCY);
            registry.pause();
        }
    }

    function _lookup(address target) private view returns (address) {
        try registry.getTargetAdapter(target) returns (address adapter) {
            return adapter;
        } catch {
            return address(0);
        }
    }
}
