// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker} from "../../../src/FeeTracker.sol";
import {IAgentWallet} from "../../../src/IAgentWallet.sol";
import {IAWKAdapter} from "../../../src/agentwalletkit/IAWKAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title AdapterWalletHarness
/// @notice Minimal wallet harness to execute adapters via delegatecall in tests
contract AdapterWalletHarness is IAgentWallet {
    IERC20 private immutable _BASE_ASSET;
    YieldSeekerFeeTracker private immutable _FEE_TRACKER;

    constructor(IERC20 baseAsset_, YieldSeekerFeeTracker feeTracker_) {
        _BASE_ASSET = baseAsset_;
        _FEE_TRACKER = feeTracker_;
    }

    function baseAsset() external view override returns (IERC20) {
        return _BASE_ASSET;
    }

    function feeTracker() external view override returns (YieldSeekerFeeTracker) {
        return _FEE_TRACKER;
    }

    /// @notice Execute adapter logic via delegatecall
    function executeAdapter(address adapter, address target, bytes memory data) external returns (bytes memory) {
        (bool ok, bytes memory res) = adapter.delegatecall(abi.encodeWithSelector(IAWKAdapter.execute.selector, target, data));
        if (!ok) {
            assembly {
                revert(add(res, 0x20), mload(res))
            }
        }
        return res;
    }

    receive() external payable {}
}
