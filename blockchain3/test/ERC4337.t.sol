// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {YieldSeekerAgentWallet} from "../src/AgentWallet.sol";
import {YieldSeekerAgentWalletFactory} from "../src/AgentWalletFactory.sol";
import {AgentActionRouter} from "../src/modules/AgentActionRouter.sol";
import {AgentActionPolicy} from "../src/modules/AgentActionPolicy.sol";
import {MultiEntryPointAccountERC7579, IEntryPointV06} from "../src/lib/MultiEntryPointAccountERC7579.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {IERC7579Execution} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/draft-ERC4337Utils.sol";
import {ERC7579Utils} from "@openzeppelin/contracts/account/utils/draft-ERC7579Utils.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockTarget} from "./mocks/MockTarget.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

address constant CANONICAL_ENTRYPOINT = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108; // v0.8
address constant ENTRYPOINT_V06 = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;

contract MockEntryPoint {
    function handleOps(PackedUserOperation[] calldata ops, address payable) external {
        for (uint256 i = 0; i < ops.length; i++) {
            PackedUserOperation calldata op = ops[i];
            bytes32 opHash = getUserOpHash(op);
            uint256 validationData = YieldSeekerAgentWallet(payable(op.sender)).validateUserOp(op, opHash, 0);
            require(validationData == 0, "Invalid UserOp");
            (bool success,) = op.sender.call(op.callData);
            require(success, "Execution failed");
        }
    }

    function getUserOpHash(PackedUserOperation calldata userOp) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees,
                keccak256(userOp.paymasterAndData),
                block.chainid,
                address(this)
            )
        );
    }

    function getUserOpHashMemory(PackedUserOperation memory userOp) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.accountGasLimits,
                userOp.preVerificationGas,
                userOp.gasFees,
                keccak256(userOp.paymasterAndData),
                block.chainid,
                address(this)
            )
        );
    }

    receive() external payable {}
}

contract MockEntryPointV06 {
    function handleOps(IEntryPointV06.UserOperation[] calldata ops, address payable) external {
        for (uint256 i = 0; i < ops.length; i++) {
            IEntryPointV06.UserOperation calldata op = ops[i];
            bytes32 opHash = getUserOpHash(op);
            uint256 validationData = YieldSeekerAgentWallet(payable(op.sender)).validateUserOp(op, opHash, 0);
            require(validationData == 0, "Invalid UserOp");
            (bool success,) = op.sender.call(op.callData);
            require(success, "Execution failed");
        }
    }

    function getUserOpHash(IEntryPointV06.UserOperation calldata userOp) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.callGasLimit,
                userOp.verificationGasLimit,
                userOp.preVerificationGas,
                userOp.maxFeePerGas,
                userOp.maxPriorityFeePerGas,
                keccak256(userOp.paymasterAndData),
                block.chainid,
                address(this)
            )
        );
    }

    function getUserOpHashMemory(IEntryPointV06.UserOperation memory userOp) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                userOp.sender,
                userOp.nonce,
                keccak256(userOp.initCode),
                keccak256(userOp.callData),
                userOp.callGasLimit,
                userOp.verificationGasLimit,
                userOp.preVerificationGas,
                userOp.maxFeePerGas,
                userOp.maxPriorityFeePerGas,
                keccak256(userOp.paymasterAndData),
                block.chainid,
                address(this)
            )
        );
    }

    receive() external payable {}
}

