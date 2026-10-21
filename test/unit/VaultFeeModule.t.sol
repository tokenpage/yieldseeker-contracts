// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InvalidAsset} from "../../src/AgentWalletV1.sol";
import {YieldSeekerVaultFeeModule} from "../../src/fees/VaultFeeModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeWallet} from "../mocks/MockFeeWallet.sol";
import {Test} from "forge-std/Test.sol";

contract VaultFeeModuleTest is Test {
    address internal admin = makeAddr("admin");
    address internal planManager = makeAddr("planManager");
    address internal collector = makeAddr("collector");
    address internal ownerA = makeAddr("ownerA");
    address internal ownerB = makeAddr("ownerB");

    MockERC20 internal baseAsset;
    MockERC20 internal rewardToken;
    MockFeeWallet internal walletA;
    MockFeeWallet internal walletB;
    YieldSeekerVaultFeeModule internal module;
    address internal vault = makeAddr("vault");

    function setUp() public {
        baseAsset = new MockERC20("Base", "BASE");
        rewardToken = new MockERC20("Reward", "RWD");
        walletA = new MockFeeWallet(ownerA, baseAsset);
        walletB = new MockFeeWallet(ownerB, baseAsset);
        module = new YieldSeekerVaultFeeModule(admin, planManager, collector, 2_000, 1_000);

        vm.prank(admin);
        module.setPlanRate(1, 500);
        vm.prank(planManager);
        module.assignPlan(ownerA, 1);
    }

    function testShareWithdrawalsChargeEachOwnersRateOnlyOnProfit() public {
        _recordShareDeposit(walletA, 1_000e6, 1_000e18);
        _recordShareDeposit(walletB, 1_000e6, 1_000e18);

        walletA.execute(address(module), abi.encodeCall(module.recordAgentVaultShareWithdraw, (vault, 1_000e18, 1_100e6)));
        walletB.execute(address(module), abi.encodeCall(module.recordAgentVaultShareWithdraw, (vault, 1_000e18, 1_100e6)));

        assertEq(module.agentFeesCharged(address(walletA)), 5e6);
        assertEq(module.agentFeesCharged(address(walletB)), 10e6);

        MockFeeWallet noProfitWallet = new MockFeeWallet(makeAddr("noProfitOwner"), baseAsset);
        _recordShareDeposit(noProfitWallet, 1_000e6, 1_000e18);
        noProfitWallet.execute(address(module), abi.encodeCall(module.recordAgentVaultShareWithdraw, (vault, 1_000e18, 900e6)));
        assertEq(module.agentFeesCharged(address(noProfitWallet)), 0);
    }

    function testAssetWithdrawalsChargeEachOwnersRateOnlyOnProfit() public {
        _recordShareDeposit(walletA, 1_000e6, 1_000e18);
        _recordShareDeposit(walletB, 1_000e6, 1_000e18);

        walletA.execute(address(module), abi.encodeCall(module.recordAgentVaultAssetWithdraw, (vault, 1_100e6, 1_100e6, 1e18)));
        walletB.execute(address(module), abi.encodeCall(module.recordAgentVaultAssetWithdraw, (vault, 1_100e6, 1_100e6, 1e18)));

        assertEq(module.agentFeesCharged(address(walletA)), 5e6);
        assertEq(module.agentFeesCharged(address(walletB)), 10e6);
    }

    function testYieldTokenFeesConvertWhenSwappedWithoutBeingChargedAgain() public {
        walletB.execute(address(module), abi.encodeCall(module.recordAgentYieldTokenEarned, (address(rewardToken), 100e6)));
        assertEq(module.getAgentYieldTokenFeesOwed(address(walletB), address(rewardToken)), 10e6);

        walletB.execute(address(module), abi.encodeCall(module.recordAgentTokenSwap, (address(rewardToken), 5e6, 5e6)));
        assertEq(module.getAgentYieldTokenFeesOwed(address(walletB), address(rewardToken)), 5e6);
        assertEq(module.agentFeesCharged(address(walletB)), 5e6);

        walletB.execute(address(module), abi.encodeCall(module.recordAgentTokenSwap, (address(rewardToken), 95e6, 95e6)));
        assertEq(module.getAgentYieldTokenFeesOwed(address(walletB), address(rewardToken)), 0);
        assertEq(module.agentFeesCharged(address(walletB)), 10e6);
    }

    function testFeePaymentReducesOwedAndOnlyBaseAssetIsWithdrawable() public {
        walletA.execute(address(module), abi.encodeCall(module.recordAgentYieldEarned, (100e6)));

        assertEq(module.getFeesOwed(address(walletA)), 5e6);
        assertEq(module.withdrawable(address(walletA), address(baseAsset), 100e6), 95e6);
        vm.expectRevert(InvalidAsset.selector);
        module.withdrawable(address(walletA), address(rewardToken), 100e6);
        assertEq(module.withdrawable(address(walletA), address(baseAsset), 3e6), 0);

        walletA.execute(address(module), abi.encodeCall(module.recordFeePaid, (2e6)));
        assertEq(module.agentFeesPaid(address(walletA)), 2e6);
        assertEq(module.getFeesOwed(address(walletA)), 3e6);

        walletA.execute(address(module), abi.encodeCall(module.recordFeePaid, (10e6)));
        assertEq(module.agentFeesPaid(address(walletA)), 12e6);
        assertEq(module.getFeesOwed(address(walletA)), 0);
    }

    function _recordShareDeposit(MockFeeWallet wallet, uint256 assets, uint256 shares) internal {
        wallet.execute(address(module), abi.encodeCall(module.recordAgentVaultShareDeposit, (vault, assets, shares)));
    }
}
