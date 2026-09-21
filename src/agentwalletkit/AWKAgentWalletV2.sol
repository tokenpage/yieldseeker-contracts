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
//  https://agentwalletkit.tokenpage.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKAgentWalletV1} from "./AWKAgentWalletV1.sol";
import {AWKErrors} from "./AWKErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {UserOperation} from "account-abstraction/interfaces/UserOperation.sol";

/**
 * @title AWKAgentWalletV2
 * @notice Adds EntryPoint-relayed (gas-sponsored) owner authorization on top of AWKAgentWalletV1.
 * @dev V1 is never modified — it's already deployed and live for thousands of wallets. This is a
 *      brand-new implementation contract that existing V1 wallets may opt in to via
 *      upgradeToLatest()/upgradeToAndCall() once the Factory is pointed here; new wallets deploy
 *      directly on this version. Storage is untouched: no new fields, same ERC-7201 slots as V1.
 *
 *      Authorization model:
 *      - Owner signature: valid for any function, whether called directly or via a relayed
 *        UserOperation. This is what makes gas-sponsored withdrawals possible — a relayer can
 *        submit and pay for the transaction, but only the owner's own signature can ever
 *        authorize it.
 *      - Operator signature: valid only for `executeViaAdapter`/`executeViaAdapterBatch`,
 *        exactly as in V1. Operators gain no new authority from this version.
 *
 *      Every override here is left `virtual` so a future V3 can extend it directly, without
 *      needing to duplicate anything — the lesson from why this file exists in the first place.
 */
abstract contract AWKAgentWalletV2 is AWKAgentWalletV1 {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    constructor(address factory) AWKAgentWalletV1(factory) {}

    /// @dev Accepts a direct owner call, or a call relayed by the canonical EntryPoint on behalf
    ///      of a UserOperation. Authorization for the EntryPoint-relayed case is enforced in
    ///      `_validateSignature`, which only accepts an operator signature for the adapter-
    ///      execution selectors — every other selector requires the owner's own signature.
    modifier onlyOwnerOrEntryPoint() virtual {
        if (msg.sender != owner() && msg.sender != address(entryPoint())) {
            revert AWKErrors.Unauthorized(msg.sender);
        }
        _;
    }

    function _validateSignature(UserOperation calldata userOp, bytes32 userOpHash) internal virtual override returns (uint256 validationData) {
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        address signer = hash.recover(userOp.signature);
        if (signer == owner()) {
            return 0;
        }
        // Operators may only authorize adapter execution. Every other selector requires the
        // owner's own signature.
        bytes4 selector = userOp.callData.length >= 4 ? bytes4(userOp.callData[:4]) : bytes4(0);
        bool isAdapterCall = selector == this.executeViaAdapter.selector || selector == this.executeViaAdapterBatch.selector;
        if (isAgentOperator(signer) && isAdapterCall) {
            return 0;
        }
        return SIG_VALIDATION_FAILED;
    }

    /**
     * @notice User withdraws any ERC20 asset from agent wallet
     * @param recipient Address to send the asset to
     * @param asset Address of the ERC20 token to withdraw
     * @param amount Amount to withdraw
     */
    function withdrawAssetToUser(address recipient, address asset, uint256 amount) external virtual override onlyOwnerOrEntryPoint {
        _withdrawAsset(recipient, asset, amount);
    }

    /**
     * @notice User withdraws all of a specific ERC20 asset from agent wallet
     * @param recipient Address to send the asset to
     * @param asset Address of the ERC20 token to withdraw
     */
    function withdrawAllAssetToUser(address recipient, address asset) external virtual override onlyOwnerOrEntryPoint {
        IERC20 token = IERC20(asset);
        uint256 balance = token.balanceOf(address(this));
        _withdrawAsset(recipient, asset, balance);
    }
}
