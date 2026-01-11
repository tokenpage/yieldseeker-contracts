// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdminTimelock} from "../../src/AdminTimelock.sol";
import {Test} from "forge-std/Test.sol";

contract DummyTarget {
    uint256 public stored;

    function setValue(uint256 value) external {
        stored = value;
    }
}

contract YieldSeekerAdminTimelockTest is Test {
    YieldSeekerAdminTimelock timelock;
    YieldSeekerAdminTimelock delayedTimelock;
    DummyTarget target;

    address proposer = makeAddr("proposer");
    address executor = makeAddr("executor");
    address admin = makeAddr("admin");

    function setUp() public {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        timelock = new YieldSeekerAdminTimelock(0, proposers, executors, admin);

        address[] memory proposersDelayed = new address[](1);
        proposersDelayed[0] = proposer;
        address[] memory executorsDelayed = new address[](1);
        executorsDelayed[0] = executor;
        delayedTimelock = new YieldSeekerAdminTimelock(1 days, proposersDelayed, executorsDelayed, admin);

        target = new DummyTarget();

        // Avoid zero-delay schedules colliding with DONE_TIMESTAMP sentinel value
        vm.warp(100);
    }

    function test_Constructor_RoleAssignment() public view {
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), proposer));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), executor));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), admin));
    }

    function test_ScheduleAndExecute_Succeeds() public {
        bytes memory data = abi.encodeWithSelector(DummyTarget.setValue.selector, 7);
        bytes32 salt = keccak256("schedule_and_execute");
        bytes32 id = timelock.hashOperation(address(target), 0, data, bytes32(0), salt);
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), salt, 0);
        uint256 scheduled = timelock.getTimestamp(id);
        assertGt(scheduled, 0);
        vm.warp(scheduled + 1);
        assertTrue(timelock.isOperationReady(id));
        vm.prank(executor);
        timelock.execute(address(target), 0, data, bytes32(0), salt);
        assertEq(target.stored(), 7);
    }

    function test_Schedule_OnlyProposer() public {
        bytes memory data = abi.encodeWithSelector(DummyTarget.setValue.selector, 1);
        bytes32 salt = keccak256("only_proposer");
        vm.expectRevert();
        timelock.schedule(address(target), 0, data, bytes32(0), salt, 0);
    }

    function test_Execute_OnlyExecutor() public {
        bytes memory data = abi.encodeWithSelector(DummyTarget.setValue.selector, 2);
        bytes32 salt = keccak256("only_executor");
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), salt, 0);
        vm.expectRevert();
        timelock.execute(address(target), 0, data, bytes32(0), salt);
    }

    function test_Execute_EnforcesDelay() public {
        bytes memory data = abi.encodeWithSelector(DummyTarget.setValue.selector, 3);
        bytes32 salt = keccak256("delay_enforced");
        vm.prank(proposer);
        delayedTimelock.schedule(address(target), 0, data, bytes32(0), salt, 1 days);
        vm.expectRevert();
        delayedTimelock.execute(address(target), 0, data, bytes32(0), salt);
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(executor);
        delayedTimelock.execute(address(target), 0, data, bytes32(0), salt);
        assertEq(target.stored(), 3);
    }

    function test_Cancel_Succeeds() public {
        bytes memory data = abi.encodeWithSelector(DummyTarget.setValue.selector, 4);
        bytes32 salt = keccak256("cancel");
        vm.prank(proposer);
        timelock.schedule(address(target), 0, data, bytes32(0), salt, 0);
        bytes32 id = timelock.hashOperation(address(target), 0, data, bytes32(0), salt);
        uint256 scheduled = timelock.getTimestamp(id);
        assertGt(scheduled, 0);
        assertTrue(timelock.isOperationPending(id));
        vm.prank(proposer);
        timelock.cancel(id);
        vm.expectRevert();
        timelock.execute(address(target), 0, data, bytes32(0), salt);
    }
}
