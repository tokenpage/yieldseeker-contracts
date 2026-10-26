# Changelog

## Unreleased

### Agent wallet V3, agent profiles and borrow agents

- `AWKAgentWalletFactory` / `YieldSeekerAgentWalletFactory`: each wallet has an agent profile (its agent type) that selects its adapter registry. `setAdapterRegistry(agentProfile, registry)` sets it and `adapterRegistry(agentProfile)` reads it; wallets store their agent profile at `initialize` (fixed for life) and read their registry with it when they sync. The fee tracker stays a single factory setting and must report `IYieldSeekerFeeModuleHost` via ERC-165. Deployed as a new factory; the V2 factory stays live.
- `AWKAgentWalletV3` / `YieldSeekerAgentWalletV3` replace V2 (same storage): the fee tracker is pinned at creation, the tracker's `withdrawReserve()` decides which tokens the owner may withdraw and how much stays for fees, and AWK wallets can also run without a factory (owner-set registry and operators). V1/V2 wallets on the V2 factory are unchanged.
- Removed the V1 wallet sources (`AWKAgentWalletV1.sol`, `AgentWalletV1.sol`) and the V2 storage facade. `AgentWalletStorageV3` keeps the V1 namespace and appends `agentProfile`; `YieldSeekerStorageV1` and the V1 errors now live in the V3 files; `IAWKAgentWalletFactory` no longer has the parameterless `adapterRegistry()`.
- `YieldSeekerFeeTracker` is now a router over pluggable fee modules: plans give each owner a rate per fee type (the plan manager can only move owners to cheaper plans), modules are add-only, and `withdrawReserve()` combines every module (each called with a gas limit; a failing module counts as allowing nothing, and the base asset can always leave). The audited vault accounting moved unchanged into `YieldSeekerVaultFeeModule` (`VAULT_FEE`), created by the tracker, which forwards the original tracker interface to it so the existing vault adapters keep working. Reward fees still owed in a token are held back in that token, and they now apply to every agent type. Added `YieldSeekerBorrowFeeModule` (`BORROW_FEE`: yearly fee on borrowed principal per market, charged on the debt seen at the previous report, interest-first repayments, paid in the borrowed token).
- Added AWK lending adapters (Aave V3, Aave V4, Morpho Blue). Each market is its own registry target (`marketTarget(market)` = hash of the market bytes), so every market needs a timelocked registration. YieldSeeker versions require collateral = base asset and settle borrow fees on repay and collateral withdrawal.
- Swap adapters (Uniswap V3, Aerodrome V2/CL) now share `YieldSeekerSwapAdapter`: reward tokens → base asset as before, plus base asset → a token a fee module accounts for in the wallet (e.g. a borrowed token), at most `MAX_SLIPPAGE_BPS` below the oracle and never spending base asset held back for fees. New instances are deployed for the borrow registry only; the vault registry keeps its deployed swap adapters.
- Added `YieldSeekerPriceOracle` (Chainlink feeds, per-asset staleness, L2 sequencer uptime check).
- Added `YieldSeekerWalletLinkRegistry` and `YieldSeekerAgentTransferAdapter`: owner-linked transfers between agent wallets of the same owner and factory; both wallets' trackers must allow the token.
- `script/Deploy.s.sol` deploys the new contracts and schedules one timelock batch that wires the factory, tracker, fee modules and the borrow registry (routers, Merkl, wallet links). The vault registry is unchanged apart from the wallet-link transfer target, so new vaults are still registered once with `RegisterVault.s.sol`. Borrow markets and price feeds are registered with `RegisterBorrowMarket.s.sol` (decodes and validates the market) and `SetPriceSource.s.sol` (checks the feed). `deployments.json` keeps the V2 factory, implementation and FeeTracker under `agentWalletV2*` keys; existing users move to new wallets by withdrawing to the new wallet address.

### Agent wallet V2

- Added `AWKAgentWalletV2` and `YieldSeekerAgentWalletV2` with EntryPoint-relayed owner actions.
- Blocklist management, ERC20/ETH withdrawals, synchronization, and UUPS upgrades can be paymaster-relayed; owner signatures remain required.
- Operator signatures remain limited to adapter execution.
- Added `AgentWalletStorageV2` as an explicit facade over the unchanged V1 storage layout.
- Existing V1 wallets retain their state when upgraded; V1 implementation behavior remains unchanged.
