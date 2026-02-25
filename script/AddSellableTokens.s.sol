// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdminTimelock as AdminTimelock} from "../src/AdminTimelock.sol";
import {YieldSeekerSwapSellPolicy as SwapSellPolicy} from "../src/adapters/SwapSellPolicy.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

/**
 * @title AddSellableTokensScript
 * @notice Helper script to add sellable tokens to the swap sell policy allowlist via timelock
 * @dev Usage:
 *   forge script script/AddSellableTokens.s.sol:AddSellableTokensScript \
 *     --rpc-url $RPC_NODE_URL_8453 \
 *     --broadcast \
 *     --sig "run(address[])" \
 *     "[<TOKEN_1>,<TOKEN_2>,...]"
 *
 * Example (single token):
 *   forge script script/AddSellableTokens.s.sol:AddSellableTokensScript \
 *     --rpc-url $RPC_NODE_URL_8453 \
 *     --broadcast \
 *     --sig "run(address[])" \
 *     "[0x590830dFDf9A3F68aFCDdE2694773dEBDF267774]"
 *
 * Example (multiple tokens):
 *   forge script script/AddSellableTokens.s.sol:AddSellableTokensScript \
 *     --rpc-url $RPC_NODE_URL_8453 \
 *     --broadcast \
 *     --sig "run(address[])" \
 *     "[0x590830dFDf9A3F68aFCDdE2694773dEBDF267774,0xBAa5CC21fd487B8Fcc2F632f3F4E8D37262a0842]"
 */
contract AddSellableTokensScript is Script {
    using stdJson for string;

    function run(address[] memory tokens) public {
        require(tokens.length > 0, "No tokens provided");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile("./deployments.json");
        address sellPolicyAddress = json.readAddress(".swapSellPolicy");
        address timelockAddress = json.readAddress(".adminTimelock");

        SwapSellPolicy sellPolicy = SwapSellPolicy(sellPolicyAddress);
        AdminTimelock timelock = AdminTimelock(payable(timelockAddress));
        uint256 delay = timelock.getMinDelay();

        console2.log("=================================================");
        console2.log("ADD SELLABLE TOKENS");
        console2.log("=================================================");
        console2.log("Swap Sell Policy:", sellPolicyAddress);
        console2.log("Timelock:", timelockAddress);
        console2.log("Tokens to add:", tokens.length);
        console2.log("");

        for (uint256 i = 0; i < tokens.length; i++) {
            require(tokens[i] != address(0), "Invalid token address");
            bool alreadySellable = sellPolicy.isSellableToken(tokens[i]);
            console2.log("Token:", tokens[i], alreadySellable ? "(already sellable)" : "(new)");
        }

        bytes32 salt = keccak256(abi.encodePacked("add-sellable-tokens-", abi.encode(tokens)));
        bytes memory data = abi.encodeCall(sellPolicy.addSellableTokens, (tokens));

        console2.log("");
        vm.startBroadcast(deployerPrivateKey);
        console2.log("-> Scheduling addSellableTokens via timelock...");
        timelock.schedule(sellPolicyAddress, 0, data, bytes32(0), salt, delay);

        if (delay == 0) {
            console2.log("-> Executing immediately (testing mode)...");
            timelock.execute(sellPolicyAddress, 0, data, bytes32(0), salt);
            console2.log("-> Sellable tokens added successfully!");
        } else {
            console2.log("-> Scheduled successfully!");
            console2.log("-> Delay:", delay, "seconds");
            console2.log("-> Execute after delay with:");
            console2.log("");
            console2.log("cast send", timelockAddress);
            console2.log('  "execute(address,uint256,bytes,bytes32,bytes32)"');
            console2.log("  ", sellPolicyAddress);
            console2.log("   0");
            console2.log("  ", vm.toString(data));
            console2.log("   0x0000000000000000000000000000000000000000000000000000000000000000");
            console2.log("  ", vm.toString(salt));
            console2.log("   --rpc-url $RPC_NODE_URL_8453 \\");
            console2.log("   --private-key $DEPLOYER_PRIVATE_KEY");
        }

        vm.stopBroadcast();

        console2.log("");
        console2.log("Current sellable tokens:");
        address[] memory allSellable = sellPolicy.getSellableTokens();
        for (uint256 i = 0; i < allSellable.length; i++) {
            console2.log(" ", allSellable[i]);
        }
        console2.log("=================================================");
    }
}
