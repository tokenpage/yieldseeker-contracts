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

import {AWKAdapterTarget} from "./AWKAdapterTarget.sol";
import {AWKErrors} from "./AWKErrors.sol";

error UnknownOperation();

/**
 * @title AWKAdapter
 * @notice Base class for all adapters in the AWK system.
 * @dev A wallet runs an adapter operation (e.g. deposit(amount)) by delegatecall, after it has checked the target
 *      against its registry and recorded it (AWKAdapterTarget). Operations carry onlyExecute, so they run only this
 *      way, and read the target with _target().
 *      A wallet's operator can call every external function of an adapter in the wallet's context: give each one
 *      that changes state onlyExecute, and add no other.
 */
abstract contract AWKAdapter {
    /// @dev The adapter's own address: address(this) is the wallet while the adapter runs by delegatecall
    address internal immutable SELF = address(this);

    /// @dev Only while a wallet runs this adapter: on a direct call the adapter's own target is never set
    modifier onlyExecute() {
        if (_target() == address(0)) revert AWKErrors.DirectCallForbidden();
        _;
    }

    fallback() external {
        revert UnknownOperation();
    }

    /// @dev The target of the call in progress, which the wallet has checked against its registry
    function _target() internal view returns (address) {
        return AWKAdapterTarget.get();
    }
}
