// SPDX-License-Identifier: MIT
//
//   /$$     /$$ /$$           /$$       /$$  /$$$$$$                      /$$
//  |  $$   /$$/|__/          | $$      | $$ /$$__  $$                    | $$
//   \  $$ /$$/  /$$  /$$$$$$ | $$  /$$$$$$$| $$  \__/  /$$$$$$   /$$$$$$ | $$   /$$  /$$$$$$   /$$$$$$
//    \  $$$$/  | $$ /$$__  $$| $$ /$$__  $$|  $$$$$$  /$$__  $$ /$$__  $$| $$  /$$/ /$$__  $$ /$$__  $$
//     \  $$/   | $$| $$$$$$$$| $$| $$  | $$ \____  $$| $$$$$$$$| $$$$$$$$| $$$$$$/ | $$$$$$$$| $$  \__/
//      | $$    | $$| $$_____/| $$| $$  | $$ /$$  \ $$| $$_____/| $$_____/| $$_  $$ | $$_____/| $$
//      | $$    | $$|  $$$$$$$| $$|  $$$$$$$|  $$$$$$/|  $$$$$$$|  $$$$$$$| $$ \  $$|  $$$$$$$| $$
//      |__/    |__/ \_______/|__/ \_______/ \______/  \_______/ \_______/|__/  \__/ \_______/|__/
//
//  Grow your wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKMerklAdapter} from "../agentwalletkit/adapters/AWKMerklAdapter.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title YieldSeekerMerklAdapter
 * @notice YieldSeeker-specific Merkl adapter
 * @dev Reports every token the claim paid out (once per token, even if the claim lists it twice) to the fee modules.
 */
contract YieldSeekerMerklAdapter is AWKMerklAdapter, YieldSeekerAdapter {
    function _claimInternal(address distributor, address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) internal override {
        uint256[] memory balancesBefore = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balancesBefore[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
        super._claimInternal(distributor, users, tokens, amounts, proofs);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (_listedEarlier(tokens, i)) continue;
            uint256 claimed = IERC20(tokens[i]).balanceOf(address(this)) - balancesBefore[i];
            if (claimed > 0) _reportClaim(tokens[i], claimed);
        }
    }

    function _listedEarlier(address[] memory tokens, uint256 index) internal pure returns (bool) {
        for (uint256 j = 0; j < index; j++) {
            if (tokens[j] == tokens[index]) return true;
        }
        return false;
    }
}
