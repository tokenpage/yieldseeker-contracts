// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/IPolicyValidator.sol";

interface IAgentWallet {
    function baseAsset() external view returns (address);
}

/**
 * @title ZeroExValidator
 * @notice Example validator for 0x Swaps.
 * @dev Enforces that the swap output token is the wallet's base asset.
 *      (e.g., "Only allow swaps that result in USDC")
 */
contract ZeroExValidator is IPolicyValidator {

    // transformERC20(address,address,uint256,uint256,(uint32,bytes)[])
    bytes4 public constant TRANSFORM_ERC20_SELECTOR = 0x415565b0;

    function validateAction(
        address wallet,
        address target,
        bytes4 selector,
        bytes calldata data
    ) external view override returns (bool) {
        if (selector != TRANSFORM_ERC20_SELECTOR) return false;

        // Decode arguments
        // transformERC20(address inputToken, address outputToken, ...)
        ( , address outputToken, , , ) = abi.decode(data[4:], (address, address, uint256, uint256, bytes[]));

        // Get the wallet's base asset
        address baseAsset = IAgentWallet(wallet).baseAsset();

        // Enforce: Output token MUST be the base asset
        if (outputToken != baseAsset) {
            return false;
        }

        return true;
    }
}
