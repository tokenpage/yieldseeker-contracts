// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC7579Account {
    // Execution
    function execute(bytes32 mode, bytes calldata executionCalldata) external payable;
    function executeFromExecutor(bytes32 mode, bytes calldata executionCalldata) external payable returns (bytes[] memory returnData);

    // Config
    function accountId() external view returns (string memory);
    function supportsExecutionMode(bytes32 mode) external view returns (bool);
    function supportsModule(uint256 moduleTypeId) external view returns (bool);

    // Module Management
    function installModule(uint256 moduleTypeId, address module, bytes calldata initData) external payable;
    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData) external payable;
    function isModuleInstalled(uint256 moduleTypeId, address module, bytes calldata additionalContext) external view returns (bool);

    // Validation
    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

interface IModule {
    function onInstall(bytes calldata data) external payable;
    function onUninstall(bytes calldata data) external payable;
    function isModuleType(uint256 moduleTypeId) external view returns (bool);
}

interface IValidator is IModule {
    function validateUserOp(bytes32 userOpHash, bytes calldata userOp) external returns (uint256);
    function isValidSignatureWithSender(address sender, bytes32 hash, bytes calldata signature) external view returns (bytes4);
}

interface IExecutor is IModule {
    // Executors don't have specific required methods other than IModule,
    // but they are authorized to call executeFromExecutor
}
