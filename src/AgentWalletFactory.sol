// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "./AdapterRegistry.sol";
import {YieldSeekerAgentWalletV1 as AgentWallet} from "./AgentWalletV1.sol";
import {YieldSeekerErrors} from "./Errors.sol";
import {YieldSeekerFeeTracker as FeeTracker} from "./FeeTracker.sol";
import {AWKAgentWalletFactory} from "./agentwalletkit/AWKAgentWalletFactory.sol";
import {AWKAgentWalletV1 as AWKAgentWallet} from "./agentwalletkit/AWKAgentWalletV1.sol";
import {AWKErrors} from "./agentwalletkit/AWKErrors.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/**
 * @title YieldSeekerAgentWalletProxy
 * @notice A custom ERC1967Proxy that queries the Factory for its implementation.
 * @dev This ensures the init-code hash is constant regardless of the implementation address.
 */
contract YieldSeekerAgentWalletProxy is ERC1967Proxy {
    constructor() ERC1967Proxy(address(YieldSeekerAgentWalletFactory(msg.sender).agentWalletImplementation()), "") {}
}

/**
 * @title YieldSeekerAgentWalletFactory
 * @notice Factory for deploying YieldSeeker agent wallets with fee tracking
 * @dev Extends AWKAgentWalletFactory with YieldSeeker-specific fee tracker and baseAsset handling
 *      Note: agentWalletImplementation() returns YieldSeekerAgentWalletV1 (aliased as AgentWallet in this contract)
 */
contract YieldSeekerAgentWalletFactory is AWKAgentWalletFactory {
    FeeTracker public feeTracker;

    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 indexed ownerAgentIndex, address baseAsset);

    /// @param admin Address of the AdminTimelock contract (gets admin role for dangerous operations)
    /// @param agentOperator Address that can create agent wallets (typically backend server)
    constructor(address admin, address agentOperator) AWKAgentWalletFactory(admin, agentOperator) {}

    /**
     * @notice Update the FeeTracker address for future wallet deployments
     * @param newFeeTracker The new tracker contract
     */
    function setFeeTracker(FeeTracker newFeeTracker) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(newFeeTracker) == address(0)) revert YieldSeekerErrors.ZeroAddress();
        if (address(newFeeTracker).code.length == 0) revert YieldSeekerErrors.NotAContract(address(newFeeTracker));
        FeeTracker oldFeeTracker = feeTracker;
        feeTracker = newFeeTracker;
        emit TrackerUpdated(address(oldFeeTracker), address(newFeeTracker));
    }

    /**
     * @notice Create a YieldSeeker AgentWallet with baseAsset support
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner (enables multiple agents per owner)
     * @param baseAsset Base asset token address for this agent (e.g., USDC)
     * @return ret The deployed AgentWallet
     */
    function createAgentWallet(address owner, uint256 ownerAgentIndex, address baseAsset) public onlyRole(AGENT_OPERATOR_ROLE) returns (AgentWallet ret) {
        _validateWalletCreation(owner, ownerAgentIndex);
        if (baseAsset == address(0)) revert YieldSeekerErrors.ZeroAddress();
        if (baseAsset.code.length == 0) revert YieldSeekerErrors.NotAContract(baseAsset);
        bytes32 salt = _calculateSalt(owner, ownerAgentIndex);
        ret = AgentWallet(payable(new YieldSeekerAgentWalletProxy{salt: salt}()));
        ret.initialize(owner, ownerAgentIndex, baseAsset);
        userWallets[owner][ownerAgentIndex] = address(ret);
        emit AgentWalletCreated(address(ret), owner, ownerAgentIndex, baseAsset);
    }

    /**
     * @notice Calculate the counterfactual address of a YieldSeeker AgentWallet
     * @param owner The owner address for the wallet
     * @param ownerAgentIndex Index of this agent for the owner
     * @return The predicted wallet address
     */
    function getAddress(address owner, uint256 ownerAgentIndex) public view override returns (address) {
        bytes32 salt = _calculateSalt(owner, ownerAgentIndex);
        return Create2.computeAddress(salt, keccak256(type(YieldSeekerAgentWalletProxy).creationCode));
    }
}
