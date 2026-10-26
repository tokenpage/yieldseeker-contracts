// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAgentWalletV3 as AgentWalletV3} from "../../src/AgentWalletV3.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import {InvalidFeeRate, YieldSeekerFeeTracker as FeeTracker} from "../../src/fees/FeeTracker.sol";
import {VAULT_FEE, YieldSeekerVaultFeeModule} from "../../src/fees/VaultFeeModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC4626} from "../mocks/MockERC4626.sol";
import {MockEntryPoint} from "../mocks/MockEntryPoint.sol";
import {Test} from "forge-std/Test.sol";

contract FeeTrackerSecurityTest is Test {
    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    ERC4626Adapter vaultAdapter;
    YieldSeekerVaultFeeModule vaultFeeModule;

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

        vm.startPrank(admin);
        registry = new AdapterRegistry(admin, emergencyAdmin);
        feeTracker = new FeeTracker(admin, admin, feeCollector);
        vaultFeeModule = new YieldSeekerVaultFeeModule(feeTracker, 5_000);
        feeTracker.addFeeModule(VAULT_FEE, vaultFeeModule);
        feeTracker.setPlanRate(0, VAULT_FEE, FEE_RATE);

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
        vm.prank(operator);
        wallet = AgentWalletV3(payable(address(factory.createAgentWallet(user, AGENT_INDEX, address(usdc), VAULT_AGENT_PROFILE))));
    }

    function test_RecordYieldAccruesFees() public {
        AgentWalletV3 wallet = _createWallet();
        vm.prank(address(wallet));
        vaultFeeModule.recordAgentYieldEarned(1_000e6);
        assertEq(vaultFeeModule.getFeesOwed(address(wallet)), 100e6);
    }

    function test_ProfitWithdrawalAccruesFees() public {
        AgentWalletV3 wallet = _createWallet();
        address vaultAddr = address(vault);

        vm.prank(address(wallet));
        vaultFeeModule.recordAgentVaultShareDeposit(vaultAddr, 1_000e6, 1_000e6);

        vm.prank(address(wallet));
        vaultFeeModule.recordAgentVaultShareWithdraw(vaultAddr, 1_000e6, 1_200e6);

        assertEq(vaultFeeModule.getFeesOwed(address(wallet)), 20e6);
    }

    function test_PartialWithdrawWithVaultTokenFees_DoesNotDoubleChargeProfit() public {
        AgentWalletV3 wallet = _createWallet();
        address vaultAddr = address(vault);

        vm.prank(address(wallet));
        vaultFeeModule.recordAgentVaultShareDeposit(vaultAddr, 1_000e6, 1_000e6);

        vm.prank(address(wallet));
        vaultFeeModule.recordAgentYieldTokenEarned(vaultAddr, 1_000e6);

        uint256 initialFees = vaultFeeModule.getFeesOwed(address(wallet));

        vm.prank(address(wallet));
        vaultFeeModule.recordAgentVaultShareWithdraw(vaultAddr, 100e6, 120e6);

        uint256 finalFees = vaultFeeModule.getFeesOwed(address(wallet));
        assertEq(finalFees - initialFees, 120e6);
    }

    function test_MixedRewardAndDepositShares_WithdrawalRetainsRemainingRewardShares() public {
        AgentWalletV3 wallet = _createWallet();
        address vaultAddr = address(vault);

        vm.prank(address(wallet));
        vaultFeeModule.recordAgentVaultShareDeposit(vaultAddr, 100e6, 100e6);

        vm.prank(address(wallet));
        vaultFeeModule.recordAgentYieldTokenEarned(vaultAddr, 50e6);

        vm.prank(address(wallet));
        vaultFeeModule.recordAgentVaultShareWithdraw(vaultAddr, 120e6, 150e6);

        (uint256 costBasis, uint256 shares) = vaultFeeModule.getAgentVaultPosition(address(wallet), vaultAddr);
        assertEq(costBasis, 0);
        assertEq(shares, 0);
    }

    function test_LossWithdrawalDoesNotChargeFees() public {
        AgentWalletV3 wallet = _createWallet();
        address vaultAddr = address(vault);

        vm.prank(address(wallet));
        vaultFeeModule.recordAgentVaultShareDeposit(vaultAddr, 1_000e6, 1_000e6);

        vm.prank(address(wallet));
        vaultFeeModule.recordAgentVaultShareWithdraw(vaultAddr, 1_000e6, 800e6);

        assertEq(vaultFeeModule.getFeesOwed(address(wallet)), 0);
    }

    function test_YieldTokenFeeTrackedAndConvertedOnSwap() public {
        AgentWalletV3 wallet = _createWallet();
        address rewardToken = address(0xDEAD);

        vm.prank(address(wallet));
        vaultFeeModule.recordAgentYieldTokenEarned(rewardToken, 1_000e6);
        assertEq(vaultFeeModule.agentYieldTokenFeesOwed(address(wallet), rewardToken), 100e6);

        vm.prank(address(wallet));
        vaultFeeModule.recordAgentTokenSwap(rewardToken, 100e6, 50e6);

        assertEq(vaultFeeModule.agentYieldTokenFeesOwed(address(wallet), rewardToken), 0);
        assertEq(vaultFeeModule.getFeesOwed(address(wallet)), 50e6);
    }

    function test_FeePaymentReducesFeesOwed() public {
        AgentWalletV3 wallet = _createWallet();

        vm.prank(address(wallet));
        vaultFeeModule.recordAgentYieldEarned(500e6);
        assertEq(vaultFeeModule.getFeesOwed(address(wallet)), 50e6);

        vm.prank(address(wallet));
        vaultFeeModule.recordFeePaid(30e6);
        assertEq(vaultFeeModule.getFeesOwed(address(wallet)), 20e6);
    }

    function test_MaxFeeRateEnforced() public {
        vm.expectRevert(InvalidFeeRate.selector);
        vm.prank(admin);
        feeTracker.setPlanRate(0, VAULT_FEE, 5_001);
    }
}
