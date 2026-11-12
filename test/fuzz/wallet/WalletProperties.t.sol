// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../../src/AgentWalletFactory.sol";
import {InvalidAsset, InvalidFeeTracker, YieldSeekerAgentWalletV3 as AgentWallet} from "../../../src/AgentWalletV3.sol";
import {AssetNotAllowed} from "../../../src/adapters/Adapter.sol";
import {InvalidTransferTarget, NotOwnersAgentWallet, YieldSeekerAgentTransferAdapter as AgentTransferAdapter} from "../../../src/adapters/AgentTransferAdapter.sol";
import {UnknownOperation} from "../../../src/agentwalletkit/AWKAdapter.sol";
import {AgentAlreadyExists, InvalidImplementationFactory, NoAgentWalletImplementationSet, TooManyOperators, UnknownAgentProfile} from "../../../src/agentwalletkit/AWKAgentWalletFactory.sol";
import {InvalidRegistry, InvalidState} from "../../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "../../../src/agentwalletkit/AWKErrors.sol";
import {IAWKAdapter} from "../../../src/agentwalletkit/IAWKAdapter.sol";
import {InvalidPercentage} from "../../../src/agentwalletkit/adapters/AWKBaseVaultAdapter.sol";
import {MarketTargetMismatch} from "../../../src/agentwalletkit/adapters/AWKLendingAdapter.sol";
import {FeePlanChoice} from "../../../src/fees/FeeTracker.sol";
import {IntegrationBase} from "../../integration/IntegrationBase.t.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockERC4626} from "../../mocks/MockERC4626.sol";
import {BlockedRecipientMockERC20, RejectingFeeCollector} from "./mocks/BlockedRecipientMockERC20.sol";
import {HostileFeeModule} from "./mocks/HostileFeeModule.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/IERC4337.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";

interface IWalletV06Validation {
    function validateUserOp(UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) external returns (uint256);
}

interface IWalletPackedValidation {
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) external returns (uint256);
}

contract PairProbeAdapter is IAWKAdapter {
    function execute(address target, bytes calldata data) external payable override returns (bytes memory) {
        return abi.encode(target, data);
    }
}

