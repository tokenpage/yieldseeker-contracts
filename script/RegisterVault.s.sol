// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAdminTimelock as AdminTimelock} from "../src/AdminTimelock.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title RegisterVaultScript
 * @notice Helper script to register vaults with adapters via timelock
 * @dev Registers the vault in the V2 vault registry (V2 adapter) and the V3 vault registry (V3 adapter) in one timelock
 *      batch, so the two registries always hold the same targets.
 *   Usage:
 *   forge script script/RegisterVault.s.sol:RegisterVaultScript \
 *     --rpc-url $RPC_NODE_URL_8453 \
 *     --broadcast \
 *     --sig "run(address,string)" \
 *     <VAULT_ADDRESS> \
 *     <ADAPTER_NAME>
 *
 *   # With predecessor dependency (recommended when config batch is still pending):
 *   forge script script/RegisterVault.s.sol:RegisterVaultScript \
 *     --rpc-url $RPC_NODE_URL_8453 \
 *     --broadcast \
 *     --sig "run(address,string,bytes32)" \
 *     <VAULT_ADDRESS> \
 *     <ADAPTER_NAME> \
 *     <PREDECESSOR_OPERATION_ID>
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

    address[] internal _targets;
    bytes[] internal _datas;

    function run(address vaultAddress, string memory adapterName) public {
        run(vaultAddress, adapterName, bytes32(0));
    }

    function run(address vaultAddress, string memory adapterName, bytes32 predecessor) public {
        require(vaultAddress != address(0), "Invalid vault address");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile("./deployments.json");
        AdapterRegistry v2Registry = AdapterRegistry(json.readAddress(".agentWalletV2AdapterRegistry"));
        AdapterRegistry registry = AdapterRegistry(json.readAddress(".vaultAdapterRegistry"));
        address timelockAddress = json.readAddress(".adminTimelock");
        (string memory v2AdapterKey, string memory adapterKey) = _adapterKeys(adapterName);
        address v2Adapter = json.readAddress(string.concat(".", v2AdapterKey));
        address adapter = json.readAddress(string.concat(".", adapterKey));

        console2.log("=================================================");
        console2.log("VAULT REGISTRATION");
        console2.log("=================================================");
        console2.log("Vault:", vaultAddress);
        console2.log("Adapter:", adapterName);
        console2.log("V2 Registry:", address(v2Registry));
        console2.log("V2 Adapter:", v2Adapter);
        console2.log("V3 Registry:", address(registry));
        console2.log("V3 Adapter:", adapter);
        console2.log("Timelock:", timelockAddress);
        console2.log("");

        _addTargetOperation(v2Registry, vaultAddress, v2Adapter, predecessor);
        _addTargetOperation(registry, vaultAddress, adapter, predecessor);
        if (_targets.length == 0) {
            console2.log("Vault is already registered in both registries; nothing to do.");
            return;
        }

        AdminTimelock timelock = AdminTimelock(payable(timelockAddress));
        uint256 delay = timelock.getMinDelay();
        uint256[] memory values = new uint256[](_targets.length);
        bytes32 salt = keccak256(abi.encodePacked("set-vault-", vaultAddress, v2Adapter, adapter));
        vm.startBroadcast(deployerPrivateKey);
        console2.log("-> Scheduling", _targets.length, "target adapter operations in one batch...");
        timelock.scheduleBatch(_targets, values, _datas, predecessor, salt, delay);

        if (delay == 0) {
            // Testing mode: execute immediately
            console2.log("-> Executing immediately (testing mode)...");
            timelock.executeBatch(_targets, values, _datas, predecessor, salt);
            console2.log("-> Target adapters set successfully!");
        } else {
            // Production mode: just schedule
            console2.log("-> Scheduled successfully!");
            console2.log("-> Delay:", delay, "seconds");
            console2.log("-> Predecessor:", vm.toString(predecessor));
            console2.log("-> Batch operation ID:", vm.toString(timelock.hashOperationBatch(_targets, values, _datas, predecessor, salt)));
            console2.log("-> Execute after the delay with executeBatch(targets, values, datas, predecessor, salt):");
            for (uint256 i = 0; i < _targets.length; i++) {
                console2.log("   target:", _targets[i]);
                console2.log("   data:", vm.toString(_datas[i]));
            }
            console2.log("   salt:", vm.toString(salt));
        }

        vm.stopBroadcast();

        console2.log("=================================================");
    }

    function _addTargetOperation(AdapterRegistry registry, address vaultAddress, address adapter, bytes32 predecessor) internal {
        bool adapterIsRegistered = registry.isRegisteredAdapter(adapter);
        console2.log("Adapter registered in", address(registry), adapterIsRegistered);
        if (!adapterIsRegistered && predecessor == bytes32(0)) {
            revert("Adapter not registered in registry");
        }
        if (registry.getTargetAdapter(vaultAddress) == adapter) return;
        _targets.push(address(registry));
        _datas.push(abi.encodeCall(registry.setTargetAdapter, (vaultAddress, adapter)));
    }

    /// @return v2AdapterKey The V2 vault registry adapter's key in deployments.json
    /// @return adapterKey The V3 vault registry adapter's key in deployments.json
    function _adapterKeys(string memory adapterName) internal pure returns (string memory v2AdapterKey, string memory adapterKey) {
        bytes32 name = keccak256(bytes(adapterName));
        if (name == keccak256("erc4626")) return ("agentWalletV2Erc4626Adapter", "erc4626Adapter");
        if (name == keccak256("uniswap") || name == keccak256("uniswapv3")) return ("agentWalletV2UniswapV3SwapAdapter", "uniswapV3SwapAdapter");
        if (name == keccak256("aerodromev2") || name == keccak256("aerov2")) return ("agentWalletV2AerodromeV2SwapAdapter", "aerodromeV2SwapAdapter");
        if (name == keccak256("aerodromecl") || name == keccak256("aerocl")) return ("agentWalletV2AerodromeCLSwapAdapter", "aerodromeCLSwapAdapter");
        if (name == keccak256("merkl")) return ("agentWalletV2MerklAdapter", "merklAdapter");
        if (name == keccak256("aave") || name == keccak256("aavev3")) return ("agentWalletV2AaveV3Adapter", "aaveV3Adapter");
        if (name == keccak256("compound") || name == keccak256("compoundv3")) return ("agentWalletV2CompoundV3Adapter", "compoundV3Adapter");
        if (name == keccak256("moonwellrewards")) return ("agentWalletV2MoonwellRewardAdapter", "moonwellRewardAdapter");
        if (name == keccak256("compoundv2") || name == keccak256("moonwell")) return ("agentWalletV2CompoundV2Adapter", "compoundV2Adapter");
        revert(string.concat("Unknown adapter name: ", adapterName, ". Use 'erc4626', 'uniswapv3', 'aerodromev2', 'aerodromecl', 'merkl', 'aave', 'compound', 'compoundv2', 'moonwell', or 'moonwellrewards'"));
    }
}
