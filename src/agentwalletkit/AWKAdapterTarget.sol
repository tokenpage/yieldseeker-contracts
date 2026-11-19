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

import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";

/**
 * @title AWKAdapterTarget
 * @notice The target of the adapter call a wallet is running
 * @dev The wallet sets it, in its own transient storage, after checking the target against its registry, and clears it
 *      when the call returns. The adapter runs by delegatecall, so it reads the same slot: zero means the adapter is
 *      not being run by a wallet.
 */
library AWKAdapterTarget {
    bytes32 private constant SLOT = keccak256("agentwalletkit.adapter.target");

    function get() internal view returns (address) {
        return TransientSlot.tload(TransientSlot.asAddress(SLOT));
    }

    function set(address target) internal {
        TransientSlot.tstore(TransientSlot.asAddress(SLOT), target);
    }
}