contract AgentTransferSpoofWallet {
    address private immutable _owner;
    uint256 private immutable _index;

    constructor(address walletOwner, uint256 index) {
        _owner = walletOwner;
        _index = index;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function ownerAgentIndex() external view returns (uint256) {
        return _index;
    }
}

contract CallOtherWalletAdapter is IAWKAdapter {
    function execute(address, bytes calldata data) external payable override returns (bytes memory result) {
        (address wallet, bytes memory callData) = abi.decode(data, (address, bytes));
        (bool success, bytes memory returnData) = wallet.call(callData);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        return returnData;
    }
}

contract WalletPropertiesTest is IntegrationBase {
    using MessageHashUtils for bytes32;

    address private constant ENTRY_POINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    uint256 private constant OWNER_KEY = 1;
    uint256 private constant OPERATOR_KEY = 2;
    uint256 private constant SIG_VALIDATION_SUCCESS = 0;
    uint256 private constant SIG_VALIDATION_FAILED = 1;

    function testFuzz_onlyOwnerOrSponsoredOperatorAdapterCallsPassSignatureValidation(bytes4 selector, bytes32 randomCallData, uint8 paymasterChoice, uint256 randomKeySeed) public {
        paymasterChoice = uint8(bound(paymasterChoice, 0, 2));
        uint256 randomKey = bound(randomKeySeed, 3, 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364140 - 1);
        address walletOwner = vm.addr(OWNER_KEY);
        address currentOperator = vm.addr(OPERATOR_KEY);
        factory.grantRole(factory.AGENT_OPERATOR_ROLE(), currentOperator);
        AgentWallet wallet = _createVaultWallet(walletOwner, 701);
        bytes memory callData = abi.encodePacked(selector, randomCallData);
        bytes memory paymaster = _paymasterData(paymasterChoice);
        bytes32 userOpHash = keccak256(abi.encode(callData, randomCallData, paymasterChoice));

        assertEq(_validateUserOp(wallet, callData, paymaster, userOpHash, OWNER_KEY), SIG_VALIDATION_SUCCESS);

        bool adapterCall = selector == wallet.executeViaAdapter.selector || selector == wallet.executeViaAdapterBatch.selector;
        uint256 operatorExpected = adapterCall && paymasterChoice == 2 ? SIG_VALIDATION_SUCCESS : SIG_VALIDATION_FAILED;
        assertEq(_validateUserOp(wallet, callData, paymaster, userOpHash, OPERATOR_KEY), operatorExpected);
        assertEq(_validateUserOp(wallet, callData, paymaster, userOpHash, randomKey), SIG_VALIDATION_FAILED);
    }

    /// @notice Public sync and the receive hook intentionally stay open.
    function testFuzz_attackerCannotCallAnyPrivilegedWalletFunction(address attacker) public {
        AgentWallet wallet = _createVaultWallet(owner, 702);
        vm.assume(attacker != address(0) && attacker != owner && attacker != operator);
        vm.assume(!wallet.isEntryPoint(attacker) && !wallet.isAgentOperator(attacker));

        bytes[] memory calls = new bytes[](20);
        calls[0] = abi.encodeCall(wallet.blockAdapter, (address(erc4626Adapter)));
        calls[1] = abi.encodeCall(wallet.unblockAdapter, (address(erc4626Adapter)));
        calls[2] = abi.encodeCall(wallet.blockTarget, (address(erc4626Vault)));
        calls[3] = abi.encodeCall(wallet.unblockTarget, (address(erc4626Vault)));
        calls[4] = abi.encodeCall(wallet.upgradeToLatest, ());
        calls[5] = abi.encodeWithSignature("upgradeToAndCall(address,bytes)", address(walletImplementation), bytes(""));
        calls[6] = abi.encodeCall(wallet.withdrawAssetToUser, (attacker, address(usdc), 1));
        calls[7] = abi.encodeCall(wallet.withdrawAllAssetToUser, (attacker, address(usdc)));
        calls[8] = abi.encodeCall(wallet.withdrawAssetsToUser, (attacker, new address[](0), new uint256[](0)));
        calls[9] = abi.encodeCall(wallet.withdrawAllAssetsToUser, (attacker, new address[](0)));
        calls[10] = abi.encodeCall(wallet.withdrawEthToUser, (attacker, 1));
        calls[11] = abi.encodeCall(wallet.withdrawAllEthToUser, (attacker));
        calls[12] = abi.encodeCall(wallet.executeViaAdapter, (address(erc4626Adapter), address(erc4626Vault), bytes("")));
        calls[13] = abi.encodeCall(wallet.executeViaAdapterBatch, (new address[](0), new address[](0), new bytes[](0)));
        calls[14] = abi.encodeWithSignature("execute(address,uint256,bytes)", address(usdc), 0, bytes(""));
        calls[15] = abi.encodeWithSignature("executeBatch(address[],bytes[])", new address[](0), new bytes[](0));
        calls[16] = abi.encodeCall(wallet.settleFeesForWithdrawal, (address(usdc), attacker, 1));
        calls[17] = abi.encodeWithSignature("initialize(address,uint256,address,bytes32)", owner, 702, address(usdc), VAULT_AGENT_PROFILE);
        calls[18] = abi.encodeWithSignature("initialize(address,uint256,bytes32)", owner, 702, VAULT_AGENT_PROFILE);

        UserOperation memory userOp = _emptyUserOp(wallet);
        calls[19] = abi.encodeCall(IWalletV06Validation.validateUserOp, (userOp, bytes32(0), 0));
        for (uint256 i; i < calls.length; ++i) {
            _assertCallReverts(wallet, attacker, calls[i]);
        }

        PackedUserOperation memory packedUserOp;
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(IWalletPackedValidation.validateUserOp, (packedUserOp, bytes32(0), 0));
        _assertCallReverts(wallet, attacker, calls[0]);

        vm.prank(attacker);
        wallet.syncFromFactory();
        assertTrue(wallet.isAgentOperator(operator));

        vm.deal(attacker, 1);
        vm.prank(attacker);
        (bool received,) = address(wallet).call{value: 1}("");
        assertTrue(received);
    }

    function testFuzz_ownerCanWithdrawEverythingWhenAFeeModuleIsHostile(uint8 behaviorSeed) public {
        HostileFeeModule.Behavior behavior = HostileFeeModule.Behavior(uint8(bound(behaviorSeed, 1, 3)));
        AgentWallet wallet = _createBorrowWallet(owner, 703);
        uint256 feeOwed = _accrueBorrowFees(wallet, 100e6, 1e18);
        uint256 withdrawalBalance = feeOwed + 10e6;
        _fundWallet(wallet, address(usdc), withdrawalBalance);
        bytes32 feeType = keccak256(abi.encode("property8-hostile-module", uint8(behavior)));
        HostileFeeModule hostile = new HostileFeeModule(address(borrowFeeTracker), feeType, behavior, 0);
        borrowFeeTracker.setFeeModule(feeType, hostile);
        uint256 ownerBalanceBefore = usdc.balanceOf(owner);

        vm.expectEmit(false, false, false, true, address(wallet));
        emit AgentWallet.FeeSettlementFailed(address(usdc), withdrawalBalance);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));

        assertEq(usdc.balanceOf(owner) - ownerBalanceBefore, withdrawalBalance);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), feeOwed);
    }

    function testFuzz_ownerCanWithdrawEverythingWhenTheFeeCollectorRejectsPayment(uint96 extraBalanceSeed) public {
        AgentWallet wallet = _createBorrowWallet(owner, 714);
        uint256 feeOwed = _accrueBorrowFees(wallet, 100e6, 1e18);
        uint256 extraBalance = bound(extraBalanceSeed, 0, 100e6);
        uint256 withdrawalBalance = feeOwed + extraBalance;
        _fundWallet(wallet, address(usdc), withdrawalBalance);

        RejectingFeeCollector rejectingCollector = new RejectingFeeCollector();
        BlockedRecipientMockERC20 tokenImplementation = new BlockedRecipientMockERC20();
        vm.etch(address(usdc), address(tokenImplementation).code);
        BlockedRecipientMockERC20(address(usdc)).setBlockedRecipient(address(rejectingCollector));
        borrowFeeTracker.setFeeCollector(address(rejectingCollector));
        uint256 ownerBalanceBefore = usdc.balanceOf(owner);

        vm.expectEmit(false, false, false, true, address(wallet));
        emit AgentWallet.FeeSettlementFailed(address(usdc), withdrawalBalance);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));

        assertEq(usdc.balanceOf(owner) - ownerBalanceBefore, withdrawalBalance);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(rejectingCollector)), 0);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), feeOwed);
    }

    function testFuzz_withdrawableBalanceIsBalanceLessFeesOwed(address walletOwner, uint128 rawBalance, uint128 rawOwed) public {
        walletOwner = _nonzero(walletOwner);
        AgentWallet wallet = _createVaultWallet(walletOwner, 704);
        uint256 balance = rawBalance;
        uint256 owed = rawOwed;
        _fundWallet(wallet, address(usdc), balance);
        bytes32 feeType = keccak256("property9-fixed-owed");
        HostileFeeModule owedModule = new HostileFeeModule(address(vaultFeeTracker), feeType, HostileFeeModule.Behavior.None, owed);
        vaultFeeTracker.setFeeModule(feeType, owedModule);

        uint256 withdrawable = wallet.withdrawableBalance(address(usdc));
        assertLe(withdrawable, balance);
        assertEq(withdrawable, balance > owed ? balance - owed : 0);

        MockERC20 unrelated = new MockERC20("Unaccounted", "NOPE");
        _fundWallet(wallet, address(unrelated), 1);
        assertEq(wallet.withdrawableBalance(address(unrelated)), 0);
    }

    function testFuzz_onlyRegisteredUnblockedUnpausedAdapterTargetPairsExecute(address registeredTargetSeed, address candidateTarget, bool useRegisteredAdapter, bool blockAdapter, bool blockTarget, bool pauseRegistry) public {
        PairProbeAdapter registeredAdapter = new PairProbeAdapter();
        PairProbeAdapter otherAdapter = new PairProbeAdapter();
        address registeredTarget = _nonzero(registeredTargetSeed);
        address candidateAdapter = useRegisteredAdapter ? address(registeredAdapter) : address(otherAdapter);
        vaultRegistry.registerAdapter(address(registeredAdapter));
        vaultRegistry.setTargetAdapter(registeredTarget, address(registeredAdapter));
        AgentWallet wallet = _createVaultWallet(owner, 705);

        if (blockAdapter) {
            vm.prank(owner);
            wallet.blockAdapter(candidateAdapter);
        }
        if (blockTarget) {
            vm.prank(owner);
            wallet.blockTarget(candidateTarget);
        }
        if (pauseRegistry) vaultRegistry.pause();

        bool pairIsRegistered = candidateAdapter == address(registeredAdapter) && candidateTarget == registeredTarget;
        bool shouldExecute = pairIsRegistered && !blockAdapter && !blockTarget && !pauseRegistry;
        vm.prank(operator);
        (bool success,) = address(wallet).call(abi.encodeCall(wallet.executeViaAdapter, (candidateAdapter, candidateTarget, bytes("fuzz"))));
        assertEq(success, shouldExecute);

        if (blockAdapter) assertTrue(wallet.isAdapterBlocked(candidateAdapter));
        if (blockTarget) assertTrue(wallet.isTargetBlocked(candidateTarget));
    }

    function testFuzz_ownersAgentsCanMoveExactAmountsBetweenEachOther(address ownerSeed, uint96 amountSeed) public {
        address walletOwner = _nonzero(ownerSeed);
        AgentWallet sender = _createVaultWallet(walletOwner, 706);
        AgentWallet receiver = _createBorrowWallet(walletOwner, 707);
        uint256 amount = bound(amountSeed, 1, 1_000_000e6);
        _fundWallet(sender, address(usdc), amount);

        _transferBetweenAgents(sender, receiver, address(usdc), amount);

        assertEq(usdc.balanceOf(address(sender)), 0);
        assertEq(usdc.balanceOf(address(receiver)), amount);
    }

    function testFuzz_transfersToOtherOwnersSpoofedWalletsOrSelfAreRejected(uint96 amountSeed) public {
        uint256 amount = bound(amountSeed, 1, 100e6);
        AgentWallet sender = _createVaultWallet(owner, 708);
        AgentWallet sameOwnerReceiver = _createVaultWallet(owner, 709);
        AgentWallet otherOwnerReceiver = _createVaultWallet(makeAddr("other owner"), 708);
        AgentTransferSpoofWallet spoof = new AgentTransferSpoofWallet(owner, sameOwnerReceiver.ownerAgentIndex());
        _fundWallet(sender, address(usdc), amount * 4);

        assertFalse(_tryTransfer(sender, address(usdc), address(otherOwnerReceiver), amount));
        assertFalse(_tryTransfer(sender, address(usdc), address(spoof), amount));
        assertFalse(_tryTransfer(sender, address(usdc), address(sender), amount));
        assertEq(usdc.balanceOf(address(sender)), amount * 4);
        assertEq(usdc.balanceOf(address(sameOwnerReceiver)), 0);
        assertEq(usdc.balanceOf(address(otherOwnerReceiver)), 0);
        assertFalse(_tryTransfer(sender, address(rewardToken), address(sameOwnerReceiver), amount));
    }

    function testFuzz_senderPaysFeesOwedBeforeMovingFundsToAnotherAgent(uint96 amountSeed) public {
        AgentWallet sender = _createBorrowWallet(owner, 710);
        AgentWallet receiver = _createBorrowWallet(owner, 711);
        uint256 feeOwed = _accrueBorrowFees(sender, 100e6, 1e18);
        uint256 amount = bound(amountSeed, 1, 50e6);
        _fundWallet(sender, address(usdc), feeOwed + amount);
        uint256 collectorBalanceBefore = usdc.balanceOf(feeCollector);

        _transferBetweenAgents(sender, receiver, address(usdc), amount);

        assertEq(usdc.balanceOf(address(sender)), 0);
        assertEq(usdc.balanceOf(address(receiver)), amount);
        assertEq(usdc.balanceOf(feeCollector) - collectorBalanceBefore, feeOwed);
        assertEq(borrowFeeModule.feesOwed(address(sender)), 0);
    }

    function testFuzz_walletMidExecutionCannotReceiveAgentTransfers(uint96 amountSeed) public {
        uint256 amount = bound(amountSeed, 1, 100e6);
        AgentWallet sender = _createVaultWallet(owner, 712);
        AgentWallet receiver = _createVaultWallet(owner, 713);
        _fundWallet(sender, address(usdc), amount);
        CallOtherWalletAdapter callerAdapter = new CallOtherWalletAdapter();
        vaultRegistry.registerAdapter(address(callerAdapter));
        vaultRegistry.setTargetAdapter(address(callerAdapter), address(callerAdapter));
        factory.grantRole(factory.AGENT_OPERATOR_ROLE(), address(receiver));
        sender.syncFromFactory();
        receiver.syncFromFactory();

        bytes memory transferData = abi.encodeCall(agentTransferAdapter.transfer, (address(usdc), address(receiver), amount));
        bytes memory nestedCall = abi.encodeCall(receiver.executeViaAdapter, (address(agentTransferAdapter), address(agentTransferAdapter), transferData));
        bytes memory outerData = abi.encode(address(sender), nestedCall);
        vm.prank(operator);
        (bool success,) = address(receiver).call(abi.encodeCall(receiver.executeViaAdapter, (address(callerAdapter), address(callerAdapter), outerData)));

        assertFalse(success);
        assertEq(usdc.balanceOf(address(sender)), amount);
        assertEq(usdc.balanceOf(address(receiver)), 0);
    }

    function testFuzz_walletLandsAtPredictedAddressAndCannotBeCreatedTwice(address ownerSeed, uint256 index) public {
        address walletOwner = _nonzero(ownerSeed);
        address predicted = factory.getAddress(walletOwner, index);
        FeePlanChoice[] memory noPlans = new FeePlanChoice[](0);

        vm.prank(operator);
        AgentWallet created = factory.createAgentWallet(walletOwner, index, address(usdc), VAULT_AGENT_PROFILE, noPlans);
        assertEq(address(created), predicted);
        assertEq(factory.userWallets(walletOwner, index), predicted);

        vm.expectRevert(abi.encodeWithSelector(AgentAlreadyExists.selector, walletOwner, index));
        vm.prank(operator);
        factory.createAgentWallet(walletOwner, index, address(usdc), BORROW_AGENT_PROFILE, noPlans);
    }

    function test_ownerAndOperatorRejectInvalidWalletAndAdapterInputs() public {
        address attacker = makeAddr("attacker");
        AgentWallet wallet = _createBorrowWallet(owner, 715);
        assertEq(wallet.listAgentOperators().length, 1);
        assertTrue(wallet.isAgentOperator(operator));
        vm.prank(attacker);
        wallet.syncFromFactory();
        MockERC4626 wrongAssetVault = new MockERC4626(address(rewardToken), "Wrong Asset", "WRONG");
        _registerTarget(borrowRegistry, address(erc4626Vault), address(erc4626Adapter));
        _registerTarget(borrowRegistry, address(wrongAssetVault), address(erc4626Adapter));

        vm.expectRevert(AWKErrors.DirectCallForbidden.selector);
        erc4626Adapter.deposit(1);
        vm.expectRevert(AWKErrors.DirectCallForbidden.selector);
        erc4626Adapter.depositPercentage(10_000);
        vm.expectRevert(AWKErrors.DirectCallForbidden.selector);
        erc4626Adapter.withdraw(1);
        vm.expectRevert(AWKErrors.DirectCallForbidden.selector);
        erc4626Adapter.execute(address(erc4626Vault), bytes(""));

        vm.expectRevert(AWKErrors.DirectCallForbidden.selector);
        agentTransferAdapter.transfer(address(usdc), address(wallet), 1);
        vm.expectRevert(AWKErrors.DirectCallForbidden.selector);
        aaveV3LendingAdapter.supplyCollateral(aaveV3Market, 1);
        vm.expectRevert(AWKErrors.DirectCallForbidden.selector);
        aaveV3LendingAdapter.withdrawCollateral(aaveV3Market, 1);
        vm.expectRevert(AWKErrors.DirectCallForbidden.selector);
        aaveV3LendingAdapter.borrow(aaveV3Market, 1);
        vm.expectRevert(AWKErrors.DirectCallForbidden.selector);
        aaveV3LendingAdapter.repay(aaveV3Market, 1);
        vm.expectRevert(AWKErrors.DirectCallForbidden.selector);
        aaveV3LendingAdapter.checkpoint(aaveV3Market);

        _executeExpectRevert(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.deposit, (0)), abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        _executeExpectRevert(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.depositPercentage, (0)), abi.encodeWithSelector(InvalidPercentage.selector, uint256(0)));
        _executeExpectRevert(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.depositPercentage, (10_001)), abi.encodeWithSelector(InvalidPercentage.selector, uint256(10_001)));
        _executeExpectRevert(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.depositPercentage, (10_000)), abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        _executeExpectRevert(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeCall(erc4626Adapter.withdraw, (0)), abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        _executeExpectRevert(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodePacked(bytes4(0xdeadbeef)), abi.encodeWithSelector(UnknownOperation.selector));
        _executeExpectRevert(wallet, address(erc4626Adapter), address(wrongAssetVault), abi.encodeCall(erc4626Adapter.deposit, (1)), abi.encodeWithSelector(AssetNotAllowed.selector));

        _executeExpectRevert(wallet, address(agentTransferAdapter), address(agentTransferAdapter), abi.encodeCall(agentTransferAdapter.transfer, (address(usdc), address(0), 0)), abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        _executeExpectRevert(wallet, address(agentTransferAdapter), address(agentTransferAdapter), abi.encodePacked(bytes4(0xdeadbeef)), abi.encodeWithSelector(UnknownOperation.selector));
        address wrongTransferTarget = address(0xCAFE);
        borrowRegistry.setTargetAdapter(wrongTransferTarget, address(agentTransferAdapter));
        _executeExpectRevert(
            wallet, address(agentTransferAdapter), wrongTransferTarget, abi.encodeCall(agentTransferAdapter.transfer, (address(usdc), address(wallet), 1)), abi.encodeWithSelector(InvalidTransferTarget.selector, wrongTransferTarget)
        );
        AgentWallet emptyReceiver = _createBorrowWallet(owner, 716);
        _executeExpectRevert(
            wallet, address(agentTransferAdapter), address(agentTransferAdapter), abi.encodeCall(agentTransferAdapter.transfer, (address(usdc), address(emptyReceiver), 1)), abi.encodeWithSelector(AWKErrors.InsufficientBalance.selector)
        );

        address marketTarget = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        bytes memory sameAssetMarket = abi.encode(address(aaveV3LendingPool), address(usdc), address(usdc), uint8(0));
        address sameAssetTarget = aaveV3LendingAdapter.marketTarget(sameAssetMarket);
        borrowRegistry.setTargetAdapter(sameAssetTarget, address(aaveV3LendingAdapter));
        _executeExpectRevert(wallet, address(aaveV3LendingAdapter), sameAssetTarget, abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (sameAssetMarket, 1)), abi.encodeWithSelector(AssetNotAllowed.selector));

        address wrongMarketTarget = address(uint160(marketTarget) ^ 1);
        borrowRegistry.setTargetAdapter(wrongMarketTarget, address(aaveV3LendingAdapter));
        _executeExpectRevert(wallet, address(aaveV3LendingAdapter), marketTarget, abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, 0)), abi.encodeWithSelector(AWKErrors.ZeroAmount.selector));
        _executeExpectRevert(wallet, address(aaveV3LendingAdapter), marketTarget, abi.encodePacked(bytes4(0xdeadbeef)), abi.encodeWithSelector(UnknownOperation.selector));
        _executeExpectRevert(wallet, address(aaveV3LendingAdapter), wrongMarketTarget, abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)), abi.encodeWithSelector(MarketTargetMismatch.selector, wrongMarketTarget, marketTarget));

        address[] memory assets = new address[](1);
        uint256[] memory amounts = new uint256[](0);
        assets[0] = address(usdc);
        vm.expectRevert(InvalidState.selector);
        vm.prank(owner);
        wallet.withdrawAssetsToUser(owner, assets, amounts);

        vm.expectRevert();
        vm.prank(operator);
        wallet.withdrawAssetToUser(operator, address(usdc), 1);
        vm.expectRevert();
        vm.prank(owner);
        wallet.withdrawAssetToUser(address(0), address(usdc), 0);
        vm.expectRevert();
        vm.prank(owner);
        wallet.withdrawAssetToUser(owner, address(usdc), 1);
        vm.expectRevert(InvalidAsset.selector);
        vm.prank(owner);
        wallet.withdrawAssetToUser(owner, address(rewardToken), 0);

        address[] memory batchAdapters = new address[](1);
        address[] memory batchTargets = new address[](0);
        bytes[] memory batchData = new bytes[](1);
        vm.expectRevert(InvalidState.selector);
        vm.prank(owner);
        wallet.executeViaAdapterBatch(batchAdapters, batchTargets, batchData);
        vm.expectRevert();
        vm.prank(owner);
        wallet.execute(address(0), 0, bytes(""));
        vm.expectRevert();
        vm.prank(owner);
        wallet.executeBatch(batchTargets, batchData);

        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(rewardToken.balanceOf(address(wallet)), 0);
        assertEq(erc4626Vault.balanceOf(address(wallet)), 0);
    }

    function test_factoryRejectsInvalidConfigurationAndWalletCreationInputs() public {
        address attacker = makeAddr("attacker");
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        new AgentWalletFactory(address(0), address(this), operator);
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        new AgentWalletFactory(address(this), address(0), operator);
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        new AgentWalletFactory(address(this), address(this), address(0));

        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, AdapterRegistry(address(0)));
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.NotAContract.selector, address(0xBEEF)));
        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, AdapterRegistry(address(0xBEEF)));
        vm.expectRevert(abi.encodeWithSelector(UnknownAgentProfile.selector, bytes32(0)));
        factory.setAdapterRegistry(bytes32(0), vaultRegistry);

        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        factory.setAgentWalletImplementation(AgentWallet(payable(address(0))));
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.NotAContract.selector, address(0xBEEF)));
        factory.setAgentWalletImplementation(AgentWallet(payable(address(0xBEEF))));
        AgentWallet wrongFactoryImplementation = new AgentWallet(address(0xBEEF));
        vm.expectRevert(InvalidImplementationFactory.selector);
        factory.setAgentWalletImplementation(wrongFactoryImplementation);

        bytes32 operatorRole = factory.AGENT_OPERATOR_ROLE();
        for (uint256 i; i < 9; ++i) {
            factory.grantRole(operatorRole, address(uint160(0x1000 + i)));
        }
        vm.expectRevert(TooManyOperators.selector);
        factory.grantRole(operatorRole, address(0x2000));

        FeePlanChoice[] memory noPlans = new FeePlanChoice[](0);
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        vm.prank(operator);
        factory.createAgentWallet(address(0), 75_000, address(usdc), VAULT_AGENT_PROFILE, noPlans);
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        vm.prank(operator);
        factory.createAgentWallet(owner, 75_001, address(0), VAULT_AGENT_PROFILE, noPlans);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.NotAContract.selector, address(0xBEEF)));
        vm.prank(operator);
        factory.createAgentWallet(owner, 75_002, address(0xBEEF), VAULT_AGENT_PROFILE, noPlans);
        vm.expectRevert(abi.encodeWithSelector(UnknownAgentProfile.selector, bytes32(uint256(1))));
        vm.prank(operator);
        factory.createAgentWallet(owner, 75_003, address(usdc), bytes32(uint256(1)), noPlans);
        vm.expectRevert();
        vm.prank(attacker);
        factory.createAgentWallet(owner, 75_004, address(usdc), VAULT_AGENT_PROFILE, noPlans);

        AgentWalletFactory incompleteFactory = new AgentWalletFactory(address(this), address(this), operator);
        vm.expectRevert(NoAgentWalletImplementationSet.selector);
        vm.prank(operator);
        incompleteFactory.createAgentWallet(owner, 75_005, address(usdc), VAULT_AGENT_PROFILE, noPlans);

        AgentWallet incompleteImplementation = new AgentWallet(address(incompleteFactory));
        incompleteFactory.setAgentWalletImplementation(incompleteImplementation);
        AdapterRegistry incompleteRegistry = new AdapterRegistry(address(this), address(this));
        incompleteFactory.setAdapterRegistry(VAULT_AGENT_PROFILE, incompleteRegistry);
        vm.expectRevert(InvalidFeeTracker.selector);
        vm.prank(operator);
        incompleteFactory.createAgentWallet(owner, 75_006, address(usdc), VAULT_AGENT_PROFILE, noPlans);
        vm.expectRevert(InvalidFeeTracker.selector);
        new ERC1967Proxy(address(incompleteImplementation), _initializeCall(owner, 75_007, address(usdc), VAULT_AGENT_PROFILE));
    }

    function test_walletsBuiltOutsideTheFactoryCannotInitializeBadlyOrActAsTheOwnersAgent() public {
        address implementation = address(factory.agentWalletImplementation());
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        AgentWallet(payable(implementation)).initialize(owner, 76_001, address(usdc), VAULT_AGENT_PROFILE);

        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        new ERC1967Proxy(implementation, _initializeCall(owner, 76_002, address(0), VAULT_AGENT_PROFILE));
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.NotAContract.selector, address(0xBA5E)));
        new ERC1967Proxy(implementation, _initializeCall(owner, 76_003, address(0xBA5E), VAULT_AGENT_PROFILE));
        vm.expectRevert(AWKErrors.ZeroAddress.selector);
        new ERC1967Proxy(implementation, _initializeCall(address(0), 76_004, address(usdc), VAULT_AGENT_PROFILE));
        vm.expectRevert(InvalidRegistry.selector);
        new ERC1967Proxy(implementation, _initializeCall(owner, 76_005, address(usdc), keccak256("unconfigured")));

        AgentWallet realAgent = _createVaultWallet(owner, 76_006);
        AgentWallet impostor = AgentWallet(payable(address(new ERC1967Proxy(implementation, _initializeCall(owner, 76_006, address(usdc), VAULT_AGENT_PROFILE)))));
        _fundWallet(impostor, address(usdc), 50e6);
        bytes memory transferToRealAgent = abi.encodeCall(agentTransferAdapter.transfer, (address(usdc), address(realAgent), 50e6));
        _executeExpectRevert(impostor, address(agentTransferAdapter), address(agentTransferAdapter), transferToRealAgent, abi.encodeWithSelector(NotOwnersAgentWallet.selector, address(impostor)));
        assertEq(usdc.balanceOf(address(realAgent)), 0);

        MockERC20 strayToken = new MockERC20("Stray", "STRAY");
        strayToken.mint(address(realAgent), 1e18);
        vm.expectRevert(InvalidAsset.selector);
        vm.prank(owner);
        realAgent.withdrawAllAssetToUser(owner, address(strayToken));
        assertEq(strayToken.balanceOf(address(realAgent)), 1e18);
    }

    function _initializeCall(address walletOwner, uint256 index, address baseAsset, bytes32 profile) private pure returns (bytes memory) {
        return abi.encodeWithSignature("initialize(address,uint256,address,bytes32)", walletOwner, index, baseAsset, profile);
    }

    function _validateUserOp(AgentWallet wallet, bytes memory callData, bytes memory paymaster, bytes32 userOpHash, uint256 signerKey) private returns (uint256) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, userOpHash.toEthSignedMessageHash());
        UserOperation memory userOp = _emptyUserOp(wallet);
        userOp.callData = callData;
        userOp.paymasterAndData = paymaster;
        userOp.signature = abi.encodePacked(r, s, v);
        vm.prank(ENTRY_POINT);
        return wallet.validateUserOp(userOp, userOpHash, 0);
    }

    function _emptyUserOp(AgentWallet wallet) private pure returns (UserOperation memory) {
        return UserOperation({
            sender: address(wallet),
            nonce: 0,
            initCode: "",
            callData: "",
            callGasLimit: 500_000,
            verificationGasLimit: 500_000,
            preVerificationGas: 21_000,
            maxFeePerGas: 1 gwei,
            maxPriorityFeePerGas: 1 gwei,
            paymasterAndData: "",
            signature: ""
        });
    }

    function _paymasterData(uint8 choice) private pure returns (bytes memory) {
        if (choice == 0) return "";
        if (choice == 1) return abi.encodePacked(address(0), bytes8(uint64(1)));
        return abi.encodePacked(address(0xD00D), bytes8(uint64(1)));
    }

    function _assertCallReverts(AgentWallet wallet, address caller, bytes memory callData) private {
        vm.prank(caller);
        (bool success,) = address(wallet).call(callData);
        assertFalse(success);
    }

    function _accrueBorrowFees(AgentWallet wallet, uint256 collateral, uint256 borrowed) private returns (uint256 feeOwed) {
        address marketTarget = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        _fundWallet(wallet, address(usdc), collateral);
        _execute(wallet, address(aaveV3LendingAdapter), marketTarget, abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, collateral)));
        _execute(wallet, address(aaveV3LendingAdapter), marketTarget, abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, borrowed)));
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _execute(wallet, address(aaveV3LendingAdapter), marketTarget, abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));
        feeOwed = borrowFeeModule.feesOwed(address(wallet));
        assertGt(feeOwed, 0);
    }

    function _transferBetweenAgents(AgentWallet sender, AgentWallet receiver, address token, uint256 amount) private {
        bytes memory data = abi.encodeCall(agentTransferAdapter.transfer, (token, address(receiver), amount));
        _execute(sender, address(agentTransferAdapter), address(agentTransferAdapter), data);
    }

    function _tryTransfer(AgentWallet sender, address token, address receiver, uint256 amount) private returns (bool success) {
        bytes memory data = abi.encodeCall(agentTransferAdapter.transfer, (token, receiver, amount));
        vm.prank(operator);
        (success,) = address(sender).call(abi.encodeCall(sender.executeViaAdapter, (address(agentTransferAdapter), address(agentTransferAdapter), data)));
    }

    function _nonzero(address candidate) private pure returns (address) {
        return candidate == address(0) ? address(1) : candidate;
    }
}
