// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapter} from "./Adapter.sol";
import {AWKERC4626Adapter, IERC4626} from "../agentwalletkit/AWKERC4626Adapter.sol";
import {AWKAdapter} from "../agentwalletkit/AWKAdapter.sol";

/**
 * @title YieldSeekerERC4626Adapter
 * @notice YieldSeeker-specific ERC4626 adapter with fee tracking
 * @dev Extends the generic AWKERC4626Adapter and implements post hooks for fee tracking.
 *      Records position changes with FeeTracker for yield fee calculation.
 */
contract YieldSeekerERC4626Adapter is AWKERC4626Adapter, YieldSeekerAdapter {
    /**
     * @notice Override execute to handle vault operations with base asset validation
     * @dev Already running in wallet context via delegatecall from AgentWallet
     */
    function execute(address target, bytes calldata data) external payable override(AWKAdapter, AWKERC4626Adapter) onlyDelegateCall returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == this.deposit.selector) {
            uint256 amount = abi.decode(data[4:], (uint256));
            uint256 shares = _depositInternal(target, amount);
            return abi.encode(shares);
        }
        if (selector == this.depositPercentage.selector) {
            uint256 percentageBps = abi.decode(data[4:], (uint256));
            uint256 shares = super._depositPercentageInternal(target, percentageBps, _baseAsset());
            return abi.encode(shares);
        }
        if (selector == this.withdraw.selector) {
            uint256 shares = abi.decode(data[4:], (uint256));
            uint256 assets = _withdrawInternal(target, shares);
            return abi.encode(assets);
        }
        revert UnknownOperation();
    }

    /**
     * @notice Pre-deposit hook - validate base asset
     * @dev Called before deposit to ensure the vault uses the correct base asset
     */
    function _preDeposit(address vault, uint256 amount) internal view override {
        address asset = IERC4626(vault).asset();
        _requireBaseAsset(asset);
    }

    /**
     * @notice Post-deposit hook - record fee tracking
     * @dev Called after deposit to record position changes for yield fee calculation
     */
    function _postDeposit(address vault, uint256 assetsDeposited, uint256 sharesReceived) internal override {
        _feeTracker().recordAgentVaultShareDeposit({vault: vault, assetsDeposited: assetsDeposited, sharesReceived: sharesReceived});
    }

    /**
     * @notice Pre-withdraw hook - validate base asset
     * @dev Called before withdraw to ensure the vault uses the correct base asset
     */
    function _preWithdraw(address vault, uint256 shares) internal view override {
        address asset = IERC4626(vault).asset();
        _requireBaseAsset(asset);
    }

    /**
     * @notice Post-withdraw hook - record fee tracking
     * @dev Called after withdraw to record position changes for yield fee calculation
     */
    function _postWithdraw(address vault, uint256 sharesSpent, uint256 assetsReceived) internal override {
        _feeTracker().recordAgentVaultShareWithdraw({vault: vault, sharesSpent: sharesSpent, assetsReceived: assetsReceived});
    }
}
