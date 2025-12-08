// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AccountERC7579} from "@openzeppelin/contracts/account/extensions/draft-AccountERC7579.sol";
import {PackedUserOperation, IAccount, IEntryPoint} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {ERC4337Utils} from "@openzeppelin/contracts/account/utils/draft-ERC4337Utils.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

// ERC-4337 v0.6 EntryPoint interface (uses unpacked UserOperation)
interface IEntryPointV06 {
    struct UserOperation {
        address sender;
        uint256 nonce;
        bytes initCode;
        bytes callData;
        uint256 callGasLimit;
        uint256 verificationGasLimit;
        uint256 preVerificationGas;
        uint256 maxFeePerGas;
        uint256 maxPriorityFeePerGas;
        bytes paymasterAndData;
        bytes signature;
    }
    function getNonce(address sender, uint192 key) external view returns (uint256);
}

// ERC-4337 v0.6 Account interface
interface IAccountV06 {
    function validateUserOp(IEntryPointV06.UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) external returns (uint256 validationData);
}

/**
 * @title MultiEntryPointAccountERC7579
 * @notice Extends OpenZeppelin's AccountERC7579 with support for multiple EntryPoint versions
 * @dev Supports EntryPoint v0.6, v0.7, and v0.8 for maximum compatibility with existing infrastructure
 *      - v0.6: Used by Coinbase Paymaster and other legacy infrastructure
 *      - v0.7: Previous standard version
 *      - v0.8: Current standard version (default in OZ)
 *
 *      Inherits full ERC-7579 functionality from AccountERC7579:
 *      - Batch execution (CALLTYPE_BATCH)
 *      - Single execution (CALLTYPE_SINGLE)
 *      - Delegate call execution (CALLTYPE_DELEGATECALL)
 *      - Try/Default execution modes
 *      - Validator modules
 *      - Executor modules
 *      - Fallback handlers
 */
abstract contract MultiEntryPointAccountERC7579 is AccountERC7579, IAccountV06 {
    // Canonical EntryPoint addresses
    address public constant ENTRY_POINT_V06 = 0x5FF137D4b0FDCD49DcA30c7CF57E578a026d2789;
    address public constant ENTRY_POINT_V07 = 0x0000000071727De22E5E9d8BAf0edAc6f37da032;
    address public constant ENTRY_POINT_V08 = 0x4337084D9E255Ff0702461CF8895CE9E3b5Ff108;

    error MultiEntryPoint__NotAuthorized(address sender);

    /**
     * @notice Override entryPoint() to return v0.8 by default
     * @dev Required by OZ's Account base class. The actual entry point used depends on which
     *      validateUserOp function is called.
     */
    function entryPoint() public view virtual override returns (IEntryPoint) {
        return ERC4337Utils.ENTRYPOINT_V08;
    }

    /**
     * @notice Get nonce from the appropriate EntryPoint
     * @dev Overrides to support querying from v0.8
     */
    function getNonce() public view virtual override returns (uint256) {
        return getNonce(0);
    }

    /**
     * @notice Get nonce for a given sequence key
     */
    function getNonce(uint192 key) public view virtual override returns (uint256) {
        return entryPoint().getNonce(address(this), key);
    }

    // ============ ERC-4337 v0.7/v0.8 VALIDATION ============

    /**
     * @notice Validate UserOperation (v0.7/v0.8 Packed format)
     * @dev Called by EntryPoint v0.7 or v0.8. Both use PackedUserOperation.
     */
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) public virtual override returns (uint256) {
        if (!_isEntryPointV07OrV08(msg.sender)) {
            revert MultiEntryPoint__NotAuthorized(msg.sender);
        }
        uint256 validationData = _validateUserOp(userOp, userOpHash, userOp.signature);
        _payPrefund(missingAccountFunds);
        return validationData;
    }

    // ============ ERC-4337 v0.6 VALIDATION ============

    /**
     * @notice Validate UserOperation (v0.6 Unpacked format)
     * @dev Called by EntryPoint v0.6 during validation phase.
     *      This enables compatibility with Coinbase Paymaster and other v0.6 infrastructure.
     */
    function validateUserOp(IEntryPointV06.UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) external virtual override returns (uint256 validationData) {
        if (msg.sender != ENTRY_POINT_V06) {
            revert MultiEntryPoint__NotAuthorized(msg.sender);
        }
        return _validateUserOpV06(userOp, userOpHash, missingAccountFunds);
    }

    /**
     * @notice Internal v0.6 validation logic
     * @dev Override this to customize v0.6 signature validation
     */
    function _validateUserOpV06(IEntryPointV06.UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) internal virtual returns (uint256) {
        bytes32 signableHash = _signableUserOpHashV06(userOp, userOpHash);
        uint256 validationData = _rawSignatureValidation(signableHash, userOp.signature) ? ERC4337Utils.SIG_VALIDATION_SUCCESS : ERC4337Utils.SIG_VALIDATION_FAILED;
        _payPrefundV06(missingAccountFunds);
        return validationData;
    }

    /**
     * @notice Get the signable hash for v0.6 UserOperations
     * @dev v0.6 uses simple keccak256 hash, not EIP-712
     */
    function _signableUserOpHashV06(
        IEntryPointV06.UserOperation calldata,
        /*userOp*/
        bytes32 userOpHash
    )
        internal
        view
        virtual
        returns (bytes32)
    {
        return MessageHashUtils.toEthSignedMessageHash(userOpHash);
    }

    /**
     * @notice Pay prefund to v0.6 EntryPoint
     */
    function _payPrefundV06(uint256 missingAccountFunds) internal virtual {
        if (missingAccountFunds > 0) {
            (bool success,) = payable(ENTRY_POINT_V06).call{value: missingAccountFunds}("");
            require(success, "MultiEntryPoint: prefund failed");
        }
    }

    // ============ ACCESS CONTROL ============

    /**
     * @notice Override _checkEntryPointOrSelf to support all EntryPoint versions
     */
    function _checkEntryPointOrSelf() internal view virtual override {
        address sender = msg.sender;
        if (sender != address(this) && !_isEntryPoint(sender)) {
            revert AccountUnauthorized(sender);
        }
    }

    /**
     * @notice Override _checkEntryPoint to support all EntryPoint versions
     */
    function _checkEntryPoint() internal view virtual override {
        if (!_isEntryPoint(msg.sender)) {
            revert AccountUnauthorized(msg.sender);
        }
    }

    /**
     * @notice Check if an address is any supported EntryPoint
     */
    function _isEntryPoint(address caller) internal pure virtual returns (bool) {
        return caller == ENTRY_POINT_V06 || caller == ENTRY_POINT_V07 || caller == ENTRY_POINT_V08;
    }

    /**
     * @notice Check if an address is v0.7 or v0.8 EntryPoint
     */
    function _isEntryPointV07OrV08(address caller) internal pure virtual returns (bool) {
        return caller == ENTRY_POINT_V07 || caller == ENTRY_POINT_V08;
    }
}
