// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {MockERC20} from "../../../mocks/MockERC20.sol";

contract BlockedRecipientMockERC20 is MockERC20 {
    address public blockedRecipient;

    error TransferToBlockedRecipient(address recipient);

    constructor() MockERC20("Blocked Recipient Token", "BRT") {}

    function setBlockedRecipient(address recipient) external {
        blockedRecipient = recipient;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        if (to == blockedRecipient) revert TransferToBlockedRecipient(to);
        return super.transfer(to, amount);
    }
}

contract RejectingFeeCollector {
    receive() external payable {
        revert();
    }
}
