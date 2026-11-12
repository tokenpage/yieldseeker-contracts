// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAdapterRegistry} from "../../../src/AdapterRegistry.sol";
import {TargetNotRegistered} from "../../../src/agentwalletkit/AWKAdapterRegistry.sol";
import {AWKErrors} from "../../../src/agentwalletkit/AWKErrors.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";

contract RegistryActor {
    address private immutable owner;
    address public controller;

    constructor(address owner_) {
        owner = owner_;
        controller = owner_;
    }

    modifier onlyController() {
        require(msg.sender == controller, "not controller");
        _;
    }

    function setController(address nextController) external {
        require(msg.sender == owner, "not owner");
        controller = nextController;
    }

    function registerAdapter(YieldSeekerAdapterRegistry registry, address adapter) external onlyController {
        registry.registerAdapter(adapter);
    }

    function setTarget(YieldSeekerAdapterRegistry registry, address target, address adapter) external onlyController {
        registry.setTargetAdapter(target, adapter);
    }

    function unregisterAdapter(YieldSeekerAdapterRegistry registry, address adapter) external onlyController {
        registry.unregisterAdapter(adapter);
    }

    function removeTarget(YieldSeekerAdapterRegistry registry, address target) external onlyController {
        registry.removeTarget(target);
    }

    function pause(YieldSeekerAdapterRegistry registry) external onlyController {
        registry.pause();
    }

    function unpause(YieldSeekerAdapterRegistry registry) external onlyController {
        registry.unpause();
    }
}

contract RegistryDummyAdapter {}

contract RegistryDummyTarget {}

contract RegistryHandler is Test {
    uint256 private constant ADAPTER_COUNT = 4;
    uint256 private constant TARGET_COUNT = 8;

    YieldSeekerAdapterRegistry public immutable registry;
    RegistryActor private immutable admin;
    RegistryActor private immutable emergency;
    RegistryActor private immutable attacker;

    address[4] private _adapters;
    address[8] private _targets;
    mapping(address adapter => bool registered) private _ghostRegistered;
    mapping(address target => address adapter) private _ghostTargetAdapter;

    uint256 public adminRegisterCalls;
    uint256 public adminSetTargetCalls;
    uint256 public emergencyUnregisterCalls;
    uint256 public emergencyRemoveCalls;
    uint256 public emergencyPauseCalls;
    uint256 public adminUnpauseCalls;
    uint256 public attackerCalls;

    constructor(YieldSeekerAdapterRegistry registry_, RegistryActor admin_, RegistryActor emergency_, RegistryActor attacker_) {
        registry = registry_;
        admin = admin_;
        emergency = emergency_;
        attacker = attacker_;
        for (uint256 i = 0; i < ADAPTER_COUNT; i++) {
            _adapters[i] = address(new RegistryDummyAdapter());
        }
        for (uint256 i = 0; i < TARGET_COUNT; i++) {
            _targets[i] = address(new RegistryDummyTarget());
        }
    }

    function adminRegisterAdapter(uint256 adapterSeed) external {
        address adapter = _adapters[bound(adapterSeed, 0, ADAPTER_COUNT - 1)];
        adminRegisterCalls++;
        try admin.registerAdapter(registry, adapter) {
            _ghostRegistered[adapter] = true;
        } catch {}
    }

    function adminSetTarget(uint256 targetSeed, uint256 adapterSeed) external {
        address target = _targets[bound(targetSeed, 0, TARGET_COUNT - 1)];
        address adapter = _adapters[bound(adapterSeed, 0, ADAPTER_COUNT - 1)];
        adminSetTargetCalls++;
        try admin.setTarget(registry, target, adapter) {
            _ghostTargetAdapter[target] = adapter;
        } catch {}
    }

    function emergencyUnregisterAdapter(uint256 adapterSeed) external {
        address adapter = _adapters[bound(adapterSeed, 0, ADAPTER_COUNT - 1)];
        emergencyUnregisterCalls++;
        try emergency.unregisterAdapter(registry, adapter) {
            _ghostRegistered[adapter] = false;
        } catch {}
    }

    function emergencyRemoveTarget(uint256 targetSeed) external {
        address target = _targets[bound(targetSeed, 0, TARGET_COUNT - 1)];
        emergencyRemoveCalls++;
        try emergency.removeTarget(registry, target) {
            _ghostTargetAdapter[target] = address(0);
        } catch {}
    }

    function emergencyPause(uint256) external {
        emergencyPauseCalls++;
        try emergency.pause(registry) {} catch {}
    }

    function adminUnpause(uint256) external {
        adminUnpauseCalls++;
        try admin.unpause(registry) {} catch {}
    }

    function attackerCannotChangeRegistry(uint256 targetSeed, uint256 adapterSeed, uint8 operationSeed) external {
        address target = _targets[bound(targetSeed, 0, TARGET_COUNT - 1)];
        address adapter = _adapters[bound(adapterSeed, 0, ADAPTER_COUNT - 1)];
        uint8 operation = uint8(bound(operationSeed, 0, 5));
        bytes32 beforeState = _registryStateDigest();
        attackerCalls++;

        if (operation == 0) {
            try attacker.registerAdapter(registry, adapter) {} catch {}
        } else if (operation == 1) {
            try attacker.setTarget(registry, target, adapter) {} catch {}
        } else if (operation == 2) {
            try attacker.unregisterAdapter(registry, adapter) {} catch {}
        } else if (operation == 3) {
            try attacker.removeTarget(registry, target) {} catch {}
        } else if (operation == 4) {
            try attacker.pause(registry) {} catch {}
        } else {
            try attacker.unpause(registry) {} catch {}
        }

        assertEq(_registryStateDigest(), beforeState, "attacker changed registry state");
    }

    function adapterAt(uint256 index) external view returns (address) {
        return _adapters[index];
    }

    function targetAt(uint256 index) external view returns (address) {
        return _targets[index];
    }

    function ghostRegistered(address adapter) external view returns (bool) {
        return _ghostRegistered[adapter];
    }

    function ghostTargetAdapter(address target) external view returns (address) {
        return _ghostTargetAdapter[target];
    }

    function selectors() external pure returns (bytes4[] memory selectors_) {
        selectors_ = new bytes4[](7);
        selectors_[0] = this.adminRegisterAdapter.selector;
        selectors_[1] = this.adminSetTarget.selector;
        selectors_[2] = this.emergencyUnregisterAdapter.selector;
        selectors_[3] = this.emergencyRemoveTarget.selector;
        selectors_[4] = this.emergencyPause.selector;
        selectors_[5] = this.adminUnpause.selector;
        selectors_[6] = this.attackerCannotChangeRegistry.selector;
    }

    function totalCalls() external view returns (uint256) {
        return adminRegisterCalls + adminSetTargetCalls + emergencyUnregisterCalls + emergencyRemoveCalls + emergencyPauseCalls + adminUnpauseCalls + attackerCalls;
    }

    function _registryStateDigest() private view returns (bytes32 digest) {
        bool isPaused = registry.paused();
        bytes memory state = abi.encode(isPaused);
        for (uint256 i = 0; i < ADAPTER_COUNT; i++) {
            address adapter = _adapters[i];
            state = abi.encode(state, registry.isRegisteredAdapter(adapter));
        }
        if (!isPaused) {
            for (uint256 i = 0; i < TARGET_COUNT; i++) {
                state = abi.encode(state, registry.getTargetAdapter(_targets[i]));
            }
        }
        address[] memory targets = registry.getAllTargets();
        state = abi.encode(state, targets);
        digest = keccak256(state);
    }
}

