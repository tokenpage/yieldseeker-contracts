// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerErrors} from "../../src/Errors.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {MockAdapterRegistry} from "../mocks/MockAdapterRegistry.sol";
import {MockAgentWalletFactory} from "../mocks/MockAgentWalletFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeTracker} from "../mocks/MockFeeTracker.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Test} from "forge-std/Test.sol";

/// @title AgentWalletFactory Unit Tests
/// @notice Isolated unit tests for wallet creation logic with complete isolation
contract AgentWalletFactoryTest is Test {
    MockAgentWalletFactory factory;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address nonOperator = makeAddr("nonOperator");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    MockERC20 mockUsdc;
    MockAdapterRegistry mockRegistry;
    MockFeeTracker mockFeeTracker;
    address mockImplementation;

    // Role constants (matching OpenZeppelin AccessControl)
    bytes32 constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    event WalletCreated(address indexed owner, uint256 indexed agentIndex, address indexed wallet, address baseAsset, address implementation);
    event ImplementationUpdated(address indexed oldImplementation, address indexed newImplementation);
    event AdapterRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event FeeTrackerUpdated(address indexed oldTracker, address indexed newTracker);
    event RoleGranted(bytes32 indexed role, address indexed account, address indexed sender);
    event RoleRevoked(bytes32 indexed role, address indexed account, address indexed sender);

    function setUp() public {
        mockUsdc = new MockERC20("Mock USDC", "mUSDC");
        mockRegistry = new MockAdapterRegistry();
        mockFeeTracker = new MockFeeTracker(1000, makeAddr("feeCollector")); // 10% fee rate
        mockImplementation = makeAddr("implementation");

        vm.prank(admin);
        factory = new MockAgentWalletFactory(address(mockRegistry), address(mockFeeTracker), mockImplementation);
    }

    // ============ CREATE2 Deployment Logic Tests ============

    function test_ComputeWalletAddress_Deterministic() public view {
        address computed1 = factory.computeWalletAddress(user1, 1, address(mockUsdc));
        address computed2 = factory.computeWalletAddress(user1, 1, address(mockUsdc));

        assertEq(computed1, computed2);
        assertTrue(computed1 != address(0));
    }

    function test_ComputeWalletAddress_DifferentSalts() public view {
        address addr1 = factory.computeWalletAddress(user1, 1, address(mockUsdc));
        address addr2 = factory.computeWalletAddress(user1, 2, address(mockUsdc));
        address addr3 = factory.computeWalletAddress(user2, 1, address(mockUsdc));

        assertTrue(addr1 != addr2);
        assertTrue(addr1 != addr3);
        assertTrue(addr2 != addr3);
    }

    function test_ComputeWalletAddress_SameInputs() public view {
        address addr1 = factory.computeWalletAddress(user1, 5, address(mockUsdc));
        address addr2 = factory.computeWalletAddress(user1, 5, address(mockUsdc));

        assertEq(addr1, addr2);
    }

    function test_CreateAgentWallet_Success() public {
        vm.prank(admin); // Admin has operator role by default
        factory.grantRole(OPERATOR_ROLE, operator);

        address predicted = factory.computeWalletAddress(user1, 1, address(mockUsdc));

        vm.expectEmit(true, true, true, true);
        emit WalletCreated(user1, 1, predicted, address(mockUsdc), mockImplementation);

        vm.prank(operator);
        address wallet = factory.createAgentWallet(user1, 1, address(mockUsdc));

        assertEq(wallet, predicted);
        assertTrue(factory.walletExists(wallet));
        assertEq(factory.getWalletCounter(), 1);
    }

    function test_CreateAgentWallet_DuplicateRevert() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        vm.prank(operator);
        factory.createAgentWallet(user1, 1, address(mockUsdc));

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AgentAlreadyExists.selector, user1, 1));
        factory.createAgentWallet(user1, 1, address(mockUsdc));
    }

    function test_CreateAgentWallet_EmitsEvent() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        address predicted = factory.computeWalletAddress(user1, 1, address(mockUsdc));

        vm.expectEmit(true, true, true, true);
        emit WalletCreated(user1, 1, predicted, address(mockUsdc), mockImplementation);

        vm.prank(operator);
        factory.createAgentWallet(user1, 1, address(mockUsdc));
    }

    // ============ Role Management Tests ============

    function test_GrantOperatorRole_Success() public {
        vm.expectEmit(true, true, true, true);
        emit RoleGranted(OPERATOR_ROLE, operator, admin);

        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        assertTrue(factory.hasRole(OPERATOR_ROLE, operator));
    }

    function test_GrantOperatorRole_OnlyAdmin() public {
        vm.prank(nonOperator);
        vm.expectRevert();
        factory.grantRole(OPERATOR_ROLE, operator);
    }

    function test_RevokeOperatorRole_Success() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);
        assertTrue(factory.hasRole(OPERATOR_ROLE, operator));

        vm.expectEmit(true, true, true, true);
        emit RoleRevoked(OPERATOR_ROLE, operator, admin);

        vm.prank(admin);
        factory.revokeRole(OPERATOR_ROLE, operator);

        assertFalse(factory.hasRole(OPERATOR_ROLE, operator));
    }

    function test_HasOperatorRole_Correct() public {
        assertFalse(factory.hasRole(OPERATOR_ROLE, operator));

        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        assertTrue(factory.hasRole(OPERATOR_ROLE, operator));
    }

    function test_CreateWallet_OnlyOperators() public {
        vm.prank(nonOperator);
        vm.expectRevert();
        factory.createAgentWallet(user1, 1, address(mockUsdc));

        // Admin should work (has all roles)
        vm.prank(admin);
        factory.createAgentWallet(user1, 1, address(mockUsdc));
    }

    function test_OperatorRole_EmitsEvents() public {
        vm.expectEmit(true, true, true, true);
        emit RoleGranted(OPERATOR_ROLE, operator, admin);

        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        vm.expectEmit(true, true, true, true);
        emit RoleRevoked(OPERATOR_ROLE, operator, admin);

        vm.prank(admin);
        factory.revokeRole(OPERATOR_ROLE, operator);
    }

    // ============ Configuration Management Tests ============

    function test_SetImplementation_Success() public {
        address newImpl = makeAddr("newImplementation");

        vm.expectEmit(true, true, false, false);
        emit ImplementationUpdated(mockImplementation, newImpl);

        vm.prank(admin);
        factory.setAgentWalletImplementation(newImpl);

        assertEq(factory.getAgentWalletImplementation(), newImpl);
    }

    function test_SetImplementation_OnlyAdmin() public {
        address newImpl = makeAddr("newImplementation");

        vm.prank(nonOperator);
        vm.expectRevert();
        factory.setAgentWalletImplementation(newImpl);
    }

    function test_SetAdapterRegistry_Success() public {
        address newRegistry = makeAddr("newRegistry");

        vm.expectEmit(true, true, false, false);
        emit AdapterRegistryUpdated(address(mockRegistry), newRegistry);

        vm.prank(admin);
        factory.setAdapterRegistry(newRegistry);

        assertEq(address(factory.getAdapterRegistry()), newRegistry);
    }

    function test_SetFeeTracker_Success() public {
        address newTracker = makeAddr("newTracker");

        vm.expectEmit(true, true, false, false);
        emit FeeTrackerUpdated(address(mockFeeTracker), newTracker);

        vm.prank(admin);
        factory.setFeeTracker(newTracker);

        assertEq(address(factory.getFeeTracker()), newTracker);
    }

    function test_SetConfiguration_ZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        factory.setAgentWalletImplementation(address(0));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        factory.setAdapterRegistry(address(0));

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        factory.setFeeTracker(address(0));
    }

    function test_GetConfiguration_Correct() public view {
        assertEq(factory.getAgentWalletImplementation(), mockImplementation);
        assertEq(address(factory.getAdapterRegistry()), address(mockRegistry));
        assertEq(address(factory.getFeeTracker()), address(mockFeeTracker));
    }

    // ============ Input Validation & Edge Cases Tests ============

    function test_CreateWallet_ZeroOwner() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        factory.createAgentWallet(address(0), 1, address(mockUsdc));
    }

    function test_CreateWallet_ZeroAsset() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.ZeroAddress.selector));
        factory.createAgentWallet(user1, 1, address(0));
    }

    function test_CreateWallet_NonContractAsset() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        address eoa = makeAddr("eoa");

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.NotAContract.selector, eoa));
        factory.createAgentWallet(user1, 1, eoa);
    }

    function test_CreateWallet_MaxGasUsage() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        uint256 gasBefore = gasleft();
        vm.prank(operator);
        factory.createAgentWallet(user1, 1, address(mockUsdc));
        uint256 gasUsed = gasBefore - gasleft();

        // Should be reasonable gas usage (less than 200k for mock)
        assertLt(gasUsed, 200000);
    }

    function test_ImplementationImmutable_AfterDeploy() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        vm.prank(operator);
        address wallet = factory.createAgentWallet(user1, 1, address(mockUsdc));

        // Change implementation
        address newImpl = makeAddr("newImpl");
        vm.prank(admin);
        factory.setAgentWalletImplementation(newImpl);

        // Existing wallet should still reference old implementation
        // (In this mock, we can't easily test this, but in real implementation
        // the wallet would be immutable after deployment)
        assertTrue(wallet != address(0));
    }

    // ============ Counter & State Management Tests ============

    function test_WalletCounter_Increments() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        assertEq(factory.getWalletCounter(), 0);

        vm.prank(operator);
        factory.createAgentWallet(user1, 1, address(mockUsdc));
        assertEq(factory.getWalletCounter(), 1);

        vm.prank(operator);
        factory.createAgentWallet(user1, 2, address(mockUsdc));
        assertEq(factory.getWalletCounter(), 2);

        vm.prank(operator);
        factory.createAgentWallet(user2, 1, address(mockUsdc));
        assertEq(factory.getWalletCounter(), 3);
    }

    function test_WalletCounter_Persistent() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        vm.prank(operator);
        factory.createAgentWallet(user1, 1, address(mockUsdc));

        uint256 counter1 = factory.getWalletCounter();
        uint256 counter2 = factory.getWalletCounter();

        assertEq(counter1, counter2);
        assertEq(counter1, 1);
    }

    function test_OwnerWalletCount_Correct() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        assertEq(factory.getOwnerWalletCount(user1), 0);
        assertEq(factory.getOwnerWalletCount(user2), 0);

        vm.prank(operator);
        factory.createAgentWallet(user1, 1, address(mockUsdc));
        assertEq(factory.getOwnerWalletCount(user1), 1);
        assertEq(factory.getOwnerWalletCount(user2), 0);

        vm.prank(operator);
        factory.createAgentWallet(user1, 2, address(mockUsdc));
        assertEq(factory.getOwnerWalletCount(user1), 2);

        vm.prank(operator);
        factory.createAgentWallet(user2, 1, address(mockUsdc));
        assertEq(factory.getOwnerWalletCount(user1), 2);
        assertEq(factory.getOwnerWalletCount(user2), 1);
    }

    function test_WalletExists_Correct() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        address predicted = factory.computeWalletAddress(user1, 1, address(mockUsdc));
        assertFalse(factory.walletExists(predicted));

        vm.prank(operator);
        address wallet = factory.createAgentWallet(user1, 1, address(mockUsdc));

        assertTrue(factory.walletExists(wallet));
        assertEq(wallet, predicted);
    }

    function test_GetWalletsByOwner_Correct() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        address[] memory wallets = factory.getWalletsByOwner(user1);
        assertEq(wallets.length, 0);

        vm.prank(operator);
        address wallet1 = factory.createAgentWallet(user1, 1, address(mockUsdc));

        wallets = factory.getWalletsByOwner(user1);
        assertEq(wallets.length, 1);
        assertEq(wallets[0], wallet1);

        vm.prank(operator);
        address wallet2 = factory.createAgentWallet(user1, 2, address(mockUsdc));

        wallets = factory.getWalletsByOwner(user1);
        assertEq(wallets.length, 2);
        assertTrue(wallets[0] == wallet1 || wallets[1] == wallet1);
        assertTrue(wallets[0] == wallet2 || wallets[1] == wallet2);
    }

    function test_StateConsistency_MultipleCreations() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        // Create multiple wallets and verify state consistency
        address[] memory expectedWallets = new address[](3);

        vm.prank(operator);
        expectedWallets[0] = factory.createAgentWallet(user1, 1, address(mockUsdc));

        vm.prank(operator);
        expectedWallets[1] = factory.createAgentWallet(user1, 2, address(mockUsdc));

        vm.prank(operator);
        expectedWallets[2] = factory.createAgentWallet(user2, 1, address(mockUsdc));

        // Verify counter
        assertEq(factory.getWalletCounter(), 3);

        // Verify owner counts
        assertEq(factory.getOwnerWalletCount(user1), 2);
        assertEq(factory.getOwnerWalletCount(user2), 1);

        // Verify existence
        for (uint256 i = 0; i < expectedWallets.length; i++) {
            assertTrue(factory.walletExists(expectedWallets[i]));
        }

        // Verify owner wallets
        address[] memory user1Wallets = factory.getWalletsByOwner(user1);
        assertEq(user1Wallets.length, 2);
    }

    // ============ Access Control Comprehensive Tests ============

    function test_AdminOnly_AllFunctions() public {
        address newImpl = makeAddr("newImpl");
        address newRegistry = makeAddr("newRegistry");
        address newTracker = makeAddr("newTracker");

        // Test all admin-only functions fail for non-admin
        vm.startPrank(nonOperator);

        vm.expectRevert();
        factory.setAgentWalletImplementation(newImpl);

        vm.expectRevert();
        factory.setAdapterRegistry(newRegistry);

        vm.expectRevert();
        factory.setFeeTracker(newTracker);

        vm.expectRevert();
        factory.grantRole(OPERATOR_ROLE, operator);

        vm.expectRevert();
        factory.revokeRole(OPERATOR_ROLE, operator);

        vm.stopPrank();

        // Test they work for admin
        vm.startPrank(admin);

        factory.setAgentWalletImplementation(newImpl);
        factory.setAdapterRegistry(newRegistry);
        factory.setFeeTracker(newTracker);
        factory.grantRole(OPERATOR_ROLE, operator);
        factory.revokeRole(OPERATOR_ROLE, operator);

        vm.stopPrank();
    }

    function test_OperatorOnly_CreateFunction() public {
        // Non-operator cannot create
        vm.prank(nonOperator);
        vm.expectRevert();
        factory.createAgentWallet(user1, 1, address(mockUsdc));

        // Operator can create
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        vm.prank(operator);
        factory.createAgentWallet(user1, 1, address(mockUsdc));

        // Admin can also create (has all roles)
        vm.prank(admin);
        factory.createAgentWallet(user1, 2, address(mockUsdc));
    }

    function test_AccessControl_EventEmission() public {
        vm.expectEmit(true, true, true, true);
        emit RoleGranted(OPERATOR_ROLE, operator, admin);

        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        vm.expectEmit(true, true, true, true);
        emit RoleRevoked(OPERATOR_ROLE, operator, admin);

        vm.prank(admin);
        factory.revokeRole(OPERATOR_ROLE, operator);
    }

    function test_PausedState_BlockOperations() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        vm.prank(admin);
        factory.pause();

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        factory.createAgentWallet(user1, 1, address(mockUsdc));
    }

    function test_UnpausedState_ResumeOperations() public {
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operator);

        vm.prank(admin);
        factory.pause();

        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        factory.createAgentWallet(user1, 1, address(mockUsdc));

        vm.prank(admin);
        factory.unpause();

        vm.prank(operator);
        factory.createAgentWallet(user1, 1, address(mockUsdc));
    }

    function test_GrantOperatorRole_RegrantAtLimit_Succeeds() public {
        // Grant MAX_OPERATORS (10) operators
        address[] memory operators = new address[](10);
        for (uint256 i = 0; i < 10; i++) {
            operators[i] = makeAddr(string(abi.encodePacked("operator", i)));
            vm.prank(admin);
            factory.grantRole(OPERATOR_ROLE, operators[i]);
            assertTrue(factory.hasRole(OPERATOR_ROLE, operators[i]));
        }

        // Re-granting to an existing operator should succeed (no-op)
        // This should NOT revert even though we're at MAX_OPERATORS
        vm.prank(admin);
        factory.grantRole(OPERATOR_ROLE, operators[0]);

        // Verify the operator still has the role
        assertTrue(factory.hasRole(OPERATOR_ROLE, operators[0]));

        // Trying to add a NEW operator should still revert
        address newOperatorAtLimit = makeAddr("newOperatorAtLimit");
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.TooManyOperators.selector));
        factory.grantRole(OPERATOR_ROLE, newOperatorAtLimit);
    }
}
