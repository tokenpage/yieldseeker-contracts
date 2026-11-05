// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {YieldSeekerERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {FeePlanChoice} from "../../src/fees/FeeTracker.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {ISafe, ISafeProxyFactory} from "./SafeOwnerFork.t.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IPackedEntryPoint {
    error FailedOp(uint256 opIndex, string reason);

    function handleOps(PackedUserOperation[] calldata ops, address payable beneficiary) external;
    function getUserOpHash(PackedUserOperation calldata userOp) external view returns (bytes32);
    function getNonce(address sender, uint192 key) external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Operator, owner and Safe-owner UserOperations run through the real v0.7, v0.8 and v0.9 EntryPoints on Base
contract PackedEntryPointsForkTest is ForkBase {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant STEAKHOUSE_USDC = 0xbeeF010f9cb27031ad51e3333f9aF9C6B1228183;
    address internal constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address internal constant ENTRY_POINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;
    address internal constant ENTRY_POINT_V09 = 0x433709009B8330FDa32311DF1C2AFA402eD8D009;
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;
    uint256 internal constant DEPOSIT_AMOUNT = 600e6;
    uint256 internal constant BATCH_DEPOSIT_AMOUNT = 200e6;

    YieldSeekerERC4626Adapter internal adapter;
    address internal signingOperator;
    uint256 internal signingOperatorKey;
    uint256 internal ownerKey;
    address internal recipient = makeAddr("recipient");

    function setUp() public override {
        super.setUp();
        (owner, ownerKey) = makeAddrAndKey("packed owner");
        (signingOperator, signingOperatorKey) = makeAddrAndKey("packed operator");
        factory.grantRole(factory.AGENT_OPERATOR_ROLE(), signingOperator);
        adapter = new YieldSeekerERC4626Adapter();
        _registerAdapter(address(adapter), STEAKHOUSE_USDC);
    }

    function test_V07OperatorAndOwnerUserOperations() public {
        _runOperatorAndOwner(IPackedEntryPoint(ENTRY_POINT_V07), IPackedEntryPoint(ENTRY_POINT_V09));
    }

    function test_V08OperatorAndOwnerUserOperations() public {
        _runOperatorAndOwner(IPackedEntryPoint(ENTRY_POINT_V08), IPackedEntryPoint(ENTRY_POINT_V07));
    }

    function test_V09OperatorAndOwnerUserOperations() public {
        _runOperatorAndOwner(IPackedEntryPoint(ENTRY_POINT_V09), IPackedEntryPoint(ENTRY_POINT_V08));
    }

    function test_V07SafeOwnerUserOperation() public {
        _runSafeOwner(IPackedEntryPoint(ENTRY_POINT_V07));
    }

    function test_V08SafeOwnerUserOperation() public {
        _runSafeOwner(IPackedEntryPoint(ENTRY_POINT_V08));
    }

    function test_V09SafeOwnerUserOperation() public {
        _runSafeOwner(IPackedEntryPoint(ENTRY_POINT_V09));
    }

    function _runOperatorAndOwner(IPackedEntryPoint entryPoint, IPackedEntryPoint otherEntryPoint) internal {
        AgentWallet wallet = _createVaultWallet(USDC, 0);
        deal(USDC, address(wallet), DEPOSIT_AMOUNT + 2 * BATCH_DEPOSIT_AMOUNT + 1);
        vm.deal(address(wallet), 1 ether);
        (, uint256 strangerKey) = makeAddrAndKey("stranger");

        PackedUserOperation memory deposit = _userOp(entryPoint, address(wallet), abi.encodeCall(wallet.executeViaAdapter, (address(adapter), STEAKHOUSE_USDC, abi.encodeCall(adapter.deposit, (DEPOSIT_AMOUNT)))));
        deposit.signature = _sign(entryPoint, deposit, strangerKey);
        _expectFailedOp(entryPoint, deposit, "AA24 signature error");
        deposit.signature = _sign(otherEntryPoint, deposit, signingOperatorKey);
        _expectFailedOp(entryPoint, deposit, "AA24 signature error");

        deposit.signature = _sign(entryPoint, deposit, signingOperatorKey);
        _handleOp(entryPoint, deposit);
        assertEq(IERC20(USDC).balanceOf(address(wallet)), 2 * BATCH_DEPOSIT_AMOUNT + 1);
        assertGt(entryPoint.balanceOf(address(wallet)), 0, "wallet paid its own prefund");
        _expectFailedOp(entryPoint, deposit, "AA25 invalid account nonce");

        address[] memory adapters = new address[](2);
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](2);
        for (uint256 i; i < 2; ++i) {
            adapters[i] = address(adapter);
            targets[i] = STEAKHOUSE_USDC;
            datas[i] = abi.encodeCall(adapter.deposit, (BATCH_DEPOSIT_AMOUNT));
        }
        PackedUserOperation memory batch = _userOp(entryPoint, address(wallet), abi.encodeCall(wallet.executeViaAdapterBatch, (adapters, targets, datas)));
        batch.signature = _sign(entryPoint, batch, signingOperatorKey);
        _handleOp(entryPoint, batch);
        assertEq(IERC20(USDC).balanceOf(address(wallet)), 1);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), STEAKHOUSE_USDC), DEPOSIT_AMOUNT + 2 * BATCH_DEPOSIT_AMOUNT);

        PackedUserOperation memory withdraw = _userOp(entryPoint, address(wallet), abi.encodeCall(wallet.withdrawAssetToUser, (recipient, USDC, 1)));
        withdraw.signature = _sign(entryPoint, withdraw, signingOperatorKey);
        _expectFailedOp(entryPoint, withdraw, "AA24 signature error");
        withdraw.signature = _sign(entryPoint, withdraw, ownerKey);
        _handleOp(entryPoint, withdraw);
        assertEq(IERC20(USDC).balanceOf(recipient), 1);
    }

    function _runSafeOwner(IPackedEntryPoint entryPoint) internal {
        (address safeSigner, uint256 safeSignerKey) = makeAddrAndKey("safe signer");
        (, uint256 strangerKey) = makeAddrAndKey("stranger");
        address safe = _deploySafe(safeSigner);
        vm.prank(operator);
        AgentWallet wallet = factory.createAgentWallet(safe, 0, USDC, VAULT_AGENT_PROFILE, new FeePlanChoice[](0));
        deal(USDC, address(wallet), 100e6);
        vm.deal(address(wallet), 1 ether);

        PackedUserOperation memory withdraw = _userOp(entryPoint, address(wallet), abi.encodeCall(wallet.withdrawAssetToUser, (recipient, USDC, 100e6)));
        withdraw.signature = _safeSignature(safe, strangerKey, entryPoint.getUserOpHash(withdraw));
        _expectFailedOp(entryPoint, withdraw, "AA24 signature error");
        withdraw.signature = _safeSignature(safe, safeSignerKey, entryPoint.getUserOpHash(withdraw));
        _handleOp(entryPoint, withdraw);
        assertEq(IERC20(USDC).balanceOf(recipient), 100e6);
    }

    function _userOp(IPackedEntryPoint entryPoint, address sender, bytes memory callData) internal view returns (PackedUserOperation memory) {
        return PackedUserOperation({
            sender: sender,
            nonce: entryPoint.getNonce(sender, 0),
            initCode: "",
            callData: callData,
            accountGasLimits: bytes32((uint256(500_000) << 128) | 1_500_000),
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

    function _deploySafe(address signer) internal returns (address) {
        address[] memory owners = new address[](1);
        owners[0] = signer;
        bytes memory setup = abi.encodeCall(ISafe.setup, (owners, 1, address(0), "", SAFE_FALLBACK_HANDLER, address(0), 0, payable(address(0))));
        return ISafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_SINGLETON, setup, uint256(keccak256("yieldseeker packed entrypoint fork test")));
    }

    function _safeSignature(address safe, uint256 signerKey, bytes32 userOpHash) internal view returns (bytes memory) {
        bytes32 safeMessageHash = ISafe(safe).getMessageHash(abi.encode(MessageHashUtils.toEthSignedMessageHash(userOpHash)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, safeMessageHash);
        return abi.encodePacked(r, s, v);
    }

    function _expectFailedOp(IPackedEntryPoint entryPoint, PackedUserOperation memory userOp, string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(IPackedEntryPoint.FailedOp.selector, 0, reason));
        _handleOp(entryPoint, userOp);
    }

    function _handleOp(IPackedEntryPoint entryPoint, PackedUserOperation memory userOp) internal {
        PackedUserOperation[] memory userOps = new PackedUserOperation[](1);
        userOps[0] = userOp;
        vm.prank(makeAddr("bundler"), makeAddr("bundler"));
        entryPoint.handleOps(userOps, payable(makeAddr("bundler")));
    }
}
