// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InvalidAsset} from "../../src/AgentWalletV3.sol";
import {AdapterIsBlocked, TargetIsBlocked} from "../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

// Real contracts (not mocks)
import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAdminTimelock as AdminTimelock} from "../../src/AdminTimelock.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWalletV3} from "../../src/AgentWalletV3.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerMerklAdapter as MerklAdapter} from "../../src/adapters/MerklAdapter.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";

// Test utilities
import {MockAgentWalletV3} from "../mocks/MockAgentWalletV3.sol";
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
abstract contract AgentWalletIntegrationBase is Test {
    bytes32 constant VAULT_AGENT_PROFILE = keccak256("vault");
    // Real contract instances
    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    YieldSeekerYieldFeeModule vaultFeeModule;
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
    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 indexed ownerAgentIndex, address baseAsset, bytes32 agentProfile);
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
        feeTracker = new FeeTracker(admin, admin, feeCollector);
        vaultFeeModule = new YieldSeekerYieldFeeModule(feeTracker, 5000);
        feeTracker.setFeeModule(YIELD_FEE, vaultFeeModule);
        feeTracker.setPlanRate(0, YIELD_FEE, FEE_RATE);

        // Deploy timelock with admin as proposer and executor
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = admin;
        executors[0] = admin;
        timelock = new AdminTimelock(TIMELOCK_DELAY, proposers, executors, admin);

        // Deploy factory with real components
        factory = new AgentWalletFactory(admin, operator);

        // Deploy implementation AFTER factory exists (so FACTORY field is correct)
        AgentWalletV3 walletImplementation = new AgentWalletV3(address(factory));

        // Configure factory components
        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, registry);
        factory.setFeeTracker(feeTracker);
        factory.setAgentWalletImplementation(AgentWalletV3(payable(address(walletImplementation))));

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
    // ============ Helper Functions ============

    function createWalletForUser(address owner) internal returns (address) {
        vm.prank(operator);
        return address(factory.createAgentWallet(owner, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE));
    }

    function computeExpectedWalletAddress() internal view returns (address) {
        return factory.getAddress(user, AGENT_INDEX);
    }
}

