// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {AWKAdapterTarget} from "../../src/agentwalletkit/AWKAdapterTarget.sol";
import {AWKSelfManagedAgentWalletV3} from "../../src/agentwalletkit/AWKSelfManagedAgentWalletV3.sol";

contract MockV3SelfManagedWallet is AWKSelfManagedAgentWalletV3 {}

contract MockV3SelfManagedWalletV2 is MockV3SelfManagedWallet {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract MockV3EchoAdapter {
    fallback(bytes calldata data) external payable returns (bytes memory) {
        return abi.encode(AWKAdapterTarget.get(), data);
    }
}

