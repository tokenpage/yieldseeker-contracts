// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC7579Account, _MODULE_TYPE_EXECUTOR, IEntryPointV06} from "./lib/ERC7579Account.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

interface IAgentActionRouter {
    function operators(address) external view returns (bool);
}

/**
 * @title YieldSeekerAgentWallet
 * @notice ERC-7579 Smart Wallet with UUPS Upgradability
 * @dev Combines OpenZeppelin's ERC7579 implementation with UUPS for full upgradability.
 *      This is the "Shell" that users deploy.
 */
contract YieldSeekerAgentWallet is ERC7579Account, Initializable, UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    event WithdrewBaseAssetToUser(address indexed owner, address indexed recipient, uint256 amount);
    event WithdrewEthToUser(address indexed owner, address indexed recipient, uint256 amount);

    error InvalidAddress();
    error InsufficientBalance();
    error TransferFailed();

    uint256 public userAgentIndex;
    address public baseAsset;
    address public executorModule;  // Store reference to the Router for operator lookups

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the wallet
     * @param _user The user address associated with this agent (owner)
     * @param _userAgentIndex The index of this agent for the user
     * @param _baseAsset The base asset token address
     * @param _executorModule The executor module (Router) to install automatically
     */
    function initialize(address _user, uint256 _userAgentIndex, address _baseAsset, address _executorModule) external initializer {
        __Ownable_init(_user);
        userAgentIndex = _userAgentIndex;
        baseAsset = _baseAsset;
        executorModule = _executorModule;
        if (_executorModule != address(0)) {
            _modules[_MODULE_TYPE_EXECUTOR][_executorModule] = true;
            emit ModuleInstalled(_MODULE_TYPE_EXECUTOR, _executorModule);
        }
    }

    /**
     * @notice Get the user address (alias for owner)
     */
    function user() public view returns (address) {
        return owner();
    }

    /**
     * @notice Return the account ID
     */
    function accountId() public view virtual override returns (string memory) {
        return "yieldseeker.agent.wallet.v1";
    }

    /**
     * @notice Authorize upgrades
     * @dev Only the owner can upgrade the wallet implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    // ============ ERC7579 OVERRIDES ============

    function execute(bytes32 mode, bytes calldata executionCalldata) external payable override onlyEntryPointOrSelf {
        _execute(mode, executionCalldata);
    }

    function installModule(uint256 moduleTypeId, address module, bytes calldata initData) public override onlyOwner {
        super.installModule(moduleTypeId, module, initData);
    }

    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) public override onlyOwner {
        super.uninstallModule(moduleTypeId, module, deInitData);
    }

    // ============ ERC-4337 VALIDATION ============

    /**
     * @notice Validate a UserOperation signature (v0.7/v0.8 / Packed format)
     * @dev Called by EntryPoint v0.7 or v0.8 during validation phase
     *      Both versions use the same PackedUserOperation struct
     * @param userOp The PackedUserOperation to validate
     * @param userOpHash Hash of the UserOperation
     * @param missingAccountFunds Amount of ETH to pay to EntryPoint for gas
     * @return validationData 0 for success, 1 for signature failure
     */
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external override returns (uint256 validationData) {
        require(_isEntryPointV07OrV08(msg.sender), "Wallet: not from EntryPoint");
        return _validateUserOpCommon(userOp.signature, userOpHash, missingAccountFunds, msg.sender);
    }

    /**
     * @notice Validate a UserOperation signature (v0.6 / Unpacked format)
     * @dev Called by EntryPoint v0.6 during validation phase
     *      This enables compatibility with Coinbase Paymaster and other v0.6 infrastructure
     * @param userOp The UserOperation to validate (v0.6 unpacked format)
     * @param userOpHash Hash of the UserOperation
     * @param missingAccountFunds Amount of ETH to pay to EntryPoint for gas
     * @return validationData 0 for success, 1 for signature failure
     */
    function validateUserOp(
        IEntryPointV06.UserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    ) external override returns (uint256 validationData) {
        require(msg.sender == ENTRY_POINT_V06, "Wallet: not from EntryPoint");
        return _validateUserOpCommon(userOp.signature, userOpHash, missingAccountFunds, ENTRY_POINT_V06);
    }

    /**
     * @notice Common validation logic for both v0.6 and v0.8 UserOperations
     */
    function _validateUserOpCommon(
        bytes calldata signature,
        bytes32 userOpHash,
        uint256 missingAccountFunds,
        address entryPoint
    ) internal returns (uint256 validationData) {
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        address signer = ECDSA.recover(ethSignedHash, signature);
        bool isValidSigner = _isAuthorizedOperator(signer);
        if (missingAccountFunds > 0) {
            (bool success,) = payable(entryPoint).call{value: missingAccountFunds}("");
            require(success, "Wallet: failed to pay prefund");
        }
        return isValidSigner ? 0 : 1;
    }

    /**
     * @notice Check if an address is an authorized operator via the installed Router
     * @dev Queries the Router's operators mapping
     */
    function _isAuthorizedOperator(address signer) internal view returns (bool) {
        if (executorModule == address(0)) return false;
        try IAgentActionRouter(executorModule).operators(signer) returns (bool isOperator) {
            return isOperator;
        } catch {
            return false;
        }
    }

    // ============ USER WITHDRAWAL FUNCTIONS ============

    /**
     * @notice User withdraws ERC20 token from agent wallet
     * @param token Address of the token to withdraw
     * @param recipient Address to send the token to
     * @param amount Amount to withdraw
     */
    function withdrawTokenToUser(address token, address recipient, uint256 amount) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        IERC20 asset = IERC20(token);
        uint256 balance = asset.balanceOf(address(this));
        if (balance < amount) revert InsufficientBalance();
        _withdrawToken(asset, recipient, amount);
    }

    /**
     * @notice User withdraws all of an ERC20 token from agent wallet
     * @param token Address of the token to withdraw
     * @param recipient Address to send the token to
     */
    function withdrawAllTokenToUser(address token, address recipient) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        IERC20 asset = IERC20(token);
        uint256 balance = asset.balanceOf(address(this));
        _withdrawToken(asset, recipient, balance);
    }

    /**
     * @notice User withdraws ETH from agent wallet
     * @param recipient Address to send the ETH to
     * @param amount Amount of ETH to withdraw
     */
    function withdrawEthToUser(address recipient, uint256 amount) external onlyOwner {
        uint256 balance = address(this).balance;
        if (balance < amount) revert InsufficientBalance();
        _withdrawEth(recipient, amount);
    }

    /**
     * @notice User withdraws all ETH from agent wallet
     * @param recipient Address to send the ETH to
     */
    function withdrawAllEthToUser(address recipient) external onlyOwner {
        uint256 balance = address(this).balance;
        _withdrawEth(recipient, balance);
    }

    /**
     * @notice Internal function to withdraw ERC20 token
     * @param asset Token contract
     * @param recipient Address to send the token to
     * @param amount Amount to withdraw
     */
    function _withdrawToken(IERC20 asset, address recipient, uint256 amount) internal {
        if (recipient == address(0)) revert InvalidAddress();
        asset.safeTransfer(recipient, amount);
        emit WithdrewBaseAssetToUser(owner(), recipient, amount);
    }

    /**
     * @notice Internal function to withdraw ETH
     * @param recipient Address to send the ETH to
     * @param amount Amount of ETH to withdraw
     */
    function _withdrawEth(address recipient, uint256 amount) internal {
        if (recipient == address(0)) revert InvalidAddress();
        (bool success,) = recipient.call{value: amount}("");
        if (!success) revert TransferFailed();
        emit WithdrewEthToUser(owner(), recipient, amount);
    }

    // Allow receiving ETH
    receive() external payable {}
}
