# Changelog

## Unreleased

### Agent wallet V3, profiles and borrow agents

- `AWKAgentWalletFactory` / `YieldSeekerAgentWalletFactory` (edited in place): each wallet has a profile (agent type) with its own adapter registry and fee tracker. `setAdapterRegistry` / `setFeeTracker` take a profile; `adapterRegistry()` and `feeTracker()` answer for the calling wallet's profile, so wallets sync with the unchanged V2 code. Fee trackers must report `IYieldSeekerFeeModule` via ERC-165. The deployed versions moved unchanged to `src/_old/`.
- Added `YieldSeekerAgentWalletV3` (`YieldSeekerAgentWalletV2` with two overrides): the fee tracker is set at creation and never re-synced, and the fee tracker's `withdrawable()` decides what the owner may withdraw. No storage changes. Only deploy it for the profile factory.
- `YieldSeekerFeeTracker` (edited in place): fee rate per wallet owner via `YieldSeekerFeePlans` (the plan manager can only lower a user's rate) and `withdrawable()`; accounting unchanged. The deployed version moved unchanged to `src/_old/FeeTracker.sol`. Added `YieldSeekerBorrowFeeModule` (yearly fee on borrowed principal per market, charged on the debt seen at the previous report, interest-first repayments, paid in the borrowed token; no fee on rewards).
- Added AWK lending adapters (Aave V3, Aave V4, Morpho Blue). Each market is its own registry target (`marketTarget(market)` = hash of the market bytes), so every market needs a timelocked registration. YieldSeeker versions require collateral = base asset and settle borrow fees on repay and collateral withdrawal.
- Added `YieldSeekerPairSwapAdapter` (Uniswap V3, Aerodrome V2/CL): base asset → a token the wallet borrowed only, at most `MAX_SLIPPAGE_BPS` below the oracle; reward tokens → base asset via a sell policy.
- Added `YieldSeekerPriceOracle` (Chainlink-style feeds, per-asset staleness, L2 sequencer uptime check).
- Added `AWKWalletLinkRegistry` and `AWKTransferAdapter` / `YieldSeekerTransferAdapter`: owner-linked transfers between wallets of the same owner recorded by the same factory; both wallets' fee contracts must allow the token.
- Added `AWKAgentWalletV3` (`AWKAgentWalletV2` that also runs without a factory: owner-set registry and operators, owner-chosen upgrades). Not used by YieldSeeker wallets.
- Added `script/DeployV3.s.sol` (deploys the stack and schedules one timelock batch). The old factory, FeeTracker and V1/V2 wallets are unchanged; existing users move to new wallets by withdrawing to the new wallet address.

### Agent wallet V2

- Added `AWKAgentWalletV2` and `YieldSeekerAgentWalletV2` with EntryPoint-relayed owner actions.
- Blocklist management, ERC20/ETH withdrawals, synchronization, and UUPS upgrades can be paymaster-relayed; owner signatures remain required.
- Operator signatures remain limited to adapter execution.
- Added `AgentWalletStorageV2` as an explicit facade over the unchanged V1 storage layout.
- Existing V1 wallets retain their state when upgraded; V1 implementation behavior remains unchanged.
