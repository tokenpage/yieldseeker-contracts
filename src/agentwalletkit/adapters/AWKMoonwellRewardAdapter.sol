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

import {AWKAdapter, UnknownOperation} from "../AWKAdapter.sol";
import {AWKErrors} from "../AWKErrors.sol";

error InvalidClaimHolder(address holder);

interface IMoonwellComptroller {
    function claimReward(address holder, address[] calldata mTokens) external;
}

abstract contract AWKMoonwellRewardAdapter is AWKAdapter {
    function execute(address target, bytes calldata data) external payable virtual override onlyDelegateCall returns (bytes memory) {
        if (bytes4(data[:4]) != this.claimReward.selector) revert UnknownOperation();
        (address holder, address[] memory mTokens) = abi.decode(data[4:], (address, address[]));
        if (holder != address(this)) revert InvalidClaimHolder(holder);
        _claimOperation(target, mTokens);
        return "";
    }

    function claimReward(address holder, address[] calldata mTokens) external pure {
        holder;
        mTokens;
        revert AWKErrors.DirectCallForbidden();
    }

    // ============ Operations (override to add rules) ============

    function _claimOperation(address comptroller, address[] memory mTokens) internal virtual {
        _claim(comptroller, mTokens);
    }

    // ============ Protocol Implementation ============

    /// @dev Claims the wallet's rewards on `mTokens` into the wallet
    function _claim(address comptroller, address[] memory mTokens) internal virtual {
        IMoonwellComptroller(comptroller).claimReward(address(this), mTokens);
    }
}