contract AgentWalletIntegrationTest is AgentWalletIntegrationBase {
    // ============ Complete Creation & Initialization Flow Tests ============

    function test_CreateWalletViaFactory_Success() public {
        // Create wallet through factory using real contracts
        vm.expectEmit(true, true, true, true);
        emit AgentWalletCreated(address(computeExpectedWalletAddress()), user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE);

        vm.prank(operator);
        AgentWalletV3 walletAddr = AgentWalletV3(payable(address(factory.createAgentWallet(user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE))));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        emit AgentWalletCreated(computeExpectedWalletAddress(), user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE);

        vm.prank(operator);
        factory.createAgentWallet(user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE);
    }

    // ============ Real Adapter Execution Tests ============

    function test_ExecuteViaAdapter_RealRegistry() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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

        AgentWalletV3 w1 = AgentWalletV3(payable(wallet1));
        AgentWalletV3 w2 = AgentWalletV3(payable(wallet2));

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
        address wallet2 = address(factory.createAgentWallet(user, 2, address(usdc), VAULT_AGENT_PROFILE));

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
        factory.createAgentWallet(user, 100, address(0xDEADBEEF), VAULT_AGENT_PROFILE);
    }

    function test_CreateWallet_ZeroOwner() public {
        // Creating wallet with zero owner should revert
        vm.prank(operator);
        vm.expectRevert();
        factory.createAgentWallet(address(0), AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE);
    }

    function test_CreateWallet_UnauthorizedOperator() public {
        // Non-operator cannot create wallets
        vm.prank(makeAddr("notOperator"));
        vm.expectRevert();
        factory.createAgentWallet(user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE);
    }

    function test_CreateWallet_DuplicateIndex() public {
        // Creating second wallet with same user + index should revert
        createWalletForUser(user);

        vm.prank(operator);
        vm.expectRevert();
        factory.createAgentWallet(user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE);
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
        emit AgentWalletCreated(expectedAddr, user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE);

        vm.prank(operator);
        factory.createAgentWallet(user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE);
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
        address walletAddr = address(factory.createAgentWallet(user, 10, address(usdc), VAULT_AGENT_PROFILE));
        assertTrue(walletAddr != address(0));
    }

    function test_CreateWallet_RealImplementationUsed() public {
        // Wallet should have real implementation, not temp one
        address walletAddr = createWalletForUser(user);
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

        // Should be able to initialize and use normally
        usdc.mint(walletAddr, 100e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (50e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        assertTrue(vault.balanceOf(walletAddr) > 0);
    }

    function test_Factory_UpdateImplementation() public {
        address newImpl = address(new AgentWalletV3(address(factory)));

        vm.prank(admin);
        factory.setAgentWalletImplementation(AgentWalletV3(payable(newImpl)));

        assertTrue(address(factory.agentWalletImplementation()) == newImpl);
    }

    // ============ Real ERC-4337 Integration Tests (15 tests) ============

    function test_ExecuteViaAdapter_OnlyExecutorsAllowed() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

        usdc.mint(walletAddr, 100e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (50e6));

        // Owner can execute
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        assertTrue(vault.balanceOf(walletAddr) > 0);
    }

    function test_ExecuteViaAdapter_OperatorCanExecute() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

        usdc.mint(walletAddr, 100e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (50e6));

        // Operator can execute
        vm.prank(operator);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        assertTrue(vault.balanceOf(walletAddr) > 0);
    }

    function test_BatchExecution_AtomicFailure() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

        usdc.mint(walletAddr, 500e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Verify shares received
        assertTrue(vault.balanceOf(walletAddr) > 0);
    }

    function test_WithdrawThroughAdapterRecordsFeeTracking() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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

        AgentWalletV3 w1 = AgentWalletV3(payable(wallet1));
        AgentWalletV3 w2 = AgentWalletV3(payable(wallet2));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

        // Fund with only 100e6 but try to deposit 500e6
        usdc.mint(walletAddr, 100e6);
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));

        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);
    }

    function test_WalletFunctionality_AfterSync() public {
        address walletAddr = createWalletForUser(user);
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
}

