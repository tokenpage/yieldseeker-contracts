// SPDX-License-Identifier: MIT
pragma solidity 0.8.38;

import {YieldSeekerAdapterRegistry as AdapterRegistry} from "../src/AdapterRegistry.sol";
import {YieldSeekerAdminTimelock as AdminTimelock} from "../src/AdminTimelock.sol";
import {IPriceFeed, YieldSeekerPriceOracle as PriceOracle} from "../src/PriceOracle.sol";
import {YieldSeekerSwapSellPolicy as SwapSellPolicy} from "../src/adapters/SwapSellPolicy.sol";
import {IAaveV4Spoke} from "../src/agentwalletkit/adapters/AWKAaveV4LendingAdapter.sol";
import {AWKLendingAdapter} from "../src/agentwalletkit/adapters/AWKLendingAdapter.sol";
import {IMorphoBlue, IMorphoOracle} from "../src/agentwalletkit/adapters/AWKMorphoBlueLendingAdapter.sol";
import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {console2} from "forge-std/console2.sol";

interface IDescribedPriceFeed {
    function description() external view returns (string memory);
    function aggregator() external view returns (address);
}

interface IAaveV3PoolConfiguration {
    function getConfiguration(address asset) external view returns (uint256);
}

interface IAaveV4OracleSources {
    function getReserveSource(uint256 reserveId) external view returns (address);
}

/**
 * @title ConfigureScript
 * @notice Brings the sell list, price sources, vault registry targets and borrow markets in line with
 *         script/config/base.json, scheduling everything missing as one timelock batch
 * @dev Usage: forge script script/Configure.s.sol:ConfigureScript --rpc-url $RPC_NODE_URL_8453 --broadcast
 *      Behind a pending Deploy.s.sol batch: add --sig "run(bytes32)" <DEPLOY_BATCH_ID>; adapters that batch
 *      registers then count as registered, and the timelock runs this batch only after it.
 *      It only adds and updates. Anything on-chain that the config lacks is reported, never removed: removal is an
 *      emergency-role action, and a rerun puts back whatever the config still lists.
 */
