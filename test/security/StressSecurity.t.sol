// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWalletV3} from "../../src/AgentWalletV3.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockEntryPoint} from "../mocks/MockEntryPoint.sol";
import {Test} from "forge-std/Test.sol";

contract StressSecurityTest is Test {
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
        feeTracker = new FeeTracker(admin, admin, feeCollector);
        YieldSeekerYieldFeeModule vaultFees = new YieldSeekerYieldFeeModule(feeTracker, 5000);
        feeTracker.setFeeModule(YIELD_FEE, vaultFees);
        feeTracker.setPlanRate(0, YIELD_FEE, FEE_RATE);

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

    function _createWallet(address owner, uint32 idx) internal returns (AgentWalletV3 wallet) {
        vm.prank(operator);
        wallet = AgentWalletV3(payable(address(factory.createAgentWallet(owner, idx, address(usdc), VAULT_AGENT_PROFILE))));
    }

    function test_MassWalletCreation_OperatorOnly() public {
        for (uint32 i = 0; i < 20; i++) {
            AgentWalletV3 wallet = _createWallet(address(uint160(uint256(keccak256(abi.encode(i))))), i + 1);
            assertEq(wallet.owner(), address(uint160(uint256(keccak256(abi.encode(i))))));
        }
    }

    function test_MassWalletCreation_NonOperatorReverts() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        factory.createAgentWallet(user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE);
    }

    function test_LargeBatchExecution_Succeeds() public {
        AgentWalletV3 wallet = _createWallet(user, AGENT_INDEX);
        usdc.mint(address(wallet), 5_000e6);

        address[] memory adapters = new address[](5);
        address[] memory targets = new address[](5);
        bytes[] memory datas = new bytes[](5);
        for (uint256 i = 0; i < 5; i++) {
            adapters[i] = address(vaultAdapter);
            targets[i] = address(vault);
            datas[i] = abi.encodeCall(vaultAdapter.deposit, ((i + 1) * 100e6));
        }

        vm.prank(user);
        wallet.executeViaAdapterBatch(adapters, targets, datas);
        assertEq(vault.balanceOf(address(wallet)), 1500e6);
        assertEq(usdc.balanceOf(address(wallet)), 3_500e6);
    }

    function test_LargeValueDepositAndWithdraw() public {
        AgentWalletV3 wallet = _createWallet(user, AGENT_INDEX);
        usdc.mint(address(wallet), 1_000_000e6);

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (750_000e6)));
        uint256 shares = vault.balanceOf(address(wallet));
        assertEq(shares, 750_000e6);

        vm.prank(user);
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.withdraw, (shares)));
        assertEq(vault.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 1_000_000e6);
    }

    function test_GasHeavySequentialDeposits() public {
        AgentWalletV3 wallet = _createWallet(user, AGENT_INDEX);
        usdc.mint(address(wallet), 2_000e6);

        uint256 expectedShares;
        for (uint256 i = 0; i < 10; i++) {
            uint256 amount = 100e6;
            expectedShares += amount;
            vm.prank(user);
            wallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (amount)));
        }
        assertEq(vault.balanceOf(address(wallet)), expectedShares);
    }

    function test_BatchWithPausedRegistryReverts() public {
        AgentWalletV3 wallet = _createWallet(user, AGENT_INDEX);
        usdc.mint(address(wallet), 500e6);

        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);
        adapters[0] = address(vaultAdapter);
        adapters[1] = address(vaultAdapter);
        targets[0] = address(vault);
        targets[1] = address(vault);
        datas[0] = abi.encodeCall(vaultAdapter.deposit, (100e6));
        datas[1] = abi.encodeCall(vaultAdapter.deposit, (100e6));

        vm.prank(emergencyAdmin);
        registry.pause();

        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapterBatch(adapters, targets, datas);
    }
}