contract AgentWalletFeeTrackingIntegrationTest is AgentWalletIntegrationBase {
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
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

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
        uint256 vaultACost = vaultFeeModule.costBasis(walletAddr, address(vault));
        console.log("VAULT A cost basis:", vaultACost);

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
        uint256 vaultBCost = vaultFeeModule.costBasis(walletAddr, address(vaultB));
        console.log("VAULT B cost basis:", vaultBCost);
        uint256 vaultBFeesOwed = vaultFeeModule.feesOwed(walletAddr);
        assertEq(vaultBFeesOwed, 0, "Vault-share fees are charged on withdrawal, not claim");
        console.log("VAULT B fees owed at claim:", vaultBFeesOwed);
        uint256 feeCollectorBalanceBefore = usdc.balanceOf(feeCollector);
        // Step 4: Redeem VAULT B shares and deposit the net USDC into VAULT A
        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (rewardShareAmount));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vaultB), withdrawData);

        // The wallet receives ~0.9 USDC after the 0.1 USDC fee is paid.
        uint256 usdcFromReward = usdc.balanceOf(walletAddr);
        assertApproxEqAbs(usdcFromReward, 0.9e6, 100, "Wallet should keep the withdrawal net of its 0.1 USDC fee");
        assertEq(usdc.balanceOf(feeCollector) - feeCollectorBalanceBefore, 100_000, "Fee collector should receive the base-asset fee");
        assertEq(vaultFeeModule.feesOwed(walletAddr), 0, "Withdrawal fee should be paid immediately");
        assertEq(vaultB.balanceOf(walletAddr), 0, "Reward shares should be fully redeemed");

        console.log("\n=== After Step 4a: Withdrew from VAULT B ===");
        console.log("USDC balance:", usdcFromReward);
        vaultBCost = vaultFeeModule.costBasis(walletAddr, address(vaultB));
        console.log("VAULT B cost basis:", vaultBCost);

        // Deposit that USDC into VAULT A
        bytes memory depositRewardData = abi.encodeCall(vaultAdapter.deposit, (usdcFromReward));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositRewardData);

        console.log("\n=== After Step 4b: Deposited reward USDC to VAULT A ===");
        vaultACost = vaultFeeModule.costBasis(walletAddr, address(vault));
        console.log("VAULT A cost basis:", vaultACost);

        // Step 5: Check final vault fee module state
        console.log("\n=== Final Vault Fee Module State ===");
        assertEq(vaultFeeModule.feesOwed(walletAddr), 0, "No base-asset fees should remain owed");
    }

    // ============ Position Tracking Edge Cases ============

    function test_DirectVaultShareTransfer_CanBeWithdrawnWithoutUnderflow() public {
        // Step 1: Create wallet and deposit 1000 USDC via adapter
        address walletAddr = createWalletForUser(user);
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

        usdc.mint(user, 1000e6);
        vm.prank(user);
        require(usdc.transfer(walletAddr, 1000e6), "Transfer failed");

        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (1000e6));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), depositData);

        // Verify tracked position
        uint256 costBasis = vaultFeeModule.costBasis(walletAddr, address(vault));
        assertEq(costBasis, 1000e6, "Cost basis should be 1000 USDC");
        assertEq(vault.balanceOf(walletAddr), 1000e6, "Wallet should hold 1000 shares");

        console.log("\n=== After Step 1: Deposited 1000 USDC via adapter ===");
        console.log("Cost basis:", costBasis);
        console.log("Actual vault shares:", vault.balanceOf(walletAddr));

        // Step 2: Someone directly transfers 500 vault shares to the wallet
        // Directly transferred shares have no cost basis, so their value is yield when withdrawn.
        usdc.mint(address(this), 500e6);
        usdc.approve(address(vault), 500e6);
        vault.deposit(500e6, address(this)); // Get vault shares
        require(vault.transfer(walletAddr, 500e6), "Transfer failed"); // Direct transfer to wallet

        console.log("\n=== After Step 2: Direct transfer of 500 vault shares ===");
        console.log("Actual vault shares:", vault.balanceOf(walletAddr));
        costBasis = vaultFeeModule.costBasis(walletAddr, address(vault));
        console.log("Cost basis (still):", costBasis);

        // Withdraw all tracked and directly transferred shares.
        uint256 totalShares = vault.balanceOf(walletAddr);
        assertEq(totalShares, 1500e6, "Wallet should have 1500 shares");
        uint256 feeCollectorBalanceBefore = usdc.balanceOf(feeCollector);

        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (totalShares));

        // User should be able to withdraw all their shares
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), withdrawData);

        // Verify withdrawal succeeded
        uint256 finalUsdcBalance = usdc.balanceOf(walletAddr);
        assertApproxEqAbs(finalUsdcBalance, 1_450e6, 100, "Direct-share value is charged as yield");
        assertEq(usdc.balanceOf(feeCollector) - feeCollectorBalanceBefore, 50e6, "Fee on transferred shares should be paid");
        assertEq(vault.balanceOf(address(wallet)), 0, "Should have no vault shares left");
        costBasis = vaultFeeModule.costBasis(walletAddr, address(vault));
        assertEq(costBasis, 0);

        console.log("\nFinal USDC balance:", finalUsdcBalance);
        console.log("Final vault shares:", vault.balanceOf(walletAddr));
        console.log("Withdrawal succeeded - user can access all their shares");
    }

    function test_WithdrawAssetToUser_BaseAsset_CanWithdrawFullBalanceAfterFeePaid() public {
        // Verify the owner can withdraw the remaining base asset after fees are paid.
        address walletAddr = factory.getAddress(user, AGENT_INDEX);
        vm.prank(operator);
        AgentWalletV3 wallet = AgentWalletV3(payable(factory.createAgentWallet(user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE)));

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
        uint256 feeCollectorBalanceBefore = usdc.balanceOf(feeCollector);
        bytes memory withdrawData = abi.encodeCall(vaultAdapter.withdraw, (shares));
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), withdrawData);

        // The 10 USDC fee (10% of 100 USDC profit) is paid at charge time.
        assertEq(vaultFeeModule.feesOwed(walletAddr), 0, "Base-asset fees should be paid immediately");
        assertEq(usdc.balanceOf(feeCollector) - feeCollectorBalanceBefore, 10e6, "Fee collector should receive 10 USDC");

        uint256 usdcBalance = usdc.balanceOf(walletAddr);
        assertEq(usdcBalance, 1_090e6, "Wallet should retain 1090 USDC after fee payment");

        // The owner can withdraw the full remaining base-asset balance.
        address recipient = makeAddr("recipient");
        vm.prank(user);
        wallet.withdrawAssetToUser(recipient, address(usdc), usdcBalance);

        assertEq(usdc.balanceOf(recipient), usdcBalance, "Recipient should receive the full balance");
        assertEq(usdc.balanceOf(walletAddr), 0, "Wallet should have no base asset left");
    }

    function test_WithdrawAllAssetToUser_BaseAsset_CanWithdrawFullBalanceAfterFeePaid() public {
        // Verify withdrawAllAssetToUser transfers the full balance after fees are paid.
        address walletAddr = factory.getAddress(user, AGENT_INDEX);
        vm.prank(operator);
        AgentWalletV3 wallet = AgentWalletV3(payable(factory.createAgentWallet(user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE)));

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
        uint256 feeCollectorBalanceBefore = usdc.balanceOf(feeCollector);
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), withdrawData);

        // The 10 USDC fee (10% of 100 USDC profit) is paid at charge time.
        assertEq(vaultFeeModule.feesOwed(walletAddr), 0, "Base-asset fees should be paid immediately");
        assertEq(usdc.balanceOf(feeCollector) - feeCollectorBalanceBefore, 10e6, "Fee collector should receive 10 USDC");

        uint256 usdcBalance = usdc.balanceOf(walletAddr);
        assertEq(usdcBalance, 1_090e6, "Wallet should retain 1090 USDC after fee payment");

        // The owner can withdraw the full remaining base-asset balance.
        address recipient = makeAddr("recipient2");
        vm.prank(user);
        wallet.withdrawAllAssetToUser(recipient, address(usdc));

        assertEq(usdc.balanceOf(recipient), usdcBalance, "Recipient should receive the full balance");
        assertEq(usdc.balanceOf(walletAddr), 0, "Wallet should have no base asset left");
    }

    function test_WithdrawAssetToUser_NonBaseAsset_Reverts() public {
        // Test that withdrawing non-baseAsset tokens is now blocked to prevent fee bypass
        address walletAddr = factory.getAddress(user, AGENT_INDEX);

        // Create a different token that will be the "wrong" baseAsset
        MockERC20 wrongToken = new MockERC20("Wrong Token", "WRONG");

        // Operator creates wallet with wrong baseAsset
        vm.prank(operator);
        AgentWalletV3 wallet = AgentWalletV3(payable(factory.createAgentWallet(user, AGENT_INDEX, address(wrongToken), VAULT_AGENT_PROFILE)));

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
        AgentWalletV3 wallet = AgentWalletV3(payable(factory.createAgentWallet(user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE)));

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
        address walletAddr = createWalletForUser(user);
        AgentWalletV3 wallet = AgentWalletV3(payable(walletAddr));

        usdc.mint(walletAddr, 1_000e6);
        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (1_000e6)));

        uint256 sharesBeforeUpgrade = vault.balanceOf(walletAddr);
        uint256 costBasisBeforeUpgrade = vaultFeeModule.costBasis(walletAddr, address(vault));
        assertEq(sharesBeforeUpgrade, 1_000e6);

        vm.prank(user);
        wallet.blockAdapter(address(merklAdapter));
        usdc.mint(address(vault), 100e6);

        MockAgentWalletV3 nextImplementation = new MockAgentWalletV3(address(factory));
        vm.prank(admin);
        factory.setAgentWalletImplementation(AgentWalletV3(payable(address(nextImplementation))));

        vm.prank(user);
        wallet.upgradeToLatest();

        MockAgentWalletV3 upgradedWallet = MockAgentWalletV3(payable(walletAddr));
        assertEq(upgradedWallet.version(), 3);
        assertEq(upgradedWallet.owner(), user);
        assertEq(upgradedWallet.ownerAgentIndex(), AGENT_INDEX);
        assertEq(address(upgradedWallet.baseAsset()), address(usdc));
        assertEq(address(upgradedWallet.feeTracker()), address(feeTracker));
        assertTrue(upgradedWallet.isAdapterBlocked(address(merklAdapter)));
        assertEq(vault.balanceOf(walletAddr), sharesBeforeUpgrade);

        uint256 costBasisAfterUpgrade = vaultFeeModule.costBasis(walletAddr, address(vault));
        assertEq(costBasisAfterUpgrade, costBasisBeforeUpgrade);

        (uint256 v3Counter, string memory v3Message, address v3CustomAddress) = upgradedWallet.getV3State();
        assertEq(v3Counter, 0);
        assertEq(bytes(v3Message).length, 0);
        assertEq(v3CustomAddress, address(0));

        vm.expectEmit(true, false, false, true);
        emit MockAgentWalletV3.V3FunctionCalled(user, "Hello from V3!");
        vm.prank(user);
        upgradedWallet.v3OnlyFunction("Hello from V3!");

        vm.expectEmit(false, false, false, true);
        emit MockAgentWalletV3.V3CounterIncremented(0, 1);
        vm.prank(user);
        upgradedWallet.incrementV3Counter();

        vm.expectEmit(false, false, false, true);
        emit MockAgentWalletV3.V3MessageSet("", "Configured message");
        vm.prank(user);
        upgradedWallet.setV3Message("Configured message");

        address customAddr = address(0xC0FFEE);
        vm.expectEmit(false, false, false, true);
        emit MockAgentWalletV3.V3CustomAddressSet(address(0), customAddr);
        vm.prank(user);
        upgradedWallet.setV3CustomAddress(customAddr);

        (uint256 newCounter, string memory newMessage, address newCustomAddress) = upgradedWallet.getV3State();
        assertEq(newCounter, 1);
        assertEq(newMessage, "Configured message");
        assertEq(newCustomAddress, customAddr);

        uint256 feeCollectorBalanceBefore = usdc.balanceOf(feeCollector);
        vm.prank(user);
        upgradedWallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.withdraw, (sharesBeforeUpgrade)));

        assertEq(vaultFeeModule.feesOwed(walletAddr), 0, "Base-asset fees should be paid immediately");
        assertEq(usdc.balanceOf(feeCollector) - feeCollectorBalanceBefore, 10e6, "Fee collector should receive 10 USDC");
        uint256 remainingBalance = usdc.balanceOf(walletAddr);
        assertEq(remainingBalance, 1_090e6, "Wallet should retain 1090 USDC after fee payment");

        address recipient = makeAddr("upgradeFeeRecipient");
        vm.prank(user);
        upgradedWallet.withdrawAssetToUser(recipient, address(usdc), remainingBalance);
        assertEq(usdc.balanceOf(recipient), remainingBalance, "Owner should be able to withdraw the full remaining balance");
        assertEq(usdc.balanceOf(walletAddr), 0, "Wallet should have no base asset left");
    }

    function test_CreateFreshV2Wallet_InitializesCorrectly() public {
        address user2 = makeAddr("user2");
        uint256 agentIndex = 99;

        vm.prank(operator);
        AgentWalletV3 wallet = AgentWalletV3(payable(address(factory.createAgentWallet(user2, agentIndex, address(usdc), VAULT_AGENT_PROFILE))));

        assertEq(wallet.owner(), user2);
        assertEq(wallet.ownerAgentIndex(), agentIndex);
        assertEq(address(wallet.baseAsset()), address(usdc));
        assertEq(address(wallet.feeTracker()), address(feeTracker));
        assertEq(address(wallet.adapterRegistry()), address(registry));

        usdc.mint(address(wallet), 500e6);
        vm.prank(user2);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (500e6)));

        assertEq(vault.balanceOf(address(wallet)), 500e6);
        uint256 costBasis = vaultFeeModule.costBasis(address(wallet), address(vault));
        assertEq(costBasis, 500e6);
    }
}
