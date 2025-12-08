// SPDX-License-Identifier: MIT
pragma solidity ^0.8.12;

import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IEntryPoint} from "account-abstraction/interfaces/IEntryPoint.sol";
import {AgentWallet} from "./AgentWallet.sol";
import {ActionRegistry} from "./ActionRegistry.sol";

/**
 * @title AgentWalletFactory
 * @notice Factory for deploying AgentWallet proxies using CREATE2
 * @dev Based on SimpleAccountFactory pattern from eth-infinitism/account-abstraction v0.6
 *      Adds AccessControl for permissioned wallet creation and ActionRegistry integration
 */
contract AgentWalletFactory is AccessControl {
    bytes32 public constant AGENT_CREATOR_ROLE = keccak256("AGENT_CREATOR_ROLE");
    AgentWallet public immutable accountImplementation;
    ActionRegistry public immutable actionRegistry;

    event AgentWalletCreated(address indexed wallet, address indexed owner, uint256 salt);

    constructor(IEntryPoint entryPoint, ActionRegistry registry, address admin) {
        accountImplementation = new AgentWallet(entryPoint);
        actionRegistry = registry;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(AGENT_CREATOR_ROLE, admin);
    }

    /**
     * @notice Create an AgentWallet for the given owner
     * @dev Returns existing address if already deployed (for EntryPoint.getSenderAddress compatibility)
     * @param owner The owner address for the wallet
     * @param salt Salt for CREATE2 deterministic deployment
     * @return ret The deployed or existing AgentWallet
     */
    function createAccount(
        address owner,
        uint256 salt
    ) public onlyRole(AGENT_CREATOR_ROLE) returns (AgentWallet ret) {
        address addr = getAddress(owner, salt);
        uint256 codeSize = addr.code.length;
        if (codeSize > 0) {
            return AgentWallet(payable(addr));
        }
        ret = AgentWallet(
            payable(
                new ERC1967Proxy{salt: bytes32(salt)}(
                    address(accountImplementation),
                    abi.encodeCall(AgentWallet.initialize, (owner, actionRegistry))
                )
            )
        );
        emit AgentWalletCreated(address(ret), owner, salt);
    }

    /**
     * @notice Calculate the counterfactual address of an AgentWallet
     * @param owner The owner address for the wallet
     * @param salt Salt for CREATE2
     * @return The predicted wallet address
     */
    function getAddress(address owner, uint256 salt) public view returns (address) {
        return Create2.computeAddress(
            bytes32(salt),
            keccak256(
                abi.encodePacked(
                    type(ERC1967Proxy).creationCode,
                    abi.encode(
                        address(accountImplementation),
                        abi.encodeCall(AgentWallet.initialize, (owner, actionRegistry))
                    )
                )
            )
        );
    }
}
