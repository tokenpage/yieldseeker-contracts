// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWalletV3} from "../../src/AgentWalletV3.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {FeeActions} from "../../src/fees/FeeActions.sol";
import {FeePlan, InvalidPlan, YieldSeekerFeeTracker as FeeTracker} from "../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockEntryPoint} from "../mocks/MockEntryPoint.sol";
import {Test} from "forge-std/Test.sol";

contract FeeTrackerSecurityTest is Test {
    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    ERC4626Adapter vaultAdapter;
    YieldSeekerYieldFeeModule vaultFeeModule;

    MockERC20 usdc;
    MockERC4626 vault;
    MockEntryPoint entryPoint;

    address admin = makeAddr("admin");
    address emergencyAdmin = makeAddr("emergencyAdmin");
    address operator = makeAddr("operator");
    address user = makeAddr("user");
    address feeCollector = makeAddr("feeCollector");

    uint256 constant FEE_RATE = 1000; // 10%
    bytes32 constant VAULT_AGENT_PROFILE = keccak256("vault");
    uint32 constant AGENT_INDEX = 1;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        vault = new MockERC4626(address(usdc), "Mock Vault", "mVault");
        entryPoint = new MockEntryPoint();

        bytes memory initialPlan = abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: FEE_RATE}));
        vm.startPrank(admin);
        registry = new AdapterRegistry(admin, emergencyAdmin);
        feeTracker = new FeeTracker(admin, feeCollector);
        vaultFeeModule = new YieldSeekerYieldFeeModule(feeTracker, 5_000);
        feeTracker.setFeeModule(YIELD_FEE, vaultFeeModule);
        feeTracker.createPlan(YIELD_FEE, initialPlan);

        factory = new AgentWalletFactory(admin, operator);
        AgentWalletV3 impl = new AgentWalletV3(address(factory));
        factory.setAdapterRegistry(VAULT_AGENT_PROFILE, registry);
        factory.setFeeTracker(feeTracker);
        factory.setAgentWalletImplementation(impl);

        vaultAdapter = new ERC4626Adapter();
        registry.registerAdapter(address(vaultAdapter));
        registry.setTargetAdapter(address(vault), address(vaultAdapter));
        vm.stopPrank();
    }

    function _createWallet() internal returns (AgentWalletV3 wallet) {
        FeePlan[] memory feePlans = new FeePlan[](0);
        vm.prank(operator);
        wallet = AgentWalletV3(payable(address(factory.createAgentWallet(user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE, feePlans))));
    }

    function test_RecordYieldAccruesFees() public {
        AgentWalletV3 wallet = _createWallet();
        _report(wallet, FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(usdc), amount: 1_000e6})), 0);
        assertEq(vaultFeeModule.feesOwed(address(wallet)), 100e6);
    }

    function test_ProfitWithdrawalAccruesFees() public {
        AgentWalletV3 wallet = _createWallet();
        address vaultAddr = address(vault);

        _report(wallet, FeeActions.DEPOSIT, abi.encode(FeeActions.Deposit({target: vaultAddr, assetsIn: 1_000e6})), 0);

        _report(wallet, FeeActions.WITHDRAW, abi.encode(FeeActions.Withdraw({target: vaultAddr, spent: 1_000e6, heldBefore: 1_000e6, assetsOut: 1_200e6})), 0);

        assertEq(vaultFeeModule.feesOwed(address(wallet)), 20e6);
    }

    function test_PartialWithdrawChargesYieldAcrossRewardShares() public {
        AgentWalletV3 wallet = _createWallet();
        address vaultAddr = address(vault);

        _report(wallet, FeeActions.DEPOSIT, abi.encode(FeeActions.Deposit({target: vaultAddr, assetsIn: 1_000e6})), 0);

        uint256 initialFees = vaultFeeModule.feesOwed(address(wallet));
        assertEq(initialFees, 0);

        _report(wallet, FeeActions.WITHDRAW, abi.encode(FeeActions.Withdraw({target: vaultAddr, spent: 100e6, heldBefore: 2_000e6, assetsOut: 120e6})), 0);

        assertEq(vaultFeeModule.feesOwed(address(wallet)) - initialFees, 7e6);
        assertEq(vaultFeeModule.costBasis(address(wallet), vaultAddr), 950e6);
    }

    function test_MixedRewardAndDepositSharesSpreadRemainingCostBasis() public {
        AgentWalletV3 wallet = _createWallet();
        address vaultAddr = address(vault);

        _report(wallet, FeeActions.DEPOSIT, abi.encode(FeeActions.Deposit({target: vaultAddr, assetsIn: 100e6})), 0);

        _report(wallet, FeeActions.WITHDRAW, abi.encode(FeeActions.Withdraw({target: vaultAddr, spent: 120e6, heldBefore: 150e6, assetsOut: 150e6})), 0);

        assertEq(vaultFeeModule.costBasis(address(wallet), vaultAddr), 20e6);
        assertEq(vaultFeeModule.feesOwed(address(wallet)), 7e6);
    }

    function test_LossWithdrawalDoesNotChargeFees() public {
        AgentWalletV3 wallet = _createWallet();
        address vaultAddr = address(vault);

        _report(wallet, FeeActions.DEPOSIT, abi.encode(FeeActions.Deposit({target: vaultAddr, assetsIn: 1_000e6})), 0);

        _report(wallet, FeeActions.WITHDRAW, abi.encode(FeeActions.Withdraw({target: vaultAddr, spent: 1_000e6, heldBefore: 1_000e6, assetsOut: 800e6})), 0);

        assertEq(vaultFeeModule.feesOwed(address(wallet)), 0);
    }

    function test_YieldTokenSaleChargesFeeOnBaseAssetReceived() public {
        AgentWalletV3 wallet = _createWallet();

        _report(wallet, FeeActions.SWAP, abi.encode(FeeActions.Swap({sold: address(vault), soldAmount: 50e6, bought: address(usdc), boughtAmount: 50e6})), 0);

        assertEq(vaultFeeModule.feesOwed(address(wallet)), 5e6);
    }

    function test_FeePaymentReducesFeesOwed() public {
        AgentWalletV3 wallet = _createWallet();

        _report(wallet, FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(usdc), amount: 500e6})), 0);
        assertEq(vaultFeeModule.feesOwed(address(wallet)), 50e6);

        assertEq(_report(wallet, FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: address(usdc), amount: 0})), 30e6), 30e6);
        assertEq(vaultFeeModule.feesOwed(address(wallet)), 20e6);
    }

    function test_MaxFeeRateEnforced() public {
        uint256 maximumRate = vaultFeeModule.MAX_FEE_RATE_BPS();
        uint256 tooHigh = maximumRate + 1;
        bytes memory maximumPlanData = abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: maximumRate}));
        vm.prank(admin);
        uint256 planId = feeTracker.createPlan(YIELD_FEE, maximumPlanData);
        assertEq(planId, 1);

        bytes memory tooHighPlanData = abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: tooHigh}));
        bytes memory invalidPlanError = abi.encodeWithSelector(InvalidPlan.selector, YIELD_FEE, feeTracker.planCount(YIELD_FEE));
        vm.expectRevert(invalidPlanError);
        vm.prank(admin);
        feeTracker.createPlan(YIELD_FEE, tooHighPlanData);
    }

    function _report(AgentWalletV3 wallet, bytes32 action, bytes memory data, uint256 walletBalance) internal returns (uint256 payment) {
        usdc.burn(address(wallet), usdc.balanceOf(address(wallet)));
        usdc.mint(address(wallet), walletBalance);
        vm.prank(address(wallet));
        payment = vaultFeeModule.onAction(action, data);
    }
}
