// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAgentWalletV3 as AgentWallet} from "../../src/AgentWalletV3.sol";
import {EModeNotAllowed, YieldSeekerAaveV3LendingAdapter} from "../../src/adapters/AaveV3LendingAdapter.sol";
import {AssetNotAllowed} from "../../src/adapters/Adapter.sol";
import {AWKErrors} from "../../src/agentwalletkit/AWKErrors.sol";
import {MarketTargetMismatch} from "../../src/agentwalletkit/adapters/AWKLendingAdapter.sol";
import {IMorphoBlue} from "../../src/agentwalletkit/adapters/AWKMorphoBlueLendingAdapter.sol";
import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";
import {FeePlanChoice} from "../../src/fees/FeeTracker.sol";
import {MockERC20, MockERC20WithDecimals} from "../mocks/MockERC20.sol";
import {IntegrationBase} from "./IntegrationBase.t.sol";

contract LendingIntegrationTest is IntegrationBase {
    uint256 private constant YEAR = 365 days;
    uint256 private constant COLLATERAL = 1_000e6;
    uint256 private constant BORROWED_WETH = 1e18;

    function test_AaveV3SupplyBorrowCheckpointRepayMaxAndOwnerExit() public {
        AgentWallet wallet = _createBorrowWallet(owner, 1);
        _fundWallet(wallet, address(usdc), COLLATERAL);
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, COLLATERAL)));
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, BORROWED_WETH)));
        _fundWallet(wallet, address(weth), BORROWED_WETH);

        assertEq(aaveV3CollateralAToken.balanceOf(address(wallet)), COLLATERAL);
        assertEq(aaveV3VariableDebtToken.balanceOf(address(wallet)), BORROWED_WETH);
        assertEq(weth.balanceOf(address(wallet)), BORROWED_WETH * 2);
        assertTrue(borrowFeeTracker.isAccountedToken(address(wallet), address(weth)));
        assertFalse(borrowFeeTracker.isAccountedToken(address(wallet), address(rewardToken)));

        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));

        uint256 expectedBorrowFee = 10e6;
        assertEq(borrowFeeModule.feesOwed(address(wallet)), expectedBorrowFee);
        assertEq(_feesCollected(address(usdc)), 0);

        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, type(uint256).max)));
        assertEq(aaveV3LendingPool.lastRepayAmount(), BORROWED_WETH);
        assertEq(aaveV3VariableDebtToken.balanceOf(address(wallet)), 0);
        assertEq(weth.balanceOf(address(wallet)), BORROWED_WETH);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), expectedBorrowFee);

        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, type(uint256).max)));
        assertEq(_feesCollected(address(usdc)), expectedBorrowFee);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), COLLATERAL - expectedBorrowFee);

        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(weth));
        assertEq(usdc.balanceOf(owner), COLLATERAL - expectedBorrowFee);
        assertEq(weth.balanceOf(owner), BORROWED_WETH);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(weth.balanceOf(address(wallet)), 0);
    }

    function test_AaveV3WithdrawAboveCollateralWithdrawsEverything() public {
        AgentWallet wallet = _createBorrowWallet(owner, 20);
        _fundWallet(wallet, address(usdc), COLLATERAL);
        address target = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        _execute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, COLLATERAL)));

        uint256 requested = COLLATERAL + 1;
        bytes memory result = _execute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, requested)));
        assertEq(abi.decode(abi.decode(result, (bytes)), (uint256)), COLLATERAL);
        assertEq(aaveV3CollateralAToken.balanceOf(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), COLLATERAL);
    }

    function test_AaveV4SupplyBorrowCheckpointRepayMaxAndWithdraw() public {
        AgentWallet wallet = _createBorrowWallet(owner, 2);
        _fundWallet(wallet, address(usdc), COLLATERAL);
        _execute(wallet, address(aaveV4LendingAdapter), aaveV4LendingAdapter.marketTarget(aaveV4Market), abi.encodeCall(aaveV4LendingAdapter.supplyCollateral, (aaveV4Market, COLLATERAL)));
        _execute(wallet, address(aaveV4LendingAdapter), aaveV4LendingAdapter.marketTarget(aaveV4Market), abi.encodeCall(aaveV4LendingAdapter.borrow, (aaveV4Market, BORROWED_WETH)));

        assertTrue(aaveV4Spoke.usingAsCollateral(1, address(wallet)));
        assertEq(aaveV4Spoke.getUserTotalDebt(2, address(wallet)), BORROWED_WETH);
        assertEq(weth.balanceOf(address(wallet)), BORROWED_WETH);

        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        _execute(wallet, address(aaveV4LendingAdapter), aaveV4LendingAdapter.marketTarget(aaveV4Market), abi.encodeCall(aaveV4LendingAdapter.checkpoint, (aaveV4Market)));
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 10e6);

        _execute(wallet, address(aaveV4LendingAdapter), aaveV4LendingAdapter.marketTarget(aaveV4Market), abi.encodeCall(aaveV4LendingAdapter.repay, (aaveV4Market, type(uint256).max)));
        assertEq(aaveV4Spoke.getUserTotalDebt(2, address(wallet)), 0);
        _execute(wallet, address(aaveV4LendingAdapter), aaveV4LendingAdapter.marketTarget(aaveV4Market), abi.encodeCall(aaveV4LendingAdapter.withdrawCollateral, (aaveV4Market, type(uint256).max)));

        assertEq(_feesCollected(address(usdc)), 10e6);
        assertEq(usdc.balanceOf(address(wallet)), COLLATERAL - 10e6);
        assertEq(aaveV4Spoke.getUserSuppliedAssets(1, address(wallet)), 0);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), COLLATERAL - 10e6);
    }

    function test_MorphoSupplyBorrowCheckpointRepayMaxAndWithdraw() public {
        AgentWallet wallet = _createBorrowWallet(owner, 3);
        IMorphoBlue.MarketParams memory params;
        (, params) = _decodeMorphoMarket(morphoMarket);
        bytes32 marketId = keccak256(abi.encode(params));
        address target = morphoBlueLendingAdapter.marketTarget(morphoMarket);
        _fundWallet(wallet, address(usdc), COLLATERAL);
        _execute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.supplyCollateral, (morphoMarket, COLLATERAL)));
        _execute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.borrow, (morphoMarket, BORROWED_WETH)));

        (uint256 supplyShares, uint128 borrowShares, uint128 collateral) = morpho.position(marketId, address(wallet));
        assertEq(supplyShares, 0);
        assertGt(borrowShares, 0);
        uint256 collateralYield = 100e6;
        morpho.accrueCollateral(params, address(wallet), collateralYield);
        (, borrowShares, collateral) = morpho.position(marketId, address(wallet));
        assertEq(collateral, COLLATERAL + collateralYield);
        assertEq(weth.balanceOf(address(wallet)), BORROWED_WETH);

        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        _execute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.checkpoint, (morphoMarket)));
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 10e6);

        _execute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.repay, (morphoMarket, type(uint256).max)));
        _execute(wallet, address(morphoBlueLendingAdapter), target, abi.encodeCall(morphoBlueLendingAdapter.withdrawCollateral, (morphoMarket, type(uint256).max)));
        (, borrowShares, collateral) = morpho.position(marketId, address(wallet));
        assertEq(borrowShares, 0);
        assertEq(collateral, 0);
        assertEq(_feesCollected(address(usdc)), 20e6);
        assertEq(usdc.balanceOf(address(wallet)), COLLATERAL + collateralYield - 20e6);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(usdc));
        assertEq(usdc.balanceOf(owner), COLLATERAL + collateralYield - 20e6);
    }

    function test_BorrowFeeUsesMarketPriceAtEachCheckpointAfterPriceSourceRemoval() public {
        AgentWallet wallet = _createBorrowWallet(owner, 4);
        _supplyAndBorrowAaveV3(wallet, COLLATERAL, BORROWED_WETH);
        priceOracle.removeSource(address(usdc));
        priceOracle.removeSource(address(weth));
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 10e6);

        aaveV3Oracle.setAssetPrice(address(weth), 1_000e8);
        vm.warp(start + 2 * YEAR);
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 15e6);

        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, type(uint256).max)));
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, type(uint256).max)));
        assertEq(_feesCollected(address(usdc)), 15e6);
        assertEq(usdc.balanceOf(address(wallet)), COLLATERAL - 15e6);
    }

    function test_WithdrawnCollateralPaysBorrowAndYieldFees() public {
        AgentWallet wallet = _createBorrowWallet(owner, 5);
        uint256 collateralYield = 100e6;
        _supplyAndBorrowAaveV3(wallet, COLLATERAL, BORROWED_WETH);
        aaveV3LendingPool.accrueCollateral(address(usdc), address(wallet), collateralYield);

        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, type(uint256).max)));
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, type(uint256).max)));

        uint256 expectedBorrowFee = 10e6;
        uint256 expectedYieldFee = 10e6;
        assertEq(_feesCollected(address(usdc)), expectedBorrowFee + expectedYieldFee);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 0);
        assertEq(borrowYieldFeeModule.feesOwed(address(wallet)), 0);
        assertEq(borrowYieldFeeModule.costBasis(address(wallet), aaveV3LendingAdapter.marketTarget(aaveV3Market)), 0);
        assertEq(usdc.balanceOf(address(wallet)), COLLATERAL + collateralYield - expectedBorrowFee - expectedYieldFee);
    }

    function test_AaveV3CollateralYieldIsChargedProRataAcrossPartialAndFullWithdrawals() public {
        AgentWallet wallet = _createBorrowWallet(owner, 6);
        uint256 collateralYield = 2_000e6;
        _fundWallet(wallet, address(usdc), COLLATERAL);
        address target = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        _execute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, COLLATERAL)));
        aaveV3LendingPool.accrueCollateral(address(usdc), address(wallet), collateralYield);

        uint256 heldBefore = COLLATERAL + collateralYield;
        uint256 partialWithdrawal = heldBefore / 2;
        uint256 partialBasisReleased = COLLATERAL * partialWithdrawal / heldBefore;
        uint256 partialFee = (partialWithdrawal - partialBasisReleased) * YIELD_FEE_BPS / 10_000;
        _execute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, partialWithdrawal)));

        assertEq(borrowYieldFeeModule.costBasis(address(wallet), target), COLLATERAL - partialBasisReleased);
        assertEq(_feesCollected(address(usdc)), partialFee);
        assertEq(usdc.balanceOf(address(wallet)), partialWithdrawal - partialFee);

        uint256 remainingCollateral = heldBefore - partialWithdrawal;
        uint256 remainingBasis = COLLATERAL - partialBasisReleased;
        uint256 finalFee = (remainingCollateral - remainingBasis) * YIELD_FEE_BPS / 10_000;
        _execute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, type(uint256).max)));

        assertEq(borrowYieldFeeModule.costBasis(address(wallet), target), 0);
        assertEq(_feesCollected(address(usdc)), partialFee + finalFee);
        assertEq(usdc.balanceOf(address(wallet)), heldBefore - partialFee - finalFee);
    }

    function test_AaveV4CollateralYieldIsChargedProRataAcrossPartialAndFullWithdrawals() public {
        AgentWallet wallet = _createBorrowWallet(owner, 7);
        uint256 collateralYield = 2_000e6;
        _fundWallet(wallet, address(usdc), COLLATERAL);
        address target = aaveV4LendingAdapter.marketTarget(aaveV4Market);
        _execute(wallet, address(aaveV4LendingAdapter), target, abi.encodeCall(aaveV4LendingAdapter.supplyCollateral, (aaveV4Market, COLLATERAL)));
        aaveV4Spoke.accrueSuppliedAssets(1, address(wallet), collateralYield);

        uint256 heldBefore = COLLATERAL + collateralYield;
        uint256 partialWithdrawal = heldBefore / 2;
        uint256 partialBasisReleased = COLLATERAL * partialWithdrawal / heldBefore;
        uint256 partialFee = (partialWithdrawal - partialBasisReleased) * YIELD_FEE_BPS / 10_000;
        _execute(wallet, address(aaveV4LendingAdapter), target, abi.encodeCall(aaveV4LendingAdapter.withdrawCollateral, (aaveV4Market, partialWithdrawal)));

        assertEq(borrowYieldFeeModule.costBasis(address(wallet), target), COLLATERAL - partialBasisReleased);
        assertEq(_feesCollected(address(usdc)), partialFee);
        assertEq(usdc.balanceOf(address(wallet)), partialWithdrawal - partialFee);

        uint256 remainingCollateral = heldBefore - partialWithdrawal;
        uint256 remainingBasis = COLLATERAL - partialBasisReleased;
        uint256 finalFee = (remainingCollateral - remainingBasis) * YIELD_FEE_BPS / 10_000;
        _execute(wallet, address(aaveV4LendingAdapter), target, abi.encodeCall(aaveV4LendingAdapter.withdrawCollateral, (aaveV4Market, type(uint256).max)));

        assertEq(borrowYieldFeeModule.costBasis(address(wallet), target), 0);
        assertEq(_feesCollected(address(usdc)), partialFee + finalFee);
        assertEq(usdc.balanceOf(address(wallet)), heldBefore - partialFee - finalFee);
    }

    function test_AaveV3CollateralLossDoesNotChargeYieldFee() public {
        AgentWallet wallet = _createBorrowWallet(owner, 8);
        uint256 loss = 200e6;
        _fundWallet(wallet, address(usdc), COLLATERAL);
        address target = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        _execute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, COLLATERAL)));
        aaveV3CollateralAToken.burn(address(wallet), loss);
        _execute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, type(uint256).max)));

        assertEq(borrowYieldFeeModule.costBasis(address(wallet), target), 0);
        assertEq(borrowYieldFeeModule.feesOwed(address(wallet)), 0);
        assertEq(_feesCollected(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(wallet)), COLLATERAL - loss);
    }

    function test_AaveV4UsesReserveDecimalsForMarketPrice() public {
        MockERC20WithDecimals collateral = new MockERC20WithDecimals("Collateral", "CBTC", 8);
        MockERC20WithDecimals debt = new MockERC20WithDecimals("Debt", "USDC", 6);
        aaveV4Spoke.setReserve(3, address(collateral), 8);
        aaveV4Spoke.setReserve(4, address(debt), 6);
        aaveV4Spoke.setReservePrice(3, 20_000e8);
        aaveV4Spoke.setReservePrice(4, 1e8);
        bytes memory market = abi.encode(address(aaveV4Spoke), uint256(3), uint256(4));
        address target = aaveV4LendingAdapter.marketTarget(market);
        borrowRegistry.setTargetAdapter(target, address(aaveV4LendingAdapter));
        vm.prank(operator);
        AgentWallet wallet = AgentWallet(payable(address(factory.createAgentWallet(owner, 9, address(collateral), BORROW_AGENT_PROFILE, new FeePlanChoice[](0)))));
        _fundWallet(wallet, address(collateral), 2e8);
        _execute(wallet, address(aaveV4LendingAdapter), target, abi.encodeCall(aaveV4LendingAdapter.supplyCollateral, (market, 2e8)));
        _execute(wallet, address(aaveV4LendingAdapter), target, abi.encodeCall(aaveV4LendingAdapter.borrow, (market, 100e6)));

        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        _execute(wallet, address(aaveV4LendingAdapter), target, abi.encodeCall(aaveV4LendingAdapter.checkpoint, (market)));
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 2_500);

        _execute(wallet, address(aaveV4LendingAdapter), target, abi.encodeCall(aaveV4LendingAdapter.repay, (market, type(uint256).max)));
        _execute(wallet, address(aaveV4LendingAdapter), target, abi.encodeCall(aaveV4LendingAdapter.withdrawCollateral, (market, type(uint256).max)));
        assertEq(collateral.balanceOf(feeCollector), 2_500);
        assertEq(collateral.balanceOf(address(wallet)), 2e8 - 2_500);
        vm.prank(owner);
        wallet.withdrawAllAssetToUser(owner, address(collateral));
        assertEq(collateral.balanceOf(owner), 2e8 - 2_500);
    }

    function test_ExternalDebtReductionCheckpointChargesOldDebtThenReducedPrincipal() public {
        AgentWallet wallet = _createBorrowWallet(owner, 10);
        uint256 principal = 100e18;
        _supplyAndBorrowAaveV3(wallet, 10_000e6, principal);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        aaveV3LendingPool.reduceDebt(address(weth), address(wallet), 60e18);
        assertEq(aaveV3VariableDebtToken.balanceOf(address(wallet)), 40e18);

        address target = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        _execute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 1_000e6);
        (uint128 recordedPrincipal,,,) = borrowFeeModule.debtPositions(address(wallet), keccak256(aaveV3Market));
        assertEq(recordedPrincipal, 40e18);

        vm.warp(start + 2 * YEAR);
        _execute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 1_400e6);
        _execute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, 2_000e6)));
        assertEq(_feesCollected(address(usdc)), 1_400e6);
        assertEq(usdc.balanceOf(address(wallet)), 600e6);
        assertEq(aaveV3VariableDebtToken.balanceOf(address(wallet)), 40e18);
    }

    function test_DustDebtDoesNotPreventCollateralWithdrawalOrEraseAccruedFee() public {
        AgentWallet wallet = _createBorrowWallet(owner, 19);
        _supplyAndBorrowAaveV3(wallet, COLLATERAL, BORROWED_WETH);
        weth.burn(address(wallet), BORROWED_WETH);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        aaveV3LendingPool.reduceDebt(address(weth), address(wallet), BORROWED_WETH - 1);

        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, 100e6)));

        assertEq(aaveV3VariableDebtToken.balanceOf(address(wallet)), 1);
        assertEq(_feesCollected(address(usdc)), 10e6);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), 90e6);
    }

    function test_ExternalFullRepayCheckpointChargesAtLastReportedPrice() public {
        AgentWallet wallet = _createBorrowWallet(owner, 11);
        _supplyAndBorrowAaveV3(wallet, COLLATERAL, BORROWED_WETH);
        uint256 start = vm.getBlockTimestamp();
        uint256 expectedBorrowFee = 10e6;
        address target = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        address externalRepayer = makeAddr("external repayer");
        vm.warp(start + YEAR);

        uint256 debt = aaveV3VariableDebtToken.balanceOf(address(wallet));
        _fund(address(weth), externalRepayer, debt);
        vm.prank(externalRepayer);
        weth.approve(address(aaveV3LendingPool), debt);
        vm.prank(externalRepayer);
        aaveV3LendingPool.repay(address(weth), type(uint256).max, 2, address(wallet));
        assertEq(aaveV3VariableDebtToken.balanceOf(address(wallet)), 0);

        _execute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));
        assertEq(borrowFeeModule.feesOwed(address(wallet)), expectedBorrowFee);
        assertEq(borrowFeeModule.pendingFee(address(wallet), keccak256(aaveV3Market)), 0);
        assertEq(_feesCollected(address(usdc)), 0);

        _execute(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, type(uint256).max)));
        assertEq(_feesCollected(address(usdc)), expectedBorrowFee);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), COLLATERAL - expectedBorrowFee);
    }

    function test_RepaymentAppliesToInterestBeforeReducingPrincipal() public {
        AgentWallet wallet = _createBorrowWallet(owner, 12);
        uint256 borrowed = 100e18;
        _supplyAndBorrowAaveV3(wallet, COLLATERAL, borrowed);
        aaveV3LendingPool.growDebt(address(weth), address(wallet), 10e18);
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, 50e18)));

        (uint128 principal, uint128 lastDebt,,) = borrowFeeModule.debtPositions(address(wallet), keccak256(aaveV3Market));
        assertEq(principal, 60e18);
        assertEq(lastDebt, 60e18);
        assertEq(aaveV3VariableDebtToken.balanceOf(address(wallet)), 60e18);
        assertEq(weth.balanceOf(address(wallet)), 50e18);
    }

    function test_BorrowFeePaymentIsCappedByAvailableBaseAsset() public {
        AgentWallet wallet = _createBorrowWallet(owner, 13);
        _supplyAndBorrowAaveV3(wallet, COLLATERAL, BORROWED_WETH);
        uint256 partialPayment = 4e6;
        _fundWallet(wallet, address(usdc), partialPayment);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.repay, (aaveV3Market, type(uint256).max)));

        assertEq(_feesCollected(address(usdc)), partialPayment);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 6e6);
        assertEq(usdc.balanceOf(address(wallet)), 0);
        assertEq(weth.balanceOf(address(wallet)), 0);

        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.withdrawCollateral, (aaveV3Market, type(uint256).max)));
        assertEq(_feesCollected(address(usdc)), 10e6);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 0);
        assertEq(usdc.balanceOf(address(wallet)), COLLATERAL + partialPayment - 10e6);
    }

    function test_BorrowFeeAccrualIsIsolatedAcrossMarkets() public {
        AgentWallet wallet = _createBorrowWallet(owner, 14);
        MockERC20WithDecimals secondDebt = new MockERC20WithDecimals("Second Debt", "SDT", 18);
        MockERC20 secondDebtToken = new MockERC20("Second Debt Position", "sdSDT");
        aaveV3LendingPool.setReserve(address(secondDebt), address(0), address(secondDebtToken));
        aaveV3Oracle.setAssetPrice(address(secondDebt), 1e8);
        bytes memory secondMarket = abi.encode(address(aaveV3LendingPool), address(usdc), address(secondDebt), uint8(0));
        address firstTarget = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        address secondTarget = aaveV3LendingAdapter.marketTarget(secondMarket);
        borrowRegistry.setTargetAdapter(secondTarget, address(aaveV3LendingAdapter));
        _fundWallet(wallet, address(usdc), 2 * COLLATERAL);
        _execute(wallet, address(aaveV3LendingAdapter), firstTarget, abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, COLLATERAL)));
        _execute(wallet, address(aaveV3LendingAdapter), firstTarget, abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, BORROWED_WETH)));
        _execute(wallet, address(aaveV3LendingAdapter), secondTarget, abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (secondMarket, COLLATERAL)));
        _execute(wallet, address(aaveV3LendingAdapter), secondTarget, abi.encodeCall(aaveV3LendingAdapter.borrow, (secondMarket, 100e18)));

        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 0);
        _execute(wallet, address(aaveV3LendingAdapter), firstTarget, abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 10e6);
        _execute(wallet, address(aaveV3LendingAdapter), secondTarget, abi.encodeCall(aaveV3LendingAdapter.checkpoint, (secondMarket)));
        assertEq(borrowFeeModule.feesOwed(address(wallet)), 10_500_000);
    }

    function test_AssignedBorrowFeePlanRateAppliesToRealWallet() public {
        uint256 customRate = 100;
        uint256 planId = borrowFeeTracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: customRate})));
        FeePlanChoice[] memory plans = new FeePlanChoice[](1);
        plans[0] = FeePlanChoice({feeType: BORROW_FEE, planId: planId});
        AgentWallet wallet = _createBorrowWallet(owner, 18, plans);
        _supplyAndBorrowAaveV3(wallet, COLLATERAL, BORROWED_WETH);
        uint256 start = vm.getBlockTimestamp();
        vm.warp(start + YEAR);
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.checkpoint, (aaveV3Market)));

        assertEq(borrowFeeModule.feesOwed(address(wallet)), 20e6);
    }

    function test_AaveV3RejectsEModeOnSupplyAndCheckpoint() public {
        AgentWallet wallet = _createBorrowWallet(owner, 15);
        bytes memory eModeMarket = abi.encode(address(aaveV3LendingPool), address(usdc), address(weth), uint8(1));
        address target = aaveV3LendingAdapter.marketTarget(eModeMarket);
        borrowRegistry.setTargetAdapter(target, address(aaveV3LendingAdapter));
        bytes memory eModeError = abi.encodeWithSelector(EModeNotAllowed.selector, uint8(1));
        _executeExpectRevert(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (eModeMarket, COLLATERAL)), eModeError);
        _executeExpectRevert(wallet, address(aaveV3LendingAdapter), target, abi.encodeCall(aaveV3LendingAdapter.checkpoint, (eModeMarket)), eModeError);
    }

    function test_LendingMarketTargetsCannotBeReusedForDifferentMarketData() public {
        AgentWallet wallet = _createBorrowWallet(owner, 16);
        bytes memory differentEMode = abi.encode(address(aaveV3LendingPool), address(usdc), address(weth), uint8(1));
        address registeredTarget = aaveV3LendingAdapter.marketTarget(aaveV3Market);
        address expectedTarget = aaveV3LendingAdapter.marketTarget(differentEMode);
        bytes memory mismatch = abi.encodeWithSelector(MarketTargetMismatch.selector, registeredTarget, expectedTarget);
        _executeExpectRevert(wallet, address(aaveV3LendingAdapter), registeredTarget, abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (differentEMode, COLLATERAL)), mismatch);
        _executeExpectRevert(wallet, address(aaveV3LendingAdapter), registeredTarget, abi.encodeCall(aaveV3LendingAdapter.checkpoint, (differentEMode)), mismatch);

        (address morphoAddress, IMorphoBlue.MarketParams memory params) = _decodeMorphoMarket(morphoMarket);
        address morphoTarget = morphoBlueLendingAdapter.marketTarget(morphoMarket);
        params.oracle = address(0x2222);
        bytes memory substitutedMorphoMarket = abi.encode(morphoAddress, params);
        bytes memory morphoMismatch = abi.encodeWithSelector(MarketTargetMismatch.selector, morphoTarget, morphoBlueLendingAdapter.marketTarget(substitutedMorphoMarket));
        _executeExpectRevert(wallet, address(morphoBlueLendingAdapter), morphoTarget, abi.encodeCall(morphoBlueLendingAdapter.borrow, (substitutedMorphoMarket, BORROWED_WETH)), morphoMismatch);
    }

    function test_UnregisteredMarketAndNonBaseCollateralAreRejected() public {
        AgentWallet wallet = _createBorrowWallet(owner, 17);
        bytes memory unregisteredMarket = abi.encode(address(aaveV3LendingPool), address(usdc), address(weth), uint8(2));
        address unregisteredTarget = aaveV3LendingAdapter.marketTarget(unregisteredMarket);
        vm.expectRevert(abi.encodeWithSelector(AWKErrors.AdapterNotRegistered.selector, address(aaveV3LendingAdapter)));
        _execute(wallet, address(aaveV3LendingAdapter), unregisteredTarget, abi.encodeCall(aaveV3LendingAdapter.borrow, (unregisteredMarket, BORROWED_WETH)));

        MockERC20WithDecimals unsupported = new MockERC20WithDecimals("Unsupported", "BAD", 6);
        bytes memory unsupportedMarket = abi.encode(address(aaveV3LendingPool), address(unsupported), address(weth), uint8(0));
        address unsupportedTarget = aaveV3LendingAdapter.marketTarget(unsupportedMarket);
        borrowRegistry.setTargetAdapter(unsupportedTarget, address(aaveV3LendingAdapter));
        _executeExpectRevert(wallet, address(aaveV3LendingAdapter), unsupportedTarget, abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (unsupportedMarket, 1e6)), abi.encodeWithSelector(AssetNotAllowed.selector));
    }

    function _supplyAndBorrowAaveV3(AgentWallet wallet, uint256 collateralAmount, uint256 borrowAmount) private {
        _fundWallet(wallet, address(usdc), collateralAmount);
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.supplyCollateral, (aaveV3Market, collateralAmount)));
        _execute(wallet, address(aaveV3LendingAdapter), aaveV3LendingAdapter.marketTarget(aaveV3Market), abi.encodeCall(aaveV3LendingAdapter.borrow, (aaveV3Market, borrowAmount)));
    }

    function _decodeMorphoMarket(bytes memory encoded) private pure returns (address morphoAddress, IMorphoBlue.MarketParams memory params) {
        (morphoAddress, params) = abi.decode(encoded, (address, IMorphoBlue.MarketParams));
    }
}
