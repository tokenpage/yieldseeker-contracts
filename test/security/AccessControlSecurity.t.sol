// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {YieldSeekerAgentWalletV1 as AgentWalletV1} from "../../src/AgentWalletV1.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockERC4626.sol";
import "../mocks/MockEntryPoint.sol";

contract AccessControlSecurityTest is Test {
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
    address attacker = makeAddr("attacker");
    address feeCollector = makeAddr("feeCollector");

    uint256 constant FEE_RATE = 1000;
    uint32 constant AGENT_INDEX = 1;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        vault = new MockERC4626(address(usdc), "Mock Vault", "mVault");
        entryPoint = new MockEntryPoint();
        vm.startPrank(admin);
        registry = new AdapterRegistry(admin, emergencyAdmin);
        feeTracker = new FeeTracker(admin);
        feeTracker.setFeeConfig(FEE_RATE, feeCollector);
        factory = new AgentWalletFactory(admin, operator);
        AgentWalletV1 impl = new AgentWalletV1(address(factory));
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(feeTracker);
        factory.setAgentWalletImplementation(impl);
        vaultAdapter = new ERC4626Adapter();
        registry.registerAdapter(address(vaultAdapter));
        registry.setTargetAdapter(address(vault), address(vaultAdapter));
        vm.stopPrank();
    }

    function _createWallet() internal returns (address wallet) {
        vm.prank(operator);
        wallet = address(factory.createAgentWallet(user, AGENT_INDEX, address(usdc)));
    }

    function test_NonOperatorCannotCreateWallet() public {
        vm.prank(attacker);
        vm.expectRevert();
        factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
    }

    function test_OperatorCreatesWalletSetsOwner() public {
        address wallet = _createWallet();
        assertEq(AgentWalletV1(payable(wallet)).owner(), user);
    }

    function test_NonOwnerCannotBlockAdapter() public {
        address wallet = _createWallet();
        usdc.mint(wallet, 1000e6);
        bytes memory deposit = abi.encodeCall(vaultAdapter.deposit, (100e6));
        vm.prank(attacker);
        vm.expectRevert();
        AgentWalletV1(payable(wallet)).blockAdapter(address(vaultAdapter));
        vm.prank(user);
        AgentWalletV1(payable(wallet)).executeViaAdapter(address(vaultAdapter), address(vault), deposit);
        assertEq(vault.balanceOf(wallet), 100e6);
    }

    function test_OwnerBlockAdapterPreventsExecution() public {
        address wallet = _createWallet();
        usdc.mint(wallet, 1000e6);
        bytes memory deposit = abi.encodeCall(vaultAdapter.deposit, (100e6));
        vm.prank(user);
        AgentWalletV1(payable(wallet)).blockAdapter(address(vaultAdapter));
        vm.prank(user);
        vm.expectRevert();
        AgentWalletV1(payable(wallet)).executeViaAdapter(address(vaultAdapter), address(vault), deposit);
    }

    function test_OnlyOwnerCanExecuteViaAdapter() public {
        address wallet = _createWallet();
        usdc.mint(wallet, 1000e6);
        bytes memory deposit = abi.encodeCall(vaultAdapter.deposit, (100e6));
        vm.prank(attacker);
        vm.expectRevert();
        AgentWalletV1(payable(wallet)).executeViaAdapter(address(vaultAdapter), address(vault), deposit);
        vm.prank(user);
        AgentWalletV1(payable(wallet)).executeViaAdapter(address(vaultAdapter), address(vault), deposit);
        assertEq(vault.balanceOf(wallet), 100e6);
    }

    function test_RegistryPauseBlocksExecution() public {
        address wallet = _createWallet();
        usdc.mint(wallet, 1000e6);
        bytes memory deposit = abi.encodeCall(vaultAdapter.deposit, (100e6));
        vm.prank(emergencyAdmin);
        registry.pause();
        vm.prank(user);
        vm.expectRevert();
        AgentWalletV1(payable(wallet)).executeViaAdapter(address(vaultAdapter), address(vault), deposit);
    }

    function test_AdminCanUpdateFeeConfig() public {
        vm.prank(admin);
        feeTracker.setFeeConfig(2000, feeCollector);
        assertEq(feeTracker.feeRateBps(), 2000);
        assertEq(feeTracker.feeCollector(), feeCollector);
    }

    function test_NonAdminCannotSetAdapterRegistry() public {
        AdapterRegistry newRegistry = new AdapterRegistry(admin, emergencyAdmin);
        vm.prank(attacker);
        vm.expectRevert();
        factory.setAdapterRegistry(newRegistry);
    }
}
