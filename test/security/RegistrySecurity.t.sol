// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWalletV3} from "../../src/AgentWalletV3.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockEntryPoint} from "../mocks/MockEntryPoint.sol";
import {Test} from "forge-std/Test.sol";

contract RegistrySecurityTest is Test {
    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    ERC4626Adapter vaultAdapter;

    MockERC20 usdc;
    MockERC4626 vault;
    MockEntryPoint entryPoint;

    address admin = makeAddr("admin");
    address emergencyAdmin = makeAddr("emergencyAdmin");
    address operator = makeAddr("operator");
    address user = makeAddr("user");
    address feeCollector = makeAddr("feeCollector");

    uint256 constant FEE_RATE = 1000;
    bytes32 constant VAULT_AGENT_PROFILE = keccak256("vault");
    uint32 constant AGENT_INDEX = 1;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        vault = new MockERC4626(address(usdc), "Mock Vault", "mVault");
        entryPoint = new MockEntryPoint();

        vm.startPrank(admin);
        registry = new AdapterRegistry(admin, emergencyAdmin);
        feeTracker = new FeeTracker(admin, admin, feeCollector, 5000, FEE_RATE);

        factory = new AgentWalletFactory(admin, operator);
        AgentWalletV3 impl = new AgentWalletV3(address(factory));
        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, registry);
        factory.setFeeTracker(feeTracker);
        factory.setAgentWalletImplementation(impl);

        vaultAdapter = new ERC4626Adapter();
        registry.registerAdapter(address(vaultAdapter));
        registry.setTargetAdapter(address(vault), address(vaultAdapter));
        vm.stopPrank();
    }

    function _createWallet() internal returns (AgentWalletV3 wallet) {
        vm.prank(operator);
        wallet = AgentWalletV3(payable(address(factory.createAgentWallet(user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE))));
    }

    function test_UnregisteredAdapterBlocksExecution() public {
        AgentWalletV3 wallet = _createWallet();
        usdc.mint(address(wallet), 500e6);

        vm.prank(emergencyAdmin);
        registry.unregisterAdapter(address(vaultAdapter));

        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (100e6)));
    }

    function test_ReregisterAdapterRestoresExecution() public {
        AgentWalletV3 wallet = _createWallet();
        usdc.mint(address(wallet), 500e6);

        vm.prank(emergencyAdmin);
        registry.unregisterAdapter(address(vaultAdapter));
        vm.prank(admin);
        registry.registerAdapter(address(vaultAdapter));

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (100e6)));
        assertEq(vault.balanceOf(address(wallet)), 100e6);
    }

    function test_RemoveTargetBlocksEvenIfAdapterRegistered() public {
        AgentWalletV3 wallet = _createWallet();
        usdc.mint(address(wallet), 500e6);

        vm.prank(emergencyAdmin);
        registry.removeTarget(address(vault));

        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (100e6)));
    }

    function test_RemoveTargetAfterUnregisterPreventsReactivation() public {
        AgentWalletV3 wallet = _createWallet();
        usdc.mint(address(wallet), 500e6);

        vm.prank(emergencyAdmin);
        registry.unregisterAdapter(address(vaultAdapter));
        vm.prank(emergencyAdmin);
        registry.removeTarget(address(vault));
        vm.prank(admin);
        registry.registerAdapter(address(vaultAdapter));

        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (100e6)));
    }

    function test_PauseReturnsNoAdapter() public {
        AgentWalletV3 wallet = _createWallet();
        usdc.mint(address(wallet), 200e6);

        vm.prank(emergencyAdmin);
        registry.pause();

        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (100e6)));
    }

    function test_UnpauseRestoresAdapterLookup() public {
        AgentWalletV3 wallet = _createWallet();
        usdc.mint(address(wallet), 200e6);

        vm.prank(emergencyAdmin);
        registry.pause();
        vm.prank(admin);
        registry.unpause();

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (50e6)));
        assertEq(vault.balanceOf(address(wallet)), 50e6);
    }
}
