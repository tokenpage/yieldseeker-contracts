// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AWKSelfManagedAgentWalletV3} from "../../src/agentwalletkit/AWKSelfManagedAgentWalletV3.sol";
import {IAWKAdapter} from "../../src/agentwalletkit/IAWKAdapter.sol";

contract MockV3SelfManagedWallet is AWKSelfManagedAgentWalletV3 {}

contract MockV3SelfManagedWalletV2 is MockV3SelfManagedWallet {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract MockV3EchoAdapter is IAWKAdapter {
    function execute(address target, bytes calldata data) external payable override returns (bytes memory) {
        return abi.encode(target, data);
    }
}

