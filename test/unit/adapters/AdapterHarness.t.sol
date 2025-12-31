// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAgentWallet} from "../../../src/IAgentWallet.sol";
import {IYieldSeekerAdapter} from "../../../src/adapters/IAdapter.sol";
import {YieldSeekerFeeTracker} from "../../../src/FeeTracker.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title AdapterWalletHarness
/// @notice Minimal wallet harness to execute adapters via delegatecall in tests
contract AdapterWalletHarness is IAgentWallet {
    IERC20 private immutable _baseAsset;
    YieldSeekerFeeTracker private immutable _feeTracker;

    constructor(IERC20 baseAsset_, YieldSeekerFeeTracker feeTracker_) {
        _baseAsset = baseAsset_;
        _feeTracker = feeTracker_;
    }

    function baseAsset() external view override returns (IERC20) {
        return _baseAsset;
    }

    function feeTracker() external view override returns (YieldSeekerFeeTracker) {
        return _feeTracker;
    }

    /// @notice Execute adapter logic via delegatecall
    function executeAdapter(address adapter, address target, bytes memory data) external returns (bytes memory) {
        (bool ok, bytes memory res) = adapter.delegatecall(
            abi.encodeWithSelector(IYieldSeekerAdapter.execute.selector, target, data)
        );
        if (!ok) {
            assembly {
                revert(add(res, 0x20), mload(res))
            }
        }
        return res;
    }

    receive() external payable {}
}
