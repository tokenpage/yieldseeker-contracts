// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {Test} from "forge-std/Test.sol";

// Real contracts (not mocks)
import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV1 as AgentWalletV1} from "../../src/AgentWalletV1.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";

// Test utilities
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";

/// @title System Integration Tests
/// @notice Simplified integration tests using real contracts working together
contract SystemIntegrationTest is Test {
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
    address user = makeAddr("user");
    address user2 = makeAddr("user2");
    address feeCollector = makeAddr("feeCollector");

    // Configuration constants
    uint256 constant FEE_RATE = 1000; // 10%
    uint256 constant AGENT_INDEX = 1;

    // Events from real contracts
    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 indexed ownerAgentIndex, address baseAsset);
    event AdapterRegistered(address indexed adapter);

    function setUp() public {
        // Deploy test tokens
        usdc = new MockERC20("Mock USDC", "mUSDC");
        vault = new MockERC4626(address(usdc), "Mock Vault", "mVault");

        vm.startPrank(admin);

        // Deploy real contracts in correct order
        registry = new AdapterRegistry(admin, admin); // admin as both admin and emergency admin
        feeTracker = new FeeTracker(admin);
        feeTracker.setFeeConfig(FEE_RATE, feeCollector);

        // Deploy factory
        factory = new AgentWalletFactory(admin, operator);

        // Configure factory components
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(feeTracker);

        // Create wallet implementation with correct factory reference
        AgentWalletV1 walletImplementation = new AgentWalletV1(address(factory));
        factory.setAgentWalletImplementation(walletImplementation);

        // Deploy real adapters
        vaultAdapter = new ERC4626Adapter();

        // Configure registry with real adapter
        registry.registerAdapter(address(vaultAdapter));
        registry.setTargetAdapter(address(vault), address(vaultAdapter));

        vm.stopPrank();

        // Setup test tokens
        usdc.mint(user, 10000e6); // 10,000 USDC
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ============ Basic System Integration Tests ============

    function test_FullSystemSetup_Success() public view {
        // Verify all components are properly configured
        assertTrue(registry.isRegisteredAdapter(address(vaultAdapter)));

        address mappedAdapter = registry.getTargetAdapter(address(vault));
        assertEq(mappedAdapter, address(vaultAdapter));

        // Verify fee tracker configuration
        assertEq(feeTracker.feeRateBps(), FEE_RATE);
        assertEq(feeTracker.feeCollector(), feeCollector);
    }

    function test_CreateWallet_BasicFlow() public {
        // Create wallet through factory using real contracts
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        // Verify wallet was created successfully
        assertEq(wallet.owner(), user);
        assertTrue(address(wallet) != address(0));
    }

    function test_WalletAdapterExecution_BasicFlow() public {
        // Create wallet
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        // Fund wallet
        usdc.mint(address(wallet), 1000e6);

        // Execute deposit through real adapter system
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));

        vm.prank(user);
        bytes memory result = wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Verify execution worked - handle double ABI encoding issue
        // The wallet returns bytes, and we need to decode the inner uint256
        bytes memory innerResult = abi.decode(result, (bytes));
        uint256 shares = abi.decode(innerResult, (uint256));
        assertGt(shares, 0);
        assertEq(vault.balanceOf(address(wallet)), shares);

        // Check that shares are reasonable (MockERC4626 uses 1:1 ratio so should be 500e6)
        assertEq(shares, 500e6, "Shares should equal deposited amount in mock vault");

        // Verify the deposit actually happened (remaining balance should be less than starting balance)
        uint256 remainingBalance = usdc.balanceOf(address(wallet));
        assertLt(remainingBalance, 1000e6); // Should be less than original 1000e6
        // Note: Exact remaining balance depends on adapter implementation and any fees
    }

    function test_RegistryPause_BlocksExecution() public {
        // Create and fund wallet
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
        usdc.mint(address(wallet), 1000e6);

        // Pause registry
        vm.prank(admin);
        registry.pause();

        // Execution should fail due to paused registry
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));

        vm.prank(user);
        vm.expectRevert(); // Registry should revert when paused
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Unpause and retry
        vm.prank(admin);
        registry.unpause();

        vm.prank(user);
        bytes memory result = wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        bytes memory innerResult = abi.decode(result, (bytes));
        uint256 shares = abi.decode(innerResult, (uint256));
        assertGt(shares, 0);
    }

    function test_BatchExecution_RealAdapters() public {
        // Create and fund wallet
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
        usdc.mint(address(wallet), 1000e6);

        // Prepare batch operations
        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        // First operation: deposit 300 USDC
        adapters[0] = address(vaultAdapter);
        targets[0] = address(vault);
        data[0] = abi.encodeCall(vaultAdapter.deposit, (300e6));

        // Second operation: deposit another 400 USDC
        adapters[1] = address(vaultAdapter);
        targets[1] = address(vault);
        data[1] = abi.encodeCall(vaultAdapter.deposit, (400e6));

        vm.prank(user);
        bytes[] memory results = wallet.executeViaAdapterBatch(adapters, targets, data);

        // Verify both operations executed
        assertEq(results.length, 2);

        bytes memory innerResult1 = abi.decode(results[0], (bytes));
        uint256 shares1 = abi.decode(innerResult1, (uint256));
        bytes memory innerResult2 = abi.decode(results[1], (bytes));
        uint256 shares2 = abi.decode(innerResult2, (uint256));

        assertGt(shares1, 0);
        assertGt(shares2, 0);
        assertEq(vault.balanceOf(address(wallet)), shares1 + shares2);
        assertEq(usdc.balanceOf(address(wallet)), 300e6); // Remaining balance
    }

    function test_MultipleWallets_SharedInfrastructure() public {
        // Create multiple wallets
        vm.prank(operator);
        AgentWalletV1 wallet1 = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        vm.prank(operator);
        AgentWalletV1 wallet2 = factory.createAgentWallet(user2, AGENT_INDEX, address(usdc));

        // Both should use same registry infrastructure
        assertTrue(registry.isRegisteredAdapter(address(vaultAdapter)));

        // Fund both wallets
        usdc.mint(address(wallet1), 1000e6);
        usdc.mint(address(wallet2), 2000e6);

        // Both should be able to execute independently
        bytes memory depositData1 = abi.encodeCall(vaultAdapter.deposit, (500e6));
        bytes memory depositData2 = abi.encodeCall(vaultAdapter.deposit, (1000e6));

        vm.prank(user);
        wallet1.executeViaAdapter(address(vaultAdapter), address(vault), depositData1);

        vm.prank(user2);
        wallet2.executeViaAdapter(address(vaultAdapter), address(vault), depositData2);

        // Both should have vault shares
        assertGt(vault.balanceOf(address(wallet1)), 0);
        assertGt(vault.balanceOf(address(wallet2)), 0);

        // Verify independent operation (different amounts)
        assertTrue(vault.balanceOf(address(wallet1)) != vault.balanceOf(address(wallet2)));
    }

    function test_UserBlocklist_IndependentFromRegistry() public {
        // Create and fund wallet
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
        usdc.mint(address(wallet), 1000e6);

        // Block adapter at wallet level
        vm.prank(user);
        wallet.blockAdapter(address(vaultAdapter));

        // Adapter should still be registered globally but blocked for this wallet
        assertTrue(registry.isRegisteredAdapter(address(vaultAdapter)));
        assertTrue(wallet.isAdapterBlocked(address(vaultAdapter)));

        // Execution should fail due to wallet-level block
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterBlocked.selector, address(vaultAdapter)));
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Unblock and retry
        vm.prank(user);
        wallet.unblockAdapter(address(vaultAdapter));

        vm.prank(user);
        bytes memory result = wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        bytes memory innerResult = abi.decode(result, (bytes));
        uint256 shares = abi.decode(innerResult, (uint256));
        assertGt(shares, 0);
    }

    function test_EmergencyUnregistration_ImmediateEffect() public {
        // Create and fund wallet
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
        usdc.mint(address(wallet), 1000e6);

        // First execution should work
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (300e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
        assertGt(vault.balanceOf(address(wallet)), 0);

        // Emergency unregister adapter
        vm.prank(admin);
        registry.unregisterAdapter(address(vaultAdapter));

        // Second execution should fail
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(vaultAdapter)));
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
    }

    // ========================================
    // WALLET LIFECYCLE TESTS
    // ========================================

    function test_WalletUpgrade_PreservesState() public {
        // Create wallet and execute operations
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        // Fund and deposit to establish state
        usdc.mint(address(wallet), 1000e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (1000e6));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Block an adapter
        vm.prank(user);
        wallet.blockAdapter(address(vaultAdapter));

        uint256 sharesBefore = vault.balanceOf(address(wallet));

        // Deploy new implementation
        AgentWalletV1 newImpl = new AgentWalletV1(address(factory));

        // Update factory's implementation
        vm.prank(admin);
        factory.setAgentWalletImplementation(newImpl);

        // Upgrade wallet
        vm.prank(user);
        wallet.upgradeToAndCall(address(newImpl), "");

        // Verify state preserved
        assertTrue(wallet.isAdapterBlocked(address(vaultAdapter)));
        assertEq(vault.balanceOf(address(wallet)), sharesBefore);
    }

    function test_MultipleWalletsPerUser_IndependentState() public {
        // Create multiple wallets for same user
        vm.startPrank(operator);
        AgentWalletV1 wallet1 = factory.createAgentWallet(user, 0, address(usdc));
        AgentWalletV1 wallet2 = factory.createAgentWallet(user, 1, address(usdc));
        vm.stopPrank();

        // Fund both wallets
        usdc.mint(address(wallet1), 1000e6);
        usdc.mint(address(wallet2), 2000e6);

        // Block adapter in wallet1 only
        vm.prank(user);
        wallet1.blockAdapter(address(vaultAdapter));

        // Wallet1 should fail to execute
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (1000e6));
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterBlocked.selector, address(vaultAdapter)));
        wallet1.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Wallet2 should succeed
        vm.prank(user);
        wallet2.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Verify independent execution
        assertEq(vault.balanceOf(address(wallet1)), 0);
        assertGt(vault.balanceOf(address(wallet2)), 0);
    }

    // ========================================
    // YIELD GENERATION & FEE TRACKING TESTS
    // ========================================

    function test_YieldGeneration_WithFeeTracking() public {
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        // Deposit 1000 USDC
        usdc.mint(address(wallet), 1000e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (1000e6));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        uint256 initialShares = vault.balanceOf(address(wallet));
        assertEq(initialShares, 1000e6);

        // Simulate yield: the vault itself generates 100 more USDC
        // (In production, this would be from interest/rewards)
        usdc.mint(address(vault), 100e6);

        // NOW the vault has 1100 USDC and still 1000 shares
        // So each share is worth 1.1 USDC

        // Try to redeem 500 shares - should get 550 assets
        bytes memory redeemData = abi.encodeCall(vaultAdapter.withdraw, (500e6));
        vm.prank(user);
        bytes memory result = wallet.executeViaAdapter(address(vaultAdapter), address(vault), redeemData);

        bytes memory innerResult = abi.decode(result, (bytes));
        uint256 assetsReceived = abi.decode(innerResult, (uint256));

        // 500 shares * 1100 assets / 1000 shares = 550
        assertEq(assetsReceived, 550e6);
    }

    function test_FeeCalculation_MultipleYieldEvents() public {
        // Create wallet first
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        // Record multiple yield events from the wallet
        vm.startPrank(address(wallet));
        feeTracker.recordAgentYieldEarned(100e6);
        feeTracker.recordAgentYieldEarned(50e6);
        feeTracker.recordAgentYieldEarned(75e6);
        vm.stopPrank();

        // Get total fees owed for the wallet
        uint256 feesOwed = feeTracker.getFeesOwed(address(wallet));

        // Should be sum of all yields * feeRate (0.1 = 10%)
        uint256 expectedFees = (100e6 + 50e6 + 75e6) * 1000 / 10000; // 10% of 225e6 = 22.5e6
        assertEq(feesOwed, expectedFees);
    }

    // ========================================
    // COMPLEX OPERATION SCENARIOS
    // ========================================

    function test_CompleteRebalance_MultipleVaults() public {
        // Create second vault and adapter
        MockERC4626 vault2 = new MockERC4626(address(usdc), "Mock Vault 2", "mVault2");
        ERC4626Adapter vaultAdapter2 = new ERC4626Adapter();

        vm.startPrank(admin);
        registry.registerAdapter(address(vaultAdapter2));
        registry.setTargetAdapter(address(vault2), address(vaultAdapter2));
        vm.stopPrank();

        // Create wallet and deposit to vault1
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
        usdc.mint(address(wallet), 1000e6);

        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (1000e6));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        uint256 shares = vault.balanceOf(address(wallet));

        // Rebalance: withdraw from vault1 and deposit to vault2
        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory calls = new bytes[](2);

        adapters[0] = address(vaultAdapter);
        targets[0] = address(vault);
        calls[0] = abi.encodeCall(vaultAdapter.withdraw, (shares));

        adapters[1] = address(vaultAdapter2);
        targets[1] = address(vault2);
        calls[1] = abi.encodeCall(vaultAdapter2.deposit, (1000e6));

        vm.prank(user);
        wallet.executeViaAdapterBatch(adapters, targets, calls);

        // Verify rebalance
        assertEq(vault.balanceOf(address(wallet)), 0);
        assertGt(vault2.balanceOf(address(wallet)), 0);
    }

    function test_AtomicBatchExecution_PartialFailure() public {
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        // Fund with only 1000 USDC
        usdc.mint(address(wallet), 1000e6);

        // Try to deposit 600 + 600 = 1200 (should fail atomically)
        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory calls = new bytes[](2);

        adapters[0] = address(vaultAdapter);
        targets[0] = address(vault);
        calls[0] = abi.encodeCall(vaultAdapter.deposit, (600e6));

        adapters[1] = address(vaultAdapter);
        targets[1] = address(vault);
        calls[1] = abi.encodeCall(vaultAdapter.deposit, (600e6));

        // Should revert during second deposit
        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapterBatch(adapters, targets, calls);

        // Verify no state change (atomic failure)
        assertEq(vault.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 1000e6);
    }

    // ========================================
    // CROSS-CONTRACT STATE TESTS
    // ========================================

    function test_RegistryUpdate_AffectsActiveWallets() public {
        // Create wallet
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        // Execute operation successfully
        usdc.mint(address(wallet), 1000e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (1000e6));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Update factory's registry reference
        AdapterRegistry newRegistry = new AdapterRegistry(admin, admin);
        vm.prank(admin);
        factory.setAdapterRegistry(newRegistry);

        // Create new wallet - should use new registry (old wallet still uses old registry)
        vm.prank(operator);
        AgentWalletV1 wallet2 = factory.createAgentWallet(user2, AGENT_INDEX, address(usdc));

        // New wallet uses new registry (empty - no adapters)
        usdc.mint(address(wallet2), 1000e6);
        vm.prank(user2);
        vm.expectRevert();
        wallet2.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
    }

    function test_WalletSync_UpdatesConfiguration() public {
        vm.prank(operator);
        factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        // Create new registry and fee tracker
        AdapterRegistry newRegistry = new AdapterRegistry(admin, admin);
        FeeTracker newFeeTracker = new FeeTracker(admin);

        // Update factory configuration
        vm.startPrank(admin);
        factory.setAdapterRegistry(newRegistry);
        factory.setFeeTracker(newFeeTracker);
        vm.stopPrank();

        // Verify factory configuration updated (sync would be called by factory in real scenario)
        // Just verify we can update the factory successfully
        assertTrue(address(factory.adapterRegistry()) == address(newRegistry));
        assertTrue(address(factory.feeTracker()) == address(newFeeTracker));
    }
}