contract ERC4337Test is Test {
    YieldSeekerAgentWallet public implementation;
    YieldSeekerAgentWalletFactory public factory;
    AgentActionRouter public router;
    AgentActionPolicy public policy;
    MockERC20 public usdc;
    MockTarget public target;

    address public admin = address(0x1);
    address public user = address(0x2);
    uint256 public operatorPrivateKey = 0x3;
    address public operator;

    function setUp() public {
        operator = vm.addr(operatorPrivateKey);
        MockEntryPoint mockEP = new MockEntryPoint();
        vm.etch(CANONICAL_ENTRYPOINT, address(mockEP).code);
        vm.startPrank(admin);
        implementation = new YieldSeekerAgentWallet();
        factory = new YieldSeekerAgentWalletFactory(address(implementation), admin);
        policy = new AgentActionPolicy(admin);
        router = new AgentActionRouter(address(policy), admin);
        router.addOperator(operator);
        factory.setDefaultExecutor(address(router));
        usdc = new MockERC20("USDC", "USDC");
        target = new MockTarget();
        policy.addPolicy(address(target), MockTarget.swap.selector, address(1));
        vm.stopPrank();
    }

    function entryPoint() internal pure returns (MockEntryPoint) {
        return MockEntryPoint(payable(CANONICAL_ENTRYPOINT));
    }

    function test_FullFlow_UserOpWithPolicyValidation() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        bytes memory swapData = abi.encodeWithSelector(MockTarget.swap.selector, address(usdc), address(0), 100);
        bytes memory routerCall = abi.encodeCall(router.executeAction, (walletAddr, address(target), 0, swapData));
        bytes memory executionCalldata = abi.encodePacked(address(router), uint256(0), routerCall);
        bytes memory callData = abi.encodeCall(IERC7579Execution.execute, (bytes32(0), executionCalldata));
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: walletAddr, nonce: 0, initCode: "", callData: callData, accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0), paymasterAndData: "", signature: ""
        });
        bytes32 userOpHash = entryPoint().getUserOpHashMemory(userOp);
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, ethSignedHash);
        userOp.signature = abi.encodePacked(r, s, v);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        entryPoint().handleOps(ops, payable(admin));
    }

    function test_FullFlow_UserOpBlockedByPolicy() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        bytes4 unauthorizedSelector = bytes4(keccak256("unauthorizedMethod()"));
        bytes memory callData = abi.encodeCall(router.executeAction, (walletAddr, address(target), 0, abi.encodeWithSelector(unauthorizedSelector)));
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: walletAddr, nonce: 0, initCode: "", callData: callData, accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0), paymasterAndData: "", signature: ""
        });
        bytes32 userOpHash = entryPoint().getUserOpHashMemory(userOp);
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, ethSignedHash);
        userOp.signature = abi.encodePacked(r, s, v);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.expectRevert("Execution failed");
        entryPoint().handleOps(ops, payable(admin));
    }

    function test_ValidateUserOp_InvalidSigner() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        bytes memory swapData = abi.encodeWithSelector(MockTarget.swap.selector, address(usdc), address(0), 100);
        bytes memory callData = abi.encodeCall(router.executeAction, (walletAddr, address(target), 0, swapData));
        PackedUserOperation memory userOp = PackedUserOperation({
            sender: walletAddr, nonce: 0, initCode: "", callData: callData, accountGasLimits: bytes32(0), preVerificationGas: 0, gasFees: bytes32(0), paymasterAndData: "", signature: ""
        });
        uint256 wrongPrivateKey = 0x999;
        bytes32 userOpHash = entryPoint().getUserOpHashMemory(userOp);
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, ethSignedHash);
        userOp.signature = abi.encodePacked(r, s, v);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.expectRevert("Invalid UserOp");
        entryPoint().handleOps(ops, payable(admin));
    }

    function test_EntryPoint_Constants() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        assertEq(wallet.ENTRY_POINT_V06(), 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789);
        assertEq(wallet.ENTRY_POINT_V07(), 0x0000000071727De22E5E9d8BAf0edAc6f37da032);
        assertEq(wallet.ENTRY_POINT_V08(), 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108);
    }

    function test_EntryPoint_ReturnsV08() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        assertEq(address(wallet.entryPoint()), 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108);
    }
}

