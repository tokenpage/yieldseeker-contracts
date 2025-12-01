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

    function setUp() public {
        vm.startPrank(admin);

        // 1. Deploy Implementation
        implementation = new YieldSeekerAgentWallet();

        // 2. Deploy Factory
        factory = new YieldSeekerAgentWalletFactory(address(implementation), admin);

        // 3. Deploy Policy & Router
        policy = new AgentActionPolicy(admin);
        router = new AgentActionRouter(address(policy), admin);
        router.addOperator(operator);

        // 4. Set default executor on factory (Router will be auto-installed)
        factory.setDefaultExecutor(address(router));

        // 5. Deploy Validators
        merklValidator = new MerklValidator();
        zeroExValidator = new ZeroExValidator();

        // 6. Deploy Mocks
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
}
