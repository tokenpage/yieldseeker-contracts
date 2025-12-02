// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {AgentActionRouter} from "../src/modules/AgentActionRouter.sol";
import {AgentActionPolicy} from "../src/modules/AgentActionPolicy.sol";
import {MerklValidator} from "../src/validators/MerklValidator.sol";
import {ZeroExValidator} from "../src/validators/ZeroExValidator.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTarget} from "./mocks/MockTarget.sol";
import {Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract AgentWalletTest is Test {
    YieldSeekerAgentWallet public implementation;
    YieldSeekerAgentWalletFactory public factory;
    AgentActionRouter public router;
    AgentActionPolicy public policy;
    MockERC20 public usdc;
    MockTarget public target;
    MerklValidator public merklValidator;
    ZeroExValidator public zeroExValidator;

    address public admin = address(0x1);
    address public user = address(0x2);
    address public operator = address(0x3);
    address public randomUser = address(0x4);

    function setUp() public {
        vm.startPrank(admin);
        implementation = new YieldSeekerAgentWallet();
        factory = new YieldSeekerAgentWalletFactory(address(implementation), admin);
        policy = new AgentActionPolicy(admin);
        router = new AgentActionRouter(address(policy), admin);
        router.addOperator(operator);
        factory.setDefaultExecutor(address(router));
        merklValidator = new MerklValidator();
        zeroExValidator = new ZeroExValidator();
        usdc = new MockERC20("USDC", "USDC");
        target = new MockTarget();
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
        // Router is auto-installed
        assertTrue(wallet.isModuleInstalled(2, address(router), ""));
    }

    function test_Workflow_DepositAndWithdraw() public {
        // 1. Create Wallet
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));

        // 2. Deposit USDC
        usdc.mint(walletAddr, 1000e6);
        assertEq(usdc.balanceOf(walletAddr), 1000e6);

        // 3. Withdraw USDC (User Action)
        vm.prank(user);
        wallet.withdrawTokenToUser(address(usdc), user, 500e6);

        assertEq(usdc.balanceOf(walletAddr), 500e6);
        assertEq(usdc.balanceOf(user), 500e6);

        // 4. Withdraw ETH
        vm.deal(walletAddr, 1 ether);
        vm.prank(user);
        wallet.withdrawEthToUser(user, 0.5 ether);

        assertEq(walletAddr.balance, 0.5 ether);
        assertEq(user.balance, 0.5 ether);
    }

    function test_Workflow_ExecutionViaRouter() public {
        // 1. Create Wallet (Router is auto-installed)
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));

        // Verify Router is already installed
        assertTrue(wallet.isModuleInstalled(2, address(router), ""));

        // 2. Configure Policy (Admin Action)
        // Allow 'swap' on MockTarget
        bytes4 swapSelector = MockTarget.swap.selector;
        vm.prank(admin);
        policy.addPolicy(address(target), swapSelector, address(1)); // address(1) = Allow All

        // 3. Execute Action (Operator Action)
        bytes memory data = abi.encodeWithSelector(swapSelector, address(usdc), address(0), 100);

        vm.prank(operator);
        router.executeAction(walletAddr, address(target), 0, data);

        // Verify execution (MockTarget emits event, but hard to check here without vm.expectEmit)
        // If it didn't revert, it passed.
    }

    function test_Workflow_BlockedByPolicy() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        // Policy is empty, so everything should be blocked
        bytes4 swapSelector = MockTarget.swap.selector;
        bytes memory data = abi.encodeWithSelector(swapSelector, address(usdc), address(0), 100);

        vm.prank(operator);
        vm.expectRevert("Policy: action not allowed");
        router.executeAction(walletAddr, address(target), 0, data);
    }

    function test_Workflow_MerklValidator() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        // Configure Policy with MerklValidator
        bytes4 claimSelector = merklValidator.CLAIM_SELECTOR(); // 0x3d13f874
        vm.prank(admin);
        policy.addPolicy(address(target), claimSelector, address(merklValidator));

        // Prepare Valid Data (Claiming for self)
        address[] memory users = new address[](1);
        users[0] = walletAddr;
        address[] memory tokens = new address[](0);
        uint256[] memory amounts = new uint256[](0);
        bytes32[][] memory proofs = new bytes32[][](0);

        bytes memory validData = abi.encodeWithSelector(claimSelector, users, tokens, amounts, proofs);

        // Execute Valid Action
        vm.prank(operator);
        router.executeAction(walletAddr, address(target), 0, validData);

        // Prepare Invalid Data (Claiming for someone else)
        users[0] = user; // Not the wallet
        bytes memory invalidData = abi.encodeWithSelector(claimSelector, users, tokens, amounts, proofs);

        // Execute Invalid Action
        vm.prank(operator);
        vm.expectRevert("Policy: validation failed");
        router.executeAction(walletAddr, address(target), 0, invalidData);
    }

    function test_Workflow_ZeroExValidator() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));

        // Configure Policy with ZeroExValidator
        bytes4 transformSelector = zeroExValidator.TRANSFORM_ERC20_SELECTOR(); // 0x415565b0
        vm.prank(admin);
        policy.addPolicy(address(target), transformSelector, address(zeroExValidator));

        // Prepare Valid Data (Output Token == Base Asset == USDC)
        bytes[] memory transformations = new bytes[](0);
        bytes memory validData = abi.encodeWithSelector(
            transformSelector,
            address(0), // input
            address(usdc), // output (Matches Base Asset)
            100,
            100,
            transformations
        );

        // Execute Valid Action
        vm.prank(operator);
        router.executeAction(walletAddr, address(target), 0, validData);

        // Prepare Invalid Data (Output Token != Base Asset)
        bytes memory invalidData = abi.encodeWithSelector(
            transformSelector,
            address(0),
            address(0x999), // Random token
            100,
            100,
            transformations
        );

        // Execute Invalid Action
        vm.prank(operator);
        vm.expectRevert("Policy: validation failed");
        router.executeAction(walletAddr, address(target), 0, invalidData);
    }

    function test_Workflow_BatchExecution() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        assertTrue(wallet.isModuleInstalled(2, address(router), ""));
        bytes4 swapSelector = MockTarget.swap.selector;
        vm.prank(admin);
        policy.addPolicy(address(target), swapSelector, address(1));
        Execution[] memory executions = new Execution[](3);
        executions[0] = Execution({target: address(target), value: 0, callData: abi.encodeWithSelector(swapSelector, address(usdc), address(0), 100)});
        executions[1] = Execution({target: address(target), value: 0, callData: abi.encodeWithSelector(swapSelector, address(usdc), address(0), 200)});
        executions[2] = Execution({target: address(target), value: 0, callData: abi.encodeWithSelector(swapSelector, address(usdc), address(0), 300)});
        vm.prank(operator);
        router.executeActions(walletAddr, executions);
    }

    function test_Workflow_BatchExecution_EmptyBatch() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        Execution[] memory executions = new Execution[](0);
        vm.prank(operator);
        vm.expectRevert(AgentActionRouter.EmptyBatch.selector);
        router.executeActions(walletAddr, executions);
    }

    function test_Workflow_BatchExecution_PolicyFailure() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        bytes4 swapSelector = MockTarget.swap.selector;
        vm.prank(admin);
        policy.addPolicy(address(target), swapSelector, address(1));
        Execution[] memory executions = new Execution[](2);
        executions[0] = Execution({target: address(target), value: 0, callData: abi.encodeWithSelector(swapSelector, address(usdc), address(0), 100)});
        executions[1] = Execution({target: address(0x999), value: 0, callData: abi.encodeWithSelector(swapSelector, address(usdc), address(0), 200)});
        vm.prank(operator);
        vm.expectRevert("Policy: action not allowed");
        router.executeActions(walletAddr, executions);
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

    function test_Router_SetPolicy_OnlyPolicyAdmin() public {
        vm.prank(randomUser);
        vm.expectRevert();
        router.setPolicy(address(0x999));
    }

    function test_Router_SetPolicy() public {
        AgentActionPolicy newPolicy = new AgentActionPolicy(admin);
        vm.prank(admin);
        router.setPolicy(address(newPolicy));
        assertEq(address(router.policy()), address(newPolicy));
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
        bytes4 swapSelector = MockTarget.swap.selector;
        vm.prank(admin);
        policy.addPolicy(address(target), swapSelector, address(1));
        vm.prank(randomUser);
        vm.expectRevert("Router: not authorized");
        router.executeAction(walletAddr, address(target), 0, abi.encodeWithSelector(swapSelector, address(usdc), address(0), 100));
    }

    function test_Router_BatchExecution_ExceedsMaxSize() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        bytes4 swapSelector = MockTarget.swap.selector;
        vm.prank(admin);
        policy.addPolicy(address(target), swapSelector, address(1));
        Execution[] memory executions = new Execution[](21);
        for (uint256 i = 0; i < 21; i++) {
            executions[i] = Execution({target: address(target), value: 0, callData: abi.encodeWithSelector(swapSelector, address(usdc), address(0), 100)});
        }
        vm.prank(operator);
        vm.expectRevert(AgentActionRouter.BatchTooLarge.selector);
        router.executeActions(walletAddr, executions);
    }

    function test_Router_IsModuleType() public view {
        assertTrue(router.isModuleType(2));
        assertFalse(router.isModuleType(1));
        assertFalse(router.isModuleType(3));
    }

    // ============ Policy Unit Tests ============

    function test_Policy_AddPolicy_OnlyPolicySetter() public {
        vm.prank(randomUser);
        vm.expectRevert();
        policy.addPolicy(address(target), MockTarget.swap.selector, address(1));
    }

    function test_Policy_AddPolicy_RejectsZeroValidator() public {
        vm.prank(admin);
        vm.expectRevert("Policy: use removePolicy to remove");
        policy.addPolicy(address(target), MockTarget.swap.selector, address(0));
    }

    function test_Policy_RemovePolicy_OnlyEmergencyRole() public {
        vm.prank(admin);
        policy.addPolicy(address(target), MockTarget.swap.selector, address(1));
        vm.prank(randomUser);
        vm.expectRevert();
        policy.removePolicy(address(target), MockTarget.swap.selector);
    }

    function test_Policy_RemovePolicy() public {
        bytes4 swapSelector = MockTarget.swap.selector;
        vm.startPrank(admin);
        policy.addPolicy(address(target), swapSelector, address(1));
        assertEq(policy.functionValidators(address(target), swapSelector), address(1));
        policy.removePolicy(address(target), swapSelector);
        assertEq(policy.functionValidators(address(target), swapSelector), address(0));
        vm.stopPrank();
    }

    function test_Policy_ValidateAction_EmptyCalldata() public {
        vm.prank(admin);
        policy.addPolicy(address(target), bytes4(0), address(1));
        policy.validateAction(user, address(target), 0, "");
    }
}
