// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeWallet} from "../mocks/MockFeeWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract YieldFeeModuleTest is Test {
    YieldSeekerFeeTracker internal feeTracker;
    YieldSeekerYieldFeeModule internal vaultFees;
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
        vaultFees = new YieldSeekerYieldFeeModule(feeTracker, 5_000);

        vm.startPrank(admin);
        feeTracker.setFeeModule(YIELD_FEE, vaultFees);
        feeTracker.setPlanRate(0, YIELD_FEE, DEFAULT_FEE_RATE);
        vm.stopPrank();
    }

    function testFeesAreRecordedForTheCallingWallet() public {
        _recordYield(agent1, 1_000);
        _recordYield(agent2, 2_000);

        assertEq(vaultFees.feesCharged(address(agent1)), 100);
        assertEq(vaultFees.feesCharged(address(agent2)), 200);
        assertEq(vaultFees.feesDue(address(agent1)), 100);
        assertEq(vaultFees.feesDue(address(agent2)), 200);
    }

    function testShareWithdrawalsUseEachOwnersPlanRate() public {
        address vault = makeAddr("vault");
        vm.prank(admin);
        feeTracker.setPlanRate(1, YIELD_FEE, 500);
        vm.prank(admin);
        feeTracker.assignPlan(owner1, 1);
        _recordDeposit(agent1, vault, 1_000e6);
        _recordDeposit(agent2, vault, 1_000e6);

        _recordShareWithdraw(agent1, vault, 1_000e18, 1_000e18, 1_100e6);
        _recordShareWithdraw(agent2, vault, 1_000e18, 1_000e18, 1_100e6);

        assertEq(vaultFees.feesCharged(address(agent1)), 5e6);
        assertEq(vaultFees.feesCharged(address(agent2)), 10e6);
    }

    function testAssetWithdrawalsUseEachOwnersPlanRate() public {
        address vault = makeAddr("vault");
        vm.prank(admin);
        feeTracker.setPlanRate(1, YIELD_FEE, 500);
        vm.prank(admin);
        feeTracker.assignPlan(owner1, 1);
        _recordDeposit(agent1, vault, 1_000e6);
        _recordDeposit(agent2, vault, 1_000e6);

        _recordAssetWithdraw(agent1, vault, 1_100e6, 1_100e6, 1_100e6);
        _recordAssetWithdraw(agent2, vault, 1_100e6, 1_100e6, 1_100e6);

        assertEq(vaultFees.feesCharged(address(agent1)), 5e6);
        assertEq(vaultFees.feesCharged(address(agent2)), 10e6);
    }

    function testPositionsAreIsolatedByWalletAndVault() public {
        address vault1 = makeAddr("vault1");
        address vault2 = makeAddr("vault2");
        _recordDeposit(agent1, vault1, 100e6);
        _recordDeposit(agent1, vault1, 400e6);
        _recordDeposit(agent1, vault2, 200e6);
        _recordDeposit(agent2, vault1, 300e6);

        assertEq(vaultFees.costBasis(address(agent1), vault1), 500e6);
        assertEq(vaultFees.costBasis(address(agent1), vault2), 200e6);
        assertEq(vaultFees.costBasis(address(agent2), vault1), 300e6);
    }

    function testWithdrawalWithoutPositionChargesTheValueAsYield() public {
        address vault = makeAddr("vault");
        _recordShareWithdraw(agent1, vault, 100e18, 100e18, 101e6);

        assertEq(vaultFees.feesDue(address(agent1)), 10.1e6);
        assertEq(vaultFees.costBasis(address(agent1), vault), 0);
    }

    function testLargePositionWithdrawalCalculatesProfitWithoutOverflow() public {
        address vault = makeAddr("vault");
        uint256 assetsDeposited = type(uint128).max;
        uint256 sharesReceived = type(uint128).max;
        _recordDeposit(agent1, vault, assetsDeposited);
        _recordShareWithdraw(agent1, vault, sharesReceived, sharesReceived, assetsDeposited + 1_000e6);

        assertEq(vaultFees.feesDue(address(agent1)), 100e6);
    }

    function testShareWithdrawalChargesProfitAndClearsPosition() public {
        address vault = makeAddr("vault");
        _recordDeposit(agent1, vault, 10e6);
        assertEq(vaultFees.costBasis(address(agent1), vault), 10e6);

        vm.expectEmit(true, false, false, true, address(vaultFees));
        emit YieldRecorded(address(agent1), 1e6, 0.1e6);
        _recordShareWithdraw(agent1, vault, 10e18, 10e18, 11e6);

        assertEq(vaultFees.feesDue(address(agent1)), 0.1e6);
        assertEq(vaultFees.costBasis(address(agent1), vault), 0);
    }

    function testPartialProfitAndLossWithdrawalsUpdatePosition() public {
        address vault = makeAddr("vault");
        _recordDeposit(agent1, vault, 1_000e6);
        _recordShareWithdraw(agent1, vault, 500e18, 1_000e18, 550e6);

        assertEq(vaultFees.costBasis(address(agent1), vault), 500e6);
        assertEq(vaultFees.feesDue(address(agent1)), 5e6);

        _recordShareWithdraw(agent1, vault, 500e18, 500e18, 450e6);
        assertEq(vaultFees.costBasis(address(agent1), vault), 0);
        assertEq(vaultFees.feesDue(address(agent1)), 5e6);
    }

    function testPartialWithdrawalSpreadsCostBasisAcrossRewardShares() public {
        address vault = makeAddr("vault");
        _recordDeposit(agent1, vault, 1_000e6);
        _recordShareWithdraw(agent1, vault, 500e18, 1_100e18, 550e6);

        assertEq(vaultFees.feesCharged(address(agent1)), 9_545_454);
        assertEq(vaultFees.costBasis(address(agent1), vault), 545_454_546);
    }

    function testRewardSharesAreChargedOnceAsYieldAtWithdrawal() public {
        address vault = makeAddr("vault");
        _recordDeposit(agent1, vault, 1_000e6);
        assertEq(vaultFees.feesCharged(address(agent1)), 0);

        _recordShareWithdraw(agent1, vault, 1_100e18, 1_100e18, 1_100e6);

        assertEq(vaultFees.feesCharged(address(agent1)), 10e6);
        assertEq(vaultFees.feesDue(address(agent1)), 10e6);
        assertEq(vaultFees.costBasis(address(agent1), vault), 0);
    }

    function testRewardSharesAndProfitAreChargedAsYieldOnFullWithdrawal() public {
        address vault = makeAddr("vault");
        _recordDeposit(agent1, vault, 1_000e6);

        _recordShareWithdraw(agent1, vault, 1_200e18, 1_200e18, 1_320e6);

        assertEq(vaultFees.feesCharged(address(agent1)), 32e6);
        assertEq(vaultFees.costBasis(address(agent1), vault), 0);
    }

    function testPartialAssetWithdrawalChargesRebasingYieldProportionally() public {
        address vault = makeAddr("vault");
        _recordDeposit(agent1, vault, 1_000e6);

        _recordAssetWithdraw(agent1, vault, 550e6, 1_100e6, 550e6);

        assertEq(vaultFees.feesCharged(address(agent1)), 5e6);
        assertEq(vaultFees.costBasis(address(agent1), vault), 500e6);
    }

    function testAssetWithdrawalRateIncreaseBeforeSettlement() public {
        address vault = makeAddr("vault");
        _recordDeposit(agent1, vault, 1_000e6);

        vm.prank(admin);
        feeTracker.setPlanRate(0, YIELD_FEE, 2_000);
        _recordAssetWithdraw(agent1, vault, 1_100e6, 1_100e6, 1_100e6);

        assertEq(vaultFees.feesCharged(address(agent1)), 20e6);
    }

    function testAssetWithdrawalRateDecreaseBeforeSettlement() public {
        address vault = makeAddr("vault");
        vm.prank(admin);
        feeTracker.setPlanRate(0, YIELD_FEE, 2_000);
        _recordDeposit(agent1, vault, 1_000e6);

        vm.prank(admin);
        feeTracker.setPlanRate(0, YIELD_FEE, DEFAULT_FEE_RATE);
        _recordAssetWithdraw(agent1, vault, 1_100e6, 1_100e6, 1_100e6);

        assertEq(vaultFees.feesCharged(address(agent1)), 10e6);
    }

    function testAssetWithdrawalChargesRebasingYieldOnceAtWithdrawal() public {
        address vault = makeAddr("vault");
        _recordDeposit(agent1, vault, 1_000e6);

        _recordAssetWithdraw(agent1, vault, 1_100e6, 1_100e6, 1_100e6);

        assertEq(vaultFees.feesCharged(address(agent1)), 10e6);
        assertEq(vaultFees.costBasis(address(agent1), vault), 0);
    }

    function testYieldTokenSalesChargeFeesOnBaseAssetReceived() public {
        _recordRewardTokenSale(agent1, 5e6);
        assertEq(vaultFees.feesCharged(address(agent1)), 0.5e6);

        _recordRewardTokenSale(agent1, 95e6);
        assertEq(vaultFees.feesCharged(address(agent1)), 10e6);
    }

    function testFeePaymentReducesReserveAndOnlyBaseAssetMayLeave() public {
        address rewardToken = makeAddr("rewardToken");
        _recordYield(agent1, 100e6);

        (bool baseAllowed, uint256 baseReserved) = vaultFees.withdrawReserve(address(agent1), address(baseAsset));
        (bool rewardAllowed, uint256 rewardReserved) = vaultFees.withdrawReserve(address(agent1), rewardToken);
        assertTrue(baseAllowed);
        assertEq(baseReserved, 10e6);
        assertFalse(rewardAllowed);
        assertEq(rewardReserved, 0);

        agent1.execute(address(vaultFees), abi.encodeCall(vaultFees.recordFeePaid, (2e6)));
        assertEq(vaultFees.feesDue(address(agent1)), 8e6);
        (, baseReserved) = vaultFees.withdrawReserve(address(agent1), address(baseAsset));
        assertEq(baseReserved, 8e6);
    }

    function testZeroAmountRewardTokenSaleDoesNotChangeFeesOwed() public {
        _recordRewardTokenSale(agent1, 0);

        assertEq(vaultFees.feesCharged(address(agent1)), 0);
        assertEq(vaultFees.feesDue(address(agent1)), 0);
    }

    function _recordDeposit(MockFeeWallet wallet, address vault, uint256 assets) internal {
        wallet.execute(address(vaultFees), abi.encodeCall(vaultFees.onDeposit, (vault, assets)));
    }

    function _recordShareWithdraw(MockFeeWallet wallet, address vault, uint256 spent, uint256 heldBefore, uint256 assetsReceived) internal {
        wallet.execute(address(vaultFees), abi.encodeCall(vaultFees.onWithdraw, (vault, spent, heldBefore, assetsReceived)));
    }

    function _recordAssetWithdraw(MockFeeWallet wallet, address vault, uint256 spent, uint256 heldBefore, uint256 assetsReceived) internal {
        wallet.execute(address(vaultFees), abi.encodeCall(vaultFees.onWithdraw, (vault, spent, heldBefore, assetsReceived)));
    }

    function _recordYield(MockFeeWallet wallet, uint256 amount) internal {
        wallet.execute(address(vaultFees), abi.encodeCall(vaultFees.onClaim, (address(baseAsset), amount)));
    }

    function _recordRewardTokenSale(MockFeeWallet wallet, uint256 baseReceived) internal {
        wallet.execute(address(vaultFees), abi.encodeCall(vaultFees.onSwap, (makeAddr("rewardToken"), baseReceived, address(baseAsset), baseReceived)));
    }
}
