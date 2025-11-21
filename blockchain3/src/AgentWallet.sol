// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC7579Account} from "./lib/ERC7579Account.sol";
import {Initializable} from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts/proxy/utils/UUPSUpgradeable.sol";
import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

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

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /**
     * @notice Initialize the wallet
     * @param _user The user address associated with this agent (owner)
     * @param _userAgentIndex The index of this agent for the user
     * @param _baseAsset The base asset token address
     */
    function initialize(address _user, uint256 _userAgentIndex, address _baseAsset) external initializer {
        // Initialize UUPS and Ownable
        __Ownable_init(_user);

        userAgentIndex = _userAgentIndex;
        baseAsset = _baseAsset;

        // Initialize ERC7579 (if needed by base implementation, usually it's stateless or init-less)
        // __ERC7579Account_init();
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

    function installModule(uint256 moduleTypeId, address module, bytes calldata initData) public payable override onlyOwner {
        super.installModule(moduleTypeId, module, initData);
    }

    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) public payable override onlyOwner {
        super.uninstallModule(moduleTypeId, module, deInitData);
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
