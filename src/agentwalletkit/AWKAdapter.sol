// SPDX-License-Identifier: MIT
//
//      _                    _ __        __    _ _      _   _  ___ _
//     / \   __ _  ___ _ __ | |\ \      / /_ _| | | ___| |_| |/ (_) |_
//    / _ \ / _` |/ _ \ '_ \| __\ \ /\ / / _` | | |/ _ \ __| ' /| | __|
//   / ___ \ (_| |  __/ | | | |_ \ V  V / (_| | | |  __/ |_| . \| | |_
//  /_/   \_\__, |\___|_| |_|\__| \_/\_/ \__,_|_|_|\___|\__|_|\_\_|\__|
//          |___/
//
//  Build verifiably secure onchain agents
//  https://agentwalletkit.com
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.38;

import {AWKErrors} from "./AWKErrors.sol";
import {IAWKAdapter} from "./IAWKAdapter.sol";
import {IAWKAgentWallet} from "./IAWKAgentWallet.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

error UnknownOperation();

/**
 * @title AWKAdapter
 * @notice Base class for all adapters in the AWK system.
 * @dev A wallet runs an adapter by delegatecalling execute(target, data), where `data` is a call to one of the
 *      adapter's operations (e.g. deposit(amount)). execute records the target for the length of the call and runs
 *      `data` on the adapter's own code, still in the wallet's context. Operations carry onlyExecute, so they run
 *      only this way, and read the target with _target().
 *      Every external function of an adapter can be reached through execute: give each one that changes state
 *      onlyExecute, and add no other.
 */
abstract contract AWKAdapter is IAWKAdapter {
    using TransientSlot for *;

    bytes32 private constant TARGET_SLOT = keccak256("agentwalletkit.adapter.target");

    /// @dev The adapter's own address: address(this) is the wallet while the adapter runs by delegatecall
    address internal immutable SELF = address(this);

    modifier onlyExecute() {
        if (_target() == address(0)) revert AWKErrors.DirectCallForbidden();
        _;
    }

    /// @dev Reverts on a direct call, and while a target is set: `data` can't call execute again to swap in a target
    ///      the wallet never checked against its registry
    function execute(address target, bytes calldata data) external payable override returns (bytes memory result) {
        if (address(this) == SELF || _target() != address(0)) revert AWKErrors.DirectCallForbidden();
        TARGET_SLOT.asAddress().tstore(target);
        bool success;
        (success, result) = SELF.delegatecall(data);
        if (!success) {
            assembly ("memory-safe") {
                revert(add(result, 32), mload(result))
            }
        }
        TARGET_SLOT.asAddress().tstore(address(0));
    }

    fallback() external {
        revert UnknownOperation();
    }

    /// @dev The target of the execute call in progress, which the wallet has checked against its registry
    function _target() internal view returns (address) {
        return TARGET_SLOT.asAddress().tload();
    }

    function _agentWallet() internal view virtual returns (IAWKAgentWallet) {
        return IAWKAgentWallet(address(this));
    }
}
