// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {YieldSeekerErrors} from "../../src/Errors.sol";
import {YieldSeekerAgentWalletV1 as AgentWalletV1} from "../../src/AgentWalletV1.sol";
import {YieldSeekerAgentWalletFactory as AgentWalletFactory} from "../../src/AgentWalletFactory.sol";
import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../../src/AdapterRegistry.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "../../src/FeeTracker.sol";
import {YieldSeekerERC4626Adapter as ERC4626Adapter} from "../../src/adapters/ERC4626Adapter.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockERC4626.sol";
import "../mocks/MockEntryPoint.sol";

contract FeeTrackerSecurityTest is Test {
    AgentWalletFactory factory;
    AdapterRegistry registry;
    FeeTracker feeTracker;
    ERC4626Adapter vaultAdapter;

    MockERC20 usdc;
    MockERC4626 vault;
    MockEntryPoint entryPoint;

    address admin = makeAddr("admin");
    address emergencyAdmin = makeAddr("emergencyAdmin");
    address operator = makeAddr("operator");
    address user = makeAddr("user");
    address feeCollector = makeAddr("feeCollector");

    uint256 constant FEE_RATE = 1000; // 10%
    uint32 constant AGENT_INDEX = 1;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        vault = new MockERC4626(address(usdc), "Mock Vault", "mVault");
        entryPoint = new MockEntryPoint();

        vm.startPrank(admin);
        registry = new AdapterRegistry(admin, emergencyAdmin);
        feeTracker = new FeeTracker(admin);
        feeTracker.setFeeConfig(FEE_RATE, feeCollector);

        factory = new AgentWalletFactory(admin, operator);
        AgentWalletV1 impl = new AgentWalletV1(address(factory));
        factory.setAdapterRegistry(registry);
        factory.setFeeTracker(feeTracker);
        factory.setAgentWalletImplementation(impl);

        vaultAdapter = new ERC4626Adapter();
        registry.registerAdapter(address(vaultAdapter));
        registry.setTargetAdapter(address(vault), address(vaultAdapter));
        vm.stopPrank();
    }

    function _createWallet() internal returns (AgentWalletV1 wallet) {
        vm.prank(operator);
        wallet = factory.createAgentWallet(user, AGENT_INDEX, address(usdc));
    }

    function test_RecordYieldAccruesFees() public {
        AgentWalletV1 wallet = _createWallet();
        vm.prank(address(wallet));
        feeTracker.recordAgentYieldEarned(1_000e6);
        assertEq(feeTracker.getFeesOwed(address(wallet)), 100e6);
    }

    function test_ProfitWithdrawalAccruesFees() public {
        AgentWalletV1 wallet = _createWallet();
        address vaultAddr = address(vault);

        vm.prank(address(wallet));
        feeTracker.recordAgentVaultShareDeposit(vaultAddr, 1_000e6, 1_000e6);

        vm.prank(address(wallet));
        feeTracker.recordAgentVaultShareWithdraw(vaultAddr, 1_000e6, 1_200e6);

        assertEq(feeTracker.getFeesOwed(address(wallet)), 20e6);
    }

    function test_LossWithdrawalDoesNotChargeFees() public {
        AgentWalletV1 wallet = _createWallet();
        address vaultAddr = address(vault);

        vm.prank(address(wallet));
        feeTracker.recordAgentVaultShareDeposit(vaultAddr, 1_000e6, 1_000e6);

        vm.prank(address(wallet));
        feeTracker.recordAgentVaultShareWithdraw(vaultAddr, 1_000e6, 800e6);

        assertEq(feeTracker.getFeesOwed(address(wallet)), 0);
    }

    function test_YieldTokenFeeTrackedAndConvertedOnSwap() public {
        AgentWalletV1 wallet = _createWallet();
        address rewardToken = address(0xDEAD);

        vm.prank(address(wallet));
        feeTracker.recordAgentYieldTokenEarned(rewardToken, 1_000e6);
        assertEq(feeTracker.getAgentYieldTokenFeesOwed(address(wallet), rewardToken), 100e6);

        vm.prank(address(wallet));
        feeTracker.recordAgentTokenSwap(rewardToken, 100e6, 50e6);

        assertEq(feeTracker.getAgentYieldTokenFeesOwed(address(wallet), rewardToken), 0);
        assertEq(feeTracker.getFeesOwed(address(wallet)), 50e6);
    }

    function test_FeePaymentReducesFeesOwed() public {
        AgentWalletV1 wallet = _createWallet();

        vm.prank(address(wallet));
        feeTracker.recordAgentYieldEarned(500e6);
        assertEq(feeTracker.getFeesOwed(address(wallet)), 50e6);

        vm.prank(address(wallet));
        feeTracker.recordFeePaid(30e6);
        assertEq(feeTracker.getFeesOwed(address(wallet)), 20e6);
    }

    function test_MaxFeeRateEnforced() public {
        vm.prank(admin);
        vm.expectRevert(YieldSeekerErrors.InvalidFeeRate.selector);
        feeTracker.setFeeConfig(5001, feeCollector);
    }
}
