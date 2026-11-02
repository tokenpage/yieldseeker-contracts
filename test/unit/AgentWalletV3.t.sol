// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {InvalidAsset, YieldSeekerAgentWalletV3} from "../../src/AgentWalletV3.sol";
import {NotApprovedImplementation} from "../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeeActions} from "../../src/fees/FeeActions.sol";
import {FeePlanChoice, YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {IYieldSeekerFeeModule} from "../../src/fees/IYieldSeekerFeeModule.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockSwapAdapterPriceOracle} from "../mocks/MockSwapAdapterPriceOracle.sol";
import {MockV3YieldSeekerWalletV1, MockV3YieldSeekerWalletV2} from "../mocks/MockV3TestHelpers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";
import {Test} from "forge-std/Test.sol";

contract RevertingFeeQueriesModule is IYieldSeekerFeeModule {
    function isValidPlan(bytes calldata) external pure override returns (bool) {
        return true;
    }

    function onAction(address, bytes32, bytes calldata, uint256) external pure override returns (uint256) {
        return 0;
    }

    function isAccountedToken(address, address) external pure override returns (bool) {
        revert();
    }

    function feesOwedInBaseAsset(address) external pure override returns (uint256) {
        revert();
    }
}

contract GasBurningFeeQueriesModule is IYieldSeekerFeeModule {
    function isValidPlan(bytes calldata) external pure override returns (bool) {
        return true;
    }

    function onAction(address, bytes32, bytes calldata, uint256) external pure override returns (uint256) {
        return 0;
    }

    function isAccountedToken(address, address) external pure override returns (bool tracked) {
        tracked = false;
        while (true) {}
    }

    function feesOwedInBaseAsset(address) external pure override returns (uint256 owed) {
        owed = 0;
        while (true) {}
    }
}

contract RevertingFeeActionModule is IYieldSeekerFeeModule {
    function isValidPlan(bytes calldata) external pure override returns (bool) {
        return true;
    }

    function onAction(address, bytes32, bytes calldata, uint256) external pure override returns (uint256) {
        revert();
    }

    function isAccountedToken(address, address) external pure override returns (bool) {
        return false;
    }

    function feesOwedInBaseAsset(address) external pure override returns (uint256) {
        return 0;
    }
}

contract GasBurningFeeActionModule is IYieldSeekerFeeModule {
    function isValidPlan(bytes calldata) external pure override returns (bool) {
        return true;
    }

    function onAction(address, bytes32, bytes calldata, uint256) external pure override returns (uint256 payment) {
        payment = 0;
        while (true) {}
    }

    function isAccountedToken(address, address) external pure override returns (bool) {
        return false;
    }

    function feesOwedInBaseAsset(address) external pure override returns (uint256) {
        return 0;
    }
}

contract AgentWalletV3Test is Test {
    using MessageHashUtils for bytes32;

    bytes32 private constant VAULT_AGENT_PROFILE = keccak256("vault-profile");
    bytes32 private constant BORROW_AGENT_PROFILE = keccak256("borrow-profile");
    address private constant ENTRY_POINT = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    bytes32 private constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address private admin;
    address private owner;
    uint256 private ownerKey;
    address private operator;
    uint256 private operatorKey;
    address private recipient = makeAddr("recipient");
    address private feeCollector = makeAddr("fee-collector");

    MockERC20 private usdc;
    MockERC20 private weth;
    MockERC20 private unrelated;
    YieldSeekerAdapterRegistry private vaultRegistry;
    YieldSeekerAdapterRegistry private borrowRegistry;
    YieldSeekerFeeTracker private vaultFees;
    YieldSeekerYieldFeeModule private vaultFeeModule;
    YieldSeekerBorrowFeeModule private borrowFees;
    YieldSeekerAgentWalletFactory private factory;
    YieldSeekerAgentWalletV3 private vaultWallet;
    YieldSeekerAgentWalletV3 private borrowWallet;

    function setUp() public {
        admin = address(this);
        (owner, ownerKey) = makeAddrAndKey("owner");
        (operator, operatorKey) = makeAddrAndKey("operator");
        usdc = new MockERC20("USD Coin", "USDC");
        weth = new MockERC20("Wrapped Ether", "WETH");
        unrelated = new MockERC20("Unrelated", "NOPE");
        vaultRegistry = new YieldSeekerAdapterRegistry(admin, admin);
        borrowRegistry = new YieldSeekerAdapterRegistry(admin, admin);
        vaultFees = new YieldSeekerFeeTracker(admin, feeCollector);
        vaultFeeModule = new YieldSeekerYieldFeeModule(vaultFees, 10_000);
        vaultFees.setFeeModule(YIELD_FEE, vaultFeeModule);
        vaultFees.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 1_000})));
        borrowFees = new YieldSeekerBorrowFeeModule(vaultFees, new MockSwapAdapterPriceOracle(), 1_000);
        vaultFees.setFeeModule(BORROW_FEE, borrowFees);
        vaultFees.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 1_000})));
        factory = new YieldSeekerAgentWalletFactory(admin, operator);

        MockV3YieldSeekerWalletV1 implementation = new MockV3YieldSeekerWalletV1(address(factory));
        factory.setAgentWalletImplementation(implementation);
        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, vaultRegistry);
        factory.setAdapterRegistry(BORROW_AGENT_PROFILE, borrowRegistry);
        factory.setFeeTracker(vaultFees);

        FeePlanChoice[] memory noFeePlans = new FeePlanChoice[](0);
        vm.startPrank(operator);
        vaultWallet = factory.createAgentWallet(owner, 1, address(usdc), VAULT_AGENT_PROFILE, noFeePlans);
        borrowWallet = factory.createAgentWallet(owner, 2, address(weth), BORROW_AGENT_PROFILE, noFeePlans);
        vm.stopPrank();

        usdc.mint(address(vaultWallet), 1_000e6);
        usdc.mint(address(borrowWallet), 1_000e6);
        weth.mint(address(borrowWallet), 400e6);
    }

    function test_SyncFollowsFactoryRegistryOperatorsAndFeeTracker() public {
        YieldSeekerAdapterRegistry nextRegistry = new YieldSeekerAdapterRegistry(admin, admin);
        YieldSeekerFeeTracker nextFees = new YieldSeekerFeeTracker(admin, feeCollector);
        address nextOperator = makeAddr("next-operator");
        bytes32 operatorRole = factory.AGENT_OPERATOR_ROLE();

        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, nextRegistry);
        factory.setFeeTracker(nextFees);
        factory.grantRole(operatorRole, nextOperator);
        factory.revokeRole(operatorRole, operator);

        vm.prank(owner);
        vaultWallet.syncFromFactory();

        assertEq(address(vaultWallet.feeTracker()), address(nextFees));
        assertEq(address(vaultWallet.adapterRegistry()), address(nextRegistry));
        assertFalse(vaultWallet.isAgentOperator(operator));
        assertTrue(vaultWallet.isAgentOperator(nextOperator));
        address[] memory syncedOperators = vaultWallet.listAgentOperators();
        assertEq(syncedOperators.length, 1);
        assertEq(syncedOperators[0], nextOperator);
    }

    function test_UpgradeToLatestUsesOnlyTheFactoryApprovedImplementation() public {
        MockV3YieldSeekerWalletV2 nextImplementation = new MockV3YieldSeekerWalletV2(address(factory));
        MockV3YieldSeekerWalletV2 unapprovedImplementation = new MockV3YieldSeekerWalletV2(address(factory));
        factory.setAgentWalletImplementation(nextImplementation);

        vm.prank(owner);
        vm.expectRevert(NotApprovedImplementation.selector);
        vaultWallet.upgradeToAndCall(address(unapprovedImplementation), "");

        vm.prank(owner);
        vaultWallet.upgradeToLatest();

        assertEq(address(uint160(uint256(vm.load(address(vaultWallet), IMPLEMENTATION_SLOT)))), address(nextImplementation));
        assertEq(MockV3YieldSeekerWalletV2(payable(address(vaultWallet))).version(), 2);
        assertEq(vaultWallet.owner(), owner);
        assertEq(address(vaultWallet.feeTracker()), address(vaultFees));
    }

    function test_OperatorSignatureOnlyAuthorizesAdapterExecution() public {
        bytes memory executeCall = abi.encodeWithSelector(vaultWallet.executeViaAdapter.selector, address(0xA11CE), address(usdc), hex"1234");
        bytes memory withdrawCall = abi.encodeWithSelector(vaultWallet.withdrawAssetToUser.selector, recipient, address(usdc), 1);

        assertEq(_validateWithSigner(executeCall, operatorKey), 0);
        assertEq(_validateWithSigner(withdrawCall, operatorKey), 1);
    }

    function test_YieldFeeModuleSettlesBaseFeesBeforeExactWithdrawal() public {
        _recordFeeAction(vaultFeeModule, address(vaultWallet), FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(usdc), amount: 100e6})));
        uint256 amountAboveAvailable = 990e6 + 1;
        uint256 amount = 990e6;

        assertEq(vaultFeeModule.feesOwed(address(vaultWallet)), 10e6);

        vm.prank(owner);
        vm.expectRevert(AWKErrors.InsufficientBalance.selector);
        vaultWallet.withdrawAssetToUser(recipient, address(usdc), amountAboveAvailable);

        vm.prank(owner);
        vaultWallet.withdrawAssetToUser(recipient, address(usdc), amount);
        assertEq(usdc.balanceOf(recipient), amount);
        assertEq(usdc.balanceOf(feeCollector), 10e6);
        assertEq(usdc.balanceOf(address(vaultWallet)), 0);
        assertEq(vaultFeeModule.feesOwed(address(vaultWallet)), 0);

        unrelated.mint(address(vaultWallet), 3e6);
        vm.prank(owner);
        vm.expectRevert(InvalidAsset.selector);
        vaultWallet.withdrawAssetToUser(recipient, address(unrelated), 1e6);
    }

    function test_YieldWithdrawAllSettlesFeesAndSendsTheRemainder() public {
        _recordFeeAction(vaultFeeModule, address(vaultWallet), FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(usdc), amount: 100e6})));
        vm.prank(owner);
        vaultWallet.withdrawAllAssetToUser(recipient, address(usdc));

        assertEq(usdc.balanceOf(recipient), 990e6);
        assertEq(usdc.balanceOf(address(vaultWallet)), 0);
        assertEq(usdc.balanceOf(feeCollector), 10e6);
        assertEq(vaultFeeModule.feesOwed(address(vaultWallet)), 0);
    }

    function test_BorrowedTokenWithdrawalSettlesBorrowFeesAndWithdrawsRemainingBaseAsset() public {
        bytes32 market = keccak256("test-market");
        uint256 startTime = vm.getBlockTimestamp();
        if (startTime == 0) {
            vm.warp(1);
            startTime = vm.getBlockTimestamp();
        }
        _recordFeeAction(borrowFees, address(borrowWallet), FeeActions.DEBT_CHANGE, abi.encode(FeeActions.DebtChange({market: market, debtToken: address(usdc), debtBefore: 0, borrowed: 100e6, repaid: 0})));

        vm.warp(startTime + 365 days);
        _recordFeeAction(borrowFees, address(borrowWallet), FeeActions.DEBT_CHANGE, abi.encode(FeeActions.DebtChange({market: market, debtToken: address(usdc), debtBefore: 100e6, borrowed: 0, repaid: 0})));
        uint256 borrowedBalance = usdc.balanceOf(address(borrowWallet));
        uint256 owedInBaseAsset = borrowFees.feesOwedInBaseAsset(address(borrowWallet));

        assertEq(borrowFees.feesOwed(address(borrowWallet), address(usdc)), 10e6);
        assertEq(owedInBaseAsset, 10e6);

        vm.prank(owner);
        borrowWallet.withdrawAssetToUser(recipient, address(usdc), borrowedBalance);
        assertEq(usdc.balanceOf(recipient), borrowedBalance);
        assertEq(usdc.balanceOf(address(borrowWallet)), 0);
        assertEq(borrowFees.feesOwed(address(borrowWallet), address(usdc)), 0);
        assertEq(weth.balanceOf(feeCollector), owedInBaseAsset);

        uint256 remainingBaseBalance = weth.balanceOf(address(borrowWallet));
        vm.prank(owner);
        borrowWallet.withdrawAllAssetToUser(recipient, address(weth));
        assertEq(weth.balanceOf(recipient), remainingBaseBalance);
        assertEq(weth.balanceOf(address(borrowWallet)), 0);
    }

    function test_BorrowedTokenWithdrawalSettlesBorrowAndYieldFeesFromBaseAsset() public {
        bytes32 market = keccak256("rewarded-debt-market");
        uint256 startTime = vm.getBlockTimestamp();
        if (startTime == 0) {
            vm.warp(1);
            startTime = vm.getBlockTimestamp();
        }

        _recordFeeAction(borrowFees, address(borrowWallet), FeeActions.DEBT_CHANGE, abi.encode(FeeActions.DebtChange({market: market, debtToken: address(usdc), debtBefore: 0, borrowed: 100e6, repaid: 0})));
        vm.warp(startTime + 365 days);
        _recordFeeAction(borrowFees, address(borrowWallet), FeeActions.DEBT_CHANGE, abi.encode(FeeActions.DebtChange({market: market, debtToken: address(usdc), debtBefore: 100e6, borrowed: 0, repaid: 0})));

        uint256 rewardAmount = 200e6;
        _recordFeeAction(vaultFeeModule, address(borrowWallet), FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(weth), amount: rewardAmount})));

        uint256 borrowFeesOwed = borrowFees.feesOwed(address(borrowWallet), address(usdc));
        uint256 vaultFeesOwed = vaultFeeModule.feesOwed(address(borrowWallet));
        uint256 borrowedBalance = usdc.balanceOf(address(borrowWallet));
        assertEq(borrowFeesOwed, 10e6);
        assertEq(vaultFeesOwed, 20e6);
        assertTrue(vaultFees.isAccountedToken(address(borrowWallet), address(usdc)));
        assertTrue(vaultFees.isAccountedToken(address(borrowWallet), address(weth)));
        assertEq(vaultFees.feesOwedInBaseAsset(address(borrowWallet)), borrowFeesOwed + vaultFeesOwed);

        vm.prank(owner);
        borrowWallet.withdrawAssetToUser(recipient, address(usdc), borrowedBalance);
        assertEq(usdc.balanceOf(recipient), borrowedBalance);
        assertEq(usdc.balanceOf(address(borrowWallet)), 0);
        assertEq(borrowFees.feesOwed(address(borrowWallet), address(usdc)), 0);
        assertEq(vaultFeeModule.feesOwed(address(borrowWallet)), 0);
        assertEq(weth.balanceOf(feeCollector), borrowFeesOwed + vaultFeesOwed);
        assertEq(weth.balanceOf(address(borrowWallet)), 400e6 - borrowFeesOwed - vaultFeesOwed);
    }

    function test_WithdrawableBalanceUsesFeesForBaseAndFullBalanceForAccountedTokens() public {
        _recordFeeAction(vaultFeeModule, address(vaultWallet), FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(usdc), amount: 100e6})));

        bytes32 market = keccak256("withdrawable-balance-market");
        uint256 startTime = vm.getBlockTimestamp();
        if (startTime == 0) {
            vm.warp(1);
            startTime = vm.getBlockTimestamp();
        }
        _recordFeeAction(borrowFees, address(borrowWallet), FeeActions.DEBT_CHANGE, abi.encode(FeeActions.DebtChange({market: market, debtToken: address(usdc), debtBefore: 0, borrowed: 100e6, repaid: 0})));
        vm.warp(startTime + 365 days);
        _recordFeeAction(borrowFees, address(borrowWallet), FeeActions.DEBT_CHANGE, abi.encode(FeeActions.DebtChange({market: market, debtToken: address(usdc), debtBefore: 100e6, borrowed: 0, repaid: 0})));
        unrelated.mint(address(vaultWallet), 3e6);

        assertEq(vaultWallet.withdrawableBalance(address(usdc)), 990e6);
        assertEq(borrowWallet.withdrawableBalance(address(usdc)), usdc.balanceOf(address(borrowWallet)));
        assertEq(borrowWallet.withdrawableBalance(address(usdc)), 1_000e6);
        assertEq(vaultWallet.withdrawableBalance(address(unrelated)), 0);
    }

    function test_FailingFeeQueriesDoNotBlockBaseWithdrawalsOrAllowOtherTokens() public {
        vaultFees.setFeeModule(keccak256("reverting-fee-queries"), new RevertingFeeQueriesModule());
        vaultFees.setFeeModule(keccak256("gas-burning-fee-queries"), new GasBurningFeeQueriesModule());

        _recordFeeAction(vaultFeeModule, address(borrowWallet), FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(weth), amount: 100e6})));
        uint256 reserve = vaultFeeModule.feesOwed(address(borrowWallet));
        uint256 baseBalance = weth.balanceOf(address(borrowWallet));
        uint256 withdrawable = baseBalance - reserve;

        assertTrue(vaultFees.isAccountedToken(address(borrowWallet), address(weth)));
        assertEq(vaultFees.feesOwedInBaseAsset(address(borrowWallet)), reserve);
        assertEq(borrowWallet.withdrawableBalance(address(weth)), withdrawable);

        vm.prank(owner);
        borrowWallet.withdrawAssetToUser(recipient, address(weth), withdrawable);
        assertEq(weth.balanceOf(recipient), withdrawable);
        assertEq(weth.balanceOf(address(borrowWallet)), 0);
        assertEq(weth.balanceOf(feeCollector), reserve);
        assertEq(vaultFeeModule.feesOwed(address(borrowWallet)), 0);

        unrelated.mint(address(borrowWallet), 3e6);
        assertFalse(vaultFees.isAccountedToken(address(borrowWallet), address(unrelated)));
        assertEq(borrowWallet.withdrawableBalance(address(unrelated)), 0);
        vm.expectRevert(InvalidAsset.selector);
        vm.prank(owner);
        borrowWallet.withdrawAssetToUser(recipient, address(unrelated), 1e6);
        assertEq(unrelated.balanceOf(address(borrowWallet)), 3e6);
    }

    function test_RevertingFeeModuleCannotBlockOwnerWithdrawal() public {
        _recordFeeAction(vaultFeeModule, address(vaultWallet), FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(usdc), amount: 100e6})));
        uint256 amount = 990e6;
        uint256 feesOwed = vaultFeeModule.feesOwed(address(vaultWallet));
        vaultFees.setFeeModule(keccak256("reverting-fee-action"), new RevertingFeeActionModule());

        vm.prank(owner);
        vaultWallet.withdrawAssetToUser(recipient, address(usdc), amount);

        assertEq(usdc.balanceOf(recipient), amount);
        assertEq(usdc.balanceOf(address(vaultWallet)), 10e6);
        assertEq(usdc.balanceOf(feeCollector), 0);
        assertEq(vaultFeeModule.feesOwed(address(vaultWallet)), feesOwed);
    }

    function test_GasBurningFeeModuleCannotBlockOwnerWithdrawal() public {
        _recordFeeAction(vaultFeeModule, address(vaultWallet), FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(usdc), amount: 100e6})));
        uint256 amount = 990e6;
        uint256 feesOwed = vaultFeeModule.feesOwed(address(vaultWallet));
        vaultFees.setFeeModule(keccak256("gas-burning-fee-action"), new GasBurningFeeActionModule());

        vm.prank(owner);
        vaultWallet.withdrawAssetToUser(recipient, address(usdc), amount);

        assertEq(usdc.balanceOf(recipient), amount);
        assertEq(usdc.balanceOf(address(vaultWallet)), 10e6);
        assertEq(usdc.balanceOf(feeCollector), 0);
        assertEq(vaultFeeModule.feesOwed(address(vaultWallet)), feesOwed);
    }

    function test_CollectorTransferFailureDoesNotBlockOwnerWithdrawal() public {
        _recordFeeAction(vaultFeeModule, address(vaultWallet), FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(usdc), amount: 100e6})));
        uint256 amount = 990e6;
        uint256 feesOwed = vaultFeeModule.feesOwed(address(vaultWallet));
        vm.mockCallRevert(address(usdc), abi.encodeWithSelector(IERC20.transfer.selector, feeCollector, feesOwed), bytes("transfer failed"));

        vm.prank(owner);
        vaultWallet.withdrawAssetToUser(recipient, address(usdc), amount);

        assertEq(usdc.balanceOf(recipient), amount);
        assertEq(usdc.balanceOf(address(vaultWallet)), 10e6);
        assertEq(usdc.balanceOf(feeCollector), 0);
        assertEq(vaultFeeModule.feesOwed(address(vaultWallet)), feesOwed);
    }

    function test_SettleFeesForWithdrawalRejectsExternalCall() public {
        address externalCaller = makeAddr("external-settlement-caller");
        vm.prank(externalCaller);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.Unauthorized.selector, externalCaller));
        vaultWallet.settleFeesForWithdrawal(address(usdc), recipient, 1e6);
    }

    function _recordFeeAction(IYieldSeekerFeeModule module, address wallet, bytes32 action, bytes memory data) private {
        vm.prank(address(vaultFees));
        module.onAction(wallet, action, data, 0);
    }

    function _validateWithSigner(bytes memory callData, uint256 signerKey) private returns (uint256) {
        bytes32 userOpHash = keccak256(abi.encode(callData, vm.getBlockTimestamp()));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, userOpHash.toEthSignedMessageHash());
        UserOperation memory userOp = UserOperation({
            sender: address(vaultWallet),
            nonce: 0,
            initCode: "",
            callData: callData,
            callGasLimit: 500_000,
            verificationGasLimit: 500_000,
            preVerificationGas: 21_000,
            maxFeePerGas: 1 gwei,
            maxPriorityFeePerGas: 1 gwei,
            paymasterAndData: "",
            signature: abi.encodePacked(r, s, v)
        });

        vm.prank(ENTRY_POINT);
        return vaultWallet.validateUserOp(userOp, userOpHash, 0);
    }
}

