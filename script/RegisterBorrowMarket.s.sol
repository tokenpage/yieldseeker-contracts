// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

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

interface IAaveV3PoolConfiguration {
    function getConfiguration(address asset) external view returns (uint256);
}

contract RegisterBorrowMarketScript is Script {
    using stdJson for string;

    address private constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address private constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address private constant MORPHO_ADAPTIVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    address private constant AAVE_V4_SPOKE = 0x17905Db0e4A3514467539956c084180616AE7B8D;

    address[] private _targets;
    bytes[] private _datas;

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
            require(keccak256(market) == keccak256(abi.encode(pool, collateralAsset, debtAsset, eMode)), "Market bytes must be the canonical encoding");
            require(IAaveV3PoolConfiguration(pool).getConfiguration(collateralAsset) & 0xFFFF != 0, "Aave V3 collateral has LTV 0 outside eMode, so supplying it as collateral reverts");
            require((IAaveV3PoolConfiguration(pool).getConfiguration(debtAsset) >> 58) & 1 == 1, "Aave V3 debt reserve has borrowing disabled");
            collateral = collateralAsset;
            debt = debtAsset;
        } else if (keccak256(bytes(protocol)) == keccak256(bytes("aavev4"))) {
            (address spokeAddress, uint256 collateralReserveId, uint256 debtReserveId) = abi.decode(market, (address, uint256, uint256));
            console2.log("Aave V4 spoke:", spokeAddress);
            console2.log("Aave V4 collateral reserve ID:", collateralReserveId);
            console2.log("Aave V4 debt reserve ID:", debtReserveId);
            require(spokeAddress == AAVE_V4_SPOKE, "Aave V4 spoke must be the Base Aave V4 spoke");
            require(keccak256(market) == keccak256(abi.encode(spokeAddress, collateralReserveId, debtReserveId)), "Market bytes must be the canonical encoding");
            IAaveV4Spoke spoke = IAaveV4Spoke(spokeAddress);
            collateral = spoke.getReserve(collateralReserveId).underlying;
            debt = spoke.getReserve(debtReserveId).underlying;
            console2.log("Aave V4 collateral underlying:", collateral);
            console2.log("Aave V4 debt underlying:", debt);
        } else {
            (address morphoAddress, IMorphoBlue.MarketParams memory params) = abi.decode(market, (address, IMorphoBlue.MarketParams));
            require(keccak256(market) == keccak256(abi.encode(morphoAddress, params)), "Market bytes must be the canonical encoding");
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
        address receiptToken = AWKLendingAdapter(adapterAddress).collateralReceiptToken(market);
        console2.log("Protocol:", protocol);
        console2.log("Raw market bytes:", vm.toString(market));
        console2.log("Market target:", target);
        console2.log("Collateral receipt token (a target too, so it can't be sold):", receiptToken);

        require(registry.isRegisteredAdapter(adapterAddress), "Adapter not registered in borrow registry");
        uint256 delay = timelock.getMinDelay();
        console2.log("Adapter:", adapterAddress);
        console2.log("Registry:", registryAddress);
        console2.log("Timelock:", timelockAddress);
        console2.log("");

        _addTargetOperation(registry, target, adapterAddress);
        if (receiptToken != address(0)) _addTargetOperation(registry, receiptToken, adapterAddress);
        if (_targets.length == 0) {
            console2.log("Market and its collateral receipt token are already registered to this adapter; nothing to do.");
            return;
        }

        bytes32 predecessor = bytes32(0);
        bytes32 salt = keccak256(abi.encode("set-market-", target, adapterAddress, block.number));
        uint256[] memory values = new uint256[](_targets.length);
        vm.startBroadcast(deployerPrivateKey);
        console2.log("-> Scheduling", _targets.length, "target adapter operations in one batch...");
        console2.log("-> Scheduling block (part of the salt):", block.number);
        timelock.scheduleBatch(_targets, values, _datas, predecessor, salt, delay);

        if (delay == 0) {
            console2.log("-> Executing immediately (testing mode)...");
            timelock.executeBatch(_targets, values, _datas, predecessor, salt);
            console2.log("-> Market targets set successfully!");
        } else {
            console2.log("-> Scheduled successfully!");
            console2.log("-> Delay:", delay, "seconds");
            console2.log("-> Batch operation ID:", vm.toString(timelock.hashOperationBatch(_targets, values, _datas, predecessor, salt)));
            console2.log("-> Execute from the Safe after the delay: ./script/check-timelock.sh");
        }
        vm.stopBroadcast();

        console2.log("=================================================");
    }

    function _addTargetOperation(AdapterRegistry registry, address target, address adapter) internal {
        address currentAdapter = registry.getTargetAdapter(target);
        if (currentAdapter == adapter) return;
        if (currentAdapter != address(0)) console2.log("Replacing the adapter of", target, currentAdapter);
        _targets.push(address(registry));
        _datas.push(abi.encodeCall(registry.setTargetAdapter, (target, adapter)));
    }
}
