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

import {AWKErrors} from "../agentwalletkit/AWKErrors.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

error SellTokenNotAllowed(address token);

interface IYieldSeekerSwapSellPolicy {
    function isSellableToken(address token) external view returns (bool);
    function validateSellableToken(address token) external view;
}

contract YieldSeekerSwapSellPolicy is AccessControl, IYieldSeekerSwapSellPolicy {
    using EnumerableSet for EnumerableSet.AddressSet;

    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    bool public allowSellingAllTokens;
    EnumerableSet.AddressSet private sellableTokens;

    event SellableTokenAdded(address indexed token);
    event SellableTokenRemoved(address indexed token);
    event AllowSellingAllTokensSet(bool enabled);

    constructor(address admin, address emergencyAdmin, bool initialAllowSellingAllTokens) {
        if (admin == address(0)) revert AWKErrors.ZeroAddress();
        if (emergencyAdmin == address(0)) revert AWKErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, emergencyAdmin);
        allowSellingAllTokens = initialAllowSellingAllTokens;
    }

    function setAllowSellingAllTokens(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allowSellingAllTokens = enabled;
        emit AllowSellingAllTokensSet(enabled);
    }

    function addSellableToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert AWKErrors.ZeroAddress();
        if (sellableTokens.add(token)) {
            emit SellableTokenAdded(token);
        }
    }

    function addSellableTokens(address[] calldata tokens) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(0)) revert AWKErrors.ZeroAddress();
            if (sellableTokens.add(tokens[i])) {
                emit SellableTokenAdded(tokens[i]);
            }
        }
    }

    function removeSellableToken(address token) external onlyRole(EMERGENCY_ROLE) {
        if (sellableTokens.remove(token)) {
            emit SellableTokenRemoved(token);
        }
    }

    function isSellableToken(address token) external view returns (bool) {
        return allowSellingAllTokens || sellableTokens.contains(token);
    }

    function validateSellableToken(address token) external view {
        if (!allowSellingAllTokens && !sellableTokens.contains(token)) revert SellTokenNotAllowed(token);
    }

    function getSellableTokens() external view returns (address[] memory) {
        return sellableTokens.values();
    }
}
