// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IPriceFeed, SequencerDown, StalePrice} from "../../../src/PriceOracle.sol";
import {IntegrationBase} from "../../integration/IntegrationBase.t.sol";
import {MockERC20WithDecimals} from "../../mocks/MockERC20.sol";
import {MockFeePriceFeed} from "../../mocks/MockFeePriceFeed.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @dev Fuzz bounds: prices range from $0.01 to $10,000 and one quote is at most one billion whole tokens.
///      Even at 24 decimals this caps raw input at 1e33; the full-precision products stay far below uint256 limits.
contract PriceOracleProperties is IntegrationBase {
    function testFuzz_quoteMatchesUnitConversionAndNeverOverflows(uint8 fromDecimalsSeed, uint8 toDecimalsSeed, uint256 fromPriceSeed, uint256 toPriceSeed, uint256 amountSeed, uint256 incrementSeed) public {
        uint8 fromDecimals = uint8(bound(fromDecimalsSeed, 0, 24));
        uint8 toDecimals = uint8(bound(toDecimalsSeed, 0, 24));
        uint256 fromAnswer = bound(fromPriceSeed, 1e6, 1e12);
        uint256 toAnswer = bound(toPriceSeed, 1e6, 1e12);
        uint256 maxAmount = 1e9 * 10 ** fromDecimals;
        uint256 amount = bound(amountSeed, 0, maxAmount / 2);
        uint256 increment = bound(incrementSeed, 1, maxAmount / 2);

        MockERC20WithDecimals fromToken = new MockERC20WithDecimals("From", "FROM", fromDecimals);
        MockERC20WithDecimals toToken = new MockERC20WithDecimals("To", "TO", toDecimals);
        MockFeePriceFeed fromFeed = new MockFeePriceFeed(8, int256(fromAnswer), block.timestamp);
        MockFeePriceFeed toFeed = new MockFeePriceFeed(8, int256(toAnswer), block.timestamp);
        priceOracle.setSource(address(fromToken), IPriceFeed(address(fromFeed)), 1 days);
        priceOracle.setSource(address(toToken), IPriceFeed(address(toFeed)), 1 days);

        uint256 fromPrice = fromAnswer * 1e10;
        uint256 toPrice = toAnswer * 1e10;
        uint256 fromValue = Math.mulDiv(amount, fromPrice, 10 ** fromDecimals);
        uint256 expected = Math.mulDiv(fromValue, 10 ** toDecimals, toPrice);
        uint256 actual = priceOracle.quote(address(fromToken), address(toToken), amount);
        assertEq(actual, expected, "quote did not convert token decimals and USD prices");

        uint256 largerAmount = amount + increment;
        uint256 largerQuote = priceOracle.quote(address(fromToken), address(toToken), largerAmount);
        assertGe(largerQuote, actual, "quote decreased as the input amount increased");

        uint256 maxQuote = priceOracle.quote(address(fromToken), address(toToken), maxAmount);
        uint256 maxFromValue = Math.mulDiv(maxAmount, fromPrice, 10 ** fromDecimals);
        assertEq(maxQuote, Math.mulDiv(maxFromValue, 10 ** toDecimals, toPrice));
    }

    function test_quoteRejectsStaleFeedAndSequencerDownOrInGracePeriod() public {
        uint256 now_ = vm.getBlockTimestamp() + 2 days;
        vm.warp(now_);
        MockERC20WithDecimals fromToken = new MockERC20WithDecimals("From", "FROM", 18);
        MockERC20WithDecimals toToken = new MockERC20WithDecimals("To", "TO", 6);
        MockFeePriceFeed fromFeed = new MockFeePriceFeed(8, 2_000e8, now_);
        MockFeePriceFeed toFeed = new MockFeePriceFeed(8, 1e8, now_);
        priceOracle.setSource(address(fromToken), IPriceFeed(address(fromFeed)), 1 days);
        priceOracle.setSource(address(toToken), IPriceFeed(address(toFeed)), 1 days);

        fromFeed.setPrice(2_000e8, 1);
        assertEq(fromFeed.updatedAt(), 1);
        vm.expectRevert(abi.encodeWithSelector(StalePrice.selector, address(fromToken), uint256(1), uint256(1 days)));
        priceOracle.quote(address(fromToken), address(toToken), 1e18);
        fromFeed.setPrice(2_000e8, now_);

        sequencerFeed.setRoundData(1, now_, now_);
        vm.expectRevert(SequencerDown.selector);
        priceOracle.quote(address(fromToken), address(toToken), 1e18);

        uint256 sequencerUpSince = now_ + 10;
        sequencerFeed.setRoundData(0, sequencerUpSince, sequencerUpSince);
        vm.warp(sequencerUpSince + 1 hours - 1);
        vm.expectRevert(SequencerDown.selector);
        priceOracle.quote(address(fromToken), address(toToken), 1e18);

        vm.warp(sequencerUpSince + 1 hours);
        assertGt(priceOracle.quote(address(fromToken), address(toToken), 1e18), 0, "quote stayed blocked after the sequencer grace period");
    }
}
