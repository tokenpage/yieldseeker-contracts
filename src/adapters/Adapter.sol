// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeLedger as FeeLedger} from "../FeeLedger.sol";
import {IAgentWallet} from "../IAgentWallet.sol";
import {IYieldSeekerAdapter} from "./IAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title YieldSeekerAdapter
 * @notice Base class for all adapters in the YieldSeeker system.
 */
abstract contract YieldSeekerAdapter is IYieldSeekerAdapter {
    error InvalidAsset();

    function _baseAsset() internal view returns (IERC20) {
        return IAgentWallet(address(this)).baseAsset();
    }

    function _baseAssetAddress() internal view returns (address) {
        return address(_baseAsset());
    }

    function _requireBaseAsset(address asset) internal view {
        if (asset != _baseAssetAddress()) revert InvalidAsset();
    }

    function _feeLedger() internal view returns (FeeLedger) {
        return IAgentWallet(address(this)).feeLedger();
    }
}
