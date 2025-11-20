// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IPolicyValidator {
    function validateAction(
        address wallet,
        address target,
        bytes4 selector,
        bytes calldata data
    ) external view returns (bool);
}
