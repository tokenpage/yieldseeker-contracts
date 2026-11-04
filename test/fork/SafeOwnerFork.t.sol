// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {FeePlanChoice} from "../../src/fees/FeeTracker.sol";
import {ForkBase} from "./ForkBase.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";

interface ISafeProxyFactory {
    function createProxyWithNonce(address singleton, bytes memory initializer, uint256 saltNonce) external returns (address proxy);
}

interface ISafe {
    function setup(address[] calldata owners, uint256 threshold, address to, bytes calldata data, address fallbackHandler, address paymentToken, uint256 payment, address payable paymentReceiver) external;
    function getMessageHash(bytes memory message) external view returns (bytes32);
}

/// @notice A wallet owned by a real Safe (v1.4.1, the version of the YieldSeeker multisig) runs an owner action from a
///         UserOperation signed by the Safe's owner, through the real EntryPoint
contract SafeOwnerForkTest is ForkBase {
    address internal constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address internal constant ENTRY_POINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    address internal constant SAFE_PROXY_FACTORY = 0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67;
    address internal constant SAFE_SINGLETON = 0x29fcB43b46531BcA003ddC8FCB67FFE91900C762;
    address internal constant SAFE_FALLBACK_HANDLER = 0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99;

    function test_SafeOwnedWalletWithdrawsThroughEntryPointWithSafeSignature() public {
        (address safeSigner, uint256 safeSignerKey) = makeAddrAndKey("safe signer");
        (, uint256 strangerKey) = makeAddrAndKey("stranger");
        address safe = _deploySafe(safeSigner);
        vm.prank(operator);
        AgentWallet wallet = factory.createAgentWallet(safe, 0, USDC, VAULT_AGENT_PROFILE, new FeePlanChoice[](0));
        uint256 amount = 100e6;
        deal(USDC, address(wallet), amount);
        vm.deal(address(wallet), 1 ether);
        address recipient = makeAddr("recipient");
        UserOperation memory userOp = _userOp(wallet, abi.encodeCall(wallet.withdrawAssetToUser, (recipient, USDC, amount)));
        bytes32 userOpHash = IEntryPoint(ENTRY_POINT).getUserOpHash(userOp);

        userOp.signature = _safeSignature(safe, strangerKey, userOpHash);
        vm.expectRevert(abi.encodeWithSelector(IEntryPoint.FailedOp.selector, 0, "AA24 signature error"));
        _handleOp(userOp);

        userOp.signature = _safeSignature(safe, safeSignerKey, userOpHash);
        _handleOp(userOp);
        assertEq(IERC20(USDC).balanceOf(recipient), amount);
        assertEq(IERC20(USDC).balanceOf(address(wallet)), 0);
    }

    function _deploySafe(address signer) internal returns (address) {
        address[] memory owners = new address[](1);
        owners[0] = signer;
        bytes memory setup = abi.encodeCall(ISafe.setup, (owners, 1, address(0), "", SAFE_FALLBACK_HANDLER, address(0), 0, payable(address(0))));
        return ISafeProxyFactory(SAFE_PROXY_FACTORY).createProxyWithNonce(SAFE_SINGLETON, setup, uint256(keccak256("yieldseeker safe owner fork test")));
    }

    function _userOp(AgentWallet wallet, bytes memory callData) internal view returns (UserOperation memory) {
        return UserOperation({
            sender: address(wallet),
            nonce: IEntryPoint(ENTRY_POINT).getNonce(address(wallet), 0),
            initCode: "",
            callData: callData,
            callGasLimit: 500_000,
            verificationGasLimit: 500_000,
            preVerificationGas: 100_000,
            maxFeePerGas: 1 gwei,
            maxPriorityFeePerGas: 1 gwei,
            paymasterAndData: "",
            signature: ""
        });
    }

    /// @dev The Safe checks its owners' signatures over its SafeMessage hash of the hash the wallet asks about
    function _safeSignature(address safe, uint256 signerKey, bytes32 userOpHash) internal view returns (bytes memory) {
        bytes32 safeMessageHash = ISafe(safe).getMessageHash(abi.encode(MessageHashUtils.toEthSignedMessageHash(userOpHash)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, safeMessageHash);
        return abi.encodePacked(r, s, v);
    }

    function _handleOp(UserOperation memory userOp) internal {
        UserOperation[] memory userOps = new UserOperation[](1);
        userOps[0] = userOp;
        IEntryPoint(ENTRY_POINT).handleOps(userOps, payable(makeAddr("bundler")));
    }
}
