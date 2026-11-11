// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {IPriceFeed, YieldSeekerPriceOracle} from "../../../src/PriceOracle.sol";

interface HalmosOracleCheatcodes {
    function warp(uint256 timestamp) external;
}

contract HalmosSequencerFeed is IPriceFeed {
    function decimals() external pure returns (uint8) {
        return 0;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        return (1, 0, 1, 1, 1);
    }
}

contract HalmosPriceFeed is IPriceFeed {
    uint8 private immutable _decimals;
    int256 private immutable _answer;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        _answer = answer_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, 10_000, 10_000, 1);
    }
}

contract HalmosTokenDecimals {
    uint8 private immutable _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }
}

contract PriceOracleHalmos {
    HalmosOracleCheatcodes private constant vm = HalmosOracleCheatcodes(address(uint160(uint256(keccak256("hevm cheat code")))));
    address private token6Decimals;
    address private token18Decimals;
    YieldSeekerPriceOracle private oracle;

    function setUp() public {
        vm.warp(10_000);
        HalmosSequencerFeed sequencer = new HalmosSequencerFeed();
        oracle = new YieldSeekerPriceOracle(address(this), address(this), sequencer);
        HalmosPriceFeed usdFeed = new HalmosPriceFeed(8, 100_000_000);
        token6Decimals = address(new HalmosTokenDecimals(6));
        token18Decimals = address(new HalmosTokenDecimals(18));
        oracle.setSource(token6Decimals, usdFeed, 1 days);
        oracle.setSource(token18Decimals, usdFeed, 1 days);
    }

    function check_property13_quoteScalesSixDecimalsIntoEighteen(uint8 amount) external view {
        uint256 quote = oracle.quote(token6Decimals, token18Decimals, amount);
        assert(quote == uint256(amount) * 1e12);
    }

    function check_property13_quoteScalesEighteenDecimalsIntoSix(uint40 amount) external view {
        uint256 quote = oracle.quote(token18Decimals, token6Decimals, amount);
        assert(quote == uint256(amount) / 1e12);
    }

    function check_property13_quoteDoesNotDecreaseForOneMoreInputUnit(uint8 amount) external view {
        if (amount == type(uint8).max) return;

        uint256 quote = oracle.quote(token6Decimals, token18Decimals, amount);
        uint256 nextQuote = oracle.quote(token6Decimals, token18Decimals, uint256(amount) + 1);

        assert(quote <= nextQuote);
    }
}
