// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker as FeeTracker} from "../FeeTracker.sol";
import {IAgentWallet} from "../IAgentWallet.sol";
import {AWKAdapter} from "../agentwalletkit/AWKAdapter.sol";
import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title YieldSeekerAdapter
 * @notice Base class for all adapters in the YieldSeeker system.
 * @dev Extends AWKAdapter with YieldSeeker-specific helpers for baseAsset and feeTracker
 */
abstract contract YieldSeekerAdapter is AWKAdapter {
    // Helper to get the wallet as IAgentWallet instead of IAWKAgentWallet
    function _ysAgentWallet() internal view returns (IAgentWallet) {
        return IAgentWallet(address(this));
    }

    function _baseAsset() internal view returns (IERC20) {
        return _ysAgentWallet().baseAsset();
    }

    function _baseAssetAddress() internal view returns (address) {
        return address(_baseAsset());
    }

    function _requireBaseAsset(address asset) internal view {
        if (asset != _baseAssetAddress()) revert AWKErrors.InvalidAddress();
    }

    function _feeTracker() internal view returns (FeeTracker) {
        return _ysAgentWallet().feeTracker();
    }
}
