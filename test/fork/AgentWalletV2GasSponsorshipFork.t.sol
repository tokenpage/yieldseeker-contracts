// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV2 as AgentWalletV2} from "../../src/AgentWalletV2.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {AWKAgentWalletV1} from "../../src/agentwalletkit/AWKAgentWalletV1.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";
import {Test} from "forge-std/Test.sol";

/// @title Agent Wallet V2 Gas Sponsorship Fork Test
/// @notice Runs against the real, canonical ERC-4337 v0.6 EntryPoint singleton deployed on Base.
///         Demonstrates the actual property the integrator needs, on the real V2 implementation:
///         a relayer that is neither the owner nor an operator can submit and pay for a
///         withdrawal, while only the owner's signature can ever authorize it, and an operator's
///         signature can authorize adapter execution but never a withdrawal.
contract AgentWalletV2GasSponsorshipForkTest is Test {
    using MessageHashUtils for bytes32;

    IEntryPoint internal constant ENTRY_POINT = IEntryPoint(0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789);

    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    ERC4626Adapter vaultAdapter;
    MockERC20 usdc;
    MockERC4626 vault;
    AgentWalletV2 wallet;

    address admin = makeAddr("admin");
    address ownerAddr;
    uint256 ownerKey;
    address operatorAddr;
    uint256 operatorKey;
    address recipient = makeAddr("recipient");
    address relayer = makeAddr("gasSponsoringRelayer");

    function setUp() public {
        if (block.chainid != 8453) vm.skip(true);

        (ownerAddr, ownerKey) = makeAddrAndKey("owner");
        (operatorAddr, operatorKey) = makeAddrAndKey("operator");

        // Base-fork tx execution requires a real gas balance on any pranked sender that makes
        // a state-changing call — unlike a plain in-memory chain. The owner intentionally stays
        // unfunded: proving it never needs native gas is the point of this test.
        vm.deal(admin, 10 ether);
        vm.deal(operatorAddr, 10 ether);
        vm.deal(relayer, 10 ether);

        usdc = new MockERC20("Mock USDC", "mUSDC");
        vault = new MockERC4626(address(usdc), "Mock Vault", "mVault");

        vm.startPrank(admin);
        registry = new AdapterRegistry(admin, admin);
        feeTracker = new FeeTracker(admin);
        feeTracker.setFeeConfig(0, admin);
        factory = new AgentWalletFactory(admin, operatorAddr);
        AgentWalletV2 implementation = new AgentWalletV2(address(factory));
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(feeTracker);
        factory.setAgentWalletImplementation(AWKAgentWalletV1(payable(address(implementation))));
        vaultAdapter = new ERC4626Adapter();
        registry.registerAdapter(address(vaultAdapter));
        registry.setTargetAdapter(address(vault), address(vaultAdapter));
        vm.stopPrank();

        vm.prank(operatorAddr);
        wallet = AgentWalletV2(payable(address(factory.createAgentWallet(ownerAddr, 1, address(usdc)))));

        usdc.mint(address(wallet), 1_000e6);

        // Fund the wallet's own contract balance so it can prefund the EntryPoint directly
        // (BaseAccount._payPrefund) with no EntryPoint deposit and no paymaster required. A
        // paymaster (Coinbase's, or the integrator's own) is an additive, separate choice of
        // *who* funds gas — irrelevant to *who* authorizes the withdrawal.
        vm.deal(address(wallet), 1 ether);
    }

    function test_RelayerSubmitsOwnerSignedWithdrawal_ThirdPartyPaysGas() public {
        assertEq(ownerAddr.balance, 0, "owner must not need native gas to withdraw");

        bytes memory callData = abi.encodeWithSelector(wallet.withdrawAssetToUser.selector, recipient, address(usdc), 500e6);
        UserOperation memory userOp = _buildSignedUserOp(callData, ownerKey);

        UserOperation[] memory ops = new UserOperation[](1);
        ops[0] = userOp;

        uint256 walletBalanceBefore = address(wallet).balance;

        // The relayer — not the owner, not an operator — submits and is compensated for gas.
        vm.txGasPrice(1 gwei);
        vm.prank(relayer);
        ENTRY_POINT.handleOps(ops, payable(relayer));

        assertEq(usdc.balanceOf(recipient), 500e6, "withdrawal must have executed");
        assertEq(ownerAddr.balance, 0, "owner still never spent native gas");
        assertGt(relayer.balance, 0, "relayer must have been compensated for submitting/paying gas");
        assertLt(address(wallet).balance, walletBalanceBefore, "execution cost paid from the wallet's own sponsor-funded balance");
    }

    function test_RelayerCannotSubmitOperatorSignedWithdrawal() public {
        bytes memory callData = abi.encodeWithSelector(wallet.withdrawAssetToUser.selector, recipient, address(usdc), 500e6);
        UserOperation memory userOp = _buildSignedUserOp(callData, operatorKey);

        UserOperation[] memory ops = new UserOperation[](1);
        ops[0] = userOp;

        vm.prank(relayer);
        vm.expectRevert();
        ENTRY_POINT.handleOps(ops, payable(relayer));

        assertEq(usdc.balanceOf(recipient), 0, "operator signature must never authorize a withdrawal");
    }

    function test_RelayerSubmitsOperatorSignedAdapterExecution_Succeeds() public {
        bytes memory depositData = abi.encodeCall(vaultAdapter.deposit, (500e6));
        bytes memory callData = abi.encodeWithSelector(wallet.executeViaAdapter.selector, address(vaultAdapter), address(vault), depositData);
        UserOperation memory userOp = _buildSignedUserOp(callData, operatorKey);

        UserOperation[] memory ops = new UserOperation[](1);
        ops[0] = userOp;

        vm.prank(relayer);
        ENTRY_POINT.handleOps(ops, payable(relayer));

        assertGt(vault.balanceOf(address(wallet)), 0, "operator-authorized adapter execution must still succeed via a relayed UserOp");
    }

    // ============ Helpers ============

    function _buildSignedUserOp(bytes memory callData, uint256 signerKey) internal view returns (UserOperation memory) {
        UserOperation memory userOp = UserOperation({
            sender: address(wallet),
            nonce: ENTRY_POINT.getNonce(address(wallet), 0),
            initCode: "",
            callData: callData,
            callGasLimit: 500000,
            verificationGasLimit: 500000,
            preVerificationGas: 100000,
            maxFeePerGas: 10 gwei,
            maxPriorityFeePerGas: 1 gwei,
            paymasterAndData: "",
            signature: ""
        });
        bytes32 userOpHash = ENTRY_POINT.getUserOpHash(userOp);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, userOpHash.toEthSignedMessageHash());
        userOp.signature = abi.encodePacked(r, s, v);
        return userOp;
    }
}
