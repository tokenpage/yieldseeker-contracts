// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAdminTimelock as AdminTimelock} from "../src/AdminTimelock.sol";
import {IPriceFeed, YieldSeekerPriceOracle as PriceOracle} from "../src/PriceOracle.sol";
import {IAaveV4Spoke} from "../src/agentwalletkit/adapters/AWKAaveV4LendingAdapter.sol";
import {AWKLendingAdapter} from "../src/agentwalletkit/adapters/AWKLendingAdapter.sol";
import {IMorphoBlue} from "../src/agentwalletkit/adapters/AWKMorphoBlueLendingAdapter.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

interface IMorphoOracle {
    function price() external view returns (uint256);
}

contract RegisterBorrowMarketScript is Script {
    using stdJson for string;

    address private constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address private constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address private constant MORPHO_ADAPTIVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    address private constant AAVE_V4_SPOKE = 0x17905Db0e4A3514467539956c084180616AE7B8D;

    function run(string memory protocol, bytes memory market) public {
        require(market.length > 0, "Market encoding must not be empty");

        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");

        // Load deployment addresses.
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
        PriceOracle priceOracle = PriceOracle(json.readAddress(".priceOracle"));
        AdapterRegistry registry = AdapterRegistry(registryAddress);
        AdminTimelock timelock = AdminTimelock(payable(timelockAddress));

        address collateral;
        address debt;
        if (keccak256(bytes(protocol)) == keccak256(bytes("aavev3"))) {
            (address pool, address collateralAsset, address debtAsset, uint8 eMode) = abi.decode(market, (address, address, address, uint8));
            console2.log("Aave V3 pool:", pool);
            console2.log("Aave V3 collateral:", collateralAsset);
            console2.log("Aave V3 debt:", debtAsset);
            console2.log("Aave V3 eMode:", uint256(eMode));
            require(pool == AAVE_V3_POOL, "Aave V3 pool must be the Base Aave V3 pool");
            require(eMode == 0, "Aave V3 eMode variants are not allowed");
            collateral = collateralAsset;
            debt = debtAsset;
        } else if (keccak256(bytes(protocol)) == keccak256(bytes("aavev4"))) {
            (address spokeAddress, uint256 collateralReserveId, uint256 debtReserveId) = abi.decode(market, (address, uint256, uint256));
            console2.log("Aave V4 spoke:", spokeAddress);
            console2.log("Aave V4 collateral reserve ID:", collateralReserveId);
            console2.log("Aave V4 debt reserve ID:", debtReserveId);
            require(spokeAddress == AAVE_V4_SPOKE, "Aave V4 spoke must be the Base Aave V4 spoke");
            IAaveV4Spoke spoke = IAaveV4Spoke(spokeAddress);
            collateral = spoke.getReserve(collateralReserveId).underlying;
            debt = spoke.getReserve(debtReserveId).underlying;
            console2.log("Aave V4 collateral underlying:", collateral);
            console2.log("Aave V4 debt underlying:", debt);
        } else {
            (address morphoAddress, IMorphoBlue.MarketParams memory params) = abi.decode(market, (address, IMorphoBlue.MarketParams));
            console2.log("Morpho Blue:", morphoAddress);
            console2.log("Morpho loan token:", params.loanToken);
            console2.log("Morpho collateral token:", params.collateralToken);
            console2.log("Morpho oracle:", params.oracle);
            console2.log("Morpho IRM:", params.irm);
            console2.log("Morpho LLTV:", params.lltv);
            require(morphoAddress == MORPHO_BLUE, "Morpho address must be Base Morpho Blue");
            require(params.irm == MORPHO_ADAPTIVE_IRM, "Morpho IRM must be the approved adaptive IRM");
            bytes32 morphoMarketId = keccak256(abi.encode(params));
            (,,,, uint128 lastUpdate,) = IMorphoBlue(morphoAddress).market(morphoMarketId);
            require(lastUpdate != 0, "Morpho market does not exist");
            console2.log("Morpho market ID:", vm.toString(morphoMarketId));
            console2.log("Morpho oracle price:", IMorphoOracle(params.oracle).price());
            collateral = params.collateralToken;
            debt = params.loanToken;
        }

        require(collateral != debt, "Collateral and debt assets must differ");
        (IPriceFeed collateralFeed,) = priceOracle.sources(collateral);
        (IPriceFeed debtFeed,) = priceOracle.sources(debt);
        require(address(collateralFeed) != address(0), "Collateral asset has no price source; run SetPriceSource first");
        require(address(debtFeed) != address(0), "Debt asset has no price source; run SetPriceSource first");

        address target = AWKLendingAdapter(adapterAddress).marketTarget(market);
        console2.log("Protocol:", protocol);
        console2.log("Raw market bytes:", vm.toString(market));
        console2.log("Market target:", target);

        require(registry.isRegisteredAdapter(adapterAddress), "Adapter not registered in borrow registry");
        uint256 delay = timelock.getMinDelay();
        address currentAdapter = registry.getTargetAdapter(target);
        console2.log("Adapter:", adapterAddress);
        console2.log("Registry:", registryAddress);
        console2.log("Timelock:", timelockAddress);
        console2.log("");

        if (currentAdapter == adapterAddress) {
            console2.log("Market is already registered to this adapter; nothing to do.");
            return;
        }

        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256(abi.encode("set-market-", target, adapterAddress, block.number));
        bytes memory data = abi.encodeCall(registry.setTargetAdapter, (target, adapterAddress));
        vm.startBroadcast(deployerPrivateKey);
        console2.log("-> Scheduling market target adapter set...");
        console2.log("-> Scheduling block (part of the salt):", block.number);
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
