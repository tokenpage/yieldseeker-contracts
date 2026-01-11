// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdapterIsBlocked} from "../../src/agentwalletkit/AWKAgentWalletV1.sol";
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

/// @title Adapter Integration Tests
/// @notice Tests for real adapter interactions with multiple vault scenarios
contract AdapterIntegrationTest is Test {
    // Real contract instances
    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    ERC4626Adapter vaultAdapter1;
    ERC4626Adapter vaultAdapter2;
    ERC4626Adapter vaultAdapter3;

    // Test utilities
    MockERC20 usdc;
    MockERC4626 vault1;
    MockERC4626 vault2;
    MockERC4626 vault3;

    // Test accounts
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address user = makeAddr("user");
    address user2 = makeAddr("user2");
    address feeCollector = makeAddr("feeCollector");

    // Configuration
    uint256 constant FEE_RATE = 1000; // 10%
    uint256 constant AGENT_INDEX = 1;

    function setUp() public {
        // Deploy test tokens
        usdc = new MockERC20("Mock USDC", "mUSDC");
        vault1 = new MockERC4626(address(usdc), "Vault 1", "V1");
        vault2 = new MockERC4626(address(usdc), "Vault 2", "V2");
        vault3 = new MockERC4626(address(usdc), "Vault 3", "V3");

        vm.startPrank(admin);

        // Deploy infrastructure
        registry = new AdapterRegistry(admin, admin);
        feeTracker = new FeeTracker(admin);
        feeTracker.setFeeConfig(FEE_RATE, feeCollector);

        factory = new AgentWalletFactory(admin, operator);
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(feeTracker);

        AgentWalletV1 walletImplementation = new AgentWalletV1(address(factory));
        factory.setAgentWalletImplementation(walletImplementation);

        // Deploy adapters
        vaultAdapter1 = new ERC4626Adapter();
        vaultAdapter2 = new ERC4626Adapter();
        vaultAdapter3 = new ERC4626Adapter();

        // Register all adapters
        registry.registerAdapter(address(vaultAdapter1));
        registry.registerAdapter(address(vaultAdapter2));
        registry.registerAdapter(address(vaultAdapter3));

        // Map vaults to adapters
        registry.setTargetAdapter(address(vault1), address(vaultAdapter1));
        registry.setTargetAdapter(address(vault2), address(vaultAdapter2));
        registry.setTargetAdapter(address(vault3), address(vaultAdapter3));

        vm.stopPrank();

        // Setup test tokens
        usdc.mint(user, 100000e6);
        usdc.mint(user2, 100000e6);
        vm.prank(user);
        usdc.approve(address(vault1), type(uint256).max);
        vm.prank(user);
        usdc.approve(address(vault2), type(uint256).max);
        vm.prank(user);
        usdc.approve(address(vault3), type(uint256).max);
    }

    // ========================================
    // SINGLE ADAPTER ADVANCED SCENARIOS
    // ========================================

    function test_SequentialDepositsAndWithdrawals() public {
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        usdc.mint(address(wallet), 10000e6);

        // First deposit: 2000 USDC
        vm.prank(user);
        bytes memory result1 = wallet.executeViaAdapter(address(vaultAdapter1), address(vault1), abi.encodeCall(vaultAdapter1.deposit, (2000e6)));
        bytes memory innerResult1 = abi.decode(result1, (bytes));
        uint256 shares1 = abi.decode(innerResult1, (uint256));
        assertEq(shares1, 2000e6);

        // Second deposit: 3000 USDC
        vm.prank(user);
        bytes memory result2 = wallet.executeViaAdapter(address(vaultAdapter1), address(vault1), abi.encodeCall(vaultAdapter1.deposit, (3000e6)));
        bytes memory innerResult2 = abi.decode(result2, (bytes));
        uint256 shares2 = abi.decode(innerResult2, (uint256));
        assertEq(shares2, 3000e6);

        // Total shares should be 5000
        assertEq(vault1.balanceOf(address(wallet)), 5000e6);

        // Partial withdrawal: redeem 2000 shares
        vm.prank(user);
        bytes memory result3 = wallet.executeViaAdapter(address(vaultAdapter1), address(vault1), abi.encodeCall(vaultAdapter1.withdraw, (2000e6)));
        bytes memory innerResult3 = abi.decode(result3, (bytes));
        uint256 assets = abi.decode(innerResult3, (uint256));
        assertEq(assets, 2000e6);
        assertEq(vault1.balanceOf(address(wallet)), 3000e6);
    }

    function test_AdapterBlockingPreventsAllOperations() public {
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
        usdc.mint(address(wallet), 5000e6);

        // Initial deposit works
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter1), address(vault1), abi.encodeCall(vaultAdapter1.deposit, (1000e6)));

        // Block adapter
        vm.prank(user);
        wallet.blockAdapter(address(vaultAdapter1));

        // All operations on this adapter now fail
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AdapterIsBlocked.selector, address(vaultAdapter1)));
        wallet.executeViaAdapter(address(vaultAdapter1), address(vault1), abi.encodeCall(vaultAdapter1.deposit, (1000e6)));

        // Unblock and try again
        vm.prank(user);
        wallet.unblockAdapter(address(vaultAdapter1));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter1), address(vault1), abi.encodeCall(vaultAdapter1.deposit, (1000e6)));

        assertEq(vault1.balanceOf(address(wallet)), 2000e6);
    }

    // ========================================
    // MULTI-VAULT SCENARIOS
    // ========================================

    function test_DistributionAcrossMultipleVaults() public {
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        usdc.mint(address(wallet), 9000e6);

        // Distribute equally: 3000 to each vault
        address[] memory adapters = new address[](3);
        address[] memory targets = new address[](3);
        bytes[] memory calls = new bytes[](3);

        adapters[0] = address(vaultAdapter1);
        targets[0] = address(vault1);
        calls[0] = abi.encodeCall(vaultAdapter1.deposit, (3000e6));

        adapters[1] = address(vaultAdapter2);
        targets[1] = address(vault2);
        calls[1] = abi.encodeCall(vaultAdapter2.deposit, (3000e6));

        adapters[2] = address(vaultAdapter3);
        targets[2] = address(vault3);
        calls[2] = abi.encodeCall(vaultAdapter3.deposit, (3000e6));

        vm.prank(user);
        wallet.executeViaAdapterBatch(adapters, targets, calls);

        // Verify distribution
        assertEq(vault1.balanceOf(address(wallet)), 3000e6);
        assertEq(vault2.balanceOf(address(wallet)), 3000e6);
        assertEq(vault3.balanceOf(address(wallet)), 3000e6);
    }

    function test_ConsolidateFromMultipleVaults() public {
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        usdc.mint(address(wallet), 9000e6);

        // Deposit 3000 to each vault
        address[] memory adapters = new address[](3);
        address[] memory targets = new address[](3);
        bytes[] memory calls = new bytes[](3);

        adapters[0] = address(vaultAdapter1);
        targets[0] = address(vault1);
        calls[0] = abi.encodeCall(vaultAdapter1.deposit, (3000e6));

        adapters[1] = address(vaultAdapter2);
        targets[1] = address(vault2);
        calls[1] = abi.encodeCall(vaultAdapter2.deposit, (3000e6));

        adapters[2] = address(vaultAdapter3);
        targets[2] = address(vault3);
        calls[2] = abi.encodeCall(vaultAdapter3.deposit, (3000e6));

        vm.prank(user);
        wallet.executeViaAdapterBatch(adapters, targets, calls);

        // Now consolidate back: withdraw all from vault1 and vault2, deposit to vault3
        adapters = new address[](3);
        targets = new address[](3);
        calls = new bytes[](3);

        adapters[0] = address(vaultAdapter1);
        targets[0] = address(vault1);
        calls[0] = abi.encodeCall(vaultAdapter1.withdraw, (3000e6));

        adapters[1] = address(vaultAdapter2);
        targets[1] = address(vault2);
        calls[1] = abi.encodeCall(vaultAdapter2.withdraw, (3000e6));

        adapters[2] = address(vaultAdapter3);
        targets[2] = address(vault3);
        calls[2] = abi.encodeCall(vaultAdapter3.deposit, (6000e6));

        vm.prank(user);
        wallet.executeViaAdapterBatch(adapters, targets, calls);

        // Verify consolidation
        assertEq(vault1.balanceOf(address(wallet)), 0);
        assertEq(vault2.balanceOf(address(wallet)), 0);
        assertEq(vault3.balanceOf(address(wallet)), 9000e6);
    }

    // ========================================
    // MULTI-USER SCENARIOS
    // ========================================

    function test_MultipleUsersIndependentPositions() public {
        // User 1 creates wallet and deposits
        vm.prank(operator);
        AgentWalletV1 wallet1 = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        usdc.mint(address(wallet1), 5000e6);
        vm.prank(user);
        wallet1.executeViaAdapter(address(vaultAdapter1), address(vault1), abi.encodeCall(vaultAdapter1.deposit, (5000e6)));

        // User 2 creates wallet and deposits
        vm.prank(operator);
        AgentWalletV1 wallet2 = factory.createAgentWallet(user2, AGENT_INDEX, address(usdc));

        usdc.mint(address(wallet2), 3000e6);
        vm.prank(user2);
        wallet2.executeViaAdapter(address(vaultAdapter1), address(vault1), abi.encodeCall(vaultAdapter1.deposit, (3000e6)));

        // Verify positions are independent
        assertEq(vault1.balanceOf(address(wallet1)), 5000e6);
        assertEq(vault1.balanceOf(address(wallet2)), 3000e6);

        // User 1 withdraws doesn't affect User 2
        vm.prank(user);
        wallet1.executeViaAdapter(address(vaultAdapter1), address(vault1), abi.encodeCall(vaultAdapter1.withdraw, (2000e6)));

        assertEq(vault1.balanceOf(address(wallet1)), 3000e6);
        assertEq(vault1.balanceOf(address(wallet2)), 3000e6); // Unaffected
    }

    // ========================================
    // ADAPTER REGISTRY CHANGES
    // ========================================

    function test_RegistryAdapterRemoval_AffectsActiveWallets() public {
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        usdc.mint(address(wallet), 5000e6);

        // Deposit works initially
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter1), address(vault1), abi.encodeCall(vaultAdapter1.deposit, (1000e6)));

        // Remove vault1 target mapping
        vm.prank(admin);
        registry.removeTarget(address(vault1));

        // Subsequent calls fail
        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter1), address(vault1), abi.encodeCall(vaultAdapter1.deposit, (1000e6)));
    }

    function test_AdapterRegistrationAfterWalletCreation() public {
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        usdc.mint(address(wallet), 5000e6);

        // Create new vault and adapter
        MockERC4626 newVault = new MockERC4626(address(usdc), "New Vault", "NV");
        ERC4626Adapter newAdapter = new ERC4626Adapter();

        // Register new adapter and vault after wallet creation
        vm.startPrank(admin);
        registry.registerAdapter(address(newAdapter));
        registry.setTargetAdapter(address(newVault), address(newAdapter));
        vm.stopPrank();

        // New vault is now accessible to existing wallet
        vm.prank(user);
        wallet.executeViaAdapter(address(newAdapter), address(newVault), abi.encodeCall(newAdapter.deposit, (2000e6)));

        assertEq(newVault.balanceOf(address(wallet)), 2000e6);
    }

    function test_ERC4626_DepositThenAppreciateThenWithdraw_ChargesFees() public {
        // Create wallet and fund with 10 USDC
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
        usdc.mint(address(wallet), 10e6);

        // Deposit 10 USDC via adapter (expect 10 shares minted)
        vm.prank(user);
        bytes memory depositResult = wallet.executeViaAdapter(address(vaultAdapter1), address(vault1), abi.encodeCall(vaultAdapter1.deposit, (10e6)));
        bytes memory depositInner = abi.decode(depositResult, (bytes));
        uint256 sharesMinted = abi.decode(depositInner, (uint256));
        assertEq(sharesMinted, 10e6, "Should mint 10 shares for 10 USDC");

        // Simulate yield: vault grows by 1 USDC
        usdc.mint(address(vault1), 1e6);

        // Withdraw all shares; assets should be 11 USDC after growth
        uint256 feesBefore = feeTracker.getFeesOwed(address(wallet));

        vm.prank(user);
        bytes memory withdrawResult = wallet.executeViaAdapter(address(vaultAdapter1), address(vault1), abi.encodeCall(vaultAdapter1.withdraw, (10e6)));
        bytes memory withdrawInner = abi.decode(withdrawResult, (bytes));
        uint256 assetsReceived = abi.decode(withdrawInner, (uint256));
        assertEq(assetsReceived, 11e6, "Should withdraw 11 USDC after appreciation");

        uint256 feesAfter = feeTracker.getFeesOwed(address(wallet));
        uint256 feesCharged = feesAfter - feesBefore;

        // Profit = 1 USDC, fee at 10% should be 0.1 USDC
        assertEq(feesCharged, 0.1e6, "Should charge 0.1 USDC fee on 1 USDC profit");

        // Position should be cleared
        assertEq(vault1.balanceOf(address(wallet)), 0, "Shares should be zero after full withdrawal");
    }
}
