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

import {YieldSeekerAgentWalletV3} from "./AgentWalletV3.sol";
import {AWKErrors} from "./agentwalletkit/AWKErrors.sol";

error SameWallet();

/**
 * @title YieldSeekerWalletLinkRegistry
 * @notice Records which pairs of agent wallets their owner allows to move funds between each other
 * @dev Only the owner of both wallets can link or unlink them. The registry does not check how the wallets
 *      were deployed; transfer adapters must verify that themselves.
 */
contract YieldSeekerWalletLinkRegistry {
    mapping(bytes32 pairKey => bool linked) internal _links;

    event WalletLinkSet(address indexed owner, address indexed walletA, address indexed walletB, bool linked);

    function isLinked(address walletA, address walletB) external view returns (bool) {
        return _links[_pairKey(walletA, walletB)];
    }

    function setLinked(address walletA, address walletB, bool linked) external {
        if (walletA == walletB) revert SameWallet();
        if (YieldSeekerAgentWalletV3(payable(walletA)).owner() != msg.sender || YieldSeekerAgentWalletV3(payable(walletB)).owner() != msg.sender) revert AWKErrors.Unauthorized(msg.sender);
        _links[_pairKey(walletA, walletB)] = linked;
        emit WalletLinkSet(msg.sender, walletA, walletB, linked);
    }

    function _pairKey(address walletA, address walletB) internal pure returns (bytes32) {
        return walletA < walletB ? keccak256(abi.encode(walletA, walletB)) : keccak256(abi.encode(walletB, walletA));
    }
}
