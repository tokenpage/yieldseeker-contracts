// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AWKAdapter} from "../../src/agentwalletkit/AWKAdapter.sol";
import {AWKSelfManagedAgentWalletV3} from "../../src/agentwalletkit/AWKSelfManagedAgentWalletV3.sol";

contract MockV3SelfManagedWallet is AWKSelfManagedAgentWalletV3 {}

contract MockV3SelfManagedWalletV2 is MockV3SelfManagedWallet {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract MockV3EchoAdapter is AWKAdapter {
    function execute(address target, bytes calldata data) external payable override onlyDelegateCall returns (bytes memory) {
        return abi.encode(target, data);
    }
}

