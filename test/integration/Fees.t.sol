// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {YieldSeekerAaveV3LendingAdapter} from "../../src/adapters/AaveV3LendingAdapter.sol";
import {AWKUniswapV3SwapAdapter} from "../../src/agentwalletkit/adapters/AWKUniswapV3SwapAdapter.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeePlanChoice, InsufficientGasForModules} from "../../src/fees/FeeTracker.sol";
import {IYieldSeekerFeeModule} from "../../src/fees/IYieldSeekerFeeModule.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../src/fees/YieldFeeModule.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

error FeeModuleActionFailed();

contract ActionFailingFeeModule is IYieldSeekerFeeModule {
    address public immutable override FEE_TRACKER;
    bytes32 public immutable override FEE_TYPE;

    constructor(address tracker, bytes32 feeType) {
        FEE_TRACKER = tracker;
        FEE_TYPE = feeType;
    }

    function isValidPlan(bytes calldata) external pure override returns (bool) {
        return true;
    }

    function onAction(address, bytes32, bytes calldata, uint256) external pure override returns (uint256) {
        revert FeeModuleActionFailed();
    }

    function isAccountedToken(address, address) external pure override returns (bool) {
        return false;
    }

    function feesOwedInBaseAsset(address) external pure override returns (uint256) {
        return 0;
    }
}

contract ViewFailingFeeModule is IYieldSeekerFeeModule {
    address public immutable override FEE_TRACKER;
    bytes32 public immutable override FEE_TYPE;

    constructor(address tracker, bytes32 feeType) {
        FEE_TRACKER = tracker;
        FEE_TYPE = feeType;
    }

    function isValidPlan(bytes calldata) external pure override returns (bool) {
        return true;
    }

    function onAction(address, bytes32, bytes calldata, uint256) external pure override returns (uint256) {
        return 0;
    }

    function isAccountedToken(address, address) external pure override returns (bool) {
        revert FeeModuleActionFailed();
    }

    function feesOwedInBaseAsset(address) external pure override returns (uint256) {
        revert FeeModuleActionFailed();
    }
}

