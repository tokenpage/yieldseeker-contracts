// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAdminTimelock as AdminTimelock} from "../src/AdminTimelock.sol";
import {AWKLendingAdapter} from "../src/agentwalletkit/adapters/AWKLendingAdapter.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

contract RegisterMarketScript is Script {
    using stdJson for string;

    function run(string memory protocol, bytes memory market) public {
        require(market.length > 0, "Invalid market");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Load deployment addresses
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile("./deployments.json");
        address adapterAddress;
        if (keccak256(bytes(protocol)) == keccak256(bytes("aavev3"))) {
            adapterAddress = json.readAddress(".aaveV3LendingAdapter");
        } else if (keccak256(bytes(protocol)) == keccak256(bytes("aavev4"))) {
            adapterAddress = json.readAddress(".aaveV4LendingAdapter");
        } else if (keccak256(bytes(protocol)) == keccak256(bytes("morpho"))) {
            adapterAddress = json.readAddress(".morphoBlueLendingAdapter");
        } else {
            revert(string.concat("Unknown protocol: ", protocol, ". Use 'aavev3', 'aavev4', or 'morpho'"));
        }

        address registryAddress = json.readAddress(".borrowAdapterRegistry");
        address timelockAddress = json.readAddress(".adminTimelock");
        AdapterRegistry registry = AdapterRegistry(registryAddress);
        AdminTimelock timelock = AdminTimelock(payable(timelockAddress));
        uint256 delay = timelock.getMinDelay();

        address target = AWKLendingAdapter(adapterAddress).marketTarget(market);
        bool adapterIsRegistered = registry.isRegisteredAdapter(adapterAddress);
        require(adapterIsRegistered, "Adapter not registered in borrow registry");
        address currentAdapter = registry.getTargetAdapter(target);
        console2.log("=================================================");
        console2.log("LENDING MARKET REGISTRATION");
        console2.log("=================================================");
        console2.log("Protocol:", protocol);
        console2.log("Market target:", target);
        console2.log("Adapter:", adapterAddress);
        console2.log("Registry:", registryAddress);
        console2.log("Timelock:", timelockAddress);
        console2.log("");

        if (currentAdapter == adapterAddress) {
            console2.log("Market is already registered to this adapter; nothing to do.");
            return;
        }

        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256(abi.encodePacked("set-market-", target, adapterAddress));
        bytes memory data = abi.encodeCall(registry.setTargetAdapter, (target, adapterAddress));
        vm.startBroadcast(deployerPrivateKey);
        console2.log("-> Scheduling market target adapter set...");
        timelock.schedule(registryAddress, 0, data, predecessor, salt, delay);

        if (delay == 0) {
            console2.log("-> Executing immediately (testing mode)...");
            timelock.execute(registryAddress, 0, data, predecessor, salt);
            console2.log("-> Market target set successfully!");
        } else {
            console2.log("-> Scheduled successfully!");
            console2.log("-> Delay:", delay, "seconds");
            console2.log("-> Execute after delay with:");
            console2.log("");
            console2.log("cast send", timelockAddress);
            console2.log('  "execute(address,uint256,bytes,bytes32,bytes32)"');
            console2.log("  ", registryAddress);
            console2.log("   0");
            console2.log("  ", vm.toString(data));
            console2.log("  ", vm.toString(predecessor));
            console2.log("  ", vm.toString(salt));
            console2.log("   --rpc-url $RPC_NODE_URL_8453 \\");
            console2.log("   --private-key $DEPLOYER_PRIVATE_KEY");
        }
        vm.stopBroadcast();

        console2.log("=================================================");
    }
}
