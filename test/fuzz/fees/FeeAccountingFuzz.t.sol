// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {BORROW_FEE, YieldSeekerBorrowFeeModule} from "../../../src/fees/BorrowFeeModule.sol";
import {FeeActions} from "../../../src/fees/FeeActions.sol";
import {YieldSeekerFeeTracker} from "../../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../../src/fees/YieldFeeModule.sol";
import {MockERC20WithDecimals} from "../../mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Test} from "forge-std/Test.sol";

contract FeeActionWallet {
    YieldSeekerFeeTracker public immutable tracker;
    IERC20 public immutable baseAsset;

    constructor(YieldSeekerFeeTracker tracker_, IERC20 baseAsset_) {
        tracker = tracker_;
        baseAsset = baseAsset_;
    }

    function reportAction(bytes32 action, bytes calldata data) external returns (uint256 payment) {
        address collector;
        (payment, collector) = tracker.reportAction(action, data);
        if (payment != 0) baseAsset.transfer(collector, payment);
    }
}

contract FeeAccountingFuzzTest is Test {
    uint256 private constant YIELD_RATE_BPS = 1_250;
    uint256 private constant BORROW_RATE_BPS = 750;
    uint256 private constant YEAR = 365 days;
    address private constant MARKET = address(0xBEEF);
    address private constant DEBT_TOKEN = address(0xD3B7);

    MockERC20WithDecimals private baseAsset;
    YieldSeekerFeeTracker private tracker;
    YieldSeekerYieldFeeModule private yieldModule;
    YieldSeekerBorrowFeeModule private borrowModule;

    function setUp() public {
        baseAsset = new MockERC20WithDecimals("Base Asset", "BASE", 6);
        tracker = new YieldSeekerFeeTracker(address(this), makeAddr("fee collector"));
        yieldModule = new YieldSeekerYieldFeeModule(tracker, 5_000);
        borrowModule = new YieldSeekerBorrowFeeModule(tracker, 1_000);
        tracker.setFeeModule(YIELD_FEE, yieldModule);
        tracker.setFeeModule(BORROW_FEE, borrowModule);
        tracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: YIELD_RATE_BPS})));
        tracker.createPlan(BORROW_FEE, abi.encode(YieldSeekerBorrowFeeModule.Plan({rateBps: BORROW_RATE_BPS})));
    }

    function testFuzz_fullWithdrawalReleasesAllCostBasis(uint128 basisSeed, uint128 heldSeed, uint128 assetsOutSeed) public {
        uint256 basis = bound(basisSeed, 1, 1e30);
        uint256 held = bound(heldSeed, 1, 1e30);
        uint256 assetsOut = bound(assetsOutSeed, 0, 2 * basis);
        FeeActionWallet wallet = _newWallet();

        _deposit(wallet, address(0xCAFE), basis);
        _withdraw(wallet, address(0xCAFE), held, held, assetsOut);

        uint256 realizedYield = assetsOut > basis ? assetsOut - basis : 0;
        assertEq(yieldModule.costBasis(address(wallet), address(0xCAFE)), 0);
        assertEq(yieldModule.feesOwed(address(wallet)), _yieldFee(realizedYield));
    }

    function testFuzz_partialWithdrawalReleasesProportionalBasis(uint128 basisSeed, uint128 heldSeed, uint128 spentSeed, uint128 assetsOutSeed) public {
        uint256 basis = bound(basisSeed, 1, 1e30);
        uint256 held = bound(heldSeed, 2, 1e30);
        uint256 spent = bound(spentSeed, 1, held - 1);
        uint256 assetsOut = bound(assetsOutSeed, 0, 2 * basis);
        FeeActionWallet wallet = _newWallet();

        _deposit(wallet, address(0xCAFE), basis);
        _withdraw(wallet, address(0xCAFE), spent, held, assetsOut);

        uint256 releasedBasis = Math.mulDiv(basis, spent, held);
        uint256 realizedYield = assetsOut > releasedBasis ? assetsOut - releasedBasis : 0;
        assertEq(yieldModule.costBasis(address(wallet), address(0xCAFE)), basis - releasedBasis);
        assertEq(yieldModule.feesOwed(address(wallet)), _yieldFee(realizedYield));
    }

    function testFuzz_lossWithdrawalReleasesBasisWithoutFee(uint128 basisSeed, uint128 heldSeed, uint128 lossSeed) public {
        uint256 basis = bound(basisSeed, 1, 1e30);
        uint256 held = bound(heldSeed, 1, 1e30);
        uint256 assetsOut = bound(lossSeed, 0, basis);
        FeeActionWallet wallet = _newWallet();

        _deposit(wallet, address(0xCAFE), basis);
        _withdraw(wallet, address(0xCAFE), held, held, assetsOut);

        assertEq(yieldModule.costBasis(address(wallet), address(0xCAFE)), 0);
        assertEq(yieldModule.feesOwed(address(wallet)), 0);
    }

    function testFuzz_withdrawalFromPositionWithoutBasisIsAllYield(uint128 heldSeed, uint128 spentSeed, uint128 assetsOutSeed) public {
        uint256 held = bound(heldSeed, 1, 1e30);
        uint256 spent = bound(spentSeed, 1, held);
        uint256 assetsOut = bound(assetsOutSeed, 0, 1e30);
        FeeActionWallet wallet = _newWallet();

        _withdraw(wallet, address(0xCAFE), spent, held, assetsOut);

        assertEq(yieldModule.costBasis(address(wallet), address(0xCAFE)), 0);
        assertEq(yieldModule.feesOwed(address(wallet)), _yieldFee(assetsOut));
    }

    function testFuzz_yieldFeeIsBoundedByRoundedYieldRate(uint128 yieldSeed) public {
        uint256 realizedYield = bound(yieldSeed, 0, 1e30);
        FeeActionWallet wallet = _newWallet();
        bytes memory claim = abi.encode(FeeActions.Claim({token: address(baseAsset), amount: realizedYield}));

        wallet.reportAction(FeeActions.CLAIM, claim);

        uint256 roundedFeeBound = Math.mulDiv(realizedYield, YIELD_RATE_BPS, 10_000, Math.Rounding.Ceil);
        assertLe(yieldModule.feesOwed(address(wallet)), roundedFeeBound);
        assertEq(yieldModule.feesOwed(address(wallet)), roundedFeeBound);
    }

    function testFuzz_paymentIsCappedAndOwedFallsByExactPayment(uint128 yieldSeed, uint128 availableSeed) public {
        uint256 realizedYield = bound(yieldSeed, 1, 1e30);
        FeeActionWallet wallet = _newWallet();
        bytes memory claim = abi.encode(FeeActions.Claim({token: address(baseAsset), amount: realizedYield}));
        wallet.reportAction(FeeActions.CLAIM, claim);

        uint256 owedBefore = yieldModule.feesOwed(address(wallet));
        uint256 available = bound(availableSeed, 0, owedBefore + 1e18);
        baseAsset.mint(address(wallet), available);
        uint256 payment = wallet.reportAction(FeeActions.SWAP, abi.encode(FeeActions.Swap({sold: address(0x1), bought: address(0x2), soldAmount: 1, boughtAmount: 1})));

        uint256 owedAfter = yieldModule.feesOwed(address(wallet));
        assertLe(payment, available);
        assertEq(owedBefore - owedAfter, payment);
        assertEq(baseAsset.balanceOf(address(wallet)), available - payment);
    }

    function testFuzz_borrowFeeAccrualIsMonotonicInTime(uint128 debtSeed, uint32 firstDelaySeed, uint32 extraDelaySeed) public {
        uint256 debt = bound(debtSeed, 1, 1e24);
        FeeActionWallet wallet = _newWallet();
        _reportDebt(wallet, 0, debt, 0, 1e36);

        uint256 start = vm.getBlockTimestamp();
        uint256 firstDelay = bound(firstDelaySeed, 1, 5 * YEAR);
        uint256 extraDelay = bound(extraDelaySeed, 1, 5 * YEAR);
        vm.warp(start + firstDelay);
        uint256 firstPending = borrowModule.pendingFee(address(wallet), MARKET);
        vm.warp(start + firstDelay + extraDelay);
        uint256 laterPending = borrowModule.pendingFee(address(wallet), MARKET);
        _reportDebt(wallet, debt, 0, 0, 1e36);

        assertGe(laterPending, firstPending);
        assertGe(borrowModule.feesOwed(address(wallet)), laterPending);
        (uint128 lastDebt,,) = borrowModule.debtPositions(address(wallet), MARKET);
        assertEq(lastDebt, debt);
    }

    function testFuzz_unusableBorrowPriceKeepsTheLastUsablePrice(uint128 debtSeed, bool reportZeroPrice, uint64 invalidSeed) public {
        uint256 debt = bound(debtSeed, 1, 1e24);
        FeeActionWallet wallet = _newWallet();
        _reportDebt(wallet, 0, debt, 0, 1e36);
        (,, uint192 lastUsablePrice) = borrowModule.debtPositions(address(wallet), MARKET);
        uint256 unusablePrice = reportZeroPrice ? 0 : uint256(type(uint192).max) + 1 + bound(invalidSeed, 0, 1e18);

        vm.warp(block.timestamp + YEAR);
        _reportDebt(wallet, debt, 0, 0, unusablePrice);

        (,, uint192 priceAfterReport) = borrowModule.debtPositions(address(wallet), MARKET);
        assertEq(priceAfterReport, lastUsablePrice);
        assertGt(borrowModule.feesOwed(address(wallet)), 0);
    }

    function testFuzz_debtAboveUint128RevertsInsteadOfWrapping(uint64 excessSeed) public {
        uint256 excess = bound(excessSeed, 1, 1e18);
        FeeActionWallet wallet = _newWallet();
        bytes memory change = abi.encode(FeeActions.DebtChange({market: MARKET, debtToken: DEBT_TOKEN, debtBefore: uint256(type(uint128).max) + excess, borrowed: 0, repaid: 0, debtPriceInBaseAsset: 1e36}));

        vm.expectRevert();
        wallet.reportAction(FeeActions.DEBT_CHANGE, change);

        (uint128 lastDebt,,) = borrowModule.debtPositions(address(wallet), MARKET);
        assertEq(lastDebt, 0);
        assertEq(borrowModule.tokenDebt(address(wallet), DEBT_TOKEN), 0);
    }

    function testFuzz_twoPartialWithdrawalsCannotAvoidFees(uint128 heldSeed, uint128 firstSpentSeed, uint128 secondSpentSeed, uint128 firstYieldSeed, uint128 secondYieldSeed) public {
        uint256 held = bound(heldSeed, 3, 1e24);
        uint256 firstSpent = bound(firstSpentSeed, 1, held - 2);
        uint256 secondSpent = bound(secondSpentSeed, 1, held - firstSpent - 1);
        uint256 firstYield = bound(firstYieldSeed, 0, 1e30);
        uint256 secondYield = bound(secondYieldSeed, 0, 1e30);
        address target = address(0xCAFE);
        FeeActionWallet wholeWallet = _newWallet();
        FeeActionWallet splitWallet = _newWallet();

        _deposit(wholeWallet, target, held);
        _deposit(splitWallet, target, held);
        _withdraw(wholeWallet, target, firstSpent + secondSpent, held, firstSpent + secondSpent + firstYield + secondYield);
        _withdraw(splitWallet, target, firstSpent, held, firstSpent + firstYield);
        _withdraw(splitWallet, target, secondSpent, held - firstSpent, secondSpent + secondYield);

        uint256 wholeFee = yieldModule.feesOwed(address(wholeWallet));
        uint256 splitFee = yieldModule.feesOwed(address(splitWallet));
        assertGe(splitFee, wholeFee);
        assertLe(splitFee - wholeFee, 1);
    }

    function testFuzz_manyBorrowCheckpointsCannotAvoidFees(uint64 elapsedSeed, uint8 periodCountSeed) public {
        uint256 intervals = bound(periodCountSeed, 2, 8);
        uint256 elapsed = bound(elapsedSeed, intervals, 10_000_000);
        uint256 debt = 1e18;
        uint256 start = vm.getBlockTimestamp();
        FeeActionWallet wholeWallet = _newWallet();
        FeeActionWallet splitWallet = _newWallet();
        _reportDebt(wholeWallet, 0, debt, 0, 1e36);
        _reportDebt(splitWallet, 0, debt, 0, 1e36);

        uint256 baseInterval = elapsed / intervals;
        uint256 remainder = elapsed % intervals;
        uint256 checkpointTime = start;
        for (uint256 i; i < intervals; i++) {
            uint256 interval = baseInterval + (i < remainder ? 1 : 0);
            checkpointTime += interval;
            vm.warp(checkpointTime);
            _reportDebt(splitWallet, debt, 0, 0, 1e36);
        }
        _reportDebt(wholeWallet, debt, 0, 0, 1e36);

        uint256 wholeFee = borrowModule.feesOwed(address(wholeWallet));
        uint256 splitFee = borrowModule.feesOwed(address(splitWallet));
        assertGe(splitFee, wholeFee);
        assertLe(splitFee - wholeFee, intervals - 1);
    }

    function _newWallet() private returns (FeeActionWallet) {
        return new FeeActionWallet(tracker, baseAsset);
    }

    function _deposit(FeeActionWallet wallet, address target, uint256 amount) private {
        wallet.reportAction(FeeActions.DEPOSIT, abi.encode(FeeActions.Deposit({target: target, assetsIn: amount})));
    }

    function _withdraw(FeeActionWallet wallet, address target, uint256 spent, uint256 heldBefore, uint256 assetsOut) private {
        wallet.reportAction(FeeActions.WITHDRAW, abi.encode(FeeActions.Withdraw({target: target, spent: spent, heldBefore: heldBefore, assetsOut: assetsOut})));
    }

    function _reportDebt(FeeActionWallet wallet, uint256 debtBefore, uint256 borrowed, uint256 repaid, uint256 price) private {
        bytes memory change = abi.encode(FeeActions.DebtChange({market: MARKET, debtToken: DEBT_TOKEN, debtBefore: debtBefore, borrowed: borrowed, repaid: repaid, debtPriceInBaseAsset: price}));
        wallet.reportAction(FeeActions.DEBT_CHANGE, change);
    }

    function _yieldFee(uint256 realizedYield) private pure returns (uint256) {
        return Math.mulDiv(realizedYield, YIELD_RATE_BPS, 10_000, Math.Rounding.Ceil);
    }
}
