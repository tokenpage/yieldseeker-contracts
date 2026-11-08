// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AWKMerklAdapter, IMerklDistributor} from "../agentwalletkit/adapters/AWKMerklAdapter.sol";
import {FeeActions} from "../fees/FeeActions.sol";
import {YieldSeekerAdapter} from "./Adapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error ClaimDeliveryMismatch(address token, uint256 paid, uint256 received);

/**
 * @title YieldSeekerMerklAdapter
 * @notice YieldSeeker-specific Merkl adapter
 * @dev Reports every token the claim paid out (once per token, even if the claim lists it twice) to the fee modules.
 *      All amounts are measured before the first report, since a report can pay fees from the base asset.
 *      A token counts as claimed exactly as the distributor records it paid to the wallet in this call (its claimed()
 *      total), so tokens that reach the wallet during the claim from anywhere else (e.g. an owner withdrawal an
 *      operator triggers from a reward token's transfer hook) are not charged as yield. A token whose balance rose by
 *      less than that reverts the claim (ClaimDeliveryMismatch): fee-on-transfer rewards and Merkl wrapper tokens that
 *      burn on receipt and pay out another token can't be claimed, so their payout can't escape the fee.
 */
contract YieldSeekerMerklAdapter is AWKMerklAdapter, YieldSeekerAdapter {
    function _claimOperation(address distributor, address[] memory tokens, uint256[] memory amounts, bytes32[][] memory proofs) internal override {
        uint256[] memory balancesBefore = new uint256[](tokens.length);
        uint256[] memory paidBefore = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            balancesBefore[i] = IERC20(tokens[i]).balanceOf(address(this));
            (paidBefore[i],,) = IMerklDistributor(distributor).claimed(address(this), tokens[i]);
        }
        super._claimOperation(distributor, tokens, amounts, proofs);
        uint256[] memory claimed = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            if (_listedEarlier(tokens, i)) continue;
            (uint256 paidAfter,,) = IMerklDistributor(distributor).claimed(address(this), tokens[i]);
            uint256 paid = paidAfter - paidBefore[i];
            uint256 received = IERC20(tokens[i]).balanceOf(address(this)) - balancesBefore[i];
            if (received < paid) revert ClaimDeliveryMismatch(tokens[i], paid, received);
            claimed[i] = paid;
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
