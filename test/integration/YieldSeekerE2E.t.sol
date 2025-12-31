// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

// Real contracts
import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV1 as AgentWalletV1} from "../../src/AgentWalletV1.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";

// Test utilities
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";

/// @title Yield Seeker System End-to-End Tests
/// @notice Tests for realistic user workflows and system stress scenarios
contract YieldSeekerE2ETest is Test {
    // Real contract instances
    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    ERC4626Adapter vaultAdapter;

    // Test utilities
    MockERC20 usdc;
    MockERC4626 vault;

    // Test accounts
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");
    address feeCollector = makeAddr("feeCollector");

    // Configuration
    uint256 constant FEE_RATE = 1000; // 10%

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        vault = new MockERC4626(address(usdc), "Vault", "V");

        vm.startPrank(admin);

        registry = new AdapterRegistry(admin, admin);
        feeTracker = new FeeTracker(admin);
        feeTracker.setFeeConfig(FEE_RATE, feeCollector);

        factory = new AgentWalletFactory(admin, operator);
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(feeTracker);

        AgentWalletV1 walletImplementation = new AgentWalletV1(address(factory));
        factory.setAgentWalletImplementation(walletImplementation);

        vaultAdapter = new ERC4626Adapter();
        registry.registerAdapter(address(vaultAdapter));
        registry.setTargetAdapter(address(vault), address(vaultAdapter));

        vm.stopPrank();

        // Mint test tokens
        usdc.mint(user1, 100000e6);
        usdc.mint(user2, 100000e6);
        usdc.mint(user3, 100000e6);

        // Allow wallets to receive tokens
        vm.prank(user1);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(user2);
        usdc.approve(address(vault), type(uint256).max);
        vm.prank(user3);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ========================================
    // REALISTIC USER WORKFLOWS
    // ========================================

    function test_UserWorkflow_OnboardingToActiveTrading() public {
        // Step 1: User onboards and creates first agent
        vm.prank(operator);
        AgentWalletV1 agent1 = factory.createAgentWallet(user1, 0, address(usdc));

        // Step 2: User deposits initial capital
        usdc.mint(address(agent1), 50000e6);
        vm.prank(user1);
        agent1.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (50000e6)));

        assertEq(vault.balanceOf(address(agent1)), 50000e6);

        // Step 3: User creates second agent (to diversify)
        vm.prank(operator);
        AgentWalletV1 agent2 = factory.createAgentWallet(user1, 1, address(usdc));

        // Step 4: User deposits to second agent
        usdc.mint(address(agent2), 30000e6);
        vm.prank(user1);
        agent2.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (30000e6)));

        // Verify both agents have deposits
        assertEq(vault.balanceOf(address(agent1)), 50000e6);
        assertEq(vault.balanceOf(address(agent2)), 30000e6);

        // Step 5: User checks positions
        assertTrue(agent1.owner() == user1);
        assertTrue(agent2.owner() == user1);
    }

    function test_MultiAgentScenario_SharedVault() public {
        // Create agents for 3 users depositing to same vault
        vm.prank(operator);
        AgentWalletV1 agent1 = factory.createAgentWallet(user1, 0, address(usdc));

        vm.prank(operator);
        AgentWalletV1 agent2 = factory.createAgentWallet(user2, 0, address(usdc));

        vm.prank(operator);
        AgentWalletV1 agent3 = factory.createAgentWallet(user3, 0, address(usdc));

        // All users deposit different amounts
        usdc.mint(address(agent1), 10000e6);
        usdc.mint(address(agent2), 20000e6);
        usdc.mint(address(agent3), 15000e6);

        // Execute deposits
        vm.prank(user1);
        agent1.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (10000e6)));

        vm.prank(user2);
        agent2.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (20000e6)));

        vm.prank(user3);
        agent3.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (15000e6)));

        // Total vault deposits = 45000
        // Each user's balance proportional to contribution
        assertEq(vault.balanceOf(address(agent1)), 10000e6);
        assertEq(vault.balanceOf(address(agent2)), 20000e6);
        assertEq(vault.balanceOf(address(agent3)), 15000e6);

        // Total shares
        assertEq(vault.balanceOf(address(agent1)) + vault.balanceOf(address(agent2)) + vault.balanceOf(address(agent3)), 45000e6);
    }

    function test_ComplexRebalancingStrategy() public {
        // Create agent with large capital
        vm.prank(operator);
        AgentWalletV1 agent = factory.createAgentWallet(user1, 0, address(usdc));

        usdc.mint(address(agent), 100000e6);

        // Initial deposit
        vm.prank(user1);
        agent.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (100000e6)));

        assertEq(vault.balanceOf(address(agent)), 100000e6);

        // Simulate rebalancing: withdraw 40% and keep 60%
        uint256 sharesToWithdraw = vault.balanceOf(address(agent)) * 40 / 100; // 40000
        uint256 sharesToKeep = vault.balanceOf(address(agent)) - sharesToWithdraw; // 60000

        vm.prank(user1);
        bytes memory withdrawResult = agent.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.withdraw, (sharesToWithdraw)));

        // Decode withdrawal result
        bytes memory innerResult = abi.decode(withdrawResult, (bytes));
        uint256 assetsReceived = abi.decode(innerResult, (uint256));

        // Should get 40000 USDC back
        assertEq(assetsReceived, 40000e6);
        assertEq(vault.balanceOf(address(agent)), sharesToKeep);
    }

    // ========================================
    // STRESS SCENARIOS
    // ========================================

    function test_HighFrequencyTrading_RapidDepositWithdrawals() public {
        vm.prank(operator);
        AgentWalletV1 agent = factory.createAgentWallet(user1, 0, address(usdc));

        usdc.mint(address(agent), 100000e6);

        // Perform 10 rapid deposit-withdraw cycles
        for (uint256 i = 0; i < 10; i++) {
            // Deposit 1000
            vm.prank(user1);
            agent.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (1000e6)));

            uint256 shares = vault.balanceOf(address(agent));

            // Withdraw all
            vm.prank(user1);
            agent.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.withdraw, (shares)));
        }

        // Final balance should be correct
        assertEq(vault.balanceOf(address(agent)), 0);
        assertEq(usdc.balanceOf(address(agent)), 100000e6);
    }

    function test_LargeScaleOperations() public {
        vm.prank(operator);
        AgentWalletV1 agent = factory.createAgentWallet(user1, 0, address(usdc));

        // Max out user balance
        usdc.mint(address(agent), 100000e6);

        // Deposit entire balance
        vm.prank(user1);
        agent.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (100000e6)));

        // Verify all funds deployed
        assertEq(vault.balanceOf(address(agent)), 100000e6);
        assertEq(usdc.balanceOf(address(agent)), 0);

        // Full withdrawal
        vm.prank(user1);
        agent.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.withdraw, (100000e6)));

        // Verify all funds recovered
        assertEq(vault.balanceOf(address(agent)), 0);
        assertEq(usdc.balanceOf(address(agent)), 100000e6);
    }

    // ========================================
    // ERROR RECOVERY SCENARIOS
    // ========================================

    function test_RecoveryFromBlockedAdapter() public {
        vm.prank(operator);
        AgentWalletV1 agent = factory.createAgentWallet(user1, 0, address(usdc));

        usdc.mint(address(agent), 10000e6);

        // Deposit successfully
        vm.prank(user1);
        agent.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (5000e6)));

        // Accidentally block adapter
        vm.prank(user1);
        agent.blockAdapter(address(vaultAdapter));

        // Cannot deposit or withdraw
        vm.prank(user1);
        vm.expectRevert();
        agent.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (1000e6)));

        // Recover by unblocking
        vm.prank(user1);
        agent.unblockAdapter(address(vaultAdapter));

        // Can now operate again
        vm.prank(user1);
        agent.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (3000e6)));

        assertEq(vault.balanceOf(address(agent)), 8000e6);
    }

    function test_RecoveryFromRegistryPause() public {
        vm.prank(operator);
        AgentWalletV1 agent = factory.createAgentWallet(user1, 0, address(usdc));

        usdc.mint(address(agent), 10000e6);

        // Initial deposit works
        vm.prank(user1);
        agent.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (5000e6)));

        // Registry gets paused (emergency)
        vm.prank(admin);
        registry.pause();

        // Cannot execute
        vm.prank(user1);
        vm.expectRevert();
        agent.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (1000e6)));

        // Admin unpauses
        vm.prank(admin);
        registry.unpause();

        // Can operate again
        vm.prank(user1);
        agent.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (3000e6)));

        assertEq(vault.balanceOf(address(agent)), 8000e6);
    }

    // ========================================
    // ACCESS CONTROL SCENARIOS
    // ========================================

    function test_AccessControl_OwnerCanControlWallet() public {
        vm.prank(operator);
        AgentWalletV1 agent = factory.createAgentWallet(user1, 0, address(usdc));

        usdc.mint(address(agent), 10000e6);

        // Only owner can execute
        vm.prank(user1);
        agent.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (5000e6)));

        // Non-owner cannot execute
        vm.prank(user2);
        vm.expectRevert();
        agent.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (1000e6)));
    }

    function test_AccessControl_BlockingIsOwnerPrerogative() public {
        vm.prank(operator);
        AgentWalletV1 agent = factory.createAgentWallet(user1, 0, address(usdc));

        // Only owner can block
        vm.prank(user2);
        vm.expectRevert();
        agent.blockAdapter(address(vaultAdapter));

        // Owner can block
        vm.prank(user1);
        agent.blockAdapter(address(vaultAdapter));

        assertTrue(agent.isAdapterBlocked(address(vaultAdapter)));
    }
}
