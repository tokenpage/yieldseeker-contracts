// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKBaseVaultAdapter} from "../agentwalletkit/adapters/AWKBaseVaultAdapter.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";

/**
 * @title YieldSeekerVaultAdapter
 * @notice Abstract base class for all YieldSeeker vault adapters
 * @dev Extends AWKBaseVaultAdapter with YieldSeeker-specific functionality.
 *      This maintains the same interface for backwards compatibility with operations like rebalancePortfolio.
 */
abstract contract YieldSeekerVaultAdapter is AWKBaseVaultAdapter, YieldSeekerAdapter {
    /**
     * @notice Internal deposit percentage implementation
     * @param vault The vault address
     * @param percentageBps The percentage in basis points (10000 = 100%)
     * @return shares The amount of vault shares received
     * @dev Implemented using base asset from YieldSeeker wallet
     */
    function _depositPercentageInternal(address vault, uint256 percentageBps) internal returns (uint256 shares) {
        return super._depositPercentageInternal(vault, percentageBps, _baseAsset());
    }
}