contract AdapterRegistryInvariant is StdInvariant, Test {
    YieldSeekerAdapterRegistry private registry;
    RegistryActor private admin;
    RegistryActor private emergency;
    RegistryActor private attacker;
    RegistryHandler private handler;

    function setUp() public {
        admin = new RegistryActor(address(this));
        emergency = new RegistryActor(address(this));
        attacker = new RegistryActor(address(this));
        registry = new YieldSeekerAdapterRegistry(address(admin), address(emergency));
        handler = new RegistryHandler(registry, admin, emergency, attacker);
        admin.setController(address(handler));
        emergency.setController(address(handler));
        attacker.setController(address(handler));

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: handler.selectors()}));
    }

    function deployRegistry(address admin, address emergencyAdmin) external returns (YieldSeekerAdapterRegistry) {
        return new YieldSeekerAdapterRegistry(admin, emergencyAdmin);
    }

    function test_adminAndEmergencyRejectInvalidRegistryInputsAndRecoverMappings() public {
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        this.deployRegistry(address(0), address(this));
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        this.deployRegistry(address(this), address(0));

        YieldSeekerAdapterRegistry registryUnderTest = new YieldSeekerAdapterRegistry(address(this), address(this));
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        registryUnderTest.registerAdapter(address(0));
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.NotAContract.selector, address(0xBEEF)));
        registryUnderTest.registerAdapter(address(0xBEEF));

        RegistryDummyAdapter firstAdapter = new RegistryDummyAdapter();
        RegistryDummyAdapter secondAdapter = new RegistryDummyAdapter();
        RegistryDummyTarget target = new RegistryDummyTarget();
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        registryUnderTest.setTargetAdapter(address(0), address(firstAdapter));
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(firstAdapter)));
        registryUnderTest.setTargetAdapter(address(target), address(firstAdapter));
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(0)));
        registryUnderTest.setTargetAdapter(address(target), address(0));

        registryUnderTest.registerAdapter(address(firstAdapter));
        registryUnderTest.registerAdapter(address(secondAdapter));
        registryUnderTest.setTargetAdapter(address(target), address(firstAdapter));
        vm.recordLogs();
        registryUnderTest.setTargetAdapter(address(target), address(firstAdapter));
        Vm.Log[] memory duplicateMappingLogs = vm.getRecordedLogs();
        assertEq(duplicateMappingLogs.length, 0);
        assertEq(registryUnderTest.getTargetAdapter(address(target)), address(firstAdapter));
        assertEq(registryUnderTest.getAllTargets().length, 1);

        registryUnderTest.setTargetAdapter(address(target), address(secondAdapter));
        assertEq(registryUnderTest.getTargetAdapter(address(target)), address(secondAdapter));
        assertEq(registryUnderTest.getAllTargets().length, 1);
        registryUnderTest.removeTarget(address(target));
        vm.expectRevert(abi.encodeWithSelector(TargetNotRegistered.selector, address(target)));
        registryUnderTest.removeTarget(address(target));
        assertEq(registryUnderTest.getAllTargets().length, 0);

        registryUnderTest.setTargetAdapter(address(target), address(firstAdapter));
        registryUnderTest.unregisterAdapter(address(firstAdapter));
        assertEq(registryUnderTest.getTargetAdapter(address(target)), address(0));
        assertEq(registryUnderTest.getAllTargets().length, 0);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(firstAdapter)));
        registryUnderTest.unregisterAdapter(address(firstAdapter));
        registryUnderTest.registerAdapter(address(firstAdapter));
        assertEq(registryUnderTest.getTargetAdapter(address(target)), address(firstAdapter));

        registryUnderTest.pause();
        vm.expectRevert();
        registryUnderTest.getTargetAdapter(address(target));
        assertEq(registryUnderTest.getAllTargets().length, 1);
        registryUnderTest.unpause();
        assertEq(registryUnderTest.getTargetAdapter(address(target)), address(firstAdapter));

        RegistryDummyAdapter unauthorizedAdapter = new RegistryDummyAdapter();
        vm.expectRevert();
        vm.prank(address(0xCAFE));
        registryUnderTest.pause();
        vm.expectRevert();
        vm.prank(address(0xCAFE));
        registryUnderTest.registerAdapter(address(unauthorizedAdapter));
    }

    function invariant_targetLookupOnlyReturnsActiveMappingsAndRevertsWhilePaused() public view {
        for (uint256 i = 0; i < 4; i++) {
            address adapter = handler.adapterAt(i);
            assertEq(registry.isRegisteredAdapter(adapter), handler.ghostRegistered(adapter));
        }

        bool isPaused = registry.paused();
        for (uint256 i = 0; i < 8; i++) {
            address target = handler.targetAt(i);
            (bool success, bytes memory result) = address(registry).staticcall(abi.encodeCall(registry.getTargetAdapter, (target)));
            if (isPaused) {
                assertFalse(success, "target lookup did not revert while the registry was paused");
                continue;
            }

            assertTrue(success, "target lookup unexpectedly reverted while unpaused");
            address actualAdapter = abi.decode(result, (address));
            address mappedAdapter = handler.ghostTargetAdapter(target);
            address expectedAdapter = handler.ghostRegistered(mappedAdapter) ? mappedAdapter : address(0);
            assertEq(actualAdapter, expectedAdapter, "target lookup differs from the ghost mapping");
            if (actualAdapter != address(0)) assertTrue(registry.isRegisteredAdapter(actualAdapter));
        }
    }

    function invariant_getAllTargetsMatchesActiveGhostSetWhilePausedOrRunning() public view {
        address[] memory actualTargets = registry.getAllTargets();
        uint256 expectedCount;
        for (uint256 i = 0; i < 8; i++) {
            address target = handler.targetAt(i);
            address mappedAdapter = handler.ghostTargetAdapter(target);
            if (mappedAdapter != address(0) && handler.ghostRegistered(mappedAdapter)) expectedCount++;
        }
        assertEq(actualTargets.length, expectedCount, "registry target count differs from ghost set");

        for (uint256 i = 0; i < actualTargets.length; i++) {
            bool found;
            for (uint256 j = 0; j < 8; j++) {
                address target = handler.targetAt(j);
                address mappedAdapter = handler.ghostTargetAdapter(target);
                if (actualTargets[i] == target && mappedAdapter != address(0) && handler.ghostRegistered(mappedAdapter)) found = true;
            }
            assertTrue(found, "registry returned a removed or inactive target");
            for (uint256 j = i + 1; j < actualTargets.length; j++) {
                assertTrue(actualTargets[i] != actualTargets[j], "registry returned a target twice");
            }
        }
    }

    function invariant_attackerWorkflowsNeverChangeRegistryState() public view {
        for (uint256 i = 0; i < 4; i++) {
            assertEq(registry.isRegisteredAdapter(handler.adapterAt(i)), handler.ghostRegistered(handler.adapterAt(i)));
        }
    }

    function afterInvariant() public {
        assertGt(handler.totalCalls(), 0, "registry handler was never exercised");
        assertGt(handler.adminRegisterCalls(), 0, "admin registration path was never exercised");
        assertGt(handler.emergencyUnregisterCalls(), 0, "emergency unregistration path was never exercised");
        assertGt(handler.emergencyRemoveCalls(), 0, "emergency target removal path was never exercised");
        assertGt(handler.emergencyPauseCalls(), 0, "emergency pause path was never exercised");
        assertGt(handler.adminUnpauseCalls(), 0, "admin unpause path was never exercised");
        assertGt(handler.attackerCalls(), 0, "attacker path was never exercised");
        console2.log("registry handler calls", handler.totalCalls());
        console2.log("registry attacker calls", handler.attackerCalls());
    }
}
