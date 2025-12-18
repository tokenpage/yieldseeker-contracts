// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAdminTimelock as AdminTimelock} from "../src/AdminTimelock.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title RegisterVaultScript
 * @notice Helper script to register vaults with adapters via timelock
 * @dev Usage:
 *   forge script script/RegisterVault.s.sol:RegisterVaultScript \
 *     --rpc-url $RPC_NODE_URL_8453 \
 *     --broadcast \
 *     --sig "run(address,string)" \
 *     <VAULT_ADDRESS> \
 *     <ADAPTER_NAME>
 *
 * Example:
 *   forge script script/RegisterVault.s.sol:RegisterVaultScript \
 *     --rpc-url $RPC_NODE_URL_8453 \
 *     --broadcast \
 *     --sig "run(address,string)" \
 *     0x1234567890123456789012345678901234567890 \
 *     erc4626
 */
contract RegisterVaultScript is Script {
    using stdJson for string;

    function run(address vaultAddress, string memory adapterName) public {
        require(vaultAddress != address(0), "Invalid vault address");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Load deployment addresses
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile("./deployments.json");
        address registryAddress = json.readAddress(".adapterRegistry");
        address timelockAddress = json.readAddress(".adminTimelock");

        // Get adapter address based on name
        address adapterAddress;
        if (keccak256(bytes(adapterName)) == keccak256(bytes("erc4626"))) {
            adapterAddress = json.readAddress(".erc4626Adapter");
        } else if (keccak256(bytes(adapterName)) == keccak256(bytes("zerox")) || keccak256(bytes(adapterName)) == keccak256(bytes("0x"))) {
            adapterAddress = json.readAddress(".zeroXAdapter");
        } else {
            revert(string.concat("Unknown adapter name: ", adapterName, ". Use 'erc4626' or 'zerox'"));
        }

        console2.log("=================================================");
        console2.log("VAULT REGISTRATION");
        console2.log("=================================================");
        console2.log("Vault:", vaultAddress);
        console2.log("Adapter:", adapterName);
        console2.log("Adapter Address:", adapterAddress);
        console2.log("Registry:", registryAddress);
        console2.log("Timelock:", timelockAddress);
        console2.log("");

        AdapterRegistry registry = AdapterRegistry(registryAddress);
        AdminTimelock timelock = AdminTimelock(payable(timelockAddress));
        uint256 delay = timelock.getMinDelay();

        bool adapterIsRegistered = registry.isRegisteredAdapter(adapterAddress);
        console2.log("Adapter registered:", adapterIsRegistered);
        require(adapterIsRegistered, "Adapter not registered in registry");

        address currentAdapter = registry.getTargetAdapter(vaultAddress);
        console2.log("Current adapter for vault:", currentAdapter);
        if (currentAdapter == adapterAddress) {
            console2.log("Vault is already registered to this adapter; nothing to do.");
            return;
        }

        // Schedule operation
        bytes32 salt = keccak256(abi.encodePacked("set-vault-", vaultAddress, adapterAddress));
        bytes memory data = abi.encodeCall(registry.setTargetAdapter, (vaultAddress, adapterAddress));
        vm.startBroadcast(deployerPrivateKey);
        console2.log("-> Scheduling target adapter set...");
        timelock.schedule(registryAddress, 0, data, bytes32(0), salt, delay);

        if (delay == 0) {
            // Testing mode: execute immediately
            console2.log("-> Executing immediately (testing mode)...");
            timelock.execute(registryAddress, 0, data, bytes32(0), salt);
            console2.log("-> Target adapter set successfully!");
        } else {
            // Production mode: just schedule
            console2.log("-> Scheduled successfully!");
            console2.log("-> Delay:", delay, "seconds");
            console2.log("-> Execute after delay with:");
            console2.log("");
            console2.log("cast send", timelockAddress);
            console2.log('  "execute(address,uint256,bytes,bytes32,bytes32)"');
            console2.log("  ", registryAddress);
            console2.log("   0");
            console2.log("  ", vm.toString(data));
            console2.log("   0x0000000000000000000000000000000000000000000000000000000000000000");
            console2.log("  ", vm.toString(salt));
            console2.log("   --rpc-url $RPC_NODE_URL_8453 \\");
            console2.log("   --private-key $DEPLOYER_PRIVATE_KEY");
        }

        vm.stopBroadcast();

        console2.log("=================================================");
    }
}
