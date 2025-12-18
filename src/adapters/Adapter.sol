// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAgentWallet} from "../IAgentWallet.sol";

abstract contract YieldSeekerAdapter {
    error InvalidAsset();
    error InvalidRoute();

    function _baseAsset() internal view returns (IERC20) {
        return IAgentWallet(address(this)).baseAsset();
    }

    function _baseAssetAddress() internal view returns (address) {
        return address(_baseAsset());
    }

    function _requireBaseAsset(address asset) internal view {
        if (asset != _baseAssetAddress()) revert InvalidAsset();
    }
}
