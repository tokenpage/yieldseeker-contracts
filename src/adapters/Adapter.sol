// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAgentWallet} from "../IAgentWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title YieldSeekerAdapter
 * @notice Base class for all adapters in the YieldSeeker system.
 *
 * SECURITY REQUIREMENT:
 * All external functions in inheriting adapters MUST take the `target` address
 * (the contract being called, e.g., a vault or swap router) as their FIRST argument.
 *
 * This is because AgentWallet "peeks" at the first 32 bytes of calldata to verify
 * that the target is registered for the specific adapter being used.
 */
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
