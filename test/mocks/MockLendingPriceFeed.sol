// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPriceFeed} from "../../src/PriceOracle.sol";

contract MockLendingPriceFeed is IPriceFeed {
    uint8 private immutable _decimals;
    int256 private _answer;
    uint256 private _startedAt;
    uint256 private _updatedAt;

    constructor(uint8 decimals_, int256 answer_) {
        _decimals = decimals_;
        setAnswer(answer_);
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function latestRoundData() external view override returns (uint80, int256 answer, uint256 startedAt, uint256 updatedAt, uint80) {
        return (1, _answer, _startedAt, _updatedAt, 1);
    }

    function setAnswer(int256 answer_) public {
        _answer = answer_;
        _startedAt = block.timestamp;
        _updatedAt = block.timestamp;
    }

    function setRoundData(int256 answer_, uint256 startedAt_, uint256 updatedAt_) external {
        _answer = answer_;
        _startedAt = startedAt_;
        _updatedAt = updatedAt_;
    }
}
