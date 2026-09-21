// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAgentWalletV2} from "../../src/AgentWalletV2.sol";

contract MockAgentWalletV3 is YieldSeekerAgentWalletV2 {
    struct AgentWalletV3Storage {
        uint256 v3Counter;
        string v3Message;
        address v3CustomAddress;
    }

    bytes32 private constant AGENT_WALLET_V3_STORAGE_LOCATION = 0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcd00;

    event V3FunctionCalled(address indexed caller, string message);
    event V3CounterIncremented(uint256 oldValue, uint256 newValue);
    event V3MessageSet(string oldMessage, string newMessage);
    event V3CustomAddressSet(address oldAddress, address newAddress);

    constructor(address factory) YieldSeekerAgentWalletV2(factory) {}

    function _getV3Storage() private pure returns (AgentWalletV3Storage storage $) {
        assembly {
            $.slot := AGENT_WALLET_V3_STORAGE_LOCATION
        }
    }

    function v3OnlyFunction(string calldata message) external onlyOwner {
        emit V3FunctionCalled(msg.sender, message);
    }

    function incrementV3Counter() external onlyOwner {
        AgentWalletV3Storage storage $ = _getV3Storage();
        uint256 oldValue = $.v3Counter;
        $.v3Counter++;
        emit V3CounterIncremented(oldValue, $.v3Counter);
    }

    function setV3Message(string calldata newMessage) external onlyOwner {
        AgentWalletV3Storage storage $ = _getV3Storage();
        string memory oldMessage = $.v3Message;
        $.v3Message = newMessage;
        emit V3MessageSet(oldMessage, newMessage);
    }

    function setV3CustomAddress(address newAddress) external onlyOwner {
        AgentWalletV3Storage storage $ = _getV3Storage();
        address oldAddress = $.v3CustomAddress;
        $.v3CustomAddress = newAddress;
        emit V3CustomAddressSet(oldAddress, newAddress);
    }

    function getV3State() external view returns (uint256 counter, string memory message, address customAddress) {
        AgentWalletV3Storage storage $ = _getV3Storage();
        return ($.v3Counter, $.v3Message, $.v3CustomAddress);
    }

    function version() external pure returns (uint256) {
        return 3;
    }
}