contract ConfigureScript is Script {
    using stdJson for string;

    string internal constant CONFIG_PATH = "./script/config/base.json";
    address internal constant AAVE_V3_POOL = 0xA238Dd80C259a72e81d7e4664a9801593F98d1c5;
    address internal constant AAVE_V4_SPOKE = 0x17905Db0e4A3514467539956c084180616AE7B8D;
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    address internal constant MORPHO_ADAPTIVE_IRM = 0x46415998764C29aB2a25CbeA6254146D50D22687;
    // Only checks that a new feed is live; the oracle enforces each source's own staleness limit on every read.
    // Four days covers the longest US market closure, so tokenized-stock feeds pass over a weekend.
    uint256 internal constant MAX_FEED_AGE = 4 days;

    string internal _config;
    string internal _deployments;
    bytes32 internal _predecessor;
    address[] internal _targets;
    bytes[] internal _datas;
    address[] internal _sourceAssets;
    address[] internal _sourceFeeds;
    address[] internal _vaultTargets;
    address[] internal _borrowTargets;
    address[] internal _marketCollaterals;
    address[] internal _marketDebts;
    bytes32[] internal _collateralVenues;
    uint256 internal _warnings;
    // About 75k gas per operation; with the Deploy batch and the factory handover, a launch bundle stays under 15M gas
    uint256 internal constant MAX_OPERATIONS = 130;

    function run() public {
        run(bytes32(0));
    }

    function run(bytes32 predecessor) public {
        require(block.chainid == 8453, "Only Base is configured");
        _predecessor = predecessor;
        // forge-lint: disable-next-line(unsafe-cheatcode)
        _config = vm.readFile(CONFIG_PATH);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        _deployments = vm.readFile("./deployments.json");
        console2.log("=================================================");
        console2.log("CONFIGURE from", CONFIG_PATH);
        console2.log("Predecessor:", vm.toString(predecessor));
        console2.log("=================================================");
        if (predecessor != bytes32(0)) {
            AdminTimelock timelock = AdminTimelock(payable(_deployments.readAddress(".adminTimelock")));
            require(timelock.isOperationPending(predecessor), "The predecessor must be a pending timelock operation (the Deploy.s.sol batch)");
        }
        _requireKnownSections();

        _configurePriceSources();
        _configureVaultTargets();
        _configureAaveV3Markets();
        _configureAaveV4Markets();
        _configureMorphoMarkets();
        _requireNoCollateralDebtCycle();
        _configureSellableTokens();
        _reportDrift();
        _schedule();
    }

    function _requireKnownSections() internal view {
        string[] memory sections = vm.parseJsonKeys(_config, "$");
        for (uint256 i = 0; i < sections.length; i++) {
            bytes32 section = keccak256(bytes(sections[i]));
            require(
                section == keccak256("sellableTokens") || section == keccak256("priceSources") || section == keccak256("vaultTargets") || section == keccak256("aaveV3Markets") || section == keccak256("aaveV4Markets")
                    || section == keccak256("morphoMarkets"),
                string.concat("Unknown config section '", sections[i], "'")
            );
        }
    }

    function _configureSellableTokens() internal {
        SwapSellPolicy sellPolicy = SwapSellPolicy(_deployments.readAddress(".swapSellPolicy"));
        require(!sellPolicy.allowSellingAllTokens(), "allowSellingAllTokens is on: turn it off, it lets an operator sell any token with no price floor");
        uint256 count = _count(".sellableTokens");
        address[] memory missing = new address[](count);
        uint256 missingCount;
        for (uint256 i = 0; i < count; i++) {
            string memory label = _config.readString(_at(".sellableTokens", i, "label"));
            address token = _config.readAddress(_at(".sellableTokens", i, "token"));
            require(token != address(0), string.concat(label, ": sellable token is the zero address"));
            bool isConfiguredTarget = _indexOf(_vaultTargets, token) != type(uint256).max || _indexOf(_borrowTargets, token) != type(uint256).max;
            require(!isConfiguredTarget && !_isAnyRegistryTarget(token), string.concat(label, " is a registry target, so it can't be a sellable token"));
            if (!sellPolicy.isSellableToken(token)) missing[missingCount++] = token;
        }
        if (missingCount == 0) return;
        assembly {
            mstore(missing, missingCount)
        }
        _op(address(sellPolicy), abi.encodeCall(sellPolicy.addSellableTokens, (missing)), "add sellable tokens");
    }

    function _configurePriceSources() internal {
        PriceOracle oracle = PriceOracle(_deployments.readAddress(".priceOracle"));
        uint256 count = _count(".priceSources");
        for (uint256 i = 0; i < count; i++) {
            string memory label = _config.readString(_at(".priceSources", i, "label"));
            address asset = _config.readAddress(_at(".priceSources", i, "asset"));
            address feed = _config.readAddress(_at(".priceSources", i, "feed"));
            uint256 maxStalenessValue = _config.readUint(_at(".priceSources", i, "maxStaleness"));
            require(maxStalenessValue <= type(uint32).max, string.concat(label, ": maxStaleness does not fit in uint32"));
            uint32 maxStaleness = uint32(maxStalenessValue);
            require(asset != address(0) && feed != address(0) && maxStaleness != 0, string.concat(label, ": asset, feed and maxStaleness must be set"));
            require(_indexOf(_sourceAssets, asset) == type(uint256).max, string.concat(label, ": asset listed twice in priceSources"));
            _sourceAssets.push(asset);
            _sourceFeeds.push(feed);
            (IPriceFeed currentFeed, uint32 currentMaxStaleness) = oracle.sources(asset);
            if (address(currentFeed) == feed && currentMaxStaleness == maxStaleness) continue;
            _requireLiveFeed(label, feed, maxStaleness);
            _op(address(oracle), abi.encodeCall(oracle.setSource, (asset, IPriceFeed(feed), maxStaleness)), string.concat("price source ", label));
        }
    }

    function _requireLiveFeed(string memory label, address feed, uint32 maxStaleness) internal view {
        console2.log(label, "feed:", IDescribedPriceFeed(feed).description());
        require(IDescribedPriceFeed(feed).aggregator() != address(0), string.concat(label, ": feed must be an aggregator proxy, not a wrapper"));
        (, int256 answer,, uint256 updatedAt,) = IPriceFeed(feed).latestRoundData();
        console2.log(string.concat(label, " answer:"), answer);
        require(answer > 0, string.concat(label, ": feed answer must be positive"));
        uint256 maxAge = maxStaleness > MAX_FEED_AGE ? maxStaleness : MAX_FEED_AGE;
        require(updatedAt != 0 && updatedAt <= block.timestamp && block.timestamp - updatedAt <= maxAge, string.concat(label, ": feed is not live"));
    }

    function _configureVaultTargets() internal {
        AdapterRegistry v2Registry = AdapterRegistry(_deployments.readAddress(".agentWalletV2AdapterRegistry"));
        AdapterRegistry vaultRegistry = AdapterRegistry(_deployments.readAddress(".vaultAdapterRegistry"));
        uint256 count = _count(".vaultTargets");
        for (uint256 i = 0; i < count; i++) {
            string memory label = _config.readString(_at(".vaultTargets", i, "label"));
            address target = _config.readAddress(_at(".vaultTargets", i, "target"));
            require(target != address(0), string.concat(label, ": target is the zero address"));
            require(_indexOf(_vaultTargets, target) == type(uint256).max, string.concat(label, ": target listed twice in vaultTargets"));
            _vaultTargets.push(target);
            (string memory v2AdapterKey, string memory adapterKey) = _vaultAdapterKeys(_config.readString(_at(".vaultTargets", i, "adapter")));
            _setTarget(v2Registry, target, _deployments.readAddress(v2AdapterKey), label);
            _setTarget(vaultRegistry, target, _deployments.readAddress(adapterKey), label);
        }
    }

    function _configureAaveV3Markets() internal {
        uint256 count = _count(".aaveV3Markets");
        for (uint256 i = 0; i < count; i++) {
            string memory label = _config.readString(_at(".aaveV3Markets", i, "label"));
            address collateral = _config.readAddress(_at(".aaveV3Markets", i, "collateral"));
            address debt = _config.readAddress(_at(".aaveV3Markets", i, "debt"));
            require(IAaveV3PoolConfiguration(AAVE_V3_POOL).getConfiguration(collateral) & 0xFFFF != 0, string.concat(label, ": Aave V3 collateral has LTV 0 outside eMode, so supplying it as collateral reverts"));
            require((IAaveV3PoolConfiguration(AAVE_V3_POOL).getConfiguration(debt) >> 58) & 1 == 1, string.concat(label, ": Aave V3 debt reserve has borrowing disabled"));
            _requireNewCollateralVenue(label, keccak256(abi.encode(AAVE_V3_POOL, collateral)));
            _registerMarket(label, ".aaveV3LendingAdapter", abi.encode(AAVE_V3_POOL, collateral, debt, uint8(0)), collateral, debt);
        }
    }

    function _configureAaveV4Markets() internal {
        IAaveV4Spoke spoke = IAaveV4Spoke(AAVE_V4_SPOKE);
        IAaveV4OracleSources spokeOracle = IAaveV4OracleSources(address(spoke.ORACLE()));
        uint256 count = _count(".aaveV4Markets");
        for (uint256 i = 0; i < count; i++) {
            string memory label = _config.readString(_at(".aaveV4Markets", i, "label"));
            uint256 collateralReserveId = _config.readUint(_at(".aaveV4Markets", i, "collateralReserveId"));
            uint256 debtReserveId = _config.readUint(_at(".aaveV4Markets", i, "debtReserveId"));
            address collateral = spoke.getReserve(collateralReserveId).underlying;
            address debt = spoke.getReserve(debtReserveId).underlying;
            require(collateral != address(0) && debt != address(0), string.concat(label, ": Aave V4 reserve does not exist"));
            // The oracle has to value the collateral as the spoke does: for tokenized stocks that is the issuer's
            // total-return feed (one token), never a per-share price
            require(_sourceFeeds[_requireSource(label, collateral)] == spokeOracle.getReserveSource(collateralReserveId), string.concat(label, ": collateral price source must be the Aave V4 spoke oracle's source for that reserve"));
            _requireNewCollateralVenue(label, keccak256(abi.encode(AAVE_V4_SPOKE, collateralReserveId)));
            _registerMarket(label, ".aaveV4LendingAdapter", abi.encode(AAVE_V4_SPOKE, collateralReserveId, debtReserveId), collateral, debt);
        }
    }

    function _configureMorphoMarkets() internal {
        uint256 count = _count(".morphoMarkets");
        for (uint256 i = 0; i < count; i++) {
            string memory label = _config.readString(_at(".morphoMarkets", i, "label"));
            IMorphoBlue.MarketParams memory params = IMorphoBlue.MarketParams({
                loanToken: _config.readAddress(_at(".morphoMarkets", i, "loanToken")),
                collateralToken: _config.readAddress(_at(".morphoMarkets", i, "collateralToken")),
                oracle: _config.readAddress(_at(".morphoMarkets", i, "oracle")),
                irm: _config.readAddress(_at(".morphoMarkets", i, "irm")),
                lltv: _config.readUint(_at(".morphoMarkets", i, "lltv"))
            });
            require(params.irm == MORPHO_ADAPTIVE_IRM, string.concat(label, ": Morpho IRM must be the approved adaptive IRM"));
            (,,,, uint128 lastUpdate,) = IMorphoBlue(MORPHO_BLUE).market(keccak256(abi.encode(params)));
            require(lastUpdate != 0, string.concat(label, ": Morpho market does not exist"));
            console2.log(label, "Morpho oracle price:", IMorphoOracle(params.oracle).price());
            _registerMarket(label, ".morphoBlueLendingAdapter", abi.encode(MORPHO_BLUE, params), params.collateralToken, params.loanToken);
        }
    }

    /// @dev Maps the market and its collateral receipt token (so swap policies never sell it) to the lending adapter
    function _registerMarket(string memory label, string memory adapterKey, bytes memory market, address collateral, address debt) internal {
        require(collateral != debt, string.concat(label, ": collateral and debt assets must differ"));
        _requireSource(label, collateral);
        _requireSource(label, debt);
        _marketCollaterals.push(collateral);
        _marketDebts.push(debt);
        AdapterRegistry borrowRegistry = AdapterRegistry(_deployments.readAddress(".borrowAdapterRegistry"));
        address adapter = _deployments.readAddress(adapterKey);
        address target = AWKLendingAdapter(adapter).marketTarget(market);
        require(_indexOf(_borrowTargets, target) == type(uint256).max, string.concat(label, ": market listed twice"));
        _borrowTargets.push(target);
        _setTarget(borrowRegistry, target, adapter, label);
        address receiptToken = AWKLendingAdapter(adapter).collateralReceiptToken(market);
        if (receiptToken == address(0)) return;
        require(_indexOf(_borrowTargets, receiptToken) == type(uint256).max, string.concat(label, ": collateral receipt token already belongs to another market"));
        _borrowTargets.push(receiptToken);
        _setTarget(borrowRegistry, receiptToken, adapter, string.concat(label, " collateral receipt token"));
    }

    /// @dev Markets on one Aave pool or spoke with the same collateral share its balance and cost basis but not their
    ///      debt, so collateral backing one market's debt could leave through another without that debt being reported
    function _requireNewCollateralVenue(string memory label, bytes32 venue) internal {
        for (uint256 i = 0; i < _collateralVenues.length; i++) {
            require(_collateralVenues[i] != venue, string.concat(label, ": only one market per Aave pool or spoke and collateral"));
        }
        _collateralVenues.push(venue);
    }

    /// @dev A borrowed token that is also some market's collateral lets an operator loop base asset through the 1%
    ///      swap floor without limit, moving each hop to the owner's next wallet with agent transfers
    function _requireNoCollateralDebtCycle() internal view {
        for (uint256 i = 0; i < _marketDebts.length; i++) {
            require(_indexOf(_marketCollaterals, _marketDebts[i]) == type(uint256).max, string.concat("A borrowed token is also a market's collateral, which forms a collateral-to-debt cycle: ", vm.toString(_marketDebts[i])));
        }
    }

    function _requireSource(string memory label, address asset) internal view returns (uint256 index) {
        index = _indexOf(_sourceAssets, asset);
        require(index != type(uint256).max, string.concat(label, ": every market asset needs an entry in priceSources"));
    }

    function _setTarget(AdapterRegistry registry, address target, address adapter, string memory label) internal {
        require(adapter != address(0), string.concat(label, ": adapter is not in deployments.json"));
        bool registeredByPredecessor = _predecessor != bytes32(0) && address(registry) != _deployments.readAddress(".agentWalletV2AdapterRegistry");
        require(registry.isRegisteredAdapter(adapter) || registeredByPredecessor, string.concat(label, ": adapter is not registered; run Deploy.s.sol first, or pass its pending batch as the predecessor"));
        require(!SwapSellPolicy(_deployments.readAddress(".swapSellPolicy")).isSellableToken(target), string.concat(label, ": target is a sellable token on-chain; remove it from the sell list first"));
        address current = registry.getTargetAdapter(target);
        if (current == adapter) return;
        if (current != address(0)) console2.log("   replacing the adapter of", target, current);
        _op(address(registry), abi.encodeCall(registry.setTargetAdapter, (target, adapter)), string.concat(label, " ", vm.toString(target)));
    }

    function _isAnyRegistryTarget(address token) internal view returns (bool) {
        string[3] memory keys = [".agentWalletV2AdapterRegistry", ".vaultAdapterRegistry", ".borrowAdapterRegistry"];
        for (uint256 i = 0; i < keys.length; i++) {
            if (AdapterRegistry(_deployments.readAddress(keys[i])).getTargetAdapter(token) != address(0)) return true;
        }
        return false;
    }

    function _reportDrift() internal {
        SwapSellPolicy sellPolicy = SwapSellPolicy(_deployments.readAddress(".swapSellPolicy"));
        address[] memory configuredTokens = new address[](_count(".sellableTokens"));
        for (uint256 i = 0; i < configuredTokens.length; i++) {
            configuredTokens[i] = _config.readAddress(_at(".sellableTokens", i, "token"));
        }
        address[] memory sellable = sellPolicy.getSellableTokens();
        for (uint256 i = 0; i < sellable.length; i++) {
            if (_indexOf(configuredTokens, sellable[i]) == type(uint256).max) _warn("sellable token not in the config:", sellable[i]);
        }
        address[] memory deployManaged = new address[](4);
        deployManaged[0] = _deployments.readAddress(".aerodromeCL2SwapAdapter");
        deployManaged[1] = _deployments.readAddress(".aerodromeCL3SwapAdapter");
        deployManaged[2] = _deployments.readAddress(".aerodromeCL4SwapAdapter");
        deployManaged[3] = _deployments.readAddress(".agentTransferAdapter");
        _reportRegistryDrift(".agentWalletV2AdapterRegistry", _vaultTargets, new address[](0));
        _reportRegistryDrift(".vaultAdapterRegistry", _vaultTargets, deployManaged);
        address[3] memory lendingAdapters = [_deployments.readAddress(".aaveV3LendingAdapter"), _deployments.readAddress(".aaveV4LendingAdapter"), _deployments.readAddress(".morphoBlueLendingAdapter")];
        AdapterRegistry borrowRegistry = AdapterRegistry(_deployments.readAddress(".borrowAdapterRegistry"));
        address[] memory borrowTargets = borrowRegistry.getAllTargets();
        for (uint256 i = 0; i < borrowTargets.length; i++) {
            bool isLendingTarget = _indexOf(_toArray(lendingAdapters), borrowRegistry.getTargetAdapter(borrowTargets[i])) != type(uint256).max;
            // A hard stop, not a warning: the one-market-per-venue and no-cycle checks only see markets in the config
            require(
                !isLendingTarget || _indexOf(_borrowTargets, borrowTargets[i]) != type(uint256).max,
                string.concat("Borrow market target on-chain is not in the config: ", vm.toString(borrowTargets[i]), "; keep its market in the config, or remove it from the registry first")
            );
        }
    }

    /// @dev Warns about targets of the registry that the config lacks, except those mapped to Deploy.s.sol's own adapters
    function _reportRegistryDrift(string memory registryKey, address[] memory configured, address[] memory skippedAdapters) internal {
        AdapterRegistry registry = AdapterRegistry(_deployments.readAddress(registryKey));
        address[] memory targets = registry.getAllTargets();
        for (uint256 i = 0; i < targets.length; i++) {
            if (_indexOf(configured, targets[i]) != type(uint256).max) continue;
            if (_indexOf(skippedAdapters, registry.getTargetAdapter(targets[i])) != type(uint256).max) continue;
            _warn(string.concat(registryKey, " target not in the config:"), targets[i]);
        }
    }

    function _schedule() internal {
        console2.log("=================================================");
        if (_warnings > 0) console2.log("!! Warnings:", _warnings, "(on-chain entries the config lacks; they are left as they are)");
        if (_targets.length == 0) {
            console2.log("-> Nothing to configure: the chain already matches", CONFIG_PATH);
            return;
        }
        require(_targets.length <= MAX_OPERATIONS, string.concat(vm.toString(_targets.length), " operations exceed the per-batch limit; add the new config entries in more than one run"));
        AdminTimelock timelock = AdminTimelock(payable(_deployments.readAddress(".adminTimelock")));
        uint256 delay = timelock.getMinDelay();
        uint256[] memory values = new uint256[](_targets.length);
        bytes32 salt = keccak256(abi.encode("configure", block.number));
        console2.log("-> Scheduling", _targets.length, "operations in one batch");
        console2.log("-> Batch operation ID:", vm.toString(timelock.hashOperationBatch(_targets, values, _datas, _predecessor, salt)));
        vm.startBroadcast(vm.envUint("DEPLOYER_PRIVATE_KEY"));
        timelock.scheduleBatch(_targets, values, _datas, _predecessor, salt, delay);
        if (delay == 0) {
            timelock.executeBatch(_targets, values, _datas, _predecessor, salt);
            console2.log("-> Executed immediately (zero delay)");
        } else {
            console2.log("-> Execute from the Safe after the delay: ./script/check-timelock.sh");
        }
        vm.stopBroadcast();
    }

    function _op(address target, bytes memory data, string memory label) internal {
        console2.log("   +", label);
        _targets.push(target);
        _datas.push(data);
    }

    function _warn(string memory message, address entry) internal {
        console2.log("!!", message, entry);
        _warnings++;
    }

    function _count(string memory key) internal view returns (uint256 count) {
        while (vm.keyExistsJson(_config, string.concat(key, "[", vm.toString(count), "]"))) count++;
    }

    function _at(string memory key, uint256 index, string memory field) internal pure returns (string memory) {
        return string.concat(key, "[", vm.toString(index), "].", field);
    }

    function _indexOf(address[] memory list, address entry) internal pure returns (uint256) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == entry) return i;
        }
        return type(uint256).max;
    }

    function _toArray(address[3] memory fixedList) internal pure returns (address[] memory list) {
        list = new address[](3);
        for (uint256 i = 0; i < 3; i++) {
            list[i] = fixedList[i];
        }
    }

    /// @return v2AdapterKey The V2 vault registry adapter's key in deployments.json
    /// @return adapterKey The V3 vault registry adapter's key in deployments.json
    function _vaultAdapterKeys(string memory kind) internal pure returns (string memory v2AdapterKey, string memory adapterKey) {
        bytes32 name = keccak256(bytes(kind));
        if (name == keccak256("erc4626")) return (".agentWalletV2Erc4626Adapter", ".erc4626Adapter");
        if (name == keccak256("aaveV3")) return (".agentWalletV2AaveV3Adapter", ".aaveV3Adapter");
        if (name == keccak256("compoundV3")) return (".agentWalletV2CompoundV3Adapter", ".compoundV3Adapter");
        if (name == keccak256("compoundV2")) return (".agentWalletV2CompoundV2Adapter", ".compoundV2Adapter");
        if (name == keccak256("moonwellReward")) return (".agentWalletV2MoonwellRewardAdapter", ".moonwellRewardAdapter");
        if (name == keccak256("merkl")) return (".agentWalletV2MerklAdapter", ".merklAdapter");
        if (name == keccak256("uniswapV3")) return (".agentWalletV2UniswapV3SwapAdapter", ".uniswapV3SwapAdapter");
        if (name == keccak256("aerodromeV2")) return (".agentWalletV2AerodromeV2SwapAdapter", ".aerodromeV2SwapAdapter");
        if (name == keccak256("aerodromeCL")) return (".agentWalletV2AerodromeCLSwapAdapter", ".aerodromeCLSwapAdapter");
        revert(string.concat("Unknown vault target adapter '", kind, "'. Use erc4626, aaveV3, compoundV3, compoundV2, moonwellReward, merkl, uniswapV3, aerodromeV2 or aerodromeCL"));
    }
}
