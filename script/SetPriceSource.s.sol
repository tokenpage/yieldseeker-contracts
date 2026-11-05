// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAdminTimelock as AdminTimelock} from "../src/AdminTimelock.sol";
import {IPriceFeed, YieldSeekerPriceOracle as PriceOracle} from "../src/PriceOracle.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

interface IDescribedPriceFeed {
    function description() external view returns (string memory);
    function aggregator() external view returns (address);
}

contract SetPriceSourceScript is Script {
    using stdJson for string;

    function run(address asset, address feed, uint32 maxStaleness) public {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Load deployment addresses
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile("./deployments.json");
        address oracleAddress = json.readAddress(".priceOracle");
        address timelockAddress = json.readAddress(".adminTimelock");
        PriceOracle oracle = PriceOracle(oracleAddress);
        AdminTimelock timelock = AdminTimelock(payable(timelockAddress));
        uint256 delay = timelock.getMinDelay();

        (IPriceFeed currentFeed, uint32 currentMaxStaleness) = oracle.sources(asset);

        IPriceFeed priceFeed = IPriceFeed(feed);
        uint8 feedDecimals = priceFeed.decimals();
        string memory feedDescription = IDescribedPriceFeed(feed).description();
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = priceFeed.latestRoundData();
        console2.log("Feed decimals:", uint256(feedDecimals));
        console2.log("Feed description:", feedDescription);
        address aggregator = IDescribedPriceFeed(feed).aggregator();
        console2.log("Feed aggregator:", aggregator);
        require(aggregator != address(0), "Feed must be an aggregator proxy, not a wrapper");
        console2.log("Feed latestRoundData roundId:", uint256(roundId));
        console2.log("Feed latestRoundData answer:", answer);
        console2.log("Feed latestRoundData startedAt:", startedAt);
        console2.log("Feed latestRoundData updatedAt:", updatedAt);
        console2.log("Feed latestRoundData answeredInRound:", uint256(answeredInRound));
        require(answer > 0, "Feed answer must be positive");
        require(updatedAt != 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxStaleness, "Feed answer is stale");
        if (address(currentFeed) == feed && currentMaxStaleness == maxStaleness) {
            console2.log("Price source is already configured; nothing to do.");
            return;
        }

        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256(abi.encode("set-price-source-", asset, feed, maxStaleness, block.number));
        bytes memory data = abi.encodeCall(oracle.setSource, (asset, IPriceFeed(feed), maxStaleness));
        vm.startBroadcast(deployerPrivateKey);
        console2.log("-> Scheduling price source set...");
        console2.log("-> Scheduling block (part of the salt):", block.number);
        timelock.schedule(oracleAddress, 0, data, predecessor, salt, delay);

        if (delay == 0) {
            console2.log("-> Executing immediately (testing mode)...");
            timelock.execute(oracleAddress, 0, data, predecessor, salt);
            console2.log("-> Price source set successfully!");
        } else {
            console2.log("-> Scheduled successfully!");
            console2.log("-> Delay:", delay, "seconds");
            console2.log("-> Operation ID:", vm.toString(timelock.hashOperation(oracleAddress, 0, data, predecessor, salt)));
            console2.log("-> Execute from the Safe after the delay: ./script/check-timelock.sh");
        }
        vm.stopBroadcast();

        console2.log("=================================================");
    }
}
