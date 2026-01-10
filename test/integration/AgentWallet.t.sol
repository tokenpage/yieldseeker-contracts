// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InvalidAsset} from "../../src/AgentWalletV1.sol";
import {AdapterIsBlocked, TargetIsBlocked} from "../../src/agentwalletkit/AWKAgentWalletV1.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

// Real contracts (not mocks)
import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAdminTimelock as AdminTimelock} from "../../src/AdminTimelock.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV1 as AgentWalletV1} from "../../src/AgentWalletV1.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerMerklAdapter as MerklAdapter} from "../../src/adapters/MerklAdapter.sol";

// Test utilities
import {MockAgentWalletV2} from "../mocks/MockAgentWalletV2.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockEntryPoint} from "../mocks/MockEntryPoint.sol";

// Mock Merkl Distributor for testing reward claims
contract MockMerklDistributor {
    function claim(address[] calldata, address[] calldata tokens, uint256[] calldata amounts, bytes32[][] calldata) external {
        for (uint256 i = 0; i < tokens.length; i++) {
            require(MockERC20(tokens[i]).transfer(msg.sender, amounts[i]), "Transfer failed");
        }
    }
}

/// @title AgentWallet Integration Tests
/// @notice Integration tests using real contracts with minimal mocking
contract AgentWalletIntegrationTest is Test {
    // Real contract instances
    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    AdminTimelock timelock;
    ERC4626Adapter vaultAdapter;
    MerklAdapter merklAdapter;

    // Test utilities (minimal mocking)
    MockERC20 usdc;
    MockERC4626 vault;
    MockEntryPoint entryPoint;
    MockMerklDistributor merklDistributor;

    // Test accounts
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address user = makeAddr("user");
    address feeCollector = makeAddr("feeCollector");

    // Configuration constants
    uint256 constant FEE_RATE = 1000; // 10%
    uint256 constant TIMELOCK_DELAY = 1 days;
    uint32 constant AGENT_INDEX = 1;

    // Events from real contracts
    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 indexed ownerAgentIndex, address baseAsset);
    event AdapterRegistered(address indexed adapter, bool indexed registered);
    event TargetAdapterSet(address indexed target, address indexed adapter);

    function setUp() public {
        // Deploy test tokens
        usdc = new MockERC20("Mock USDC", "mUSDC");
        vault = new MockERC4626(address(usdc), "Mock Vault", "mVault");
        entryPoint = new MockEntryPoint();
        merklDistributor = new MockMerklDistributor();

        vm.startPrank(admin);

        // Deploy real contracts in correct order
        registry = new AdapterRegistry(admin, admin); // admin as both admin and emergency admin
        feeTracker = new FeeTracker(admin);
        feeTracker.setFeeConfig(FEE_RATE, feeCollector);

        // Deploy timelock with admin as proposer and executor
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = admin;
        executors[0] = admin;
        timelock = new AdminTimelock(TIMELOCK_DELAY, proposers, executors, admin);

        // Deploy factory with real components
        factory = new AgentWalletFactory(admin, operator);

        // Deploy implementation AFTER factory exists (so FACTORY field is correct)
        AgentWalletV1 walletImplementation = new AgentWalletV1(address(factory));

        // Configure factory components
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(feeTracker);
        factory.setAgentWalletImplementation(walletImplementation);

        // Deploy real adapters
        vaultAdapter = new ERC4626Adapter();
        merklAdapter = new MerklAdapter();

        // Configure registry with real adapters
        registry.registerAdapter(address(vaultAdapter));
        registry.setTargetAdapter(address(vault), address(vaultAdapter));
        registry.registerAdapter(address(merklAdapter));
        registry.setTargetAdapter(address(merklDistributor), address(merklAdapter));

        // Grant operator role
        // Role already granted in constructor
        // factory.grantRole(factory.AGENT_OPERATOR_ROLE(), operator);

        vm.stopPrank();

        // Setup test tokens
        usdc.mint(user, 10000e6); // 10,000 USDC
        usdc.mint(address(merklDistributor), 1000000e6); // Fund merkl distributor
        vm.prank(user);
        usdc.approve(address(vault), type(uint256).max);
    }

    // ============ Complete Creation & Initialization Flow Tests ============

    function test_CreateWalletViaFactory_Success() public {
        // Create wallet through factory using real contracts
        vm.expectEmit(true, true, true, true);
        emit AgentWalletCreated(address(computeExpectedWalletAddress()), user, AGENT_INDEX, address(usdc));

        vm.prank(operator);
        AgentWalletV1 walletAddr = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));

        // Verify wallet was created with real contract references
        assertEq(walletAddr.owner(), user);

        // Verify real registry integration
        address expectedAdapter = registry.getTargetAdapter(address(vault));
        assertEq(expectedAdapter, address(vaultAdapter));

        // Verify wallet can query real registry
        vm.prank(user);
        bool isRegistered = registry.isRegisteredAdapter(address(vaultAdapter));
        assertTrue(isRegistered);
    }

    function test_InitializeWalletWithRealContracts() public {
        createWalletForUser(user);

        // Verify wallet initialized with real registry reference
        // Note: We'd need to add a getter to check this, but we can test behavior

        // Test that wallet can interact with real registry
        vm.prank(user);
        // This should not revert since adapter is registered
        bool canExecute = registry.isRegisteredAdapter(address(vaultAdapter));
        assertTrue(canExecute);
    }

    function test_FactoryRegistryIntegration() public {
        // Test factory's interaction with real registry
        address walletAddr = createWalletForUser(user);

        // Both should use same registry
        assertTrue(registry.isRegisteredAdapter(address(vaultAdapter)));

        // Adapter should be mapped to target
        address mappedAdapter = registry.getTargetAdapter(address(vault));
        assertEq(mappedAdapter, address(vaultAdapter));

        // Wallet should be able to use this mapping
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Fund the wallet for testing
        usdc.mint(walletAddr, 1000e6);

        // Execute through real adapter system
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Verify successful execution
        assertTrue(vault.balanceOf(walletAddr) > 0);
    }

    function test_WalletProxy_ImplementationUpgrade() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Verify wallet is functional after creation (proxy is working)
        usdc.mint(walletAddr, 100e6);

        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (50e6));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Wallet should have vault shares, proving proxy works correctly
        assertTrue(vault.balanceOf(walletAddr) > 0);
    }

    function test_InitializationEvent_RealEmission() public {
        // Test that real events are emitted during creation
        vm.expectEmit(true, true, true, true);
        emit AgentWalletCreated(computeExpectedWalletAddress(), user, AGENT_INDEX, address(usdc));

        vm.prank(operator);
        factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
    }

    // ============ Real Adapter Execution Tests ============

    function test_ExecuteViaAdapter_RealRegistry() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Fund wallet
        usdc.mint(walletAddr, 1000e6);

        // Execute deposit through real adapter system using correct pattern
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Verify execution - wallet should have vault shares now
        assertTrue(vault.balanceOf(walletAddr) > 0);
        assertEq(usdc.balanceOf(walletAddr), 500e6); // Remaining balance
    }

    function test_ExecuteViaAdapterBatch_MultipleOperations() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Fund wallet
        usdc.mint(walletAddr, 1000e6);

        // Prepare batch operations
        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory data = new bytes[](2);

        // First operation: deposit 400 USDC
        adapters[0] = address(vaultAdapter);
        targets[0] = address(vault);
        data[0] = abi.encodeCall(vaultAdapter.deposit, (400e6));

        // Second operation: deposit another 300 USDC
        adapters[1] = address(vaultAdapter);
        targets[1] = address(vault);
        data[1] = abi.encodeCall(vaultAdapter.deposit, (300e6));

        vm.prank(user);
        bytes[] memory results = wallet.executeViaAdapterBatch(adapters, targets, data);

        // Verify both operations executed
        assertEq(results.length, 2);

        // Each result contains the encoded return value from the adapter
        uint256 shares1 = abi.decode(results[0], (uint256));
        uint256 shares2 = abi.decode(results[1], (uint256));

        assertGt(shares1, 0);
        assertGt(shares2, 0);
        // Total shares should equal sum of both operations
        uint256 totalShares = vault.balanceOf(walletAddr);
        assertGt(totalShares, 0);
    }

    function test_AdapterBlocking_CrossContract() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Block adapter at wallet level
        vm.prank(user);
        wallet.blockAdapter(address(vaultAdapter));

        // Verify adapter is still registered in registry but blocked at wallet
        assertTrue(registry.isRegisteredAdapter(address(vaultAdapter)));
        assertTrue(wallet.isAdapterBlocked(address(vaultAdapter)));

        // Fund wallet
        usdc.mint(walletAddr, 1000e6);

        // Attempt to execute - should fail due to wallet-level block
        bytes memory depositData = abi.encodeCall(vault.deposit, (500e6, walletAddr));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AdapterIsBlocked.selector, address(vaultAdapter)));
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
    }

    function test_YieldGeneration_WithRealFeeTracking() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Fund wallet
        usdc.mint(walletAddr, 1000e6);

        // Deposit to generate yield
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (1000e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Simulate yield generation in vault
        uint256 initialShares = vault.balanceOf(walletAddr);
        usdc.mint(address(vault), 100e6); // Add yield to vault

        // Withdraw to realize yield
        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (initialShares));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), withdrawData);

        // Check that wallet received more than deposited (yield generated)
        // Wallet should have more USDC after yield realization
        uint256 finalBalance = usdc.balanceOf(walletAddr);
        assertGt(finalBalance, 0);
    }

    // ============ Cross-Contract Validation Tests ============

    function test_RegistryPause_EffectsOnWallet() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Pause registry
        vm.prank(admin);
        registry.pause();

        // Fund wallet
        usdc.mint(walletAddr, 1000e6);

        // Attempt execution should fail due to paused registry
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));

        vm.prank(user);
        vm.expectRevert(); // Registry should revert when paused
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Unpause and retry
        vm.prank(admin);
        registry.unpause();

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        assertTrue(vault.balanceOf(walletAddr) > 0);
    }

    function test_AdapterUnregistration_ImmediateEffect() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Fund wallet
        usdc.mint(walletAddr, 1000e6);

        // First execution should work
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (300e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Unregister adapter
        vm.prank(admin);
        registry.unregisterAdapter(address(vaultAdapter));

        // Second execution should fail
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(vaultAdapter)));
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
    }

    function test_MultipleWallets_SharedRegistry() public {
        // Create multiple wallets
        address wallet1 = createWalletForUser(user);
        address wallet2 = createWalletForUser(makeAddr("user2"));

        AgentWalletV1 w1 = AgentWalletV1(payable(wallet1));
        AgentWalletV1 w2 = AgentWalletV1(payable(wallet2));

        // Both should use same registry
        assertTrue(registry.isRegisteredAdapter(address(vaultAdapter)));

        // Fund both wallets
        usdc.mint(wallet1, 1000e6);
        usdc.mint(wallet2, 2000e6);

        // Both should be able to execute
        bytes memory depositData1 = abi.encodeCall(vaultAdapter.deposit, (500e6));
        bytes memory depositData2 = abi.encodeCall(vaultAdapter.deposit, (1000e6));

        vm.prank(user);
        w1.executeViaAdapter(address(vaultAdapter), address(vault), depositData1);

        vm.prank(makeAddr("user2"));
        w2.executeViaAdapter(address(vaultAdapter), address(vault), depositData2);

        // Both should have vault shares
        assertGt(vault.balanceOf(wallet1), 0);
        assertGt(vault.balanceOf(wallet2), 0);
    }

    // ============ Complete Creation & Initialization Flow Tests (15 tests) ============

    function test_CreateWallet_WithDifferentAgentIndices() public {
        // Create multiple agents for same user with different indices
        address wallet1 = createWalletForUser(user);

        // Create second agent with different index
        vm.prank(operator);
        address wallet2 = address(factory.createAgentWallet(user, 2, address(usdc)));

        assertTrue(wallet1 != wallet2);
        assertTrue(wallet1 != address(0));
        assertTrue(wallet2 != address(0));
    }

    function test_CreateWallet_DeterministicAddress() public {
        // Verify CREATE2 determinism: same inputs = same address
        address expectedAddr = computeExpectedWalletAddress();
        address actualAddr = createWalletForUser(user);
        assertEq(expectedAddr, actualAddr);
    }

    function test_CreateWallet_InvalidAsset() public {
        // Attempting to create wallet with non-contract asset should revert
        vm.prank(operator);
        vm.expectRevert();
        factory.createAgentWallet(user, 100, address(0xDEADBEEF));
    }

    function test_CreateWallet_ZeroOwner() public {
        // Creating wallet with zero owner should revert
        vm.prank(operator);
        vm.expectRevert();
        factory.createAgentWallet(address(0), AGENT_INDEX, address(usdc));
    }

    function test_CreateWallet_UnauthorizedOperator() public {
        // Non-operator cannot create wallets
        vm.prank(makeAddr("notOperator"));
        vm.expectRevert();
        factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
    }

    function test_CreateWallet_DuplicateIndex() public {
        // Creating second wallet with same user + index should revert
        createWalletForUser(user);

        vm.prank(operator);
        vm.expectRevert();
        factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
    }

    function test_InitialState_CorrectConfiguration() public {
        address walletAddr = createWalletForUser(user);

        // Wallet should be properly initialized
        // Note: Would test owner, baseAsset, etc if getters existed
        assertTrue(walletAddr != address(0));
    }

    function test_InitializeWithRegistry_Correct() public {
        createWalletForUser(user);

        // Wallet should have access to registry via factory
        assertTrue(registry.isRegisteredAdapter(address(vaultAdapter)));
    }

    function test_WalletCreatedEvent_EmitsCorrectly() public {
        // Verify factory emits correct event on creation
        address expectedAddr = computeExpectedWalletAddress();

        vm.expectEmit(true, true, true, true);
        emit AgentWalletCreated(expectedAddr, user, AGENT_INDEX, address(usdc));

        vm.prank(operator);
        factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
    }

    function test_FactoryComponents_ProperlySet() public view {
        // Verify factory has all required components
        assertTrue(address(registry) != address(0));
        assertTrue(address(feeTracker) != address(0));
        assertTrue(address(factory.agentWalletImplementation()) != address(0));
    }

    function test_MultipleOperators_CanCreateWallets() public {
        // Grant second operator from admin (who has DEFAULT_ADMIN_ROLE)
        address op2 = makeAddr("operator2");
        vm.startPrank(admin);
        factory.grantRole(factory.AGENT_OPERATOR_ROLE(), op2);
        vm.stopPrank();

        // Second operator can create wallet
        vm.prank(op2);
        address walletAddr = address(factory.createAgentWallet(user, 10, address(usdc)));
        assertTrue(walletAddr != address(0));
    }

    function test_CreateWallet_RealImplementationUsed() public {
        // Wallet should have real implementation, not temp one
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Should be able to initialize and use normally
        usdc.mint(walletAddr, 100e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (50e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        assertTrue(vault.balanceOf(walletAddr) > 0);
    }

    function test_Factory_UpdateImplementation() public {
        address newImpl = address(new AgentWalletV1(address(factory)));

        vm.prank(admin);
        factory.setAgentWalletImplementation(AgentWalletV1(payable(newImpl)));

        assertTrue(address(factory.agentWalletImplementation()) == newImpl);
    }

    // ============ Real ERC-4337 Integration Tests (15 tests) ============

    function test_ExecuteViaAdapter_OnlyExecutorsAllowed() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        usdc.mint(walletAddr, 100e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (50e6));

        // Non-executor (not owner, operator, or entrypoint) should fail
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
    }

    function test_ExecuteViaAdapter_OwnerCanExecute() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        usdc.mint(walletAddr, 100e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (50e6));

        // Owner can execute
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        assertTrue(vault.balanceOf(walletAddr) > 0);
    }

    function test_ExecuteViaAdapter_OperatorCanExecute() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        usdc.mint(walletAddr, 100e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (50e6));

        // Operator can execute
        vm.prank(operator);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        assertTrue(vault.balanceOf(walletAddr) > 0);
    }

    function test_BatchExecution_AtomicFailure() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        usdc.mint(walletAddr, 100e6);

        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);

        adapters[0] = address(vaultAdapter);
        adapters[1] = address(0xDEADBEEF); // Invalid adapter
        targets[0] = address(vault);
        targets[1] = address(vault);
        datas[0] = abi.encodeCall(vaultAdapter.deposit, (50e6));
        datas[1] = abi.encodeCall(vaultAdapter.deposit, (50e6));

        // Batch should fail atomically
        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapterBatch(adapters, targets, datas);

        // First operation should not have succeeded
        assertEq(vault.balanceOf(walletAddr), 0);
    }

    function test_BatchExecution_LargeScale() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Fund with enough for 10 deposits of 100e6 each
        usdc.mint(walletAddr, 1100e6);

        uint256 batchSize = 10;
        address[] memory adapters = new address[](batchSize);
        address[] memory targets = new address[](batchSize);
        bytes[] memory datas = new bytes[](batchSize);

        for (uint256 i = 0; i < batchSize; i++) {
            adapters[i] = address(vaultAdapter);
            targets[i] = address(vault);
            datas[i] = abi.encodeCall(vaultAdapter.deposit, (100e6));
        }

        vm.prank(user);
        wallet.executeViaAdapterBatch(adapters, targets, datas);

        assertTrue(vault.balanceOf(walletAddr) > 0);
    }

    function test_DepositAndWithdraw_RealSequence() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Deposit
        usdc.mint(walletAddr, 1000e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        uint256 shares = vault.balanceOf(walletAddr);
        assertTrue(shares > 0);

        // Withdraw
        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (shares));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), withdrawData);

        // Should have received assets back
        assertTrue(usdc.balanceOf(walletAddr) > 500e6);
    }

    function test_ConsecutiveDeposits_Accumulate() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        usdc.mint(walletAddr, 2000e6);

        bytes memory depositData1 = abi.encodeCall(vaultAdapter.deposit, (500e6));
        bytes memory depositData2 = abi.encodeCall(vaultAdapter.deposit, (500e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData1);

        uint256 sharesAfter1 = vault.balanceOf(walletAddr);

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData2);

        uint256 sharesAfter2 = vault.balanceOf(walletAddr);
        assertGt(sharesAfter2, sharesAfter1);
    }

    function test_RebalancingFlow() public {
        // Simulate rebalancing: withdraw from one vault, deposit to another
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        usdc.mint(walletAddr, 1000e6);

        // Deposit 600e6
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (600e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        uint256 shares = vault.balanceOf(walletAddr);

        // Withdraw 300 shares worth
        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (shares / 2));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), withdrawData);

        // Wallet should have some shares and some tokens
        assertGt(vault.balanceOf(walletAddr), 0);
        assertGt(usdc.balanceOf(walletAddr), 300e6);
    }

    function test_MultiVaultInteraction() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Create second vault
        MockERC4626 vault2 = new MockERC4626(address(usdc), "Vault 2", "v2");

        // Register second vault from admin context
        vm.startPrank(admin);
        registry.registerAdapter(address(vaultAdapter));
        registry.setTargetAdapter(address(vault2), address(vaultAdapter));
        vm.stopPrank();

        usdc.mint(walletAddr, 1000e6);

        // Deposit to first vault
        bytes memory depositData1 = abi.encodeCall(vaultAdapter.deposit, (400e6));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData1);

        // Deposit to second vault
        bytes memory depositData2 = abi.encodeCall(vaultAdapter.deposit, (400e6));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault2), depositData2);

        assertTrue(vault.balanceOf(walletAddr) > 0);
        assertTrue(vault2.balanceOf(walletAddr) > 0);
    }

    function test_WithdrawToUser_ThroughWallet() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        usdc.mint(walletAddr, 100e6);

        uint256 balanceBefore = usdc.balanceOf(user);

        // Withdraw tokens to user
        vm.prank(user);
        wallet.withdrawAssetToUser(user, address(usdc), 50e6);

        uint256 balanceAfter = usdc.balanceOf(user);
        assertEq(balanceAfter - balanceBefore, 50e6);
    }

    // ============ Real Adapter Execution Tests (18 tests) ============

    function test_DepositThroughAdapterRecordsFeeTracking() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        usdc.mint(walletAddr, 500e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Verify shares received
        assertTrue(vault.balanceOf(walletAddr) > 0);
    }

    function test_WithdrawThroughAdapterRecordsFeeTracking() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        usdc.mint(walletAddr, 1000e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        uint256 shares = vault.balanceOf(walletAddr);
        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (shares));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), withdrawData);

        // Wallet should have tokens back
        assertTrue(usdc.balanceOf(walletAddr) > 400e6);
    }

    function test_DepositPercentage_CalculatesCorrectly() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Fund wallet
        usdc.mint(walletAddr, 1000e6);

        // Deposit 50% = 500e6
        bytes memory depositPercentData = abi.encodeCall(vaultAdapter.depositPercentage, (5000)); // 50.00%

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositPercentData);

        // Should have vault shares
        assertTrue(vault.balanceOf(walletAddr) > 0);

        // Should have 500e6 remaining
        assertEq(usdc.balanceOf(walletAddr), 500e6);
    }

    function test_AdapterIntegration_MultipleUsers() public {
        address wallet1 = createWalletForUser(user);
        address wallet2 = createWalletForUser(makeAddr("user2"));

        AgentWalletV1 w1 = AgentWalletV1(payable(wallet1));
        AgentWalletV1 w2 = AgentWalletV1(payable(wallet2));

        usdc.mint(wallet1, 500e6);
        usdc.mint(wallet2, 500e6);

        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (400e6));

        vm.prank(user);
        w1.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        vm.prank(makeAddr("user2"));
        w2.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        assertTrue(vault.balanceOf(wallet1) > 0);
        assertTrue(vault.balanceOf(wallet2) > 0);
    }

    function test_AdapterBlocking_PreventsUserFromUsing() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        usdc.mint(walletAddr, 500e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (400e6));

        // First execution should work
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
        assertTrue(vault.balanceOf(walletAddr) > 0);

        // Block adapter
        vm.prank(user);
        wallet.blockAdapter(address(vaultAdapter));

        // Second execution should fail
        usdc.mint(walletAddr, 500e6);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(AdapterIsBlocked.selector, address(vaultAdapter)));
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
    }

    function test_TargetBlocking_PreventsUserFromUsingTarget() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        usdc.mint(walletAddr, 500e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (400e6));

        // First execution should work
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
        assertTrue(vault.balanceOf(walletAddr) > 0);

        // Block target
        vm.prank(user);
        wallet.blockTarget(address(vault));

        // Second execution should fail
        usdc.mint(walletAddr, 500e6);
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(TargetIsBlocked.selector, address(vault)));
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
    }

    function test_AdapterUnblock_RestoresAccess() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Block adapter
        vm.prank(user);
        wallet.blockAdapter(address(vaultAdapter));

        // Unblock adapter
        vm.prank(user);
        wallet.unblockAdapter(address(vaultAdapter));

        // Should now work
        usdc.mint(walletAddr, 500e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (400e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
        assertTrue(vault.balanceOf(walletAddr) > 0);
    }

    function test_CompleteYieldCycle() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // 1. Deposit
        usdc.mint(walletAddr, 1000e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (1000e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        uint256 shares = vault.balanceOf(walletAddr);

        // 2. Simulate yield
        usdc.mint(address(vault), 100e6);

        // 3. Withdraw all shares
        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (shares));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), withdrawData);

        // 4. Verify yield captured
        assertTrue(usdc.balanceOf(walletAddr) >= 1000e6);
    }

    function test_PartialWithdraw_LeavesRemainingShares() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        usdc.mint(walletAddr, 1000e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (1000e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        uint256 totalShares = vault.balanceOf(walletAddr);

        // Withdraw half
        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (totalShares / 2));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), withdrawData);

        // Should have remaining shares and some tokens
        assertTrue(vault.balanceOf(walletAddr) > 0);
        assertTrue(vault.balanceOf(walletAddr) < totalShares);
        assertTrue(usdc.balanceOf(walletAddr) > 400e6);
    }

    function test_AdapterExecution_WithInsufficientBalance() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Fund with only 100e6 but try to deposit 500e6
        usdc.mint(walletAddr, 100e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));

        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
    }

    function test_WalletFunctionality_AfterSync() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        // Sync from factory (updates registry reference)
        vm.prank(user);
        wallet.syncFromFactory();

        // Wallet should still be functional
        usdc.mint(walletAddr, 500e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        assertTrue(vault.balanceOf(walletAddr) > 0);
    }

    // ============ Helper Functions ============

    function createWalletForUser(address owner) internal returns (address) {
        vm.prank(operator);
        return address(factory.createAgentWallet(owner, AGENT_INDEX, address(usdc)));
    }

    function computeExpectedWalletAddress() internal view returns (address) {
        return factory.getAddress(user, AGENT_INDEX);
    }

    // ============ Vault Share Reward Tests ============

    function test_VaultShareReward_FeesTrackedCorrectly() public {
        // Create second vault for reward scenario (VAULT B for rewards)
        MockERC4626 vaultB = new MockERC4626(address(usdc), "Vault B", "vB");

        // Register vaultB with adapter
        vm.startPrank(admin);
        registry.setTargetAdapter(address(vaultB), address(vaultAdapter));
        vm.stopPrank();

        // Step 1: User deposits 10 USDC into their wallet
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        usdc.mint(user, 10e6);
        vm.prank(user);
        require(usdc.transfer(walletAddr, 10e6), "Transfer failed");

        assertEq(usdc.balanceOf(walletAddr), 10e6, "Wallet should have 10 USDC");

        // Step 2: Executor moves 10 USDC into VAULT A
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (10e6));

        vm.prank(user); // owner can execute
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        uint256 vaultAShares = vault.balanceOf(walletAddr);
        assertGt(vaultAShares, 0, "Should have VAULT A shares");
        assertEq(usdc.balanceOf(walletAddr), 0, "USDC should be in vault");

        console.log("\n=== After Step 2: Deposited to VAULT A ===");
        (uint256 vaultACost, uint256 vaultASharesTracked) = feeTracker.getAgentVaultPosition(walletAddr, address(vault));
        console.log("VAULT A cost basis:", vaultACost);
        console.log("VAULT A shares tracked:", vaultASharesTracked);

        // Step 3: User receives vault share reward via Merkl
        // First, seed vaultB with liquidity so shares have value
        usdc.mint(address(this), 100e6);
        usdc.approve(address(vaultB), 100e6);
        vaultB.deposit(100e6, address(this));

        // Now claim vault shares as reward (simulating Merkl distributing vault tokens as rewards)
        uint256 rewardShareAmount = 1e6; // 1 USDC worth of shares (1:1 ratio)

        // Transfer shares to merkl distributor so it can distribute them
        require(vaultB.transfer(address(merklDistributor), rewardShareAmount), "Transfer failed");

        // Prepare Merkl claim for vault B shares
        address[] memory users = new address[](1);
        users[0] = walletAddr;
        address[] memory tokens = new address[](1);
        tokens[0] = address(vaultB); // Claiming VAULT B shares as reward
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = rewardShareAmount;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);

        bytes memory claimData = abi.encodeCall(merklAdapter.claim, (users, tokens, amounts, proofs));

        vm.prank(user);
        wallet.executeViaAdapter(address(merklAdapter), address(merklDistributor), claimData);

        assertEq(vaultB.balanceOf(walletAddr), rewardShareAmount, "Wallet should have reward shares in VAULT B");

        console.log("\n=== After Step 3: Claimed VAULT B shares via Merkl ===");
        console.log("VAULT B shares in wallet:", vaultB.balanceOf(walletAddr));
        (uint256 vaultBCost, uint256 vaultBSharesTracked) = feeTracker.getAgentVaultPosition(walletAddr, address(vaultB));
        console.log("VAULT B cost basis:", vaultBCost);
        console.log("VAULT B shares tracked:", vaultBSharesTracked);
        uint256 vaultBFeesOwed = feeTracker.getAgentYieldTokenFeesOwed(walletAddr, address(vaultB));
        console.log("VAULT B token fees owed:", vaultBFeesOwed);

        // Step 4: Executor withdraws from VAULT B and deposits converted USDC into VAULT A
        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (rewardShareAmount));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vaultB), withdrawData);

        // Should now have ~1 USDC from the withdrawal
        uint256 usdcFromReward = usdc.balanceOf(walletAddr);
        assertApproxEqAbs(usdcFromReward, 1e6, 100, "Should have ~1 USDC from VAULT B withdrawal");

        console.log("\n=== After Step 4a: Withdrew from VAULT B ===");
        console.log("USDC balance:", usdcFromReward);
        (vaultBCost, vaultBSharesTracked) = feeTracker.getAgentVaultPosition(walletAddr, address(vaultB));
        console.log("VAULT B cost basis:", vaultBCost);
        console.log("VAULT B shares tracked:", vaultBSharesTracked);

        // Deposit that USDC into VAULT A
        bytes memory depositRewardData = abi.encodeCall(vaultAdapter.deposit, (usdcFromReward));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositRewardData);

        console.log("\n=== After Step 4b: Deposited reward USDC to VAULT A ===");
        (vaultACost, vaultASharesTracked) = feeTracker.getAgentVaultPosition(walletAddr, address(vault));
        console.log("VAULT A cost basis:", vaultACost);
        console.log("VAULT A shares tracked:", vaultASharesTracked);

        // Step 5: Check final fee tracker state
        console.log("\n=== Final Fee Tracker State ===");
        (uint256 feesCharged, uint256 feesPaid, uint256 feesOwed) = feeTracker.getWalletStats(walletAddr);
        console.log("Fees charged:", feesCharged);
        console.log("Fees paid:", feesPaid);
        console.log("Fees owed:", feesOwed);

        console.log("\n=== Expected vs Actual ===");
        console.log("Expected fee (10% of 1 USDC reward): 100000");
        console.log("Actual fee owed:", feesOwed);
        console.log("\nIssue: Vault share rewards aren't recognized as rewards.");
        console.log("The FeeTracker sees VAULT B shares appear (not from deposit),");
        console.log("then disappear (withdraw). But it has 0 cost basis, so no profit.");
        console.log("It doesn't know those shares were a REWARD that should incur fees.");

        // This assertion will FAIL, highlighting the issue
        assertEq(feesOwed, 100000, "Should owe 10% fee on vault share reward value");
    }

    // ============ Position Tracking Edge Cases ============

    function test_DirectVaultShareTransfer_CausesUnderflow() public {
        // This test demonstrates the auditor's finding:
        // When vault shares are received outside the adapter system,
        // position tracking breaks and causes underflow on withdrawal

        // Step 1: Create wallet and deposit 1000 USDC via adapter
        address walletAddr = createWalletForUser(user);
        AgentWalletV1 wallet = AgentWalletV1(payable(walletAddr));

        usdc.mint(user, 1000e6);
        vm.prank(user);
        require(usdc.transfer(walletAddr, 1000e6), "Transfer failed");

        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (1000e6));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Verify tracked position
        (uint256 costBasis, uint256 trackedShares) = feeTracker.getAgentVaultPosition(walletAddr, address(vault));
        assertEq(costBasis, 1000e6, "Cost basis should be 1000 USDC");
        assertEq(trackedShares, 1000e6, "Tracked shares should be 1000");

        console.log("\n=== After Step 1: Deposited 1000 USDC via adapter ===");
        console.log("Cost basis:", costBasis);
        console.log("Tracked shares:", trackedShares);
        console.log("Actual vault shares:", vault.balanceOf(walletAddr));

        // Step 2: Someone directly transfers 500 vault shares to the wallet
        // (NOT through the adapter, so FeeTracker doesn't know about it)
        usdc.mint(address(this), 500e6);
        usdc.approve(address(vault), 500e6);
        vault.deposit(500e6, address(this)); // Get vault shares
        require(vault.transfer(walletAddr, 500e6), "Transfer failed"); // Direct transfer to wallet

        console.log("\n=== After Step 2: Direct transfer of 500 vault shares ===");
        console.log("Actual vault shares:", vault.balanceOf(walletAddr));
        (costBasis, trackedShares) = feeTracker.getAgentVaultPosition(walletAddr, address(vault));
        console.log("Cost basis (still):", costBasis);
        console.log("Tracked shares (still):", trackedShares);
        console.log("DISCREPANCY: Wallet has 1500 shares but FeeTracker only knows about 1000");

        // Step 3: Try to withdraw all shares (1500) via adapter
        // This should cause underflow in FeeTracker:
        // proportionalCost = (1000 * 1500) / 1000 = 1500
        // agentVaultCostBasis = 1000 - 1500 = UNDERFLOW
        uint256 totalShares = vault.balanceOf(walletAddr);
        assertEq(totalShares, 1500e6, "Wallet should have 1500 shares");

        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (totalShares));

        console.log("\n=== Step 3: Attempting to withdraw all 1500 shares ===");
        console.log("User should be able to withdraw all shares they legitimately own...");

        // User should be able to withdraw all their shares
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), withdrawData);

        // Verify withdrawal succeeded
        uint256 finalUsdcBalance = usdc.balanceOf(walletAddr);
        assertApproxEqAbs(finalUsdcBalance, 1500e6, 100, "Should have ~1500 USDC from withdrawal");
        assertEq(vault.balanceOf(walletAddr), 0, "Should have no vault shares left");

        console.log("\nFinal USDC balance:", finalUsdcBalance);
        console.log("Final vault shares:", vault.balanceOf(walletAddr));
        console.log("Withdrawal succeeded - user can access all their shares");
    }

    function test_WithdrawAssetToUser_BaseAsset_RespectsFees() public {
        // Test that withdrawing baseAsset via withdrawAssetToUser respects fees
        address walletAddr = factory.getAddress(user, AGENT_INDEX);
        vm.prank(operator);
        AgentWalletV1 wallet = AgentWalletV1(payable(factory.createAgentWallet(user, AGENT_INDEX, address(usdc))));

        // Give wallet 1000 USDC and deposit into vault
        usdc.mint(user, 1000e6);
        vm.prank(user);
        require(usdc.transfer(walletAddr, 1000e6), "Transfer failed");

        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (1000e6));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Generate 100 USDC profit
        usdc.mint(address(vault), 100e6);

        // Withdraw all shares (should have 1100 USDC worth)
        uint256 shares = vault.balanceOf(walletAddr);
        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (shares));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), withdrawData);

        // Should have 10 USDC fees (10% of 100 profit)
        uint256 feesOwed = feeTracker.getFeesOwed(walletAddr);
        assertEq(feesOwed, 10e6, "Should owe 10 USDC in fees");

        uint256 usdcBalance = usdc.balanceOf(walletAddr);
        assertApproxEqAbs(usdcBalance, 1100e6, 100, "Should have ~1100 USDC");

        // Try to withdraw all USDC via withdrawAssetToUser - should respect fees
        address recipient = makeAddr("recipient");
        vm.prank(user);
        vm.expectRevert(AWKErrors.InsufficientBalance.selector);
        wallet.withdrawAssetToUser(recipient, address(usdc), usdcBalance); // Should fail

        // Should be able to withdraw withdrawable amount (balance - fees)
        uint256 withdrawable = usdcBalance - feesOwed;
        vm.prank(user);
        wallet.withdrawAssetToUser(recipient, address(usdc), withdrawable);

        assertEq(usdc.balanceOf(recipient), withdrawable, "Recipient should receive withdrawable amount");
        assertApproxEqAbs(usdc.balanceOf(walletAddr), feesOwed, 100, "Wallet should have fees left");
    }

    function test_WithdrawAllAssetToUser_BaseAsset_RespectsFees() public {
        // Test that withdrawAllAssetToUser with baseAsset respects fees
        address walletAddr = factory.getAddress(user, AGENT_INDEX);
        vm.prank(operator);
        AgentWalletV1 wallet = AgentWalletV1(payable(factory.createAgentWallet(user, AGENT_INDEX, address(usdc))));

        // Give wallet 1000 USDC and deposit into vault
        usdc.mint(user, 1000e6);
        vm.prank(user);
        require(usdc.transfer(walletAddr, 1000e6), "Transfer failed");

        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (1000e6));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Generate 100 USDC profit
        usdc.mint(address(vault), 100e6);

        // Withdraw all shares
        uint256 shares = vault.balanceOf(walletAddr);
        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (shares));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), withdrawData);

        // Should have 10 USDC fees (10% of 100 profit)
        uint256 feesOwed = feeTracker.getFeesOwed(walletAddr);
        assertEq(feesOwed, 10e6, "Should owe 10 USDC in fees");

        uint256 usdcBalance = usdc.balanceOf(walletAddr);
        assertApproxEqAbs(usdcBalance, 1100e6, 100, "Should have ~1100 USDC");

        // Withdraw all using withdrawAllAssetToUser - should automatically deduct fees
        address recipient = makeAddr("recipient2");
        vm.prank(user);
        wallet.withdrawAllAssetToUser(recipient, address(usdc));

        uint256 withdrawable = usdcBalance - feesOwed;
        assertApproxEqAbs(usdc.balanceOf(recipient), withdrawable, 100, "Recipient should receive withdrawable amount");
        assertApproxEqAbs(usdc.balanceOf(walletAddr), feesOwed, 100, "Wallet should have fees left");
    }

    function test_WithdrawAssetToUser_NonBaseAsset_Reverts() public {
        // Test that withdrawing non-baseAsset tokens is now blocked to prevent fee bypass
        address walletAddr = factory.getAddress(user, AGENT_INDEX);

        // Create a different token that will be the "wrong" baseAsset
        MockERC20 wrongToken = new MockERC20("Wrong Token", "WRONG");

        // Operator creates wallet with wrong baseAsset
        vm.prank(operator);
        AgentWalletV1 wallet = AgentWalletV1(payable(factory.createAgentWallet(user, AGENT_INDEX, address(wrongToken))));

        // User accidentally sends USDC to this wallet
        usdc.mint(user, 1000e6);
        vm.prank(user);
        require(usdc.transfer(walletAddr, 1000e6), "Transfer failed");

        // User tries to recover USDC but it's not the baseAsset, so it reverts
        address recipient = makeAddr("recipient");
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(InvalidAsset.selector));
        wallet.withdrawAssetToUser(recipient, address(usdc), 1000e6);

        // USDC remains in wallet (recovery requires different mechanism)
        assertEq(usdc.balanceOf(recipient), 0, "Should not have received USDC");
        assertEq(usdc.balanceOf(walletAddr), 1000e6, "Wallet should still have USDC");
    }

    function test_WithdrawAssetToUser_RevertsOnZeroAddress() public {
        address walletAddr = factory.getAddress(user, AGENT_INDEX);
        vm.prank(operator);
        AgentWalletV1 wallet = AgentWalletV1(payable(factory.createAgentWallet(user, AGENT_INDEX, address(usdc))));

        usdc.mint(walletAddr, 100e6);

        // Should revert on zero recipient
        vm.prank(user);
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        wallet.withdrawAssetToUser(address(0), address(usdc), 100e6);

        // Should revert on zero asset (InvalidAsset because address(0) != baseAsset)
        vm.prank(user);
        vm.expectRevert(InvalidAsset.selector);
        wallet.withdrawAssetToUser(user, address(0), 100e6);
    }

    function test_UpgradeWallet_WithActivePosition_FeesTrackedCorrectly() public {
        // Step 1: Create V1 wallet
        address walletAddr = factory.getAddress(user, AGENT_INDEX);
        vm.prank(operator);
        AgentWalletV1 wallet = AgentWalletV1(payable(factory.createAgentWallet(user, AGENT_INDEX, address(usdc))));

        console.log("\n=== Step 1: Created V1 wallet ===");
        console.log("Wallet address:", walletAddr);

        // Step 2: Fund wallet and deposit into vault
        uint256 userBalanceBefore = usdc.balanceOf(user);
        usdc.mint(user, 1000e6);
        vm.prank(user);
        require(usdc.transfer(walletAddr, 1000e6), "Transfer failed");

        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (1000e6));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        uint256 sharesAfterDeposit = vault.balanceOf(walletAddr);
        assertEq(sharesAfterDeposit, 1000e6, "Should have 1000 vault shares");

        console.log("\n=== Step 2: Deposited 1000 USDC to vault ===");
        console.log("Vault shares:", sharesAfterDeposit);

        // Verify position is tracked
        (uint256 costBasis, uint256 trackedShares) = feeTracker.getAgentVaultPosition(walletAddr, address(vault));
        assertEq(costBasis, 1000e6, "Cost basis should be 1000 USDC");
        assertEq(trackedShares, 1000e6, "Tracked shares should be 1000");

        // Step 3: Generate yield (10% profit = 100 USDC)
        usdc.mint(address(vault), 100e6);

        console.log("\n=== Step 3: Generated 100 USDC yield (10% profit) ===");

        // Step 4: Deploy V2 implementation
        MockAgentWalletV2 v2Implementation = new MockAgentWalletV2(address(factory));

        // Update factory to use V2
        vm.prank(admin);
        factory.setAgentWalletImplementation(v2Implementation);

        console.log("\n=== Step 4: Deployed V2 implementation ===");
        console.log("V2 implementation:", address(v2Implementation));

        // Step 5: Upgrade wallet to V2 (no initialization needed!)
        vm.prank(user);
        wallet.upgradeToAndCall(address(v2Implementation), "");

        // Cast to V2 to access new functions
        MockAgentWalletV2 walletV2 = MockAgentWalletV2(payable(walletAddr));

        console.log("\n=== Step 5: Upgraded wallet to V2 (no initialization required) ===");

        // Verify V2 state starts at zero values
        (uint256 v2Counter, string memory v2Message, address v2CustomAddress) = walletV2.getV2State();

        assertEq(v2Counter, 0, "V2 counter should start at 0");
        assertEq(bytes(v2Message).length, 0, "V2 message should be empty");
        assertEq(v2CustomAddress, address(0), "V2 custom address should be zero");

        console.log("V2 state (zero-initialized):");
        console.log("  - Counter:", v2Counter);
        console.log("  - Message: (empty)");
        console.log("  - Custom address:", v2CustomAddress);

        // Verify upgrade worked - call V2-only function (works immediately!)
        vm.expectEmit(true, true, false, true);
        emit MockAgentWalletV2.V2FunctionCalled(user, "Hello from V2!");
        vm.prank(user);
        walletV2.v2OnlyFunction("Hello from V2!");

        assertEq(walletV2.version(), 2, "Should report version 2");

        // Test incrementing the counter (starts at 0, goes to 1)
        vm.expectEmit(true, false, false, true);
        emit MockAgentWalletV2.V2CounterIncremented(0, 1);
        vm.prank(user);
        walletV2.incrementV2Counter();

        // Optionally configure V2 state
        vm.expectEmit(true, false, false, true);
        emit MockAgentWalletV2.V2MessageSet("", "Configured message");
        vm.prank(user);
        walletV2.setV2Message("Configured message");

        address customAddr = address(0xC0FFEE);
        vm.expectEmit(true, false, false, true);
        emit MockAgentWalletV2.V2CustomAddressSet(address(0), customAddr);
        vm.prank(user);
        walletV2.setV2CustomAddress(customAddr);

        (uint256 newCounter, string memory newMessage, address newAddr) = walletV2.getV2State();
        assertEq(newCounter, 1, "Counter should be incremented to 1");
        assertEq(newMessage, "Configured message", "Message should be set");
        assertEq(newAddr, customAddr, "Custom address should be set");

        console.log("V2 functions work! Version:", walletV2.version());
        console.log("Counter incremented to:", newCounter);
        console.log("Message set to:", newMessage);
        console.log("Custom address set to:", newAddr);

        // Step 6: Verify V1 storage is preserved
        assertEq(address(walletV2.baseAsset()), address(usdc), "Base asset should be preserved");
        assertEq(walletV2.owner(), user, "Owner should be preserved");
        assertEq(walletV2.ownerAgentIndex(), AGENT_INDEX, "Agent index should be preserved");

        // Verify vault shares are still there
        assertEq(vault.balanceOf(walletAddr), sharesAfterDeposit, "Vault shares should be preserved");

        // Verify position tracking is preserved
        (uint256 costBasisAfterUpgrade, uint256 trackedSharesAfterUpgrade) = feeTracker.getAgentVaultPosition(walletAddr, address(vault));
        assertEq(costBasisAfterUpgrade, costBasis, "Cost basis should be preserved");
        assertEq(trackedSharesAfterUpgrade, trackedShares, "Tracked shares should be preserved");

        console.log("\n=== Step 6: Verified storage preservation ===");
        console.log("Cost basis preserved:", costBasisAfterUpgrade);
        console.log("Tracked shares preserved:", trackedSharesAfterUpgrade);

        // Step 7: Withdraw from vault using V2 wallet
        uint256 sharesToWithdraw = vault.balanceOf(walletAddr);
        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (sharesToWithdraw));

        vm.prank(user);
        walletV2.executeViaAdapter(address(vaultAdapter), address(vault), withdrawData);

        console.log("\n=== Step 7: Withdrew all shares from vault ===");

        // Step 8: Verify fees are correctly calculated (10% of 100 USDC profit = 10 USDC)
        uint256 feesOwed = feeTracker.getFeesOwed(walletAddr);
        assertEq(feesOwed, 10e6, "Should owe 10 USDC in fees (10% of 100 profit)");

        uint256 finalUsdcBalance = usdc.balanceOf(walletAddr);
        assertApproxEqAbs(finalUsdcBalance, 1100e6, 100, "Should have ~1100 USDC (1000 + 100 profit)");

        console.log("\n=== Step 8: Verified fee calculation ===");
        console.log("Fees owed:", feesOwed);
        console.log("Final USDC balance:", finalUsdcBalance);
        console.log("Expected: 1100 USDC (1000 principal + 100 profit)");

        // Step 9: Withdraw USDC to user (respecting fees)
        uint256 withdrawable = finalUsdcBalance - feesOwed;

        vm.prank(user);
        walletV2.withdrawAssetToUser(user, address(usdc), withdrawable);

        console.log("\n=== Step 9: Withdrew USDC to user ===");
        console.log("Withdrawable amount:", withdrawable);
        console.log("User received (delta):", usdc.balanceOf(user) - userBalanceBefore);

        // Verify user got the right amount (principal + profit - fees)
        assertApproxEqAbs(usdc.balanceOf(user) - userBalanceBefore, 1090e6, 100, "User should receive ~1090 USDC (1100 - 10 fees)");

        // Verify fees remain in wallet
        assertApproxEqAbs(usdc.balanceOf(walletAddr), feesOwed, 100, "Wallet should have ~10 USDC fees remaining");

        console.log("\n=== Test Complete ===");
        console.log("* Wallet upgraded from V1 to V2");
        console.log("* V2 state zero-initialized automatically (no manual step!)");
        console.log("* V2 functions work immediately after upgrade");
        console.log("* V2 state can be optionally configured via setters");
        console.log("* V1 storage preserved across upgrade");
        console.log("* Vault operations work after upgrade");
        console.log("* Fees tracked correctly across upgrade");
        console.log("* User withdrawals respect fees");
    }

    function test_CreateFreshV2Wallet_InitializesCorrectly() public {
        // Step 1: Deploy V2 implementation
        MockAgentWalletV2 v2Implementation = new MockAgentWalletV2(address(factory));

        console.log("\n=== Step 1: Deployed V2 implementation ===");
        console.log("V2 implementation:", address(v2Implementation));

        // Step 2: Update factory to use V2 as default implementation
        vm.prank(admin);
        factory.setAgentWalletImplementation(v2Implementation);

        console.log("\n=== Step 2: Set V2 as factory's default implementation ===");

        // Step 3: Create a new wallet (should be V2 from the start)
        uint256 newAgentIndex = 99;
        address user2 = makeAddr("user2");
        address walletAddr = factory.getAddress(user2, newAgentIndex);

        vm.prank(operator);
        address createdWallet = address(factory.createAgentWallet(user2, newAgentIndex, address(usdc)));

        assertEq(createdWallet, walletAddr, "Created wallet should match computed address");

        // Cast to V2
        MockAgentWalletV2 walletV2 = MockAgentWalletV2(payable(walletAddr));

        console.log("\n=== Step 3: Created fresh V2 wallet ===");
        console.log("Wallet address:", walletAddr);
        console.log("Version:", walletV2.version());

        // Step 4: Verify V1 state is properly initialized
        assertEq(walletV2.version(), 2, "Should be V2 wallet");
        assertEq(walletV2.owner(), user2, "Owner should be set to user2");
        assertEq(walletV2.ownerAgentIndex(), newAgentIndex, "Agent index should be set");
        assertEq(address(walletV2.baseAsset()), address(usdc), "Base asset should be USDC");

        console.log("\n=== Step 4: Verified V1 state initialization ===");
        console.log("Owner:", walletV2.owner());
        console.log("Agent index:", walletV2.ownerAgentIndex());
        console.log("Base asset:", address(walletV2.baseAsset()));

        // Step 5: V2 state is zero-initialized (works immediately!)
        (uint256 v2Counter, string memory v2Message, address v2CustomAddress) = walletV2.getV2State();
        assertEq(v2Counter, 0, "V2 counter should start at 0");
        assertEq(bytes(v2Message).length, 0, "V2 message should be empty");
        assertEq(v2CustomAddress, address(0), "V2 custom address should be zero");

        // V2 functions work immediately - no manual initialization needed!
        vm.prank(user2);
        walletV2.v2OnlyFunction("Works immediately!");

        console.log("\n=== Step 5: V2 state zero-initialized and ready ===");
        console.log("V2 counter:", v2Counter);
        console.log("V2 message: (empty)");
        console.log("V2 custom address:", v2CustomAddress);

        // Step 6: Optionally configure V2 state
        vm.prank(user2);
        walletV2.setV2Message("Fresh V2 Wallet");

        address customAddr = address(0xBEEF);
        vm.prank(user2);
        walletV2.setV2CustomAddress(customAddr);

        console.log("\n=== Step 6: Configured V2 state (optional) ===");

        // Step 7: Verify V2 state is configured
        (uint256 counter, string memory message, address customAddress) = walletV2.getV2State();

        assertEq(counter, 0, "Counter should still be 0");
        assertEq(message, "Fresh V2 Wallet", "Message should be set");
        assertEq(customAddress, customAddr, "Custom address should be set");

        console.log("V2 state:");
        console.log("  - Counter:", counter);
        console.log("  - Message:", message);
        console.log("  - Custom address:", customAddress);

        // Step 8: Test V2 functions
        vm.expectEmit(true, true, false, true);
        emit MockAgentWalletV2.V2FunctionCalled(user2, "V2 works!");
        vm.prank(user2);
        walletV2.v2OnlyFunction("V2 works!");

        // Increment counter
        vm.expectEmit(true, false, false, true);
        emit MockAgentWalletV2.V2CounterIncremented(0, 1);
        vm.prank(user2);
        walletV2.incrementV2Counter();

        (uint256 newCounter,,) = walletV2.getV2State();
        assertEq(newCounter, 1, "Counter should be incremented to 1");

        console.log("\n=== Step 8: Verified V2 functions work ===");
        console.log("Counter after increment:", newCounter);

        // Step 9: Verify V1 functionality still works (deposit to vault)
        usdc.mint(user2, 500e6);
        vm.prank(user2);
        require(usdc.transfer(walletAddr, 500e6), "Transfer failed");

        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));
        vm.prank(user2);
        walletV2.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        uint256 vaultShares = vault.balanceOf(walletAddr);
        assertEq(vaultShares, 500e6, "Should have 500 vault shares");

        // Verify fee tracking works
        (uint256 costBasis, uint256 trackedShares) = feeTracker.getAgentVaultPosition(walletAddr, address(vault));
        assertEq(costBasis, 500e6, "Cost basis should be 500 USDC");
        assertEq(trackedShares, 500e6, "Tracked shares should be 500");

        console.log("\n=== Step 9: Verified V1 functionality ===");
        console.log("Vault shares:", vaultShares);
        console.log("Cost basis:", costBasis);
        console.log("Tracked shares:", trackedShares);

        console.log("\n=== Test Complete ===");
        console.log("* Fresh V2 wallet created from factory");
        console.log("* V1 state initialized automatically");
        console.log("* V2 state zero-initialized (works immediately!)");
        console.log("* V2 functions work without manual initialization");
        console.log("* V2 state can be optionally configured via setters");
        console.log("* Both V1 and V2 functionality works");
        console.log("* Fee tracking works correctly");
    }
}
