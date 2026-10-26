// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {VAULT_FEE, YieldSeekerVaultFeeModule} from "../../src/fees/VaultFeeModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeWallet} from "../mocks/MockFeeWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract VaultFeeModuleTest is Test {
    YieldSeekerFeeTracker internal feeTracker;
    YieldSeekerVaultFeeModule internal vaultFees;
    MockERC20 internal baseAsset;
    MockFeeWallet internal agent1;
    MockFeeWallet internal agent2;

    address internal admin = makeAddr("admin");
    address internal collector = makeAddr("collector");
    address internal owner1 = makeAddr("owner1");
    address internal owner2 = makeAddr("owner2");

    uint256 internal constant DEFAULT_FEE_RATE = 1_000;

    event YieldRecorded(address indexed wallet, uint256 yield, uint256 fee);

    function setUp() public {
        baseAsset = new MockERC20("Base", "BASE");
        agent1 = new MockFeeWallet(owner1, IERC20(address(baseAsset)));
        agent2 = new MockFeeWallet(owner2, IERC20(address(baseAsset)));
        feeTracker = new YieldSeekerFeeTracker(admin, admin, collector);
        vaultFees = new YieldSeekerVaultFeeModule(feeTracker, 5_000);

        vm.startPrank(admin);
        feeTracker.addFeeModule(VAULT_FEE, vaultFees);
        feeTracker.setPlanRate(0, VAULT_FEE, DEFAULT_FEE_RATE);
        vm.stopPrank();
    }

    function testFeesAreRecordedForTheCallingWallet() public {
        agent1.execute(address(vaultFees), abi.encodeCall(vaultFees.recordAgentYieldEarned, (1_000)));
        agent2.execute(address(vaultFees), abi.encodeCall(vaultFees.recordAgentYieldEarned, (2_000)));

        assertEq(vaultFees.agentFeesCharged(address(agent1)), 100);
        assertEq(vaultFees.agentFeesCharged(address(agent2)), 200);
        assertEq(vaultFees.getFeesOwed(address(agent1)), 100);
        assertEq(vaultFees.getFeesOwed(address(agent2)), 200);
    }

    function testShareWithdrawalsUseEachOwnersPlanRate() public {
        address vault = makeAddr("vault");
        vm.prank(admin);
        feeTracker.setPlanRate(1, VAULT_FEE, 500);
        vm.prank(admin);
        feeTracker.assignPlan(owner1, 1);
        _recordShareDeposit(agent1, vault, 1_000e6, 1_000e18);
        _recordShareDeposit(agent2, vault, 1_000e6, 1_000e18);

        _recordShareWithdraw(agent1, vault, 1_000e18, 1_100e6);
        _recordShareWithdraw(agent2, vault, 1_000e18, 1_100e6);

        assertEq(vaultFees.agentFeesCharged(address(agent1)), 5e6);
        assertEq(vaultFees.agentFeesCharged(address(agent2)), 10e6);
    }

    function testAssetWithdrawalsUseEachOwnersPlanRate() public {
        address vault = makeAddr("vault");
        vm.prank(admin);
        feeTracker.setPlanRate(1, VAULT_FEE, 500);
        vm.prank(admin);
        feeTracker.assignPlan(owner1, 1);
        _recordShareDeposit(agent1, vault, 1_000e6, 1_000e18);
        _recordShareDeposit(agent2, vault, 1_000e6, 1_000e18);

        _recordAssetWithdraw(agent1, vault, 1_100e6, 1_100e6);
        _recordAssetWithdraw(agent2, vault, 1_100e6, 1_100e6);

        assertEq(vaultFees.agentFeesCharged(address(agent1)), 5e6);
        assertEq(vaultFees.agentFeesCharged(address(agent2)), 10e6);
    }

    function testPositionsAreIsolatedByWalletAndVault() public {
        address vault1 = makeAddr("vault1");
        address vault2 = makeAddr("vault2");
        _recordShareDeposit(agent1, vault1, 100e6, 100e18);
        _recordShareDeposit(agent1, vault1, 400e6, 400e18);
        _recordShareDeposit(agent1, vault2, 200e6, 200e18);
        _recordShareDeposit(agent2, vault1, 300e6, 300e18);

        (uint256 costBasis, uint256 shares) = vaultFees.getAgentVaultPosition(address(agent1), vault1);
        assertEq(costBasis, 500e6);
        assertEq(shares, 500e18);
        (costBasis, shares) = vaultFees.getAgentVaultPosition(address(agent1), vault2);
        assertEq(costBasis, 200e6);
        assertEq(shares, 200e18);
        (costBasis, shares) = vaultFees.getAgentVaultPosition(address(agent2), vault1);
        assertEq(costBasis, 300e6);
        assertEq(shares, 300e18);
    }

    function testWithdrawalWithoutPositionDoesNotChargeFees() public {
        address vault = makeAddr("vault");
        _recordShareWithdraw(agent1, vault, 100e18, 101e6);

        assertEq(vaultFees.getFeesOwed(address(agent1)), 0);
        (uint256 costBasis, uint256 shares) = vaultFees.getAgentVaultPosition(address(agent1), vault);
        assertEq(costBasis, 0);
        assertEq(shares, 0);
    }

    function testLargePositionWithdrawalCalculatesProfitWithoutOverflow() public {
        address vault = makeAddr("vault");
        uint256 assetsDeposited = type(uint128).max;
        uint256 sharesReceived = type(uint128).max;
        _recordShareDeposit(agent1, vault, assetsDeposited, sharesReceived);
        _recordShareWithdraw(agent1, vault, sharesReceived, assetsDeposited + 1_000e6);

        assertEq(vaultFees.getFeesOwed(address(agent1)), 100e6);
    }

    function testShareWithdrawalChargesProfitAndClearsPosition() public {
        address vault = makeAddr("vault");
        _recordShareDeposit(agent1, vault, 10e6, 10e18);
        (uint256 costBasis, uint256 shares) = vaultFees.getAgentVaultPosition(address(agent1), vault);
        assertEq(costBasis, 10e6);
        assertEq(shares, 10e18);

        vm.expectEmit(true, false, false, true, address(vaultFees));
        emit YieldRecorded(address(agent1), 1e6, 0.1e6);
        _recordShareWithdraw(agent1, vault, 10e18, 11e6);

        assertEq(vaultFees.getFeesOwed(address(agent1)), 0.1e6);
        (costBasis, shares) = vaultFees.getAgentVaultPosition(address(agent1), vault);
        assertEq(costBasis, 0);
        assertEq(shares, 0);
    }

    function testPartialProfitAndLossWithdrawalsUpdatePosition() public {
        address vault = makeAddr("vault");
        _recordShareDeposit(agent1, vault, 1_000e6, 1_000e18);
        _recordShareWithdraw(agent1, vault, 500e18, 550e6);

        (uint256 costBasis, uint256 shares) = vaultFees.getAgentVaultPosition(address(agent1), vault);
        assertEq(costBasis, 500e6);
        assertEq(shares, 500e18);
        assertEq(vaultFees.getFeesOwed(address(agent1)), 5e6);

        _recordShareWithdraw(agent1, vault, 500e18, 450e6);
        (costBasis, shares) = vaultFees.getAgentVaultPosition(address(agent1), vault);
        assertEq(costBasis, 0);
        assertEq(shares, 0);
        assertEq(vaultFees.getFeesOwed(address(agent1)), 5e6);
    }

    function testShareWithdrawalWithYieldTokenFeesDoesNotDoubleChargeProfit() public {
        address vault = makeAddr("vault");
        _recordShareDeposit(agent1, vault, 1_000e6, 1_000e18);
        _recordYieldToken(agent1, vault, 100e18);
        assertEq(vaultFees.agentYieldTokenFeesOwed(address(agent1), vault), 10e18);

        _recordShareWithdraw(agent1, vault, 500e18, 550e6);

        assertEq(vaultFees.agentFeesCharged(address(agent1)), 11e6);
        assertEq(vaultFees.agentYieldTokenFeesOwed(address(agent1), vault), 0);
    }

    function testOverwithdrawalWithYieldTokenFeesDoesNotDoubleCharge() public {
        address vault = makeAddr("vault");
        _recordShareDeposit(agent1, vault, 1_000e6, 1_000e18);
        _recordYieldToken(agent1, vault, 200e18);
        assertEq(vaultFees.agentYieldTokenFeesOwed(address(agent1), vault), 20e18);

        _recordShareWithdraw(agent1, vault, 1_200e18, 1_320e6);

        assertEq(vaultFees.agentFeesCharged(address(agent1)), 22e6);
        (uint256 costBasis, uint256 shares) = vaultFees.getAgentVaultPosition(address(agent1), vault);
        assertEq(costBasis, 0);
        assertEq(shares, 0);
    }

    function testAssetWithdrawalCapsFeeAtAssetsReceived() public {
        address vault = makeAddr("vault");
        _recordShareDeposit(agent1, vault, 50e6, 50e6);
        _recordYieldToken(agent1, vault, 1_000e6);
        assertEq(vaultFees.agentYieldTokenFeesOwed(address(agent1), vault), 100e6);

        _recordAssetWithdraw(agent1, vault, 200e6, 1_050e6);

        assertTrue(vaultFees.agentFeesCharged(address(agent1)) <= 200e6);
        assertTrue(vaultFees.agentFeesCharged(address(agent1)) > 0);
    }

    function testAssetWithdrawalSettlesVaultTokenFeesOneToOne() public {
        address vault = makeAddr("vault");
        _recordShareDeposit(agent1, vault, 1_000e6, 1_000e6);
        _recordYieldToken(agent1, vault, 100e6);
        assertEq(vaultFees.agentYieldTokenFeesOwed(address(agent1), vault), 10e6);

        _recordAssetWithdraw(agent1, vault, 550e6, 1_100e6);

        assertEq(vaultFees.agentFeesCharged(address(agent1)), 5e6);
        assertEq(vaultFees.agentYieldTokenFeesOwed(address(agent1), vault), 5e6);
    }

    function testAssetWithdrawalDoesNotDoubleChargeRewardValue() public {
        address vault = makeAddr("vault");
        _recordShareDeposit(agent1, vault, 1_000e6, 1_000e6);
        _recordYieldToken(agent1, vault, 100e6);

        _recordAssetWithdraw(agent1, vault, 1_100e6, 1_100e6);

        assertEq(vaultFees.agentFeesCharged(address(agent1)), 10e6);
        (uint256 costBasis, uint256 shares) = vaultFees.getAgentVaultPosition(address(agent1), vault);
        assertEq(costBasis, 0);
        assertEq(shares, 0);
    }

    function testAssetWithdrawalRateIncreaseBeforeSettlement() public {
        address vault = makeAddr("vault");
        _recordShareDeposit(agent1, vault, 1_000e6, 1_000e6);
        _recordYieldToken(agent1, vault, 100e6);

        vm.prank(admin);
        feeTracker.setPlanRate(0, VAULT_FEE, 2_000);
        _recordAssetWithdraw(agent1, vault, 1_100e6, 1_100e6);

        assertEq(vaultFees.agentFeesCharged(address(agent1)), 20e6);
    }

    function testAssetWithdrawalRateDecreaseBeforeSettlement() public {
        address vault = makeAddr("vault");
        vm.prank(admin);
        feeTracker.setPlanRate(0, VAULT_FEE, 2_000);
        _recordShareDeposit(agent1, vault, 1_000e6, 1_000e6);
        _recordYieldToken(agent1, vault, 100e6);

        vm.prank(admin);
        feeTracker.setPlanRate(0, VAULT_FEE, DEFAULT_FEE_RATE);
        _recordAssetWithdraw(agent1, vault, 1_100e6, 1_100e6);

        assertEq(vaultFees.agentFeesCharged(address(agent1)), 20e6);
    }

    function testShareWithdrawalDoesNotDoubleChargeRewardValue() public {
        address vault = makeAddr("vault");
        _recordShareDeposit(agent1, vault, 1_000e6, 1_000e18);
        _recordYieldToken(agent1, vault, 100e18);

        _recordShareWithdraw(agent1, vault, 500e18, 550e6);

        assertEq(vaultFees.agentFeesCharged(address(agent1)), 11e6);
    }

    function testYieldTokenFeesConvertOnSwapWithoutBeingChargedAgain() public {
        address rewardToken = makeAddr("rewardToken");
        _recordYieldToken(agent1, rewardToken, 100e6);
        assertEq(vaultFees.agentYieldTokenFeesOwed(address(agent1), rewardToken), 10e6);

        _recordTokenSwap(agent1, rewardToken, 5e6, 5e6);
        assertEq(vaultFees.agentYieldTokenFeesOwed(address(agent1), rewardToken), 5e6);
        assertEq(vaultFees.agentFeesCharged(address(agent1)), 5e6);

        _recordTokenSwap(agent1, rewardToken, 95e6, 95e6);
        assertEq(vaultFees.agentYieldTokenFeesOwed(address(agent1), rewardToken), 0);
        assertEq(vaultFees.agentFeesCharged(address(agent1)), 10e6);
    }

    function testFeePaymentReducesReserveAndOnlyBaseAssetMayLeave() public {
        address rewardToken = makeAddr("rewardToken");
        _recordYieldToken(agent1, rewardToken, 100e6);
        _recordYieldEarned(agent1, 100e6);

        (bool baseAllowed, uint256 baseReserved) = vaultFees.withdrawReserve(address(agent1), address(baseAsset));
        (bool rewardAllowed, uint256 rewardReserved) = vaultFees.withdrawReserve(address(agent1), rewardToken);
        assertTrue(baseAllowed);
        assertEq(baseReserved, 10e6);
        assertFalse(rewardAllowed);
        assertEq(rewardReserved, 10e6);

        agent1.execute(address(vaultFees), abi.encodeCall(vaultFees.recordFeePaid, (2e6)));
        assertEq(vaultFees.getFeesOwed(address(agent1)), 8e6);
        (, baseReserved) = vaultFees.withdrawReserve(address(agent1), address(baseAsset));
        assertEq(baseReserved, 8e6);
    }

    function testZeroAmountSwapDoesNotChangeFeesOwed() public {
        address rewardToken = makeAddr("rewardToken");
        _recordYieldToken(agent1, rewardToken, 100e18);
        _recordTokenSwap(agent1, rewardToken, 0, 100e6);

        assertEq(vaultFees.agentYieldTokenFeesOwed(address(agent1), rewardToken), 10e18);
        assertEq(vaultFees.getFeesOwed(address(agent1)), 0);
    }

    function _recordShareDeposit(MockFeeWallet wallet, address vault, uint256 assets, uint256 shares) internal {
        wallet.execute(address(vaultFees), abi.encodeCall(vaultFees.recordAgentVaultShareDeposit, (vault, assets, shares)));
    }

    function _recordShareWithdraw(MockFeeWallet wallet, address vault, uint256 shares, uint256 assets) internal {
        wallet.execute(address(vaultFees), abi.encodeCall(vaultFees.recordAgentVaultShareWithdraw, (vault, shares, assets)));
    }

    function _recordAssetWithdraw(MockFeeWallet wallet, address vault, uint256 assets, uint256 totalBalance) internal {
        wallet.execute(address(vaultFees), abi.encodeCall(vaultFees.recordAgentVaultAssetWithdraw, (vault, assets, totalBalance)));
    }

    function _recordYieldEarned(MockFeeWallet wallet, uint256 amount) internal {
        wallet.execute(address(vaultFees), abi.encodeCall(vaultFees.recordAgentYieldEarned, (amount)));
    }

    function _recordYieldToken(MockFeeWallet wallet, address token, uint256 amount) internal {
        wallet.execute(address(vaultFees), abi.encodeCall(vaultFees.recordAgentYieldTokenEarned, (token, amount)));
    }

    function _recordTokenSwap(MockFeeWallet wallet, address token, uint256 swappedAmount, uint256 baseReceived) internal {
        wallet.execute(address(vaultFees), abi.encodeCall(vaultFees.recordAgentTokenSwap, (token, swappedAmount, baseReceived)));
    }
}
