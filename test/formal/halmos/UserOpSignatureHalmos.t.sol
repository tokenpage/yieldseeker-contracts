// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAgentWalletV3} from "../../../src/AgentWalletV3.sol";

contract HalmosAlwaysApprove1271 {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0x1626ba7e;
    }
}

contract UserOpSignatureProofHarness is YieldSeekerAgentWalletV3 {
    address private immutable _proofOwner;
    address private immutable _proofOperator;

    constructor(address owner_, address operator_) YieldSeekerAgentWalletV3(address(0)) {
        _proofOwner = owner_;
        _proofOperator = operator_;
    }

    function owner() public view override returns (address) {
        return _proofOwner;
    }

    function isAgentOperator(address operator) public view override returns (bool) {
        return operator == _proofOperator;
    }

    function validateSignature(bytes calldata signature, bytes calldata callData, bytes calldata paymasterAndData, bytes32 userOpHash) external view returns (uint256) {
        return _validateUserOpSignature(signature, callData, paymasterAndData, userOpHash);
    }
}

contract UserOpSignatureHalmos {
    bytes32 private constant USER_OP_HASH = keccak256("YieldSeeker Halmos user operation");

    UserOpSignatureProofHarness private erc1271Wallet;

    function setUp() public {
        erc1271Wallet = new UserOpSignatureProofHarness(address(new HalmosAlwaysApprove1271()), address(0));
    }

    function check_property6_erc1271OwnerCanApproveShortNonAdapterOperation(bytes3 callDataPrefix, bytes19 paymasterPrefix) external view {
        assert(erc1271Wallet.validateSignature(hex"", abi.encodePacked(callDataPrefix), abi.encodePacked(paymasterPrefix), USER_OP_HASH) == 0);
    }
}
