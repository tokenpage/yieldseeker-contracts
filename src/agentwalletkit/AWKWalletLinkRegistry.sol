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

import {AWKAgentWalletV2} from "./AWKAgentWalletV2.sol";
import {AWKErrors} from "./AWKErrors.sol";

error SameWallet();

/**
 * @title AWKWalletLinkRegistry
 * @notice Records which pairs of agent wallets their owner allows to move funds between each other
 * @dev Only the owner of both wallets can link or unlink them. The registry does not check how the wallets
 *      were deployed; transfer adapters must verify that themselves.
 */
contract AWKWalletLinkRegistry {
    mapping(bytes32 pairKey => bool linked) internal _links;

    event WalletLinkSet(address indexed owner, address indexed walletA, address indexed walletB, bool linked);

    function isLinked(address walletA, address walletB) external view returns (bool) {
        return _links[_pairKey(walletA, walletB)];
    }

    function setLinked(address walletA, address walletB, bool linked) external {
        if (walletA == walletB) revert SameWallet();
        if (AWKAgentWalletV2(payable(walletA)).owner() != msg.sender || AWKAgentWalletV2(payable(walletB)).owner() != msg.sender) revert AWKErrors.Unauthorized(msg.sender);
        _links[_pairKey(walletA, walletB)] = linked;
        emit WalletLinkSet(msg.sender, walletA, walletB, linked);
    }

    function _pairKey(address walletA, address walletB) internal pure returns (bytes32) {
        return walletA < walletB ? keccak256(abi.encode(walletA, walletB)) : keccak256(abi.encode(walletB, walletA));
    }
}
