// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPriceFeed} from "../../src/PriceOracle.sol";

contract MockFeePriceFeed is IPriceFeed {
    uint8 private immutable _decimals;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;

    constructor(uint8 decimals_, int256 answer_, uint256 updatedAt_) {
        _decimals = decimals_;
        answer = answer_;
        startedAt = updatedAt_;
        updatedAt = updatedAt_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function setPrice(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setRoundData(int256 answer_, uint256 startedAt_, uint256 updatedAt_) external {
        answer = answer_;
        startedAt = startedAt_;
        updatedAt = updatedAt_;
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, startedAt, updatedAt, 1);
    }
}
