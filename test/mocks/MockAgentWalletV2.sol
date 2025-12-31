// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAgentWalletV1} from "../../src/AgentWalletV1.sol";
import {IAgentWalletFactory} from "../../src/IAgentWalletFactory.sol";

/**
 * @title MockAgentWalletV2
 * @notice Mock V2 implementation for testing upgrades
 * @dev Extends V1 with new state variables - no initialization required (Option 1)
 */
contract MockAgentWalletV2 is YieldSeekerAgentWalletV1 {
    /// @custom:storage-location erc7201:yieldseeker.storage.AgentWalletV2
    struct AgentWalletV2Storage {
        uint256 v2Counter;
        string v2Message;
        address v2CustomAddress;
    }

    // keccak256(abi.encode(uint256(keccak256("yieldseeker.storage.AgentWalletV2")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AGENT_WALLET_V2_STORAGE_LOCATION = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcd00;

    event V2FunctionCalled(address indexed caller, string message);
    event V2CounterIncremented(uint256 oldValue, uint256 newValue);
    event V2MessageSet(string oldMessage, string newMessage);
    event V2CustomAddressSet(address oldAddress, address newAddress);

    constructor(address factory) YieldSeekerAgentWalletV1(factory) {}

    function _getV2Storage() private pure returns (AgentWalletV2Storage storage $) {
        assembly {
            $.slot := AGENT_WALLET_V2_STORAGE_LOCATION
        }
    }

    /**
     * @notice V2 function - works immediately after upgrade (no initialization required)
     * @param message A message to emit
     */
    function v2OnlyFunction(string calldata message) external onlyOwner {
        emit V2FunctionCalled(msg.sender, message);
    }

    /**
     * @notice Increment the V2 counter (starts at 0)
     */
    function incrementV2Counter() external onlyOwner {
        AgentWalletV2Storage storage $ = _getV2Storage();
        uint256 oldValue = $.v2Counter;
        $.v2Counter++;
        emit V2CounterIncremented(oldValue, $.v2Counter);
    }

    /**
     * @notice Set V2 message (optional configuration)
     */
    function setV2Message(string calldata newMessage) external onlyOwner {
        AgentWalletV2Storage storage $ = _getV2Storage();
        string memory oldMessage = $.v2Message;
        $.v2Message = newMessage;
        emit V2MessageSet(oldMessage, newMessage);
    }

    /**
     * @notice Set V2 custom address (optional configuration)
     */
    function setV2CustomAddress(address newAddress) external onlyOwner {
        AgentWalletV2Storage storage $ = _getV2Storage();
        address oldAddress = $.v2CustomAddress;
        $.v2CustomAddress = newAddress;
        emit V2CustomAddressSet(oldAddress, newAddress);
    }

    /**
     * @notice Get V2 state variables
     */
    function getV2State() external view returns (uint256 counter, string memory message, address customAddress) {
        AgentWalletV2Storage storage $ = _getV2Storage();
        return ($.v2Counter, $.v2Message, $.v2CustomAddress);
    }

    /**
     * @notice Helper to verify this is V2
     * @return Version number
     */
    function version() external pure returns (uint256) {
        return 2;
    }
}
