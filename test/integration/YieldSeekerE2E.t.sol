// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

// Real contracts
import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWalletV3} from "../../src/AgentWalletV3.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/fees/FeeTracker.sol";
import {VAULT_FEE, YieldSeekerVaultFeeModule} from "../../src/fees/VaultFeeModule.sol";

// Test utilities
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";

/// @title Yield Seeker System End-to-End Tests
/// @notice Tests for realistic user workflows and system stress scenarios
contract YieldSeekerE2ETest is Test {
    bytes32 constant VAULT_AGENT_PROFILE = keccak256("vault");
    // Real contract instances
    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    YieldSeekerVaultFeeModule vaultFeeModule;
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
        feeTracker = new FeeTracker(admin, admin, feeCollector);
        vaultFeeModule = new YieldSeekerVaultFeeModule(feeTracker, 5000);
        feeTracker.addFeeModule(VAULT_FEE, vaultFeeModule);
        feeTracker.setPlanRate(0, VAULT_FEE, FEE_RATE);

        factory = new AgentWalletFactory(admin, operator);
        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, registry);
        factory.setFeeTracker(feeTracker);

        AgentWalletV3 walletImplementation = new AgentWalletV3(address(factory));
        factory.setAgentWalletImplementation(AgentWalletV3(payable(address(walletImplementation))));

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
        AgentWalletV3 agent1 = AgentWalletV3(payable(address(factory.createAgentWallet(user1, 0, address(usdc), VAULT_AGENT_PROFILE))));

        // Step 2: User deposits initial capital
        usdc.mint(address(agent1), 50000e6);
        vm.prank(user1);
        agent1.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (50000e6)));

        assertEq(vault.balanceOf(address(agent1)), 50000e6);

        // Step 3: User creates second agent (to diversify)
        vm.prank(operator);
        AgentWalletV3 agent2 = AgentWalletV3(payable(address(factory.createAgentWallet(user1, 1, address(usdc), VAULT_AGENT_PROFILE))));

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
        AgentWalletV3 agent1 = AgentWalletV3(payable(address(factory.createAgentWallet(user1, 0, address(usdc), VAULT_AGENT_PROFILE))));

        vm.prank(operator);
        AgentWalletV3 agent2 = AgentWalletV3(payable(address(factory.createAgentWallet(user2, 0, address(usdc), VAULT_AGENT_PROFILE))));

        vm.prank(operator);
        AgentWalletV3 agent3 = AgentWalletV3(payable(address(factory.createAgentWallet(user3, 0, address(usdc), VAULT_AGENT_PROFILE))));

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
        AgentWalletV3 agent = AgentWalletV3(payable(address(factory.createAgentWallet(user1, 0, address(usdc), VAULT_AGENT_PROFILE))));

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
        AgentWalletV3 agent = AgentWalletV3(payable(address(factory.createAgentWallet(user1, 0, address(usdc), VAULT_AGENT_PROFILE))));

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
        AgentWalletV3 agent = AgentWalletV3(payable(address(factory.createAgentWallet(user1, 0, address(usdc), VAULT_AGENT_PROFILE))));

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
        AgentWalletV3 agent = AgentWalletV3(payable(address(factory.createAgentWallet(user1, 0, address(usdc), VAULT_AGENT_PROFILE))));

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
        AgentWalletV3 agent = AgentWalletV3(payable(address(factory.createAgentWallet(user1, 0, address(usdc), VAULT_AGENT_PROFILE))));

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
        AgentWalletV3 agent = AgentWalletV3(payable(address(factory.createAgentWallet(user1, 0, address(usdc), VAULT_AGENT_PROFILE))));

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
        AgentWalletV3 agent = AgentWalletV3(payable(address(factory.createAgentWallet(user1, 0, address(usdc), VAULT_AGENT_PROFILE))));

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
