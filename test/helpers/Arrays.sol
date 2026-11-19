// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

function toArray(address item) pure returns (address[] memory items) {
    items = new address[](1);
    items[0] = item;
}
