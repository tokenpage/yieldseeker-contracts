// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IYieldSeekerPriceOracle} from "../../src/PriceOracle.sol";

contract MockSwapAdapterPriceOracle is IYieldSeekerPriceOracle {
    function getPrice(address) external pure returns (uint256) {
        return 1e18;
    }

    function quote(address, address, uint256 amount) external pure returns (uint256) {
        return amount;
    }
}
