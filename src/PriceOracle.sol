// SPDX-License-Identifier: MIT
//
//   /$$     /$$ /$$           /$$       /$$  /$$$$$$                      /$$
//  |  $$   /$$/|__/          | $$      | $$ /$$__  $$                    | $$
//   \  $$ /$$/  /$$  /$$$$$$ | $$  /$$$$$$$| $$  \__/  /$$$$$$   /$$$$$$ | $$   /$$  /$$$$$$   /$$$$$$
//    \  $$$$/  | $$ /$$__  $$| $$ /$$__  $$|  $$$$$$  /$$__  $$ /$$__  $$| $$  /$$/ /$$__  $$ /$$__  $$
//     \  $$/   | $$| $$$$$$$$| $$| $$  | $$ \____  $$| $$$$$$$$| $$$$$$$$| $$$$$$/ | $$$$$$$$| $$  \__/
//      | $$    | $$| $$_____/| $$| $$  | $$ /$$  \ $$| $$_____/| $$_____/| $$_  $$ | $$_____/| $$
//      | $$    | $$|  $$$$$$$| $$|  $$$$$$$|  $$$$$$/|  $$$$$$$|  $$$$$$$| $$ \  $$|  $$$$$$$| $$
//      |__/    |__/ \_______/|__/ \_______/ \______/  \_______/ \_______/|__/  \__/ \_______/|__/
//
//  Grow your wealth on auto-pilot with DeFi agents
//  https://yieldseeker.xyz
//
//  For technical queries or guidance contact @krishan711
//
pragma solidity 0.8.28;

import {AWKErrors} from "./agentwalletkit/AWKErrors.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

error NoPriceSource(address asset);
error InvalidPrice(address asset, int256 answer);
error StalePrice(address asset, uint256 updatedAt, uint256 maxStaleness);
error SequencerDown();

/// @notice Chainlink-style price feed (Aave V3 and V4 oracle sources implement this)
interface IPriceFeed {
    function decimals() external view returns (uint8);
    function latestRoundData() external view returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

interface IYieldSeekerPriceOracle {
    /// @notice USD price of one whole token, scaled to 1e18
    function getPrice(address asset) external view returns (uint256);

    /// @notice Value of `amount` of `fromToken` expressed in `toToken` units
    function quote(address fromToken, address toToken, uint256 amount) external view returns (uint256);
}

/**
 * @title YieldSeekerPriceOracle
 * @notice USD prices per asset from Chainlink-style feeds, with a per-asset staleness limit
 * @dev Used to bound swap outputs and to value fees owed in another token. The admin (timelock) sets
 *      sources; the emergency role can remove a source, which makes dependent operations revert.
 *      Prices revert while the L2 sequencer is down and for SEQUENCER_GRACE_PERIOD after it comes back.
 */
contract YieldSeekerPriceOracle is AccessControl, IYieldSeekerPriceOracle {
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    IPriceFeed public immutable SEQUENCER_UPTIME_FEED;

    struct PriceSource {
        IPriceFeed feed;
        uint32 maxStaleness;
    }

    mapping(address asset => PriceSource) public sources;

    event PriceSourceSet(address indexed asset, address indexed feed, uint32 maxStaleness);
    event PriceSourceRemoved(address indexed asset);

    constructor(address admin, address emergencyAdmin, IPriceFeed sequencerUptimeFeed) {
        if (admin == address(0) || emergencyAdmin == address(0) || address(sequencerUptimeFeed) == address(0)) revert AWKErrors.ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(EMERGENCY_ROLE, emergencyAdmin);
        SEQUENCER_UPTIME_FEED = sequencerUptimeFeed;
    }

    function setSource(address asset, IPriceFeed feed, uint32 maxStaleness) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (asset == address(0) || address(feed) == address(0)) revert AWKErrors.ZeroAddress();
        if (maxStaleness == 0) revert AWKErrors.ZeroAmount();
        sources[asset] = PriceSource({feed: feed, maxStaleness: maxStaleness});
        emit PriceSourceSet(asset, address(feed), maxStaleness);
    }

    function removeSource(address asset) external onlyRole(EMERGENCY_ROLE) {
        delete sources[asset];
        emit PriceSourceRemoved(asset);
    }

    function getPrice(address asset) public view returns (uint256) {
        (, int256 sequencerStatus, uint256 sequencerUpSince,,) = SEQUENCER_UPTIME_FEED.latestRoundData();
        if (sequencerStatus != 0 || sequencerUpSince == 0 || block.timestamp < sequencerUpSince + SEQUENCER_GRACE_PERIOD) revert SequencerDown();
        PriceSource memory source = sources[asset];
        if (address(source.feed) == address(0)) revert NoPriceSource(asset);
        (, int256 answer,, uint256 updatedAt,) = source.feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(asset, answer);
        if (block.timestamp > updatedAt + source.maxStaleness) revert StalePrice(asset, updatedAt, source.maxStaleness);
        return Math.mulDiv(uint256(answer), 1e18, 10 ** source.feed.decimals());
    }

    function quote(address fromToken, address toToken, uint256 amount) external view returns (uint256) {
        uint256 fromValue = Math.mulDiv(amount, getPrice(fromToken), 10 ** IERC20Metadata(fromToken).decimals());
        return Math.mulDiv(fromValue, 10 ** IERC20Metadata(toToken).decimals(), getPrice(toToken));
    }
}