contract FeesIntegrationTest is IntegrationBase {
    uint256 private constant USDC = 1e6;
    bytes32 private constant ACTION_FAILURE_FEE = keccak256("actionFailure");
    bytes32 private constant VIEW_FAILURE_FEE = keccak256("viewFailure");

    function testWalletPlansAreChosenAtCreationForEachProfile() public {
        AgentWallet defaultVaultWallet = _createVaultWallet(owner, 1);
        uint256 vaultPlanId = vaultFeeTracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 500})));
        uint256 borrowYieldPlanId = borrowFeeTracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 2_000})));
        uint256 borrowPlanId = borrowFeeTracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: 100})));

        FeePlanChoice[] memory vaultPlans = new FeePlanChoice[](1);
        vaultPlans[0] = FeePlanChoice({feeType: YIELD_FEE, planId: vaultPlanId});
        AgentWallet customVaultWallet = _createVaultWallet(owner, 2, vaultPlans);

        FeePlanChoice[] memory borrowPlans = new FeePlanChoice[](2);
        borrowPlans[0] = FeePlanChoice({feeType: YIELD_FEE, planId: borrowYieldPlanId});
        borrowPlans[1] = FeePlanChoice({feeType: BORROW_FEE, planId: borrowPlanId});
        AgentWallet borrowWallet = _createBorrowWallet(owner, 3, borrowPlans);

        uint256 collectorBefore = usdc.balanceOf(feeCollector);
        _fundWallet(defaultVaultWallet, address(usdc), 1_000 * USDC);
        _execute(defaultVaultWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.deposit.selector, 1_000 * USDC));
        usdc.mint(address(erc4626Vault), 100 * USDC);
        _execute(defaultVaultWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, 1_000 * USDC));
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 10 * USDC);

        _fundWallet(customVaultWallet, address(usdc), 1_000 * USDC);
        _execute(customVaultWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.deposit.selector, 1_000 * USDC));
        usdc.mint(address(erc4626Vault), 100 * USDC);
        _execute(customVaultWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, 1_000 * USDC));
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 15 * USDC);
        assertEq(usdc.balanceOf(address(customVaultWallet)), 1_095 * USDC);

        _claim(borrowWallet, address(usdc), 100 * USDC);
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 35 * USDC);
        assertEq(usdc.balanceOf(address(borrowWallet)), 80 * USDC);

        _fundWallet(borrowWallet, address(usdc), USDC);
        _executeLending(borrowWallet, aaveV3LendingAdapter.supplyCollateral.selector, USDC);
        _executeLending(borrowWallet, aaveV3LendingAdapter.borrow.selector, 1e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _executeLending(borrowWallet, aaveV3LendingAdapter.repay.selector, type(uint256).max);
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 55 * USDC);
        assertEq(borrowFeeModule.feesOwed(address(borrowWallet)), 0);
    }

    function testClaimFeesAreTrackedIndependentlyForEachWallet() public {
        AgentWallet firstWallet = _createVaultWallet(owner, 4);
        AgentWallet secondWallet = _createVaultWallet(owner, 5);
        uint256 collectorBefore = usdc.balanceOf(feeCollector);

        _claim(firstWallet, address(usdc), 100 * USDC);
        _claim(secondWallet, address(usdc), 200 * USDC);

        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 30 * USDC);
        assertEq(usdc.balanceOf(address(firstWallet)), 90 * USDC);
        assertEq(usdc.balanceOf(address(secondWallet)), 180 * USDC);
        assertEq(vaultYieldFeeModule.feesOwed(address(firstWallet)), 0);
        assertEq(vaultYieldFeeModule.feesOwed(address(secondWallet)), 0);
    }

    function testPartialAndFullWithdrawalsChargeOnlyRealizedYield() public {
        AgentWallet wallet = _createVaultWallet(owner, 10);
        _fundWallet(wallet, address(usdc), 1_000 * USDC);
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.deposit.selector, 1_000 * USDC));
        usdc.mint(address(erc4626Vault), 100 * USDC);
        uint256 collectorBefore = usdc.balanceOf(feeCollector);

        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, 500 * USDC));
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 5 * USDC);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(erc4626Vault)), 500 * USDC);
        assertEq(usdc.balanceOf(address(wallet)), 545 * USDC);

        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, 500 * USDC));
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 10 * USDC);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(erc4626Vault)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 1_090 * USDC);
    }

    function testNewFeeCollectorReceivesFeesFromTheNextAction() public {
        AgentWallet wallet = _createVaultWallet(owner, 30);
        address newCollector = makeAddr("new-collector");
        _fundWallet(wallet, address(usdc), 1_000 * USDC);
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.deposit.selector, 1_000 * USDC));
        usdc.mint(address(erc4626Vault), 100 * USDC);
        uint256 oldCollectorBefore = usdc.balanceOf(feeCollector);

        vm.prank(admin);
        vaultFeeTracker.setFeeCollector(newCollector);
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, 1_000 * USDC));

        assertEq(usdc.balanceOf(newCollector), 10 * USDC);
        assertEq(usdc.balanceOf(feeCollector), oldCollectorBefore);
    }

    function testLossWithdrawalReleasesBasisWithoutChargingFee() public {
        AgentWallet wallet = _createVaultWallet(owner, 11);
        _fundWallet(wallet, address(usdc), 1_000 * USDC);
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.deposit.selector, 1_000 * USDC));
        usdc.burn(address(erc4626Vault), 100 * USDC);
        uint256 collectorBefore = usdc.balanceOf(feeCollector);

        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, 1_000 * USDC));

        assertEq(usdc.balanceOf(feeCollector), collectorBefore);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(erc4626Vault)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 900 * USDC);
    }

    function testPartialProfitThenLossReleasesRemainingBasis() public {
        AgentWallet wallet = _createVaultWallet(owner, 15);
        _fundWallet(wallet, address(usdc), 1_000 * USDC);
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.deposit.selector, 1_000 * USDC));
        usdc.mint(address(erc4626Vault), 100 * USDC);
        uint256 collectorBefore = usdc.balanceOf(feeCollector);

        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, 500 * USDC));
        usdc.burn(address(erc4626Vault), 100 * USDC);
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, 500 * USDC));

        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 5 * USDC);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(erc4626Vault)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 995 * USDC);
    }

    function testRebasingWithdrawalsReleaseCostBasisProportionally() public {
        uint256 customPlanId = vaultFeeTracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: 500})));
        FeePlanChoice[] memory customPlans = new FeePlanChoice[](1);
        customPlans[0] = FeePlanChoice({feeType: YIELD_FEE, planId: customPlanId});
        AgentWallet customWallet = _createVaultWallet(owner, 12, customPlans);
        AgentWallet defaultWallet = _createVaultWallet(owner, 18);
        _fundWallet(customWallet, address(usdc), 1_000 * USDC);
        _fundWallet(defaultWallet, address(usdc), 1_000 * USDC);
        _execute(customWallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeWithSelector(aaveV3Adapter.deposit.selector, 1_000 * USDC));
        _execute(defaultWallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeWithSelector(aaveV3Adapter.deposit.selector, 1_000 * USDC));
        aaveV3Vault.addYield(address(customWallet), 100 * USDC);
        aaveV3Vault.addYield(address(defaultWallet), 100 * USDC);
        usdc.mint(address(aaveV3Vault), 200 * USDC);
        uint256 collectorBefore = usdc.balanceOf(feeCollector);

        _execute(customWallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeWithSelector(aaveV3Adapter.withdraw.selector, 550 * USDC));
        _execute(defaultWallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeWithSelector(aaveV3Adapter.withdraw.selector, 550 * USDC));
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 7_500_000);
        assertEq(vaultYieldFeeModule.costBasis(address(customWallet), address(aaveV3Vault)), 500 * USDC);
        assertEq(vaultYieldFeeModule.costBasis(address(defaultWallet), address(aaveV3Vault)), 500 * USDC);
        assertEq(usdc.balanceOf(address(customWallet)), 547_500_000);
        assertEq(usdc.balanceOf(address(defaultWallet)), 545 * USDC);

        _execute(customWallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeWithSelector(aaveV3Adapter.withdraw.selector, 550 * USDC));
        _execute(defaultWallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeWithSelector(aaveV3Adapter.withdraw.selector, 550 * USDC));
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 15 * USDC);
        assertEq(vaultYieldFeeModule.costBasis(address(customWallet), address(aaveV3Vault)), 0);
        assertEq(vaultYieldFeeModule.costBasis(address(defaultWallet), address(aaveV3Vault)), 0);
        assertEq(usdc.balanceOf(address(customWallet)), 1_095 * USDC);
        assertEq(usdc.balanceOf(address(defaultWallet)), 1_090 * USDC);
    }

    function testPositionsAreIsolatedByWalletAndVaultTarget() public {
        AgentWallet firstWallet = _createVaultWallet(owner, 16);
        AgentWallet secondWallet = _createVaultWallet(owner, 17);
        _fundWallet(firstWallet, address(usdc), 2_000 * USDC);
        _fundWallet(secondWallet, address(usdc), 1_000 * USDC);
        _execute(firstWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.deposit.selector, 1_000 * USDC));
        _execute(firstWallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeWithSelector(aaveV3Adapter.deposit.selector, 1_000 * USDC));
        _execute(secondWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.deposit.selector, 1_000 * USDC));
        usdc.mint(address(erc4626Vault), 200 * USDC);
        aaveV3Vault.addYield(address(firstWallet), 100 * USDC);
        usdc.mint(address(aaveV3Vault), 100 * USDC);
        uint256 collectorBefore = usdc.balanceOf(feeCollector);

        _execute(firstWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, 1_000 * USDC));
        _execute(secondWallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, 1_000 * USDC));
        _execute(firstWallet, address(aaveV3Adapter), address(aaveV3Vault), abi.encodeWithSelector(aaveV3Adapter.withdraw.selector, 1_100 * USDC));

        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 30 * USDC);
        assertEq(usdc.balanceOf(address(firstWallet)), 2_180 * USDC);
        assertEq(usdc.balanceOf(address(secondWallet)), 1_090 * USDC);
        assertEq(vaultYieldFeeModule.costBasis(address(firstWallet), address(erc4626Vault)), 0);
        assertEq(vaultYieldFeeModule.costBasis(address(firstWallet), address(aaveV3Vault)), 0);
        assertEq(vaultYieldFeeModule.costBasis(address(secondWallet), address(erc4626Vault)), 0);
    }

    function testUnpositionedSharesClaimsAndRewardSalesChargeWhenBaseAssetArrives() public {
        AgentWallet wallet = _createVaultWallet(owner, 13);
        uint256 directDeposit = 100 * USDC;
        usdc.mint(address(this), directDeposit);
        usdc.approve(address(erc4626Vault), directDeposit);
        uint256 shares = erc4626Vault.deposit(directDeposit, address(this));
        erc4626Vault.transfer(address(wallet), shares);
        uint256 collectorBefore = usdc.balanceOf(feeCollector);

        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, shares));
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 10 * USDC);
        assertEq(usdc.balanceOf(address(wallet)), 90 * USDC);

        _claim(wallet, address(usdc), 100 * USDC);
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 20 * USDC);
        assertEq(usdc.balanceOf(address(wallet)), 180 * USDC);

        _claim(wallet, address(rewardToken), 100e18);
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 20 * USDC);
        assertEq(rewardToken.balanceOf(address(wallet)), 100e18);

        address[] memory path = new address[](2);
        path[0] = address(rewardToken);
        path[1] = address(usdc);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3_000;
        AWKUniswapV3SwapAdapter.SwapRoute memory route = AWKUniswapV3SwapAdapter.SwapRoute({path: path, fees: fees});
        uniswapV3Router.setBuyAmount(20 * USDC);
        _execute(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), abi.encodeWithSelector(uniswapV3SwapAdapter.swap.selector, address(rewardToken), address(usdc), route, 100e18, 20 * USDC));

        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 22 * USDC);
        assertEq(usdc.balanceOf(address(wallet)), 198 * USDC);
        assertEq(rewardToken.balanceOf(address(wallet)), 0);
        assertEq(vaultYieldFeeModule.feesOwed(address(wallet)), 0);
    }

    function testMerklVaultShareRewardIsChargedWhenWithdrawn() public {
        AgentWallet wallet = _createVaultWallet(owner, 14);
        uint256 deposit = 100 * USDC;
        usdc.mint(address(this), deposit);
        usdc.approve(address(erc4626Vault), deposit);
        uint256 shares = erc4626Vault.deposit(deposit, address(this));
        erc4626Vault.transfer(address(merklDistributor), shares);
        uint256 collectorBefore = usdc.balanceOf(feeCollector);

        _claim(wallet, address(erc4626Vault), shares);
        assertEq(usdc.balanceOf(feeCollector), collectorBefore);
        assertEq(erc4626Vault.balanceOf(address(wallet)), shares);

        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, shares));

        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 10 * USDC);
        assertEq(usdc.balanceOf(address(wallet)), 90 * USDC);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(erc4626Vault)), 0);
    }

    function testRewardSharesSpreadCostBasisAcrossPartialAndFullWithdrawals() public {
        AgentWallet wallet = _createVaultWallet(owner, 19);
        _fundWallet(wallet, address(usdc), 1_000 * USDC);
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.deposit.selector, 1_000 * USDC));
        usdc.mint(address(this), 100 * USDC);
        usdc.approve(address(erc4626Vault), 100 * USDC);
        uint256 rewardShares = erc4626Vault.deposit(100 * USDC, address(this));
        erc4626Vault.transfer(address(merklDistributor), rewardShares);
        usdc.mint(address(erc4626Vault), 110 * USDC);
        uint256 collectorBefore = usdc.balanceOf(feeCollector);
        uint256 partialBasisReleased = Math.mulDiv(1_000 * USDC, 500 * USDC, 1_100 * USDC);
        uint256 partialFee = Math.mulDiv(550 * USDC - partialBasisReleased, YIELD_FEE_BPS, 10_000, Math.Rounding.Ceil);
        uint256 remainingBasis = 1_000 * USDC - partialBasisReleased;
        uint256 finalFee = Math.mulDiv(660 * USDC - remainingBasis, YIELD_FEE_BPS, 10_000, Math.Rounding.Ceil);
        _claim(wallet, address(erc4626Vault), rewardShares);

        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, 500 * USDC));
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, partialFee);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(erc4626Vault)), 545_454_546);

        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, 600 * USDC));
        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, partialFee + finalFee);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(erc4626Vault)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 1_210 * USDC - partialFee - finalFee);
    }

    function testFeeModulesRunInOrderAndCapPaymentsToFundsAvailable() public {
        AgentWallet wallet = _createBorrowWallet(owner, 20);
        _fundWallet(wallet, address(usdc), USDC);
        _executeLending(wallet, aaveV3LendingAdapter.supplyCollateral.selector, USDC);
        _executeLending(wallet, aaveV3LendingAdapter.borrow.selector, 1e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _executeLending(wallet, aaveV3LendingAdapter.repay.selector, type(uint256).max);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 10 * USDC);

        uint256 collectorBefore = usdc.balanceOf(feeCollector);
        _claim(wallet, address(usdc), 10 * USDC);

        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 10 * USDC);
        assertEq(vaultYieldFeeModule.feesOwed(address(wallet)), 0);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), USDC);
        assertEq(usdc.balanceOf(address(wallet)), 0);

        _fundWallet(wallet, address(usdc), 2 * USDC);
        assertEq(wallet.withdrawableBalance(address(usdc)), USDC);
        uint256 ownerBefore = usdc.balanceOf(owner);
        vm.prank(owner);
        wallet.withdrawAssetToUser(owner, address(usdc), USDC);

        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, 11 * USDC);
        assertEq(usdc.balanceOf(owner) - ownerBefore, USDC);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    function testModuleReplacementRoutesRealWithdrawalsToReplacement() public {
        AgentWallet wallet = _createVaultWallet(owner, 30);
        YieldSeekerYieldFeeModule replacement = new YieldSeekerYieldFeeModule(vaultFeeTracker, 5_000);
        vaultFeeTracker.setFeeModule(YIELD_FEE, replacement);
        _fundWallet(wallet, address(usdc), 100 * USDC);
        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.deposit.selector, 100 * USDC));
        usdc.mint(address(erc4626Vault), 10 * USDC);
        uint256 collectorBefore = usdc.balanceOf(feeCollector);

        _execute(wallet, address(erc4626Adapter), address(erc4626Vault), abi.encodeWithSelector(erc4626Adapter.withdraw.selector, 100 * USDC));

        assertEq(usdc.balanceOf(feeCollector) - collectorBefore, USDC);
        assertEq(usdc.balanceOf(address(wallet)), 109 * USDC);
        assertEq(replacement.costBasis(address(wallet), address(erc4626Vault)), 0);
        assertEq(vaultYieldFeeModule.costBasis(address(wallet), address(erc4626Vault)), 0);
    }

    function testActionFailureBlocksAdapterButNotOwnerExit() public {
        AgentWallet wallet = _createVaultWallet(owner, 40);
        ActionFailingFeeModule failure = new ActionFailingFeeModule(address(vaultFeeTracker), ACTION_FAILURE_FEE);
        vaultFeeTracker.setFeeModule(ACTION_FAILURE_FEE, failure);
        _fundWallet(wallet, address(usdc), 100 * USDC);
        bytes memory deposit = abi.encodeWithSelector(erc4626Adapter.deposit.selector, 100 * USDC);
        bytes memory failureError = abi.encodeWithSelector(FeeModuleActionFailed.selector);
        _executeExpectRevert(wallet, address(erc4626Adapter), address(erc4626Vault), deposit, failureError);
        assertEq(usdc.balanceOf(address(wallet)), 100 * USDC);
        assertEq(erc4626Vault.balanceOf(address(wallet)), 0);

        uint256 ownerBefore = usdc.balanceOf(owner);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));

        assertEq(usdc.balanceOf(owner) - ownerBefore, 100 * USDC);
        assertEq(usdc.balanceOf(address(wallet)), 0);
    }

    function testFeeViewsIgnoreModulesThatRevert() public {
        AgentWallet wallet = _createBorrowWallet(owner, 50);
        _fundWallet(wallet, address(usdc), USDC);
        _executeLending(wallet, aaveV3LendingAdapter.supplyCollateral.selector, USDC);
        _executeLending(wallet, aaveV3LendingAdapter.borrow.selector, 1e18);
        vm.warp(vm.getBlockTimestamp() + 365 days);
        _executeLending(wallet, aaveV3LendingAdapter.repay.selector, type(uint256).max);
        ViewFailingFeeModule failure = new ViewFailingFeeModule(address(borrowFeeTracker), VIEW_FAILURE_FEE);
        borrowFeeTracker.setFeeModule(VIEW_FAILURE_FEE, failure);
        _fundWallet(wallet, address(usdc), 20 * USDC);

        assertEq(borrowFeeTracker.feesOwedInBaseAsset(address(wallet)), 10 * USDC);
        assertTrue(borrowFeeTracker.isAccountedToken(address(wallet), address(weth)));
        assertFalse(borrowFeeTracker.isAccountedToken(address(wallet), address(rewardToken)));
        assertEq(wallet.withdrawableBalance(address(usdc)), 10 * USDC);
        assertEq(wallet.withdrawableBalance(address(rewardToken)), 0);

        vm.expectRevert(InsufficientGasForModules.selector);
        borrowFeeTracker.feesOwedInBaseAsset{gas: 50_000}(address(wallet));
    }

    function testPlainBorrowCollateralTradeDoesNotAccrueYieldFees() public {
        AgentWallet wallet = _createBorrowWallet(owner, 60);
        _fundWallet(wallet, address(usdc), 1_000 * USDC);
        _executeLending(wallet, aaveV3LendingAdapter.supplyCollateral.selector, 1_000 * USDC);
        uint256 bought = 0.05e18;
        _executeLending(wallet, aaveV3LendingAdapter.borrow.selector, bought);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(weth));
        _fundWallet(wallet, address(usdc), 100 * USDC);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3_000;
        AWKUniswapV3SwapAdapter.SwapRoute memory route = AWKUniswapV3SwapAdapter.SwapRoute({path: path, fees: fees});
        uniswapV3Router.setBuyAmount(bought);

        _execute(wallet, address(uniswapV3SwapAdapter), address(uniswapV3Router), abi.encodeWithSelector(uniswapV3SwapAdapter.swap.selector, address(usdc), address(weth), route, 100 * USDC, bought));

        assertEq(vaultYieldFeeModule.feesOwed(address(wallet)), 0);
        assertEq(usdc.balanceOf(feeCollector), 0);
        assertEq(weth.balanceOf(address(wallet)), bought);

        _executeLending(wallet, aaveV3LendingAdapter.repay.selector, type(uint256).max);
        assertEq(weth.balanceOf(address(wallet)), 0);
        assertEq(borrowFeeModule.tokenDebt(address(wallet), address(weth)), 0);
    }

    function _claim(AgentWallet wallet, address token, uint256 amount) private {
        address[] memory tokens = new address[](1);
        tokens[0] = token;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amount;
        bytes32[][] memory proofs = new bytes32[][](1);
        proofs[0] = new bytes32[](0);
        _execute(wallet, address(merklAdapter), address(merklDistributor), abi.encodeCall(merklAdapter.claim, (tokens, amounts, proofs)));
    }

    function _executeLending(AgentWallet wallet, bytes4 selector, uint256 amount) private {
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeWithSelector(selector, aaveV3Market, amount));
    }
}
