// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAgentWallet} from "../../../src/IAgentWallet.sol";
import {IAWKAdapter} from "../../../src/agentwalletkit/IAWKAdapter.sol";
import {YieldSeekerFeeTracker} from "../../../src/fees/FeeTracker.sol";
import {YIELD_FEE, YieldSeekerYieldFeeModule} from "../../../src/fees/YieldFeeModule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library AdapterFeeSetup {
    function deploy(address feeCollector, uint256 maxFeeRateBps, uint256 rateBps) internal returns (YieldSeekerFeeTracker feeTracker, YieldSeekerYieldFeeModule yieldFees) {
        feeTracker = new YieldSeekerFeeTracker(address(this), feeCollector);
        yieldFees = addYieldModule(feeTracker, maxFeeRateBps, rateBps);
    }

    function addYieldModule(YieldSeekerFeeTracker feeTracker, uint256 maxFeeRateBps, uint256 rateBps) internal returns (YieldSeekerYieldFeeModule yieldFees) {
        yieldFees = new YieldSeekerYieldFeeModule(feeTracker, maxFeeRateBps);
        feeTracker.setFeeModule(YIELD_FEE, yieldFees);
        feeTracker.createPlan(YIELD_FEE, abi.encode(YieldSeekerYieldFeeModule.Plan({rateBps: rateBps})));
    }
}

/// @title AdapterWalletHarness
/// @notice Minimal wallet harness to execute adapters via delegatecall in tests
contract AdapterWalletHarness is IAgentWallet {
    IERC20 private immutable _BASE_ASSET;
    YieldSeekerFeeTracker private immutable _FEE_TRACKER;
    address public immutable owner;

    constructor(IERC20 baseAsset_, YieldSeekerFeeTracker feeTracker_) {
        owner = msg.sender;
        _BASE_ASSET = baseAsset_;
        _FEE_TRACKER = feeTracker_;
    }

    function baseAsset() external view override returns (IERC20) {
        return _BASE_ASSET;
    }

    function feeTracker() external view override returns (YieldSeekerFeeTracker) {
        return _FEE_TRACKER;
    }

    function yieldFeeModule() external view returns (YieldSeekerYieldFeeModule) {
        return YieldSeekerYieldFeeModule(address(_FEE_TRACKER.feeModules(YIELD_FEE)));
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
