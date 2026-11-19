// SPDX-License-Identifier: MIT
//
//      _                    _ __        __    _ _      _   _  ___ _
//     / \   __ _  ___ _ __ | |\ \      / /_ _| | | ___| |_| |/ (_) |_
//    / _ \ / _` |/ _ \ '_ \| __\ \ /\ / / _` | | |/ _ \ __| ' /| | __|
//   / ___ \ (_| |  __/ | | | |_ \ V  V / (_| | | |  __/ |_| . \| | |_
//  /_/   \_\__, |\___|_| |_|\__| \_/\_/ \__,_|_|_|\___|\__|_|\_\_|\__|
//          |___/
//
//  Build verifiably secure onchain agents
//  https://agentwalletkit.com
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.38;

import {AWKAdapter, UnknownOperation} from "../AWKAdapter.sol";
import {AWKErrors} from "../AWKErrors.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

error InvalidPercentage(uint256 percentage);

/// @notice The calls a wallet can pass to a vault adapter's execute. The adapter decodes them; it doesn't implement them
interface IAWKVaultAdapter {
    /// @param amount The amount of the vault asset to deposit
    function deposit(uint256 amount) external returns (uint256 shares, uint256 assetsDeposited);
    /// @param percentageBps The share of the wallet's vault asset balance to deposit, in basis points (10000 = 100%)
    function depositPercentage(uint256 percentageBps) external returns (uint256 shares, uint256 assetsDeposited);
    /// @param shares The amount of vault shares to withdraw
    function withdraw(uint256 shares) external returns (uint256 assets);
}

/**
 * @title AWKBaseVaultAdapter
 * @notice Base class for vault adapters: deposit, deposit a percentage of the balance, and withdraw (IAWKVaultAdapter)
 * @dev execute validates the input and calls the operation (_depositOperation / _withdrawOperation), which an
 *      operations layer implements around the protocol implementation (_deposit / _withdraw): AWKVaultOperations for a
 *      plain kit adapter, or a wallet's own rules layer.
 */
abstract contract AWKBaseVaultAdapter is AWKAdapter {
    event Deposited(address indexed wallet, address indexed vault, uint256 assets, uint256 shares);
    event Withdrawn(address indexed wallet, address indexed vault, uint256 shares, uint256 assets);

    function execute(address target, bytes calldata data) external payable virtual override onlyDelegateCall returns (bytes memory) {
        bytes4 selector = bytes4(data[:4]);
        if (selector == IAWKVaultAdapter.withdraw.selector) {
            uint256 shares = abi.decode(data[4:], (uint256));
            if (shares == 0) revert AWKErrors.ZeroAmount();
            uint256 assets = _withdrawOperation(target, shares);
            emit Withdrawn(address(this), target, shares, assets);
            return abi.encode(assets);
        }
        uint256 amount;
        if (selector == IAWKVaultAdapter.deposit.selector) {
            amount = abi.decode(data[4:], (uint256));
        } else if (selector == IAWKVaultAdapter.depositPercentage.selector) {
            uint256 percentageBps = abi.decode(data[4:], (uint256));
            if (percentageBps == 0 || percentageBps > 1e4) revert InvalidPercentage(percentageBps);
            amount = (IERC20(_getVaultAsset(target)).balanceOf(address(this)) * percentageBps) / 1e4;
        } else {
            revert UnknownOperation();
        }
        if (amount == 0) revert AWKErrors.ZeroAmount();
        (uint256 sharesReceived, uint256 assetsDeposited) = _depositOperation(target, amount);
        emit Deposited(address(this), target, assetsDeposited, sharesReceived);
        return abi.encode(sharesReceived, assetsDeposited);
    }

    // ============ Operations (implemented by an operations layer) ============

    function _depositOperation(address vault, uint256 amount) internal virtual returns (uint256 shares, uint256 assetsDeposited);

    function _withdrawOperation(address vault, uint256 shares) internal virtual returns (uint256 assets);

    // ============ Protocol Implementation ============

    /// @dev The vault's underlying asset
    function _getVaultAsset(address vault) internal view virtual returns (address);

    /// @dev Deposits `amount` of the vault asset; returns the shares received and the assets actually taken
    function _deposit(address vault, uint256 amount) internal virtual returns (uint256 shares, uint256 assetsDeposited);

    /// @dev Withdraws `shares` (the asset amount for rebasing vaults); returns the vault asset received
    function _withdraw(address vault, uint256 shares) internal virtual returns (uint256 assets);
}

/// @notice The kit's default operations: the protocol call with no further rules
abstract contract AWKVaultOperations is AWKBaseVaultAdapter {
    function _depositOperation(address vault, uint256 amount) internal override returns (uint256 shares, uint256 assetsDeposited) {
        return _deposit(vault, amount);
    }

    function _withdrawOperation(address vault, uint256 shares) internal override returns (uint256 assets) {
        return _withdraw(vault, shares);
    }
}