contract ERC4337V06Test is Test {
    YieldSeekerAgentWallet public implementation;
    YieldSeekerAgentWalletFactory public factory;
    AgentActionRouter public router;
    AgentActionPolicy public policy;
    MockERC20 public usdc;
    MockTarget public target;

    address public admin = address(0x1);
    address public user = address(0x2);
    uint256 public operatorPrivateKey = 0x3;
    address public operator;

    function setUp() public {
        operator = vm.addr(operatorPrivateKey);
        MockEntryPointV06 mockEPV06 = new MockEntryPointV06();
        vm.etch(ENTRYPOINT_V06, address(mockEPV06).code);
        vm.startPrank(admin);
        implementation = new YieldSeekerAgentWallet();
        factory = new YieldSeekerAgentWalletFactory(address(implementation), admin);
        policy = new AgentActionPolicy(admin);
        router = new AgentActionRouter(address(policy), admin);
        router.addOperator(operator);
        factory.setDefaultExecutor(address(router));
        usdc = new MockERC20("USDC", "USDC");
        target = new MockTarget();
        policy.addPolicy(address(target), MockTarget.swap.selector, address(1));
        vm.stopPrank();
    }

    function entryPointV06() internal pure returns (MockEntryPointV06) {
        return MockEntryPointV06(payable(ENTRYPOINT_V06));
    }

    function test_V06_FullFlow_UserOpWithPolicyValidation() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        bytes memory swapData = abi.encodeWithSelector(MockTarget.swap.selector, address(usdc), address(0), 100);
        bytes memory routerCall = abi.encodeCall(router.executeAction, (walletAddr, address(target), 0, swapData));
        bytes memory executionCalldata = abi.encodePacked(address(router), uint256(0), routerCall);
        bytes memory callData = abi.encodeCall(IERC7579Execution.execute, (bytes32(0), executionCalldata));
        IEntryPointV06.UserOperation memory userOp = IEntryPointV06.UserOperation({
            sender: walletAddr,
            nonce: 0,
            initCode: "",
            callData: callData,
            callGasLimit: 1000000,
            verificationGasLimit: 1000000,
            preVerificationGas: 100000,
            maxFeePerGas: 1 gwei,
            maxPriorityFeePerGas: 1 gwei,
            paymasterAndData: "",
            signature: ""
        });
        bytes32 userOpHash = entryPointV06().getUserOpHashMemory(userOp);
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(operatorPrivateKey, ethSignedHash);
        userOp.signature = abi.encodePacked(r, s, v);
        IEntryPointV06.UserOperation[] memory ops = new IEntryPointV06.UserOperation[](1);
        ops[0] = userOp;
        entryPointV06().handleOps(ops, payable(admin));
    }

    function test_V06_InvalidSigner() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        bytes memory swapData = abi.encodeWithSelector(MockTarget.swap.selector, address(usdc), address(0), 100);
        bytes memory routerCall = abi.encodeCall(router.executeAction, (walletAddr, address(target), 0, swapData));
        bytes memory executionCalldata = abi.encodePacked(address(router), uint256(0), routerCall);
        bytes memory callData = abi.encodeCall(IERC7579Execution.execute, (bytes32(0), executionCalldata));
        IEntryPointV06.UserOperation memory userOp = IEntryPointV06.UserOperation({
            sender: walletAddr,
            nonce: 0,
            initCode: "",
            callData: callData,
            callGasLimit: 1000000,
            verificationGasLimit: 1000000,
            preVerificationGas: 100000,
            maxFeePerGas: 1 gwei,
            maxPriorityFeePerGas: 1 gwei,
            paymasterAndData: "",
            signature: ""
        });
        uint256 wrongPrivateKey = 0x999;
        bytes32 userOpHash = entryPointV06().getUserOpHashMemory(userOp);
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongPrivateKey, ethSignedHash);
        userOp.signature = abi.encodePacked(r, s, v);
        IEntryPointV06.UserOperation[] memory ops = new IEntryPointV06.UserOperation[](1);
        ops[0] = userOp;
        vm.expectRevert("Invalid UserOp");
        entryPointV06().handleOps(ops, payable(admin));
    }

    function test_V06_OnlyEntryPointCanCall() public {
        vm.prank(admin);
        address walletAddr = factory.createAgentWallet(user, 0, address(usdc));
        YieldSeekerAgentWallet wallet = YieldSeekerAgentWallet(payable(walletAddr));
        IEntryPointV06.UserOperation memory userOp = IEntryPointV06.UserOperation({
            sender: walletAddr,
            nonce: 0,
            initCode: "",
            callData: "",
            callGasLimit: 0,
            verificationGasLimit: 0,
            preVerificationGas: 0,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymasterAndData: "",
            signature: ""
        });
        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(MultiEntryPointAccountERC7579.MultiEntryPoint__NotAuthorized.selector, user));
        wallet.validateUserOp(userOp, bytes32(0), 0);
    }
}
