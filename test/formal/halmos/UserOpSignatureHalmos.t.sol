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

    function validateRecoveredSigner(address signer, bytes calldata callData, bytes calldata paymasterAndData) external view returns (uint256) {
        if (signer != address(0) && signer == owner()) return 0;

        bytes4 selector = callData.length >= 4 ? bytes4(callData[:4]) : bytes4(0);
        if (selector == this.executeViaAdapter.selector || selector == this.executeViaAdapterBatch.selector) {
            bool sponsored = paymasterAndData.length >= 20 && address(bytes20(paymasterAndData[:20])) != address(0);
            return signer != address(0) && sponsored && isAgentOperator(signer) ? 0 : 1;
        }
        return 1;
    }
}

contract UserOpSignatureHalmos {
    uint256 private constant SIG_VALIDATION_FAILED = 1;
    bytes32 private constant USER_OP_HASH = keccak256("YieldSeeker Halmos user operation");

    address private constant OWNER = address(0xA11CE);
    address private constant OPERATOR = address(0xB0B);
    address private constant ATTACKER = address(0xCAFE);

    UserOpSignatureProofHarness private wallet;
    UserOpSignatureProofHarness private erc1271Wallet;

    function setUp() public {
        wallet = new UserOpSignatureProofHarness(OWNER, OPERATOR);
        erc1271Wallet = new UserOpSignatureProofHarness(address(new HalmosAlwaysApprove1271()), OPERATOR);
    }

    function check_property6_ownerSignatureAlwaysValidates(bytes4 selector, address paymaster) external view {
        assert(wallet.validateRecoveredSigner(OWNER, abi.encodePacked(selector), abi.encodePacked(paymaster)) == 0);
    }

    function check_property6_operatorValidatesOnlySponsoredAdapterCalls(bytes4 selector, address paymaster) external view {
        bool adapterCall = _isAdapterCall(selector);
        uint256 expected = adapterCall && paymaster != address(0) ? 0 : SIG_VALIDATION_FAILED;

        assert(wallet.validateRecoveredSigner(OPERATOR, abi.encodePacked(selector), abi.encodePacked(paymaster)) == expected);
    }

    function check_property6_operatorSignaturesRejectShortCallDataAndPaymaster(bytes3 shortCallData, bytes19 shortPaymaster) external view {
        bytes memory validPaymaster = abi.encodePacked(address(1));
        bytes memory validAdapterCall = abi.encodePacked(wallet.executeViaAdapter.selector);

        assert(wallet.validateRecoveredSigner(OPERATOR, abi.encodePacked(shortCallData), validPaymaster) == SIG_VALIDATION_FAILED);
        assert(wallet.validateRecoveredSigner(OPERATOR, validAdapterCall, abi.encodePacked(shortPaymaster)) == SIG_VALIDATION_FAILED);
    }

    function check_property6_otherSignersCannotValidate(address signer, bytes4 selector, address paymaster) external view {
        if (signer != OWNER && signer != OPERATOR) {
            assert(wallet.validateRecoveredSigner(signer, abi.encodePacked(selector), abi.encodePacked(paymaster)) == SIG_VALIDATION_FAILED);
        }
    }

    function check_property6_symbolicSignerOutcomeMatchesPolicy(address signer, bytes4 selector, address paymaster) external view {
        uint256 expected;
        if (signer == OWNER) {
            expected = 0;
        } else if (_isAdapterCall(selector) && paymaster != address(0) && signer == OPERATOR) {
            expected = 0;
        } else {
            expected = SIG_VALIDATION_FAILED;
        }

        assert(wallet.validateRecoveredSigner(signer, abi.encodePacked(selector), abi.encodePacked(paymaster)) == expected);
    }

    function check_property6_erc1271OwnerCanApproveShortNonAdapterOperation(bytes3 callDataPrefix, bytes19 paymasterPrefix) external view {
        assert(erc1271Wallet.validateSignature(hex"", abi.encodePacked(callDataPrefix), abi.encodePacked(paymasterPrefix), USER_OP_HASH) == 0);
    }

    function _isAdapterCall(bytes4 selector) private view returns (bool) {
        return selector == wallet.executeViaAdapter.selector || selector == wallet.executeViaAdapterBatch.selector;
    }
}
