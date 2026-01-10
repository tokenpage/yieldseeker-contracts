// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKErrors} from "./AWKErrors.sol";
import {IAWKAdapter} from "./IAWKAdapter.sol";
import {IAWKAgentWallet} from "./IAWKAgentWallet.sol";

error UnknownOperation();

/**
 * @title AWKAdapter
 * @notice Base class for all adapters in the AWK system.
 * @dev Adapters are designed to be called ONLY via delegatecall from AgentWallet.
 *      Direct calls to adapter contracts are prevented via the onlyDelegateCall modifier.
 */
abstract contract AWKAdapter is IAWKAdapter {
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
        if (address(this) == SELF) revert AWKErrors.DirectCallForbidden();
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

    function _agentWallet() internal view virtual returns (IAWKAgentWallet) {
        return IAWKAgentWallet(address(this));
    }
}
