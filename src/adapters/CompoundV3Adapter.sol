// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AWKBaseVaultAdapter} from "../agentwalletkit/adapters/AWKBaseVaultAdapter.sol";
import {AWKCompoundV3Adapter} from "../agentwalletkit/adapters/AWKCompoundV3Adapter.sol";
import {YieldSeekerVaultAdapter} from "./VaultAdapter.sol";

/**
 * @title YieldSeekerCompoundV3Adapter
 * @notice YieldSeeker Compound V3 (Comet) vault adapter: the AWK protocol code plus the shared YieldSeeker vault rules and fee reports
 */
contract YieldSeekerCompoundV3Adapter is AWKCompoundV3Adapter, YieldSeekerVaultAdapter {
    function _depositOperation(address vault, uint256 amount) internal override(AWKBaseVaultAdapter, YieldSeekerVaultAdapter) returns (uint256, uint256) {
        return super._depositOperation(vault, amount);
    }

    function _withdrawOperation(address vault, uint256 shares) internal override(AWKBaseVaultAdapter, YieldSeekerVaultAdapter) returns (uint256) {
        return super._withdrawOperation(vault, shares);
    }
}
