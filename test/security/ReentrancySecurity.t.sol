// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV1 as AgentWalletV1} from "../../src/AgentWalletV1.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {IAWKAdapter} from "../../src/agentwalletkit/IAWKAdapter.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockEntryPoint} from "../mocks/MockEntryPoint.sol";
import {Test} from "forge-std/Test.sol";

contract ReenterExecuteAdapter is IAWKAdapter {
    function execute(address target, bytes calldata data) external payable returns (bytes memory) {
        // Attempt to re-enter wallet execution; should revert due to onlyExecutors
        AgentWalletV1 wallet = AgentWalletV1(payable(msg.sender));
        wallet.executeViaAdapter(address(this), target, data);
        return "";
    }
}

contract ReenterWithdrawAdapter is IAWKAdapter {
    function execute(address target, bytes calldata) external payable returns (bytes memory) {
        // Attempt to withdraw during adapter call; should revert due to onlyOwner
        AgentWalletV1 wallet = AgentWalletV1(payable(msg.sender));
        wallet.withdrawBaseAssetToUser(target, 1);
        return "";
    }
}

contract ReentrancySecurityTest is Test {
    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    ERC4626Adapter vaultAdapter;
    ReenterExecuteAdapter reenterExecute;
    ReenterWithdrawAdapter reenterWithdraw;

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

        reenterExecute = new ReenterExecuteAdapter();
        reenterWithdraw = new ReenterWithdrawAdapter();
        registry.registerAdapter(address(reenterExecute));
        registry.registerAdapter(address(reenterWithdraw));
        registry.setTargetAdapter(address(reenterExecute), address(reenterExecute));
        registry.setTargetAdapter(address(reenterWithdraw), address(reenterWithdraw));
        vm.stopPrank();
    }

    function _createWallet() internal returns (AgentWalletV1 wallet) {
        vm.prank(operator);
        wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
    }

    function test_ReenterExecuteViaAdapter_RevertsUnauthorized() public {
        AgentWalletV1 wallet = _createWallet();
        usdc.mint(address(wallet), 1000e6);

        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapter(address(reenterExecute), address(reenterExecute), "");
    }

    function test_ReenterWithdrawBaseAsset_RevertsUnauthorized() public {
        AgentWalletV1 wallet = _createWallet();
        usdc.mint(address(wallet), 1000e6);

        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapter(address(reenterWithdraw), address(user), "");
    }

    function test_ReenterDuringBatch_RevertsUnauthorized() public {
        AgentWalletV1 wallet = _createWallet();
        usdc.mint(address(wallet), 1000e6);

        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);

        adapters[0] = address(vaultAdapter);
        targets[0] = address(vault);
        datas[0] = abi.encodeCall(vaultAdapter.deposit, (100e6));

        adapters[1] = address(reenterExecute);
        targets[1] = address(reenterExecute);
        datas[1] = "";

        vm.prank(user);
        vm.expectRevert();
        wallet.executeViaAdapterBatch(adapters, targets, datas);
    }

    function test_NonExecutorCannotTriggerReenterAdapter() public {
        AgentWalletV1 wallet = _createWallet();
        usdc.mint(address(wallet), 1000e6);

        vm.prank(feeCollector);
        vm.expectRevert();
        wallet.executeViaAdapter(address(reenterExecute), address(reenterExecute), "");
    }
}
