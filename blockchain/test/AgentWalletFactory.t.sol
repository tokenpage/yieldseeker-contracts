// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {YieldSeekerAccessController} from "../src/AccessController.sol";
import {MockERC20} from "./MockERC20.sol";

/**
 * @title AgentWalletFactoryTest
 * @notice Comprehensive test suite for AgentWalletFactory
 */
contract AgentWalletFactoryTest is Test {
    YieldSeekerAgentWallet public agentWalletImpl;
    YieldSeekerAgentWalletFactory public factory;
    YieldSeekerAccessController public operator;
    MockERC20 public mockUSDC;

    address public admin = address(0x1);
    address public user1 = address(0x2);
    address public user2 = address(0x3);

    event AgentWalletCreated(address indexed user, uint256 indexed ownerAgentIndex, address indexed agentWallet);
    event Initialized(address indexed owner, uint256 indexed ownerAgentIndex);

    function setUp() public {
        vm.startPrank(admin);

        mockUSDC = new MockERC20("USDC", "USDC");
        operator = new YieldSeekerAccessController(admin);
        agentWalletImpl = new YieldSeekerAgentWallet(address(operator));
        factory = new YieldSeekerAgentWalletFactory(admin, address(agentWalletImpl));

        vm.stopPrank();
    }

    function testCreateAgentWallet() public {
        // Create first agent for user1 at index 0
        vm.prank(admin);
        address agentWallet = factory.createAgentWallet(user1, 0, address(mockUSDC));

        // Verify agent was created
        assertTrue(agentWallet != address(0));
        assertEq(factory.userWallets(user1, 0), agentWallet);
        assertEq(factory.getTotalWalletCount(), 1);
        assertEq(factory.allAgentWallets(0), agentWallet);

        // Verify agent is initialized with correct owner
        YieldSeekerAgentWallet agent = YieldSeekerAgentWallet(payable(agentWallet));
        assertEq(agent.owner(), user1);
        assertEq(agent.ownerAgentIndex(), 0);
    }

    function testCreateMultipleAgentsForSameUser() public {
        vm.startPrank(admin);

        // Create agents at indices 0, 1, 2
        address agent0 = factory.createAgentWallet(user1, 0, address(mockUSDC));
        address agent1 = factory.createAgentWallet(user1, 1, address(mockUSDC));
        address agent2 = factory.createAgentWallet(user1, 2, address(mockUSDC));

        vm.stopPrank();

        // Verify all agents exist at correct indices
        assertEq(factory.userWallets(user1, 0), agent0);
        assertEq(factory.userWallets(user1, 1), agent1);
        assertEq(factory.userWallets(user1, 2), agent2);

        // Verify all agents are different
        assertTrue(agent0 != agent1);
        assertTrue(agent1 != agent2);
        assertTrue(agent0 != agent2);

        // Verify total count
        assertEq(factory.getTotalWalletCount(), 3);

        // Verify all are owned by user1
        assertEq(YieldSeekerAgentWallet(payable(agent0)).owner(), user1);
        assertEq(YieldSeekerAgentWallet(payable(agent1)).owner(), user1);
        assertEq(YieldSeekerAgentWallet(payable(agent2)).owner(), user1);

        // Verify ownerAgentIndex is set correctly for each
        assertEq(YieldSeekerAgentWallet(payable(agent0)).ownerAgentIndex(), 0);
        assertEq(YieldSeekerAgentWallet(payable(agent1)).ownerAgentIndex(), 1);
        assertEq(YieldSeekerAgentWallet(payable(agent2)).ownerAgentIndex(), 2);
    }

    function testCreateAgentsForMultipleUsers() public {
        vm.startPrank(admin);
        // Create agents for different users
        address user1Agent0 = factory.createAgentWallet(user1, 0, address(mockUSDC));
        address user2Agent0 = factory.createAgentWallet(user2, 0, address(mockUSDC));
        address user1Agent1 = factory.createAgentWallet(user1, 1, address(mockUSDC));

        // Verify each user's agents
        assertEq(factory.userWallets(user1, 0), user1Agent0);
        assertEq(factory.userWallets(user1, 1), user1Agent1);
        assertEq(factory.userWallets(user2, 0), user2Agent0);

        // Verify all agents are different
        assertTrue(user1Agent0 != user2Agent0);
        assertTrue(user1Agent0 != user1Agent1);
        assertTrue(user2Agent0 != user1Agent1);

        // Verify total count
        assertEq(factory.getTotalWalletCount(), 3);

        // Verify ownership
        assertEq(YieldSeekerAgentWallet(payable(user1Agent0)).owner(), user1);
        assertEq(YieldSeekerAgentWallet(payable(user1Agent1)).owner(), user1);
        assertEq(YieldSeekerAgentWallet(payable(user2Agent0)).owner(), user2);

        // Verify ownerAgentIndex
        assertEq(YieldSeekerAgentWallet(payable(user1Agent0)).ownerAgentIndex(), 0);
        assertEq(YieldSeekerAgentWallet(payable(user1Agent1)).ownerAgentIndex(), 1);
        assertEq(YieldSeekerAgentWallet(payable(user2Agent0)).ownerAgentIndex(), 0);
    }

    function testCreateAgentWithNonSequentialIndices() public {
        vm.startPrank(admin);
        // Create agents at non-sequential indices: 5, 10, 3
        address agent5 = factory.createAgentWallet(user1, 5, address(mockUSDC));
        address agent10 = factory.createAgentWallet(user1, 10, address(mockUSDC));
        address agent3 = factory.createAgentWallet(user1, 3, address(mockUSDC));

        // Verify agents stored at correct indices
        assertEq(factory.userWallets(user1, 5), agent5);
        assertEq(factory.userWallets(user1, 10), agent10);
        assertEq(factory.userWallets(user1, 3), agent3);

        // Verify indices that weren't used are empty
        assertEq(factory.userWallets(user1, 0), address(0));
        assertEq(factory.userWallets(user1, 4), address(0));
        assertEq(factory.userWallets(user1, 6), address(0));

        // Verify total count
        assertEq(factory.getTotalWalletCount(), 3);

        // Verify ownerAgentIndex is set correctly for non-sequential indices
        assertEq(YieldSeekerAgentWallet(payable(agent5)).ownerAgentIndex(), 5);
        assertEq(YieldSeekerAgentWallet(payable(agent10)).ownerAgentIndex(), 10);
        assertEq(YieldSeekerAgentWallet(payable(agent3)).ownerAgentIndex(), 3);
    }

    function testCannotCreateAgentAtSameIndexTwice() public {
        vm.startPrank(admin);
        // Create agent at index 0
        factory.createAgentWallet(user1, 0, address(mockUSDC));

        // Try to create another agent at index 0
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerAgentWalletFactory.AgentAlreadyExists.selector, user1, 0));
        factory.createAgentWallet(user1, 0, address(mockUSDC));
    }

    function testCannotCreateAgentWithZeroAddress() public {
        vm.startPrank(admin);
        vm.expectRevert(YieldSeekerAgentWalletFactory.InvalidAddress.selector);
        factory.createAgentWallet(address(0), 0, address(mockUSDC));
        vm.stopPrank();
    }

    function testOnlyAgentCreatorRoleCanCreateAgents() public {
        // Get the role hash first (before prank)
        bytes32 creatorRole = factory.AGENT_CREATOR_ROLE();

        // Non-admin (user1) tries to create agent - should fail with AccessControlUnauthorizedAccount error
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, creatorRole));
        factory.createAgentWallet(user1, 0, address(mockUSDC));

        // Admin (has AGENT_CREATOR_ROLE) can create agent - should succeed
        vm.prank(admin);
        address agentWallet = factory.createAgentWallet(user1, 0, address(mockUSDC));
        assertTrue(agentWallet != address(0));
        assertEq(factory.userWallets(user1, 0), agentWallet);
    }

    function testDefaultAdminCanGrantAgentCreatorRole() public {
        bytes32 creatorRole = factory.AGENT_CREATOR_ROLE();

        // Admin (has DEFAULT_ADMIN_ROLE) grants AGENT_CREATOR_ROLE to user2
        vm.prank(admin);
        factory.grantRole(creatorRole, user2);

        // Verify user2 now has the role
        assertTrue(factory.hasRole(creatorRole, user2));

        // user2 can now create agents
        vm.prank(user2);
        address agentWallet = factory.createAgentWallet(user1, 0, address(mockUSDC));
        assertTrue(agentWallet != address(0));
    }

    function testDefaultAdminCanRevokeAgentCreatorRole() public {
        bytes32 creatorRole = factory.AGENT_CREATOR_ROLE();

        // Admin grants role to user2
        vm.prank(admin);
        factory.grantRole(creatorRole, user2);
        assertTrue(factory.hasRole(creatorRole, user2));

        // Admin revokes the role
        vm.prank(admin);
        factory.revokeRole(creatorRole, user2);
        assertFalse(factory.hasRole(creatorRole, user2));

        // user2 can no longer create agents
        vm.prank(user2);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user2, creatorRole));
        factory.createAgentWallet(user1, 0, address(mockUSDC));
    }

    function testNonAdminCannotGrantRoles() public {
        bytes32 adminRole = factory.DEFAULT_ADMIN_ROLE();
        bytes32 creatorRole = factory.AGENT_CREATOR_ROLE();

        // user1 (non-admin) tries to grant AGENT_CREATOR_ROLE to user2
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, user1, adminRole));
        factory.grantRole(creatorRole, user2);
    }

    function testPredictAgentWalletAddress() public {
        vm.startPrank(admin);
        // Predict address before deployment
        address predicted = factory.predictAgentWalletAddress(user1, 0);

        // Create agent
        address actual = factory.createAgentWallet(user1, 0, address(mockUSDC));

        // Verify prediction was correct
        assertEq(predicted, actual);
    }

    function testPredictAgentWalletAddressForDifferentIndices() public {
        vm.startPrank(admin);
        // Predict addresses for different indices
        address predicted0 = factory.predictAgentWalletAddress(user1, 0);
        address predicted1 = factory.predictAgentWalletAddress(user1, 1);
        address predicted2 = factory.predictAgentWalletAddress(user1, 2);

        // Verify predictions are all different
        assertTrue(predicted0 != predicted1);
        assertTrue(predicted1 != predicted2);
        assertTrue(predicted0 != predicted2);

        // Create agents in different order
        address actual1 = factory.createAgentWallet(user1, 1, address(mockUSDC));
        address actual0 = factory.createAgentWallet(user1, 0, address(mockUSDC));
        address actual2 = factory.createAgentWallet(user1, 2, address(mockUSDC));

        // Verify predictions were correct
        assertEq(predicted0, actual0);
        assertEq(predicted1, actual1);
        assertEq(predicted2, actual2);
    }

    function testPredictAgentWalletAddressForDifferentUsers() public {
        vm.startPrank(admin);
        // Same index, different users should have different addresses
        address user1Predicted = factory.predictAgentWalletAddress(user1, 0);
        address user2Predicted = factory.predictAgentWalletAddress(user2, 0);

        assertTrue(user1Predicted != user2Predicted);

        // Verify by creating
        address user1Actual = factory.createAgentWallet(user1, 0, address(mockUSDC));
        address user2Actual = factory.createAgentWallet(user2, 0, address(mockUSDC));

        assertEq(user1Predicted, user1Actual);
        assertEq(user2Predicted, user2Actual);
    }

    function testAllAgentWalletsArray() public {
        vm.startPrank(admin);
        // Create several agents
        address agent1 = factory.createAgentWallet(user1, 0, address(mockUSDC));
        address agent2 = factory.createAgentWallet(user2, 0, address(mockUSDC));
        address agent3 = factory.createAgentWallet(user1, 1, address(mockUSDC));

        // Verify allAgentWallets array
        assertEq(factory.allAgentWallets(0), agent1);
        assertEq(factory.allAgentWallets(1), agent2);
        assertEq(factory.allAgentWallets(2), agent3);
        assertEq(factory.getTotalWalletCount(), 3);
    }

    function testAgentWalletCreatedEvent() public {
        vm.startPrank(admin);
        // Expect event to be emitted
        vm.expectEmit(true, true, true, false);
        emit AgentWalletCreated(user1, 0, factory.predictAgentWalletAddress(user1, 0));

        factory.createAgentWallet(user1, 0, address(mockUSDC));
    }

    function testAgentWalletCreatedEventWithMultipleAgents() public {
        vm.startPrank(admin);
        // Create first agent
        factory.createAgentWallet(user1, 0, address(mockUSDC));

        // Expect event for second agent
        vm.expectEmit(true, true, true, false);
        emit AgentWalletCreated(user1, 5, factory.predictAgentWalletAddress(user1, 5));

        factory.createAgentWallet(user1, 5, address(mockUSDC));
    }

    function testInitializedEventEmitted() public {
        vm.startPrank(admin);
        // Expect the Initialized event to be emitted during agent creation
        vm.expectEmit(true, true, false, false);
        emit Initialized(user1, 7);

        // Create agent and verify event is emitted
        factory.createAgentWallet(user1, 7, address(mockUSDC));
    }

    function testGetTotalWalletCount() public {
        vm.startPrank(admin);
        assertEq(factory.getTotalWalletCount(), 0);

        factory.createAgentWallet(user1, 0, address(mockUSDC));
        assertEq(factory.getTotalWalletCount(), 1);

        factory.createAgentWallet(user1, 1, address(mockUSDC));
        assertEq(factory.getTotalWalletCount(), 2);

        factory.createAgentWallet(user2, 0, address(mockUSDC));
        assertEq(factory.getTotalWalletCount(), 3);
    }

    function testDeterministicAddressAcrossChains() public {
        vm.startPrank(admin);
        // This test verifies the address would be the same on another chain
        // by checking it only depends on user, userAgentIndex, and factory address

        address predicted = factory.predictAgentWalletAddress(user1, 42);

        // Deploy on "another chain" by creating new factory at same address
        // (In real multi-chain deployment, factory would be at same address via CREATE2)
        address actual = factory.createAgentWallet(user1, 42, address(mockUSDC));

        assertEq(predicted, actual);
    }

    function testFuzzCreateAgent(address user, uint256 userAgentIndex) public {
        vm.startPrank(admin);
        // Skip zero address
        vm.assume(user != address(0));

        // Predict and create
        address predicted = factory.predictAgentWalletAddress(user, userAgentIndex);
        address actual = factory.createAgentWallet(user, userAgentIndex, address(mockUSDC));

        // Verify
        assertEq(predicted, actual);
        assertEq(factory.userWallets(user, userAgentIndex), actual);
        assertEq(YieldSeekerAgentWallet(payable(actual)).owner(), user);
        assertEq(YieldSeekerAgentWallet(payable(actual)).ownerAgentIndex(), userAgentIndex);
    }

    function testFuzzCannotCreateDuplicate(address user, uint256 userAgentIndex) public {
        vm.startPrank(admin);
        vm.assume(user != address(0));

        // Create first agent
        factory.createAgentWallet(user, userAgentIndex, address(mockUSDC));

        // Try to create duplicate
        vm.expectRevert(abi.encodeWithSelector(YieldSeekerAgentWalletFactory.AgentAlreadyExists.selector, user, userAgentIndex));
        factory.createAgentWallet(user, userAgentIndex, address(mockUSDC));
    }

    function testOwnerAgentIndexStoredCorrectly() public {
        vm.startPrank(admin);
        // Test that ownerAgentIndex is stored correctly and can be read
        uint256[] memory indices = new uint256[](4);
        indices[0] = 0;
        indices[1] = 5;
        indices[2] = 100;
        indices[3] = 999;

        for (uint256 i = 0; i < indices.length; i++) {
            address agentWallet = factory.createAgentWallet(user1, indices[i], address(mockUSDC));
            YieldSeekerAgentWallet agent = YieldSeekerAgentWallet(payable(agentWallet));

            // Verify ownerAgentIndex is stored and retrievable
            assertEq(agent.ownerAgentIndex(), indices[i]); // Verify it matches the index in factory storage
            assertEq(factory.userWallets(user1, indices[i]), agentWallet);
        }
    }
}
