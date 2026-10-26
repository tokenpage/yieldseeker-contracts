// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAgentWalletV3} from "../../src/AgentWalletV3.sol";
import {AWKAdapter} from "../../src/agentwalletkit/AWKAdapter.sol";
import {AWKAgentWalletV3} from "../../src/agentwalletkit/AWKAgentWalletV3.sol";
import {IAWKAgentWalletFactory} from "../../src/agentwalletkit/IAWKAgentWalletFactory.sol";
import {YieldSeekerBorrowFeeModule} from "../../src/fees/BorrowFeeModule.sol";

contract MockV3SelfManagedWallet is AWKAgentWalletV3 {
    constructor(address factory) AWKAgentWalletV3(factory) {}
}

contract MockV3SelfManagedWalletV2 is MockV3SelfManagedWallet {
    constructor(address factory) MockV3SelfManagedWallet(factory) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract MockV3YieldSeekerWalletV1 is YieldSeekerAgentWalletV3 {
    constructor(address factory) YieldSeekerAgentWalletV3(factory) {}

    function version() external pure returns (uint256) {
        return 1;
    }
}

contract MockV3YieldSeekerWalletV2 is YieldSeekerAgentWalletV3 {
    constructor(address factory) YieldSeekerAgentWalletV3(factory) {}

    function version() external pure returns (uint256) {
        return 2;
    }
}

contract MockV3EchoAdapter is AWKAdapter {
    function execute(address target, bytes calldata data) external payable override onlyDelegateCall returns (bytes memory) {
        return abi.encode(target, data);
    }
}

contract MockV3BorrowReporter is AWKAdapter {
    YieldSeekerBorrowFeeModule private immutable _feeModule;

    constructor(YieldSeekerBorrowFeeModule feeModule) {
        _feeModule = feeModule;
    }

    function execute(address, bytes calldata data) external payable override onlyDelegateCall returns (bytes memory) {
        (bytes32 market, address token, uint256 amount, uint256 debtBefore) = abi.decode(data, (bytes32, address, uint256, uint256));
        _feeModule.recordBorrow(market, token, amount, debtBefore);
        return abi.encode(amount);
    }
}

contract MockV3WalletFactory is IAWKAgentWalletFactory {
    address private _registry;
    address private _implementation;
    address[] private _operators;

    function setConfiguration(address registry_, address implementation_, address[] calldata operators_) external {
        _registry = registry_;
        _implementation = implementation_;
        _operators = operators_;
    }

    function agentWalletImplementation() external view override returns (address) {
        return _implementation;
    }

    function adapterRegistry(bytes32) external view override returns (address) {
        return _registry;
    }

    function listAgentOperators() external view override returns (address[] memory) {
        return _operators;
    }
}

contract MockV3FakeWallet {
    address private immutable _owner;
    uint256 private immutable _ownerAgentIndex;

    constructor(address owner_, uint256 ownerAgentIndex_) {
        _owner = owner_;
        _ownerAgentIndex = ownerAgentIndex_;
    }

    function owner() external view returns (address) {
        return _owner;
    }

    function ownerAgentIndex() external view returns (uint256) {
        return _ownerAgentIndex;
    }
}
