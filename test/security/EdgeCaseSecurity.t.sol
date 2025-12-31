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

contract EdgeCaseSecurityTest is Test {
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

    function _createWallet() internal returns (AgentWalletV1 wallet) {
        vm.prank(operator);
        wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
    }

    function test_DepositZeroAmountReverts() public {
        AgentWalletV1 wallet = _createWallet();
        usdc.mint(address(wallet), 1000e6);
        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.deposit, (0)));
    }

    function test_WithdrawZeroSharesReverts() public {
        AgentWalletV1 wallet = _createWallet();
        usdc.mint(address(wallet), 1000e6);
        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.withdraw, (0)));
    }

    function test_WithdrawWithoutSharesReverts() public {
        AgentWalletV1 wallet = _createWallet();
        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapter(address(vaultAdapter), address(vault), abi.encodeCall(vaultAdapter.withdraw, (1)));
    }

    function test_BatchAtomicityRevertsAndRollsBack() public {
        AgentWalletV1 wallet = _createWallet();
        usdc.mint(address(wallet), 1000e6);

        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);

        adapters[0] = address(vaultAdapter);
        targets[0] = address(vault);
        datas[0] = abi.encodeCall(vaultAdapter.deposit, (200e6));

        adapters[1] = address(vaultAdapter);
        targets[1] = address(0); // will fail registry lookup
        datas[1] = abi.encodeCall(vaultAdapter.deposit, (100e6));

        uint256 balanceBefore = usdc.balanceOf(address(wallet));
        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapterBatch(adapters, targets, datas);
        assertEq(usdc.balanceOf(address(wallet)), balanceBefore);
        assertEq(vault.balanceOf(address(wallet)), 0);
    }

    function test_BatchSuccessAccumulatesShares() public {
        AgentWalletV1 wallet = _createWallet();
        usdc.mint(address(wallet), 1000e6);

        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);

        adapters[0] = address(vaultAdapter);
        adapters[1] = address(vaultAdapter);
        targets[0] = address(vault);
        targets[1] = address(vault);
        datas[0] = abi.encodeCall(vaultAdapter.deposit, (200e6));
        datas[1] = abi.encodeCall(vaultAdapter.deposit, (300e6));

        vm.prank(user);
        wallet.executeViaAdapterBatch(adapters, targets, datas);
        uint256 shares = vault.balanceOf(address(wallet));
        assertEq(shares, 500e6);
    }

    function test_FeeRateAboveMaxReverts() public {
        vm.prank(admin);
        vm.expectRevert();
        feeTracker.setFeeConfig(6000, feeCollector);
    }
}
