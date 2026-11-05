// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {YieldSeekerERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IPackedEntryPoint {
    error FailedOp(uint256 opIndex, string reason);

    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;
    function getUserOpHash(PackedUserOperation calldata userOp) external view returns (bytes32);
    function getNonce(address sender, uint192 key) external view returns (uint256);
}

/// @notice Operator and owner UserOperations run through the real v0.7, v0.8 and v0.9 EntryPoints on Base
contract PackedEntryPointsForkTest is ForkBase {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant STEAKHOUSE_USDC = 0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183;
    address internal constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address internal constant ENTRY_POINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    uint256 internal constant DEPOSIT_AMOUNT = 1_000e6;

    YieldSeekerERC4626Adapter internal adapter;
    address internal signingOperator;
    uint256 internal signingOperatorKey;
    uint256 internal ownerKey;

    function setUp() public override {
        super.setUp();
        (owner, ownerKey) = makeAddrAndKey("packed owner");
        (signingOperator, signingOperatorKey) = makeAddrAndKey("packed operator");
        factory.grantRole(factory.AGENT_OPERATOR_ROLE(), signingOperator);
        adapter = new YieldSeekerERC4626Adapter();
        _registerAdapter(address(adapter), STEAKHOUSE_USDC);
    }

    function test_V07OperatorDepositsAndOwnerWithdraws() public {
        _runThrough(IPackedEntryPoint(ENTRY_POINT_V07), 0);
    }

    function test_V08OperatorDepositsAndOwnerWithdraws() public {
        _runThrough(IPackedEntryPoint(ENTRY_POINT_V08), 1);
    }

    function test_V09OperatorDepositsAndOwnerWithdraws() public {
        _runThrough(IPackedEntryPoint(ENTRY_POINT_V09), 2);
    }

    function _runThrough(IPackedEntryPoint entryPoint, uint256 index) internal {
        AgentWallet wallet = _createVaultWallet(USDC, index);
        deal(USDC, address(wallet), DEPOSIT_AMOUNT + 1);
        vm.deal(address(wallet), 1 ether);
        address recipient = makeAddr("recipient");
        (, uint256 strangerKey) = makeAddrAndKey("stranger");

        PackedUserOperation memory deposit = _userOp(entryPoint, wallet, abi.encodeCall(wallet.executeViaAdapter, (address(adapter), STEAKHOUSE_USDC, abi.encodeCall(adapter.deposit, (DEPOSIT_AMOUNT)))));
        deposit.signature = _sign(entryPoint, deposit, strangerKey);
        vm.expectRevert(abi.encodeWithSelector(IPackedEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        _handleOp(entryPoint, deposit);

        deposit.signature = _sign(entryPoint, deposit, signingOperatorKey);
        _handleOp(entryPoint, deposit);
        assertGt(IERC20(STEAKHOUSE_USDC).balanceOf(address(wallet)), 0);
        assertEq(IERC20(USDC).balanceOf(address(wallet)), 1);

        PackedUserOperation memory withdraw = _userOp(entryPoint, wallet, abi.encodeCall(wallet.withdrawAssetToUser, (recipient, USDC, 1)));
        withdraw.signature = _sign(entryPoint, withdraw, signingOperatorKey);
        vm.expectRevert(abi.encodeWithSelector(IPackedEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        _handleOp(entryPoint, withdraw);

        withdraw.signature = _sign(entryPoint, withdraw, ownerKey);
        _handleOp(entryPoint, withdraw);
        assertEq(IERC20(USDC).balanceOf(recipient), 1);
    }

    function _userOp(IPackedEntryPoint entryPoint, AgentWallet wallet, bytes memory callData) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: address(wallet),
            nonce: entryPoint.getNonce(address(wallet), 0),
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32((uint256(500_000) << 128) | 1_000_000),
            preVerificationGas: 100_000,
            gasFees: bytes32((uint256(1 gwei) << 128) | 1 gwei),
            paymasterAndData: "",
            signature: ""
        });
    }

    function _sign(IPackedEntryPoint entryPoint, PackedUserOperation memory userOp, uint256 key) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, MessageHashUtils.toEthSignedMessageHash(entryPoint.getUserOpHash(userOp)));
        return abi.encodePacked(r, s, v);
    }

    function _handleOp(IPackedEntryPoint entryPoint, PackedUserOperation memory userOp) internal {
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        vm.prank(makeAddr("bundler"), makeAddr("bundler"));
        entryPoint.handleOps(userOps, payable(makeAddr("bundler")));
    }
}
