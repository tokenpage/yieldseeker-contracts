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
//  Build wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKMerklAdapter} from "../agentwalletkit/adapters/AWKMerklAdapter.sol";
import {FeeActions} from "../fees/FeeActions.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title YieldSeekerMerklAdapter
 * @notice YieldSeeker-specific Merkl adapter
 * @dev Reports every token the claim paid out (once per token, even if the claim lists it twice) to the fee modules.
 *      All amounts are measured before the first report, since a report can pay fees from the base asset.
 */
contract YieldSeekerMerklAdapter is AWKMerklAdapter, YieldSeekerAdapter {
    function _claimOperation(address distributor, address[] memory users, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) internal override {
        uint256[] memory balancesBefore = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balancesBefore[i] = IERC20(tokens[i]).balanceOf(address(this));
        }
        super._claimOperation(distributor, users, tokens, amounts, proofs);
        uint256[] memory claimed = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (!_listedEarlier(tokens, i)) claimed[i] = IERC20(tokens[i]).balanceOf(address(this)) - balancesBefore[i];
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            if (claimed[i] > 0) _reportAction(FeeActions.CLAIM, abi.encode(FeeActions.Claim({token: tokens[i], amount: claimed[i]})));
        }
    }

    function _listedEarlier(address[] memory tokens, uint256 index) internal pure returns (bool) {
        for (uint256 j = 0; j < index; j++) {
            if (tokens[j] == tokens[index]) return true;
        }
        return false;
    }
}
