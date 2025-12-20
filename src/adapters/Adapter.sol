// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerFeeTracker as FeeTracker} from "../FeeTracker.sol";
import {IAgentWallet} from "../IAgentWallet.sol";
import {IYieldSeekerAdapter} from "./IAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title YieldSeekerAdapter
 * @notice Base class for all adapters in the YieldSeeker system.
 * @dev Adapters are designed to be called ONLY via delegatecall from AgentWallet.
 *      Direct calls to adapter contracts are prevented via the onlyDelegateCall modifier.
 */
abstract contract YieldSeekerAdapter is IYieldSeekerAdapter {
    error InvalidAsset();
    error UnknownOperation();
    error DirectCallNotAllowed();

    /// @notice The adapter's own address, set at deployment
    /// @dev Used to detect direct calls vs delegatecalls
    address private immutable SELF;

    constructor() {
        SELF = address(this);
    }

    /**
     * @notice Ensures function is only called via delegatecall
     * @dev When called via delegatecall, address(this) is the caller's address (AgentWallet).
     *      When called directly, address(this) equals SELF (the adapter's address).
     */
    modifier onlyDelegateCall() {
        if (address(this) == SELF) revert DirectCallNotAllowed();
        _;
    }

    /**
     * @notice Standard entry point for all adapter logic
     * @dev Subclasses must override this and MUST include the onlyDelegateCall modifier.
     *      Already running in wallet context via delegatecall from AgentWallet.
     * @param target The contract the adapter will interact with
     * @param data The specific operation data
     */
    function execute(address target, bytes calldata data) external payable virtual override returns (bytes memory);

    function _agentWallet() internal view returns (IAgentWallet) {
        return IAgentWallet(address(this));
    }

    function _baseAsset() internal view returns (IERC20) {
        return _agentWallet().baseAsset();
    }

    function _baseAssetAddress() internal view returns (address) {
        return address(_baseAsset());
    }

    function _requireBaseAsset(address asset) internal view {
        if (asset != _baseAssetAddress()) revert InvalidAsset();
    }

    function _feeTracker() internal view returns (FeeTracker) {
        return _agentWallet().feeTracker();
    }
}
