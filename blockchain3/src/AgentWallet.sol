// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {MultiEntryPointAccountERC7579, IEntryPointV06} from "./lib/MultiEntryPointAccountERC7579.sol";
import {AgentWalletStorageV1} from "./lib/AgentWalletStorage.sol";
import {PackedUserOperation} from "@openzeppelin/contracts/interfaces/draft-IERC4337.sol";
import {MODULE_TYPE_EXECUTOR} from "@openzeppelin/contracts/interfaces/draft-IERC7579.sol";
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
 * @notice ERC-7579 Smart Wallet with UUPS Upgradability and Multi-EntryPoint Support
 * @dev Combines OpenZeppelin's ERC7579 implementation with UUPS for full upgradability.
 *      Uses ERC-7201 namespaced storage for safe upgrades.
 *      This is the "Shell" that users deploy.
 *
 *      Supported ERC-7579 features:
 *      - Single execution (CALLTYPE_SINGLE)
 *      - Batch execution (CALLTYPE_BATCH)
 *      - Delegate call execution (CALLTYPE_DELEGATECALL)
 *      - Default/Try execution modes
 *      - Executor modules
 *
 *      Supported ERC-4337 EntryPoints:
 *      - v0.6 (Coinbase Paymaster compatibility)
 *      - v0.7
 *      - v0.8
 */
contract YieldSeekerAgentWallet is MultiEntryPointAccountERC7579, Initializable, UUPSUpgradeable, OwnableUpgradeable {
    using SafeERC20 for IERC20;

    event WithdrewTokenToUser(address indexed owner, address indexed recipient, address indexed token, uint256 amount);
    event WithdrewEthToUser(address indexed owner, address indexed recipient, uint256 amount);

    error InvalidAddress();
    error InsufficientBalance();
    error TransferFailed();
    error CannotUninstallDefaultModule();

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
        AgentWalletStorageV1.Layout storage $ = AgentWalletStorageV1.layout();
        $.userAgentIndex = _userAgentIndex;
        $.baseAsset = _baseAsset;
        $.executorModule = _executorModule;
        if (_executorModule != address(0)) {
            _installExecutorDirect(_executorModule);
        }
    }

    /**
     * @notice Internal function to install executor without calling onInstall
     * @dev Used during initialization to avoid external calls
     */
    function _installExecutorDirect(address module) internal {
        _installModule(MODULE_TYPE_EXECUTOR, module, "");
    }

    /**
     * @notice Get the user address (alias for owner)
     */
    function user() public view returns (address) {
        return owner();
    }

    /**
     * @notice Get the user agent index
     */
    function userAgentIndex() public view returns (uint256) {
        return AgentWalletStorageV1.layout().userAgentIndex;
    }

    /**
     * @notice Get the base asset
     */
    function baseAsset() public view returns (address) {
        return AgentWalletStorageV1.layout().baseAsset;
    }

    /**
     * @notice Get the executor module
     */
    function executorModule() public view returns (address) {
        return AgentWalletStorageV1.layout().executorModule;
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

    // ============ ERC7579 ACCESS CONTROL OVERRIDES ============

    function installModule(uint256 moduleTypeId, address module, bytes calldata initData) public override onlyOwner {
        super.installModule(moduleTypeId, module, initData);
    }

    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) public override onlyOwner {
        if (module == AgentWalletStorageV1.layout().executorModule) revert CannotUninstallDefaultModule();
        super.uninstallModule(moduleTypeId, module, deInitData);
    }

    // ============ ERC-4337 VALIDATION ============

    /**
     * @notice Override v0.6 validation to use operator-based auth
     */
    function _validateUserOpV06(IEntryPointV06.UserOperation calldata userOp, bytes32 userOpHash, uint256 missingAccountFunds) internal virtual override returns (uint256) {
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(userOpHash);
        address signer = ECDSA.recover(ethSignedHash, userOp.signature);
        bool isValidSigner = _isAuthorizedOperator(signer);
        _payPrefundV06(missingAccountFunds);
        return isValidSigner ? 0 : 1;
    }

    /**
     * @notice Override v0.7/v0.8 raw signature validation
     * @dev The parent AccountERC7579 calls this during _validateUserOp.
     *      We use eth_sign prefix for consistency with wallets/signers.
     */
    function _rawSignatureValidation(bytes32 hash, bytes calldata signature) internal view virtual override returns (bool) {
        bytes32 ethSignedHash = MessageHashUtils.toEthSignedMessageHash(hash);
        address signer = ECDSA.recover(ethSignedHash, signature);
        return _isAuthorizedOperator(signer);
    }

    /**
     * @notice Check if an address is an authorized operator via the installed Router
     * @dev Queries the Router's operators mapping
     */
    function _isAuthorizedOperator(address signer) internal view returns (bool) {
        address module = AgentWalletStorageV1.layout().executorModule;
        if (module == address(0)) return false;
        try IAgentActionRouter(module).operators(signer) returns (bool isOperator) {
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
        emit WithdrewTokenToUser(owner(), recipient, address(asset), amount);
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
}
