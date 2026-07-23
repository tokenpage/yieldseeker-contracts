// SPDX-License-Identifier: MIT
//
//      _                    _ __        __    _ _      _   _  ___ _
//     / \   __ _  ___ _ __ | |\ \      / /_ _| | | ___| |_| |/ (_) |_
//    / _ \ / _` |/ _ \ '_ \| |__\ \ /\ / / _` | | |/ _ \ __| ' /| | __|
//   / ___ \ (_| |  __/ | | | |_ \ V  V / (_| | | |  __/ |_| . \| | |_
//  /_/   \_\__, |\___|_| |_\__| \_/\_/ \__,_|_|_|\___|\__|_|\_\_| |_|
//          |___/
//
//  Build verifiably secure onchain agents
//  https://agentwalletkit.tokenpage.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKAdapter, UnknownOperation} from "../AWKAdapter.sol";
import {AWKErrors} from "../AWKErrors.sol";

error InvalidClaimHolder(address holder);

interface IMoonwellComptroller {
    function claimReward(address holder, address[] calldata mTokens) external;
}

abstract contract AWKMoonwellRewardAdapter is AWKAdapter {
    function execute(address target, bytes calldata data) external payable virtual override onlyDelegateCall returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == this.claimReward.selector) {
            (address holder, address[] memory mTokens) = abi.decode(data[4:], (address, address[]));
            _claimInternal(target, holder, mTokens);
            return "";
        }
        revert UnknownOperation();
    }

    function claimReward(address holder, address[] calldata mTokens) external pure {
        holder;
        mTokens;
        revert AWKErrors.DirectCallForbidden();
    }

    function _claimInternal(address comptroller, address holder, address[] memory mTokens) internal virtual {
        if (holder != address(this)) revert InvalidClaimHolder(holder);
        IMoonwellComptroller(comptroller).claimReward(holder, mTokens);
    }
}
