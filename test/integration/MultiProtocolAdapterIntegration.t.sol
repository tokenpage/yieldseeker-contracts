// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

// Real contracts
import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV1 as AgentWalletV1} from "../../src/AgentWalletV1.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerAaveV3Adapter as AaveV3Adapter} from "../../src/adapters/AaveV3Adapter.sol";
import {YieldSeekerCompoundV2Adapter as CompoundV2Adapter} from "../../src/adapters/CompoundV2Adapter.sol";
import {YieldSeekerCompoundV3Adapter as CompoundV3Adapter} from "../../src/adapters/CompoundV3Adapter.sol";

// Test utilities
import {MockAToken, MockAaveV3Pool} from "../mocks/MockAaveV3.sol";
import {MockCToken} from "../mocks/MockCompoundV2.sol";
import {MockCompoundV3Comet} from "../mocks/MockCompoundV3.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title Multi-Protocol Adapter Integration Tests
/// @notice Tests for Aave V3, Compound V3, and Compound V2 adapter interactions
contract MultiProtocolAdapterIntegrationTest is Test {
    // Real contract instances
    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    AaveV3Adapter aaveAdapter;
    CompoundV3Adapter compoundV3Adapter;
    CompoundV2Adapter compoundV2Adapter;

    // Test utilities
    MockERC20 usdc;
    MockAaveV3Pool aavePool;
    MockAToken aToken;
    MockCompoundV3Comet comet;
    MockCToken cToken;

    // Test accounts
    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address user = makeAddr("user");
    address feeCollector = makeAddr("feeCollector");

    // Configuration
    uint256 constant FEE_RATE = 1000; // 10%
    uint256 constant AGENT_INDEX = 1;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        aavePool = new MockAaveV3Pool(address(usdc));
        aToken = MockAToken(aavePool.aToken());
        comet = new MockCompoundV3Comet(address(usdc));
        cToken = new MockCToken(address(usdc), "Mock cUSDC", "cUSDC");

        vm.startPrank(admin);
        registry = new AdapterRegistry(admin, admin);
        feeTracker = new FeeTracker(admin);
        feeTracker.setFeeConfig(FEE_RATE, feeCollector);
        factory = new AgentWalletFactory(admin, operator);
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(feeTracker);
        AgentWalletV1 walletImplementation = new AgentWalletV1(address(factory));
        factory.setAgentWalletImplementation(walletImplementation);
        aaveAdapter = new AaveV3Adapter();
        compoundV3Adapter = new CompoundV3Adapter();
        compoundV2Adapter = new CompoundV2Adapter();
        registry.registerAdapter(address(aaveAdapter));
        registry.registerAdapter(address(compoundV3Adapter));
        registry.registerAdapter(address(compoundV2Adapter));
        registry.setTargetAdapter(address(aToken), address(aaveAdapter));
        registry.setTargetAdapter(address(comet), address(compoundV3Adapter));
        registry.setTargetAdapter(address(cToken), address(compoundV2Adapter));
        vm.stopPrank();
        usdc.mint(user, 100_000e6);
    }

    function _decodeUint(bytes memory data) internal pure returns (uint256) {
        return abi.decode(abi.decode(data, (bytes)), (uint256));
    }

    // ========================================
    // AAVE V3 INTEGRATION
    // ========================================

    function test_AaveV3_DepositWithdraw() public {
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
        usdc.mint(address(wallet), 10_000e6);
        vm.prank(user);
        bytes memory result = wallet.executeViaAdapter(address(aaveAdapter), address(aToken), abi.encodeCall(aaveAdapter.deposit, (5_000e6)));
        uint256 shares = _decodeUint(result);
        assertEq(shares, 5_000e6, "Should receive 1:1 aToken shares");
        assertEq(aToken.balanceOf(address(wallet)), 5_000e6, "Wallet should have aTokens");
        vm.prank(user);
        bytes memory withdrawResult = wallet.executeViaAdapter(address(aaveAdapter), address(aToken), abi.encodeCall(aaveAdapter.withdraw, (3_000e6)));
        uint256 assetsReceived = _decodeUint(withdrawResult);
        assertEq(assetsReceived, 3_000e6, "Should withdraw correct amount");
        assertEq(aToken.balanceOf(address(wallet)), 2_000e6, "Should have remaining aTokens");
    }

    // ========================================
    // COMPOUND V3 INTEGRATION
    // ========================================

    function test_CompoundV3_DepositWithdraw() public {
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
        usdc.mint(address(wallet), 10_000e6);
        vm.prank(user);
        bytes memory result = wallet.executeViaAdapter(address(compoundV3Adapter), address(comet), abi.encodeCall(compoundV3Adapter.deposit, (5_000e6)));
        uint256 shares = _decodeUint(result);
        assertEq(shares, 5_000e6, "Should receive 1:1 shares");
        assertEq(comet.balanceOf(address(wallet)), 5_000e6, "Wallet should have comet balance");
        vm.prank(user);
        bytes memory withdrawResult = wallet.executeViaAdapter(address(compoundV3Adapter), address(comet), abi.encodeCall(compoundV3Adapter.withdraw, (3_000e6)));
        uint256 assetsReceived = _decodeUint(withdrawResult);
        assertEq(assetsReceived, 3_000e6, "Should withdraw correct amount");
    }

    // ========================================
    // COMPOUND V2 INTEGRATION
    // ========================================

    function test_CompoundV2_DepositWithdraw() public {
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
        usdc.mint(address(wallet), 10_000e6);
        vm.prank(user);
        bytes memory result = wallet.executeViaAdapter(address(compoundV2Adapter), address(cToken), abi.encodeCall(compoundV2Adapter.deposit, (5_000e6)));
        uint256 shares = _decodeUint(result);
        assertEq(shares, 5_000e6, "Should receive shares at initial rate");
        assertEq(cToken.balanceOf(address(wallet)), 5_000e6, "Wallet should have cTokens");
        vm.prank(user);
        bytes memory withdrawResult = wallet.executeViaAdapter(address(compoundV2Adapter), address(cToken), abi.encodeCall(compoundV2Adapter.withdraw, (3_000e6)));
        uint256 assetsReceived = _decodeUint(withdrawResult);
        assertEq(assetsReceived, 3_000e6, "Should withdraw correct amount");
    }

    // ========================================
    // CROSS-PROTOCOL SCENARIOS
    // ========================================

    function test_MovePositionAcrossProtocols() public {
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
        usdc.mint(address(wallet), 10_000e6);
        vm.prank(user);
        wallet.executeViaAdapter(address(aaveAdapter), address(aToken), abi.encodeCall(aaveAdapter.deposit, (10_000e6)));
        assertEq(aToken.balanceOf(address(wallet)), 10_000e6, "Should have position in Aave");
        vm.prank(user);
        wallet.executeViaAdapter(address(aaveAdapter), address(aToken), abi.encodeCall(aaveAdapter.withdraw, (10_000e6)));
        vm.prank(user);
        wallet.executeViaAdapter(address(compoundV3Adapter), address(comet), abi.encodeCall(compoundV3Adapter.deposit, (10_000e6)));
        assertEq(aToken.balanceOf(address(wallet)), 0, "Should have no position in Aave");
        assertEq(comet.balanceOf(address(wallet)), 10_000e6, "Should have position in Compound V3");
    }

    function test_DistributeAcrossAllProtocols() public {
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
        usdc.mint(address(wallet), 9_000e6);
        address[] memory adapters = new address[](3);
        address[] memory targets = new address[](3);
        bytes[] memory calls = new bytes[](3);
        adapters[0] = address(aaveAdapter);
        targets[0] = address(aToken);
        calls[0] = abi.encodeCall(aaveAdapter.deposit, (3_000e6));
        adapters[1] = address(compoundV3Adapter);
        targets[1] = address(comet);
        calls[1] = abi.encodeCall(compoundV3Adapter.deposit, (3_000e6));
        adapters[2] = address(compoundV2Adapter);
        targets[2] = address(cToken);
        calls[2] = abi.encodeCall(compoundV2Adapter.deposit, (3_000e6));
        vm.prank(user);
        wallet.executeViaAdapterBatch(adapters, targets, calls);
        assertEq(aToken.balanceOf(address(wallet)), 3_000e6, "Should have 3000 in Aave");
        assertEq(comet.balanceOf(address(wallet)), 3_000e6, "Should have 3000 in Compound V3");
        assertEq(cToken.balanceOf(address(wallet)), 3_000e6, "Should have 3000 in Compound V2");
    }

    function test_ConsolidateFromAllProtocols() public {
        vm.prank(operator);
        AgentWalletV1 wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
        usdc.mint(address(wallet), 9_000e6);
        address[] memory adapters = new address[](3);
        address[] memory targets = new address[](3);
        bytes[] memory calls = new bytes[](3);
        adapters[0] = address(aaveAdapter);
        targets[0] = address(aToken);
        calls[0] = abi.encodeCall(aaveAdapter.deposit, (3_000e6));
        adapters[1] = address(compoundV3Adapter);
        targets[1] = address(comet);
        calls[1] = abi.encodeCall(compoundV3Adapter.deposit, (3_000e6));
        adapters[2] = address(compoundV2Adapter);
        targets[2] = address(cToken);
        calls[2] = abi.encodeCall(compoundV2Adapter.deposit, (3_000e6));
        vm.prank(user);
        wallet.executeViaAdapterBatch(adapters, targets, calls);
        adapters = new address[](3);
        targets = new address[](3);
        calls = new bytes[](3);
        adapters[0] = address(aaveAdapter);
        targets[0] = address(aToken);
        calls[0] = abi.encodeCall(aaveAdapter.withdraw, (3_000e6));
        adapters[1] = address(compoundV3Adapter);
        targets[1] = address(comet);
        calls[1] = abi.encodeCall(compoundV3Adapter.withdraw, (3_000e6));
        adapters[2] = address(compoundV2Adapter);
        targets[2] = address(cToken);
        calls[2] = abi.encodeCall(compoundV2Adapter.withdraw, (3_000e6));
        vm.prank(user);
        wallet.executeViaAdapterBatch(adapters, targets, calls);
        assertEq(aToken.balanceOf(address(wallet)), 0, "Should have 0 in Aave");
        assertEq(comet.balanceOf(address(wallet)), 0, "Should have 0 in Compound V3");
        assertEq(cToken.balanceOf(address(wallet)), 0, "Should have 0 in Compound V2");
        assertEq(usdc.balanceOf(address(wallet)), 9_000e6, "Should have all USDC back");
    }
}
