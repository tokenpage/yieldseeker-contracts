// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IYieldSeekerPriceOracle} from "../../../src/PriceOracle.sol";
import {IYieldSeekerSwapSellPolicy} from "../../../src/adapters/SwapSellPolicy.sol";
import {BORROW_FEE} from "../../../src/fees/BorrowFeeModule.sol";
import {FeeActions} from "../../../src/fees/FeeActions.sol";
import {YieldSeekerFeeTracker} from "../../../src/fees/FeeTracker.sol";
import {SwapAboveDebt, SwapBelowOraclePrice, YieldSeekerBorrowSwapPolicy as BorrowSwapPolicy} from "../../../src/swaps/BorrowSwapPolicy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract HalmosSwapOracle is IYieldSeekerPriceOracle {
    uint256 private immutable _quote;

    constructor(uint256 quote_) {
        _quote = quote_;
    }

    function getPrice(address) external pure returns (uint256) {
        return 1;
    }

    function quote(address, address, uint256) external view returns (uint256) {
        return _quote;
    }
}

contract HalmosSwapToken {
    uint256 private immutable _held;

    constructor(uint256 held_) {
        _held = held_;
    }

    function balanceOf(address) external view returns (uint256) {
        return _held;
    }
}

contract HalmosBorrowDebt {
    uint256 private immutable _debt;

    constructor(uint256 debt_) {
        _debt = debt_;
    }

    function tokenDebt(address, address) external view returns (uint256) {
        return _debt;
    }
}

contract HalmosSwapFeeTracker {
    address private immutable _borrowModule;

    constructor(address borrowModule_) {
        _borrowModule = borrowModule_;
    }

    function feeModules(bytes32 feeType) external view returns (address) {
        assert(feeType == BORROW_FEE);
        return _borrowModule;
    }
}

contract HalmosSwapWallet {
    address private immutable _baseAsset;
    address private immutable _feeTracker;

    constructor(address baseAsset_, address feeTracker_) {
        _baseAsset = baseAsset_;
        _feeTracker = feeTracker_;
    }

    function baseAsset() external view returns (IERC20) {
        return IERC20(_baseAsset);
    }

    function feeTracker() external view returns (YieldSeekerFeeTracker) {
        return YieldSeekerFeeTracker(_feeTracker);
    }
}

contract HalmosUnusedSellPolicy is IYieldSeekerSwapSellPolicy {
    function isSellableToken(address) external pure returns (bool) {
        return true;
    }

    function validateSellableToken(address) external pure {}
}

contract BorrowSwapHalmos {
    address private constant BASE_ASSET = address(0xB0);
    uint256 private constant MAX_SLIPPAGE_BPS = 500;

    function check_property11_acceptsExactlyWhenBothFormulaBoundsHold(uint256 soldAmount, uint256 boughtAmount, uint256 held, uint240 debt, uint256 oracleQuote) external {
        uint256 minimum = Math.mulDiv(oracleQuote, 10_000 - MAX_SLIPPAGE_BPS, 10_000, Math.Rounding.Ceil);
        uint256 debtCap = uint256(debt) * 10_300 / 10_000;
        if (boughtAmount < minimum || held > debtCap) return;

        (BorrowSwapPolicy policy, HalmosSwapWallet wallet, address buyToken) = _newPolicy(oracleQuote, held, debt);
        bytes32 action = policy.checkSwapResult(address(wallet), BASE_ASSET, soldAmount, buyToken, boughtAmount);

        assert(action == FeeActions.SWAP);
    }

    function check_property11_rejectsBoughtAmountBelowCeilingAdjustedOracleFloor(uint256 soldAmount, uint256 boughtAmount, uint256 held, uint240 debt, uint256 oracleQuote) external {
        uint256 minimum = Math.mulDiv(oracleQuote, 10_000 - MAX_SLIPPAGE_BPS, 10_000, Math.Rounding.Ceil);
        if (boughtAmount >= minimum) return;

        (BorrowSwapPolicy policy, HalmosSwapWallet wallet, address buyToken) = _newPolicy(oracleQuote, held, debt);
        bool rejectedWithPriceFloor;
        try policy.checkSwapResult(address(wallet), BASE_ASSET, soldAmount, buyToken, boughtAmount) returns (bytes32) {
            assert(false);
        } catch (bytes memory reason) {
            rejectedWithPriceFloor = _errorSelector(reason) == SwapBelowOraclePrice.selector;
        }
        assert(rejectedWithPriceFloor);
    }

    function check_property11_rejectsHeldDebtAboveTheBufferedDebtCap(uint256 soldAmount, uint256 boughtAmount, uint256 held, uint240 debt, uint256 oracleQuote) external {
        uint256 minimum = Math.mulDiv(oracleQuote, 10_000 - MAX_SLIPPAGE_BPS, 10_000, Math.Rounding.Ceil);
        uint256 debtCap = uint256(debt) * 10_300 / 10_000;
        if (boughtAmount < minimum || held <= debtCap) return;

        (BorrowSwapPolicy policy, HalmosSwapWallet wallet, address buyToken) = _newPolicy(oracleQuote, held, debt);
        bool rejectedWithDebtCap;
        try policy.checkSwapResult(address(wallet), BASE_ASSET, soldAmount, buyToken, boughtAmount) returns (bytes32) {
            assert(false);
        } catch (bytes memory reason) {
            rejectedWithDebtCap = _errorSelector(reason) == SwapAboveDebt.selector;
        }
        assert(rejectedWithDebtCap);
    }

    function _newPolicy(uint256 oracleQuote, uint256 held, uint256 debt) private returns (BorrowSwapPolicy policy, HalmosSwapWallet wallet, address buyToken) {
        HalmosSwapOracle oracle = new HalmosSwapOracle(oracleQuote);
        HalmosSwapToken token = new HalmosSwapToken(held);
        HalmosBorrowDebt borrowModule = new HalmosBorrowDebt(debt);
        HalmosSwapFeeTracker feeTracker = new HalmosSwapFeeTracker(address(borrowModule));
        wallet = new HalmosSwapWallet(BASE_ASSET, address(feeTracker));
        buyToken = address(token);
        policy = new BorrowSwapPolicy(IYieldSeekerSwapSellPolicy(address(new HalmosUnusedSellPolicy())), oracle, MAX_SLIPPAGE_BPS);
    }

    function _errorSelector(bytes memory reason) private pure returns (bytes4 selector) {
        if (reason.length >= 4) {
            assembly ("memory-safe") {
                selector := mload(add(reason, 32))
            }
        }
    }
}
