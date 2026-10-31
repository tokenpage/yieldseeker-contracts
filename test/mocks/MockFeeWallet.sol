// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFeeWallet {
    address public immutable owner;
    IERC20 public immutable baseAsset;

    constructor(address owner_, IERC20 baseAsset_) {
        owner = owner_;
        baseAsset = baseAsset_;
    }

    function execute(address target, bytes calldata callData) external returns (bytes memory returnData) {
        (bool success, bytes memory result) = target.call(callData);
        if (!success) {
            assembly {
                revert(add(result, 0x20), mload(result))
            }
        }
        return result;
    }
}
