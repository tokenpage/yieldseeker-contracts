// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import "../interfaces/IPolicyValidator.sol";

interface IAaveV3Pool {
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);
}

interface IAToken {
    function UNDERLYING_ASSET_ADDRESS() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
}

interface IAgentWallet {
    function baseAsset() external view returns (address);
}

/**
 * @title AaveV3VaultWrapper
 * @notice Combined wrapper + validator for Aave V3 pools
 * @dev This contract:
 *      1. Acts as a VALIDATOR for the AgentActionPolicy (implements IPolicyValidator)
 *      2. Acts as a WRAPPER that wallets call to interact with Aave V3
 *
 *      Aave V3 has a single Pool contract that manages multiple assets.
 *      Each asset has its own aToken for tracking positions.
 *
 *      Security guarantees:
 *      - Only the allowed pool can be interacted with
 *      - Only allowed assets can be deposited/withdrawn
 *      - Asset must match wallet's baseAsset
 *      - All aTokens are minted directly to the calling wallet
 *      - Wallet must pre-approve this wrapper for token transfers
 *
 *      Flow:
 *      1. Router calls Policy.validateAction() → Policy calls this.validateAction()
 *      2. If valid, Router triggers wallet.executeFromExecutor() → wallet CALLs this.deposit()
 *      3. This contract pulls tokens from wallet, supplies to Aave, aTokens go to wallet
 */
contract AaveV3VaultWrapper is IPolicyValidator, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant VAULT_ADMIN_ROLE = keccak256("VAULT_ADMIN_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    address public immutable pool;
    mapping(address => address) public assetToAToken;
    mapping(address => bool) public allowedAssets;

    event AssetAdded(address indexed asset, address indexed aToken);
    event AssetRemoved(address indexed asset);
    event Deposited(address indexed wallet, address indexed asset, uint256 amount);
    event Withdrawn(address indexed wallet, address indexed asset, uint256 amount);

    error PoolMismatch(address expected, address actual);
    error AssetNotAllowed(address asset);
    error AssetMismatch(address expected, address actual);
    error InvalidSelector(bytes4 selector);
    error ZeroAmount();

    bytes4 public constant DEPOSIT_SELECTOR = bytes4(keccak256("deposit(address,uint256)"));
    bytes4 public constant WITHDRAW_SELECTOR = bytes4(keccak256("withdraw(address,uint256)"));

    constructor(address _pool, address _admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(VAULT_ADMIN_ROLE, _admin);
        _grantRole(EMERGENCY_ROLE, _admin);
        pool = _pool;
    }

    // ============ Admin (Timelocked) ============

    /**
     * @notice Add an asset to the whitelist (should go through timelock)
     */
    function addAsset(address asset, address aToken) external onlyRole(VAULT_ADMIN_ROLE) {
        assetToAToken[asset] = aToken;
        allowedAssets[asset] = true;
        emit AssetAdded(asset, aToken);
    }

    // ============ Emergency (Instant) ============

    /**
     * @notice Remove an asset from whitelist immediately (for emergencies)
     * @dev This bypasses timelock for fast response to compromised assets
     */
    function removeAsset(address asset) external onlyRole(EMERGENCY_ROLE) {
        allowedAssets[asset] = false;
        emit AssetRemoved(asset);
    }

    // ============ IPolicyValidator ============

    function validateAction(
        address wallet,
        address, // target (this contract)
        bytes4 selector,
        bytes calldata data
    )
        external
        view
        override
        returns (bool)
    {
        if (selector != DEPOSIT_SELECTOR && selector != WITHDRAW_SELECTOR) {
            revert InvalidSelector(selector);
        }
        if (data.length < 4 + 64) return false;
        (address asset, uint256 amount) = abi.decode(data[4:], (address, uint256));
        if (amount == 0) return false;
        if (!allowedAssets[asset]) return false;
        if (selector == DEPOSIT_SELECTOR) {
            address walletBaseAsset = IAgentWallet(wallet).baseAsset();
            if (asset != walletBaseAsset) return false;
        }
        return true;
    }

    // ============ Vault Operations ============

    /**
     * @notice Deposit assets into Aave V3
     * @param asset Address of the asset to deposit
     * @param amount Amount of assets to deposit
     * @dev Caller (wallet) must have approved this contract for the asset
     *      aTokens are minted directly to the calling wallet (msg.sender)
     */
    function deposit(address asset, uint256 amount) external {
        if (!allowedAssets[asset]) revert AssetNotAllowed(asset);
        if (amount == 0) revert ZeroAmount();
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20(asset).forceApprove(pool, amount);
        IAaveV3Pool(pool).supply(asset, amount, msg.sender, 0);
        emit Deposited(msg.sender, asset, amount);
    }

    /**
     * @notice Withdraw assets from Aave V3
     * @param asset Address of the asset to withdraw
     * @param amount Amount of assets to withdraw (use type(uint256).max for full balance)
     * @return actualAmount Amount of assets actually withdrawn
     * @dev Caller (wallet) must have approved this contract for the aToken
     *      Assets are sent directly to the calling wallet (msg.sender)
     */
    function withdraw(address asset, uint256 amount) external returns (uint256 actualAmount) {
        if (!allowedAssets[asset]) revert AssetNotAllowed(asset);
        if (amount == 0) revert ZeroAmount();
        address aToken = assetToAToken[asset];
        uint256 aTokenAmount = amount == type(uint256).max ? IAToken(aToken).balanceOf(msg.sender) : amount;
        IERC20(aToken).safeTransferFrom(msg.sender, address(this), aTokenAmount);
        actualAmount = IAaveV3Pool(pool).withdraw(asset, amount, msg.sender);
        emit Withdrawn(msg.sender, asset, actualAmount);
    }

    // ============ View Functions ============

    function getAToken(address asset) external view returns (address) {
        return assetToAToken[asset];
    }

    function getShareBalance(address asset, address wallet) external view returns (uint256) {
        address aToken = assetToAToken[asset];
        return IAToken(aToken).balanceOf(wallet);
    }
}
