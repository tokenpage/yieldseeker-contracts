// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {AgentActionRouter} from "../src/modules/AgentActionRouter.sol";
import {ActionRegistry} from "../src/ActionRegistry.sol";
import {ERC4626Adapter} from "../src/adapters/ERC4626Adapter.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC4626} from "./mocks/MockERC4626.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract AgentWalletTest is Test {
    YieldSeekerAgentWallet public implementation;
    YieldSeekerAgentWalletFactory public factory;
    AgentActionRouter public router;
    ActionRegistry public registry;
    ERC4626Adapter public erc4626Adapter;
    MockERC20 public usdc;
    MockERC4626 public vault;

    address public admin = address(0x1);
    address public user = address(0x2);
    address public operator = address(0x3);
    address public randomUser = address(0x4);

    function setUp() public {
        vm.startPrank(admin);
        implementation = new YieldSeekerAgentWallet();
        factory = new YieldSeekerAgentWalletFactory(address(implementation), admin);
        registry = new ActionRegistry(admin);
        router = new AgentActionRouter(address(registry), admin);
        router.addOperator(operator);
        factory.setDefaultExecutor(address(router));
        usdc = new MockERC20("USDC", "USDC");
        vault = new MockERC4626(address(usdc));
        erc4626Adapter = new ERC4626Adapter(address(registry));
        registry.registerAdapter(address(erc4626Adapter));
        registry.registerTarget(address(vault), address(erc4626Adapter));
        vm.stopPrank();
    }

    function test_CreateWallet() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        assertEq(wallet.user(), user);
        assertEq(wallet.userAgentIndex(), 0);
        assertEq(wallet.baseAsset(), address(usdc));
        assertEq(wallet.owner(), user);
        assertTrue(wallet.isModuleInstalled(2, address(router), ""));
    }

    function test_Workflow_DepositAndWithdraw() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        usdc.mint(walletAddr, 1000e6);
        assertEq(usdc.balanceOf(walletAddr), 1000e6);
        vm.prank(user);
        wallet.withdrawTokenToUser(address(usdc), user, 500e6);
        assertEq(usdc.balanceOf(walletAddr), 500e6);
        assertEq(usdc.balanceOf(user), 500e6);
        vm.deal(walletAddr, 1 ether);
        vm.prank(user);
        wallet.withdrawEthToUser(user, 0.5 ether);
        assertEq(walletAddr.balance, 0.5 ether);
        assertEq(user.balance, 0.5 ether);
    }

    function test_Workflow_ExecutionViaAdapter() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        assertTrue(wallet.isModuleInstalled(2, address(router), ""));
        usdc.mint(walletAddr, 1000e6);
        bytes memory actionData = abi.encodeCall(ERC4626Adapter.deposit, (address(vault), 500e6));
        vm.prank(operator);
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), actionData);
        assertEq(vault.balanceOf(walletAddr), 500e6);
        assertEq(usdc.balanceOf(walletAddr), 500e6);
    }

    function test_Workflow_BlockedByUnregisteredAdapter() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        address fakeAdapter = address(0x999);
        bytes memory actionData = abi.encodeCall(ERC4626Adapter.deposit, (address(vault), 100e6));
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(AgentActionRouter.AdapterNotRegistered.selector, fakeAdapter));
        router.executeAdapterAction(walletAddr, fakeAdapter, actionData);
    }

    function test_Workflow_BlockedByUnregisteredTarget() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        usdc.mint(walletAddr, 1000e6);
        MockERC4626 unregisteredVault = new MockERC4626(address(usdc));
        bytes memory actionData = abi.encodeCall(ERC4626Adapter.deposit, (address(unregisteredVault), 100e6));
        vm.prank(operator);
        vm.expectRevert();
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), actionData);
    }

    function test_Workflow_BatchExecution() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        assertTrue(wallet.isModuleInstalled(2, address(router), ""));
        usdc.mint(walletAddr, 1000e6);
        address[] memory adapters = new address[](2);
        bytes[] memory actionDatas = new bytes[](2);
        adapters[0] = address(erc4626Adapter);
        adapters[1] = address(erc4626Adapter);
        actionDatas[0] = abi.encodeCall(ERC4626Adapter.deposit, (address(vault), 200e6));
        actionDatas[1] = abi.encodeCall(ERC4626Adapter.deposit, (address(vault), 300e6));
        vm.prank(operator);
        router.executeAdapterActions(walletAddr, adapters, actionDatas);
        assertEq(vault.balanceOf(walletAddr), 500e6);
        assertEq(usdc.balanceOf(walletAddr), 500e6);
    }

    function test_Workflow_BatchExecution_EmptyBatch() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        address[] memory adapters = new address[](0);
        bytes[] memory actionDatas = new bytes[](0);
        vm.prank(operator);
        vm.expectRevert(AgentActionRouter.EmptyBatch.selector);
        router.executeAdapterActions(walletAddr, adapters, actionDatas);
    }

    // ============ AgentWallet Unit Tests ============

    function test_Wallet_AccountId() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        assertEq(wallet.accountId(), "yieldseeker.agent.wallet.v1");
    }

    function test_Wallet_WithdrawAllTokenToUser() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        usdc.mint(walletAddr, 1000e6);
        vm.prank(user);
        wallet.withdrawAllTokenToUser(address(usdc), user);
        assertEq(usdc.balanceOf(walletAddr), 0);
        assertEq(usdc.balanceOf(user), 1000e6);
    }

    function test_Wallet_WithdrawAllEthToUser() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        vm.deal(walletAddr, 1 ether);
        vm.prank(user);
        wallet.withdrawAllEthToUser(user);
        assertEq(walletAddr.balance, 0);
        assertEq(user.balance, 1 ether);
    }

    function test_Wallet_WithdrawTokenToUser_OnlyOwner() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        usdc.mint(walletAddr, 1000e6);
        vm.prank(randomUser);
        vm.expectRevert();
        wallet.withdrawTokenToUser(address(usdc), randomUser, 500e6);
    }

    function test_Wallet_WithdrawEthToUser_OnlyOwner() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        vm.deal(walletAddr, 1 ether);
        vm.prank(randomUser);
        vm.expectRevert();
        wallet.withdrawEthToUser(randomUser, 0.5 ether);
    }

    function test_Wallet_WithdrawToken_InsufficientBalance() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        usdc.mint(walletAddr, 100e6);
        vm.prank(user);
        vm.expectRevert(YieldSeekerAgentWallet.InsufficientBalance.selector);
        wallet.withdrawTokenToUser(address(usdc), user, 500e6);
    }

    function test_Wallet_WithdrawEth_InsufficientBalance() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        vm.deal(walletAddr, 0.1 ether);
        vm.prank(user);
        vm.expectRevert(YieldSeekerAgentWallet.InsufficientBalance.selector);
        wallet.withdrawEthToUser(user, 1 ether);
    }

    function test_Wallet_WithdrawToken_InvalidAddress() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        usdc.mint(walletAddr, 1000e6);
        vm.prank(user);
        vm.expectRevert(YieldSeekerAgentWallet.InvalidAddress.selector);
        wallet.withdrawTokenToUser(address(0), user, 500e6);
    }

    function test_Wallet_WithdrawToken_InvalidRecipient() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        usdc.mint(walletAddr, 1000e6);
        vm.prank(user);
        vm.expectRevert(YieldSeekerAgentWallet.InvalidAddress.selector);
        wallet.withdrawTokenToUser(address(usdc), address(0), 500e6);
    }

    function test_Wallet_InstallModule_OnlyOwner() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        vm.prank(randomUser);
        vm.expectRevert();
        wallet.installModule(2, address(0x999), "");
    }

    function test_Wallet_UninstallModule_OnlyOwner() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        vm.prank(randomUser);
        vm.expectRevert();
        wallet.uninstallModule(2, address(router), "");
    }

    function test_Wallet_UninstallModule_CannotUninstallDefaultModule() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        vm.prank(user);
        vm.expectRevert(YieldSeekerAgentWallet.CannotUninstallDefaultModule.selector);
        wallet.uninstallModule(2, address(router), "");
    }

    // ============ Factory Unit Tests ============

    function test_Factory_PredictAgentWalletAddress() public {
        address predicted = factory.predictAgentWalletAddress(user, 0, address(usdc));
        vm.prank(admin);
        address actual = factory.createAgentWallet(user, 0, address(usdc));
        assertEq(predicted, actual);
    }

    function test_Factory_CreateAgentWallet_OnlyCreatorRole() public {
        vm.prank(randomUser);
        vm.expectRevert();
        factory.createAgentWallet(randomUser, 0, address(usdc));
    }

    function test_Factory_SetImplementation_OnlyAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert();
        factory.setImplementation(address(0x999));
    }

    function test_Factory_SetDefaultExecutor_OnlyAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert();
        factory.setDefaultExecutor(address(0x999));
    }

    function test_Factory_CreateWallet_RequiresDefaultExecutor() public {
        vm.startPrank(admin);
        YieldSeekerAgentWalletFactory newFactory = new YieldSeekerAgentWalletFactory(address(implementation), admin);
        vm.expectRevert("Default executor not set");
        newFactory.createAgentWallet(user, 0, address(usdc));
        vm.stopPrank();
    }

    // ============ Router Unit Tests ============

    function test_Router_SetRegistry_OnlyRegistryAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert();
        router.setRegistry(address(0x999));
    }

    function test_Router_SetRegistry() public {
        ActionRegistry newRegistry = new ActionRegistry(admin);
        vm.prank(admin);
        router.setRegistry(address(newRegistry));
        assertEq(address(router.registry()), address(newRegistry));
    }

    function test_Router_AddOperator_OnlyOperatorAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert();
        router.addOperator(randomUser);
    }

    function test_Router_RemoveOperator_OnlyEmergencyRole() public {
        vm.prank(randomUser);
        vm.expectRevert();
        router.removeOperator(operator);
    }

    function test_Router_RemoveOperator() public {
        assertTrue(router.operators(operator));
        vm.prank(admin);
        router.removeOperator(operator);
        assertFalse(router.operators(operator));
    }

    function test_Router_ExecuteAction_NotAuthorized() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        bytes memory actionData = abi.encodeCall(ERC4626Adapter.deposit, (address(vault), 100e6));
        vm.prank(randomUser);
        vm.expectRevert("Router: not authorized");
        router.executeAdapterAction(walletAddr, address(erc4626Adapter), actionData);
    }

    function test_Router_BatchExecution_ExceedsMaxSize() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        address[] memory adapters = new address[](21);
        bytes[] memory actionDatas = new bytes[](21);
        for (uint256 i = 0; i < 21; i++) {
            adapters[i] = address(erc4626Adapter);
            actionDatas[i] = abi.encodeCall(ERC4626Adapter.deposit, (address(vault), 100e6));
        }
        vm.prank(operator);
        vm.expectRevert(AgentActionRouter.BatchTooLarge.selector);
        router.executeAdapterActions(walletAddr, adapters, actionDatas);
    }

    function test_Router_IsModuleType() public view {
        assertTrue(router.isModuleType(2));
        assertFalse(router.isModuleType(1));
        assertFalse(router.isModuleType(3));
    }

    // ============ Registry Unit Tests ============

    function test_Registry_RegisterAdapter_OnlyAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert();
        registry.registerAdapter(address(0x999));
    }

    function test_Registry_RegisterTarget_OnlyAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert();
        registry.registerTarget(address(0x999), address(erc4626Adapter));
    }

    function test_Registry_RemoveTarget() public {
        vm.prank(admin);
        registry.removeTarget(address(vault));
        (bool valid,) = registry.isValidTarget(address(vault));
        assertFalse(valid);
    }
}
