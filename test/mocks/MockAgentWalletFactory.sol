// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerErrors} from "../../src/Errors.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @title MockAgentWalletFactory
/// @notice Simple mock for isolated AgentWalletFactory testing
contract MockAgentWalletFactory is AccessControl, Pausable {
    // Role constants
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    // State variables
    address public agentWalletImplementation;
    address public adapterRegistry;
    address public feeTracker;

    uint256 private _walletCounter;
    mapping(address => bool) private _walletExists;
    mapping(address => uint256) private _ownerWalletCount;
    mapping(address => address[]) private _ownerWallets;

    // Events
    event WalletCreated(
        address indexed owner,
        uint256 indexed agentIndex,
        address indexed wallet,
        address baseAsset,
        address implementation
    );
    event ImplementationUpdated(address indexed oldImplementation, address indexed newImplementation);
    event AdapterRegistryUpdated(address indexed oldRegistry, address indexed newRegistry);
    event FeeTrackerUpdated(address indexed oldTracker, address indexed newTracker);

    constructor(address _adapterRegistry, address _feeTracker, address _implementation) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        adapterRegistry = _adapterRegistry;
        feeTracker = _feeTracker;
        agentWalletImplementation = _implementation;
    }

    modifier onlyOperator() {
        require(hasRole(OPERATOR_ROLE, msg.sender) || hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Unauthorized");
        _;
    }

    /// @dev Compute deterministic wallet address using CREATE2
    function computeWalletAddress(address owner, uint256 agentIndex, address baseAsset)
        external
        view
        returns (address)
    {
        bytes32 salt = keccak256(abi.encode(owner, agentIndex, baseAsset));
        bytes32 hash = keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            keccak256(abi.encode(agentWalletImplementation, owner, baseAsset))
        ));
        return address(uint160(uint256(hash)));
    }

    /// @dev Create agent wallet with mock deployment
    function createAgentWallet(address owner, uint256 agentIndex, address baseAsset)
        external
        onlyOperator
        whenNotPaused
        returns (address wallet)
    {
        if (owner == address(0)) {
            revert YieldSeekerErrors.ZeroAddress();
        }
        if (baseAsset == address(0)) {
            revert YieldSeekerErrors.ZeroAddress();
        }
        if (agentIndex == 0) {
            revert YieldSeekerErrors.InvalidAgentIndex();
        }
        if (!_isContract(baseAsset)) {
            revert YieldSeekerErrors.InvalidAsset();
        }

        wallet = this.computeWalletAddress(owner, agentIndex, baseAsset);

        if (_walletExists[wallet]) {
            revert YieldSeekerErrors.WalletAlreadyExists();
        }

        // Mock wallet creation (in real implementation, this would deploy via CREATE2)
        _walletExists[wallet] = true;
        _walletCounter++;
        _ownerWalletCount[owner]++;
        _ownerWallets[owner].push(wallet);

        emit WalletCreated(owner, agentIndex, wallet, baseAsset, agentWalletImplementation);

        return wallet;
    }

    /// @dev Set agent wallet implementation
    function setAgentWalletImplementation(address newImplementation)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (newImplementation == address(0)) {
            revert YieldSeekerErrors.ZeroAddress();
        }

        address oldImplementation = agentWalletImplementation;
        agentWalletImplementation = newImplementation;

        emit ImplementationUpdated(oldImplementation, newImplementation);
    }

    /// @dev Set adapter registry
    function setAdapterRegistry(address newRegistry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newRegistry == address(0)) {
            revert YieldSeekerErrors.ZeroAddress();
        }

        address oldRegistry = adapterRegistry;
        adapterRegistry = newRegistry;

        emit AdapterRegistryUpdated(oldRegistry, newRegistry);
    }

    /// @dev Set fee tracker
    function setFeeTracker(address newTracker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newTracker == address(0)) {
            revert YieldSeekerErrors.ZeroAddress();
        }

        address oldTracker = feeTracker;
        feeTracker = newTracker;

        emit FeeTrackerUpdated(oldTracker, newTracker);
    }

    /// @dev Check if wallet exists
    function walletExists(address wallet) external view returns (bool) {
        return _walletExists[wallet];
    }

    /// @dev Get total wallet counter
    function getWalletCounter() external view returns (uint256) {
        return _walletCounter;
    }

    /// @dev Get owner wallet count
    function getOwnerWalletCount(address owner) external view returns (uint256) {
        return _ownerWalletCount[owner];
    }

    /// @dev Get wallets by owner
    function getWalletsByOwner(address owner) external view returns (address[] memory) {
        return _ownerWallets[owner];
    }

    /// @dev Get current implementation
    function getAgentWalletImplementation() external view returns (address) {
        return agentWalletImplementation;
    }

    /// @dev Get adapter registry
    function getAdapterRegistry() external view returns (address) {
        return adapterRegistry;
    }

    /// @dev Get fee tracker
    function getFeeTracker() external view returns (address) {
        return feeTracker;
    }

    /// @dev Pause contract
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @dev Unpause contract
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /// @dev Check if address is contract
    function _isContract(address account) internal view returns (bool) {
        return account.code.length > 0;
    }
}

/// @title MockWalletAlreadyExistsError
/// @notice Mock error for testing duplicate wallet creation
contract MockWalletAlreadyExistsError {
    error WalletAlreadyExists();
}
