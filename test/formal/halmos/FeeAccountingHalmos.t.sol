// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerBorrowFeeModule} from "../../../src/fees/BorrowFeeModule.sol";
import {FeeActions} from "../../../src/fees/FeeActions.sol";
import {YieldSeekerFeeTracker} from "../../../src/fees/FeeTracker.sol";
import {YieldSeekerYieldFeeModule} from "../../../src/fees/YieldFeeModule.sol";

interface HalmosTimeCheatcodes {
    function warp(uint256 timestamp) external;
}

contract HalmosPlanTracker {
    uint256 private immutable _rateBps;

    constructor(uint256 rateBps) {
        _rateBps = rateBps;
    }

    function walletPlan(address, bytes32) external view returns (bytes memory) {
        return abi.encode(_rateBps);
    }

    function reportWithdrawal(YieldSeekerYieldFeeModule module, address wallet, FeeActions.Withdraw calldata withdrawal, uint256 maxPayment) external returns (uint256) {
        return module.onAction(wallet, FeeActions.WITHDRAW, abi.encode(withdrawal), maxPayment);
    }
}

contract YieldFeeProofHarness is YieldSeekerYieldFeeModule {
    constructor(HalmosPlanTracker tracker) YieldSeekerYieldFeeModule(YieldSeekerFeeTracker(address(tracker)), 10_000) {}

    function setBasis(address wallet, address target, uint256 basis) external {
        costBasis[wallet][target] = basis;
    }

    function release(address wallet, FeeActions.Withdraw calldata withdrawal) external returns (uint256) {
        return _releaseCostBasis(wallet, withdrawal);
    }
}

contract BorrowFeeProofHarness is YieldSeekerBorrowFeeModule {
    constructor(HalmosPlanTracker tracker) YieldSeekerBorrowFeeModule(YieldSeekerFeeTracker(address(tracker)), 10_000) {}

    function pendingFor(address wallet, uint128 debt, uint64 lastAccrual) external view returns (uint256) {
        return _pendingFee(wallet, DebtPosition({lastDebt: debt, lastAccrual: lastAccrual, lastPrice: 0}));
    }
}

contract FeeAccountingHalmos {
    HalmosTimeCheatcodes private constant vm = HalmosTimeCheatcodes(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private constant WALLET = address(0xA11CE);
    address private constant TARGET = address(0xBEEF);

    function check_property2_fullWithdrawalReleasesAllRemainingBasis(uint128 basis, uint128 heldBefore, uint128 spent, uint128 assetsOut) external {
        if (heldBefore == 0 || spent < heldBefore) return;

        (YieldFeeProofHarness module,) = _newYieldModule(0);
        module.setBasis(WALLET, TARGET, basis);
        uint256 yield = module.release(WALLET, _withdrawal(spent, heldBefore, assetsOut));
        uint256 expectedYield = assetsOut > basis ? assetsOut - basis : 0;

        assert(yield == expectedYield);
        assert(module.costBasis(WALLET, TARGET) == 0);
    }

    function check_property2_partialWithdrawalReleasesOnlyItsShareOfBasis(uint128 basis, uint128 heldBefore, uint128 spent, uint128 assetsOut) external {
        if (heldBefore == 0 || spent >= heldBefore) return;

        (YieldFeeProofHarness module,) = _newYieldModule(0);
        module.setBasis(WALLET, TARGET, basis);
        uint256 releasedBasis = uint256(basis) * spent / heldBefore;
        uint256 yield = module.release(WALLET, _withdrawal(spent, heldBefore, assetsOut));
        uint256 expectedYield = assetsOut > releasedBasis ? assetsOut - releasedBasis : 0;

        assert(yield == expectedYield);
        assert(module.costBasis(WALLET, TARGET) == uint256(basis) - releasedBasis);
        assert(module.costBasis(WALLET, TARGET) <= basis);
    }

    function check_property2_aLossNeverCreatesYieldFee(uint128 basis, uint128 heldBefore, uint128 spent, uint128 assetsOut) external {
        if (heldBefore == 0 || spent >= heldBefore) return;
        uint256 releasedBasis = uint256(basis) * spent / heldBefore;
        if (assetsOut > releasedBasis) return;

        (YieldFeeProofHarness module,) = _newYieldModule(0);
        module.setBasis(WALLET, TARGET, basis);
        uint256 yield = module.release(WALLET, _withdrawal(spent, heldBefore, assetsOut));

        assert(yield == 0);
        assert(module.costBasis(WALLET, TARGET) == uint256(basis) - releasedBasis);
    }

    function check_property2_withdrawalWithoutCostBasisTreatsAllOutputAsYield(uint128 spent, uint128 heldBefore, uint128 assetsOut) external {
        (YieldFeeProofHarness module,) = _newYieldModule(0);
        uint256 yield = module.release(WALLET, _withdrawal(spent, heldBefore, assetsOut));

        assert(yield == assetsOut);
        assert(module.costBasis(WALLET, TARGET) == 0);
    }

    function check_property2_yieldFeeNeverExceedsRoundedRate(uint8 yieldAmount, uint8 rateBps) external {
        if (rateBps > 10_000) return;
        HalmosPlanTracker tracker = new HalmosPlanTracker(rateBps);
        YieldFeeProofHarness module = new YieldFeeProofHarness(tracker);
        FeeActions.Withdraw memory withdrawal = _withdrawal(0, 0, yieldAmount);
        uint256 fee = tracker.reportWithdrawal(module, WALLET, withdrawal, type(uint256).max);
        uint256 maximumFee = (uint256(yieldAmount) * rateBps + 9_999) / 10_000;

        assert(fee <= maximumFee);
        assert(fee == maximumFee);
    }

    function check_property5_pendingBorrowFeeIsMonotonicInDebt(uint8 debtA, uint8 debtB) external {
        vm.warp(1_000_000);
        (BorrowFeeProofHarness module,) = _newBorrowModule();
        uint128 lowerDebt = debtA <= debtB ? debtA : debtB;
        uint128 higherDebt = debtA <= debtB ? debtB : debtA;
        uint256 lowerFee = module.pendingFor(WALLET, lowerDebt, 1);
        uint256 higherFee = module.pendingFor(WALLET, higherDebt, 1);

        assert(lowerFee <= higherFee);
    }

    function check_property5_pendingBorrowFeeNeverFallsAfterOneMoreSecondAtFixedDebt(uint8 elapsed) external {
        vm.warp(300);
        (BorrowFeeProofHarness module,) = _newBorrowModule();
        uint64 lastAccrual = 300 - uint64(elapsed);
        uint128 debt = 1e18;

        uint256 currentFee = module.pendingFor(WALLET, debt, lastAccrual);
        uint256 nextSecondFee = module.pendingFor(WALLET, debt, lastAccrual - 1);

        assert(currentFee <= nextSecondFee);
    }

    function _newYieldModule(uint256 rateBps) private returns (YieldFeeProofHarness module, HalmosPlanTracker tracker) {
        tracker = new HalmosPlanTracker(rateBps);
        module = new YieldFeeProofHarness(tracker);
    }

    function _newBorrowModule() private returns (BorrowFeeProofHarness module, HalmosPlanTracker tracker) {
        tracker = new HalmosPlanTracker(10_000);
        module = new BorrowFeeProofHarness(tracker);
    }

    function _withdrawal(uint256 spent, uint256 heldBefore, uint256 assetsOut) private pure returns (FeeActions.Withdraw memory) {
        return FeeActions.Withdraw({target: TARGET, spent: spent, heldBefore: heldBefore, assetsOut: assetsOut});
    }
}

