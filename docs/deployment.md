# Deployment and operations


## Environment and roles

Set these environment variables before running deployment scripts:

| Variable | Use |
|---|---|
| `DEPLOYER_PRIVATE_KEY` | Deployer address is a timelock proposer and canceller, and an emergency admin alongside krishan711.eth. |
| `DEPLOYER_ADDRESS` | The deployer's address; `check-timelock.sh` names it as the factory's emergency admin in the handover and checks it is the vault registry's emergency admin and still a timelock proposer. |
| `DEPLOYER_ADDRESS_OLD1` | Optional earlier deployer address; `check-timelock.sh` uses it only to label operations that address proposed. |
| `MULTISIG_ADMIN_ADDRESS` | Safe address used as timelock admin, proposer, canceller and sole executor. The factory's constructor Safe is the constant `FACTORY_ROOT_SAFE` in `Deploy.s.sol`, not this variable, so a different team Safe on another chain doesn't change wallet addresses. |
| `SERVER_ADDRESS` | Address granted `AGENT_OPERATOR_ROLE`. `check-timelock.sh` requires it to be an operator of the V2 factory before handing it the V3 factory's operator role. |
| `FEE_COLLECTOR_ADDRESS` | Receives collected fees. |
| `RPC_NODE_URL_8453` | Base RPC endpoint. |
| `RPC_ARCHIVE_NODE_URL_8453` | Archive RPC used by `script/check-timelock.sh`. It must support `debug_traceTransaction` with `callTracer` and `withLog`; without it, operations sent through Safe transactions show as unverified. |
| `ETHERSCAN_API_KEY` | Optional verification key for `--verify`. |

`Deploy.s.sol` sets the timelock delay to four days and makes the deployer and krishan711.eth emergency admins: the deployer through the constructors and the factory handover, krishan711.eth through `grantRole` in the configuration batch. The Safe and deployer can propose and cancel operations; the Safe executes them. To add a proposer, the Safe grants `PROPOSER_ROLE` and `CANCELLER_ROLE` to that address on the timelock. The grants take effect immediately. Use `revokeRole` to remove them. The Safe's timelock admin role can grant or revoke these roles directly.

## Deploy

`Deploy.s.sol` reads and updates `deployments.json`. It:

- deploys missing V3 contracts and saves their addresses;
- wires factory profiles and fee trackers, and grants `SERVER_ADDRESS` if it is not already an operator;
- schedules configuration as one timelock batch, including `setFeeCollector` when a tracker's collector differs;
- registers the profile adapters, shared swap adapters and agent-transfer adapter, and maps the targets it owns: the CL2, CL3 and CL4 routers and agent transfers in the vault registry, and the routers, Merkl and agent transfers in the borrow registry;
- grants `EMERGENCY_ROLE` to krishan711.eth wherever it is missing, including on the V2 vault registry. Otherwise it does not deploy or reconfigure the V2 system, which remains under `agentWalletV2*` keys.

Everything else the registries, price oracle and sell list hold comes from `script/config/base.json` through `Configure.s.sol` (see [Configure](#configure-vaults-sellable-tokens-price-sources-and-borrow-markets)).

```bash
forge script script/Deploy.s.sol:DeployScript --rpc-url "$RPC_NODE_URL_8453" --broadcast --verify
```

Before a production run, use `./script/dry-run-deploy.sh`. It runs `Deploy.s.sol` on a local Base fork and has the Safe hand the factory over, schedules `Configure.s.sol` with the Deploy batch as predecessor, warps past the delay, executes both batches as the Safe and requires a second run of each script to schedule nothing. It fails if:

- Configure reports an on-chain entry the config lacks or would move a target to another adapter;
- the handover and both batches together use more than 15,000,000 gas (they share one Safe transaction in production, under Base's 16,777,216 cap; the launch took about 10,000,000);
- the factory isn't at the address computed from the Safe and its bytecode, or its roles didn't end with the timelock, the server, the deployer and krishan711.eth.

It sends the Safe's calls one by one, so it does not exercise the Transaction Builder bundle that `check-timelock.sh` writes. It restores `deployments.json`, `broadcast/Deploy.s.sol` and `broadcast/Configure.s.sol` afterwards. It requires `anvil`, `cast`, `forge`, `jq` and `RPC_NODE_URL_8453`.

In production, the scripts schedule timelock operations. Wait for the four-day delay, then execute the emitted calls from the Safe. Use `./script/check-timelock.sh` to list operations and build Safe Transaction Builder instructions for ready operations:

- It rebuilds execute calls from timelock events in the order they were scheduled, including operations proposed by the Safe.
- It leaves out, as "ready but left out", any ready operation that would make the whole Safe transaction revert: one with an `unpause()` of a registry that isn't paused, a second `unpause()` of a registry already in the bundle, or, while the factory handover can't be bundled, a call to the factory. It warns when the bundle unpauses a registry.
- While the Safe still holds the V3 factory's roles, it puts the factory handover first in the same bundle. It then also needs `DEPLOYER_ADDRESS` and `SERVER_ADDRESS`, and leaves the handover out with a warning unless `DEPLOYER_ADDRESS` is the emergency admin of the V3 vault registry and still a timelock proposer and `SERVER_ADDRESS` is a V2 factory operator.
- It requires `cast`, `jq`, `RPC_NODE_URL_8453` and `RPC_ARCHIVE_NODE_URL_8453`.

## Same wallet address on every chain

A wallet's address depends only on the factory address, the owner and the owner's agent index. `Deploy.s.sol` creates the factory through the CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` with salt `0x711`, passing `FACTORY_ROOT_SAFE` (the Safe `0x403E…2fEa`) as admin, emergency admin and operator. The factory address therefore depends only on that Safe's address and the factory bytecode, not on the deployer key, the chain's timelock, its team Safe or the server. Every chain where the factory is deployed this way gives `(owner, index)` the same wallet address. If someone else deploys the same factory there first, `Deploy.s.sol` reuses it: its roles are still the Safe's.

The Safe then hands the factory over in one Safe transaction: it grants the admin role to that chain's timelock, the operator role to `SERVER_ADDRESS` and the emergency role to the deployer, and gives up all three (`script/factory-handover.sh` lists the calls and refuses a timelock address with no code). `check-timelock.sh` bundles these calls ahead of the deployment's timelock batch, which needs the timelock to be the factory admin. Wallets can't be created until the handover.

To keep that true:

- The Safe must exist at the same address on the new chain. Safe{Wallet} can add the Safe to another network: it recreates the Safe from its original setup, with its original owners and threshold. Owners changed on Base afterwards don't carry over, so enough of the original owners to meet the threshold must still be able to sign on the new chain. See [The Safe's original setup](#the-safes-original-setup).
- The CREATE2 deployer `0x4e59b44847b379578588920cA78FbF26c0B4956C` must exist on the new chain; `Deploy.s.sol` refuses to run without it.
- Deploy from the same factory bytecode. `foundry.toml` turns off compiler metadata (`bytecode_hash = "none"`, `cbor_metadata = false`), so comments and file paths don't change it. The factory's bytecode comes from `AgentWalletFactory.sol`, `AWKAgentWalletFactory.sol` (including the embedded `AWKAgentWalletProxy`), the OpenZeppelin code they use, the `AWKErrors` errors they use, the selectors of the wallet and tracker functions they call, and the compiler version and settings; changing a wallet function's body doesn't change it. Build with the same command as on Base, compute the predicted factory address and compare it with Base's before deploying a new chain.
- The wallet implementation, registries, trackers and adapters can differ per chain.

If a user sends tokens to their wallet's address on a chain where it doesn't exist yet, recreate the Safe there, deploy the V3 contracts, and create the wallet for the same owner and index with the stranded token as its base asset. The owner can then withdraw it, provided the owner can act on that chain: an EOA key, or a contract owner that also exists at its address there. Only one token per `(owner, index)` can be the base asset; another stranded ERC20 is not accounted, so the owner can't withdraw it. Native ETH can always be withdrawn. Create the recovery wallet as soon as the operator is set up there: whoever creates it first picks the base asset (see [Known risks](security.md#known-risks-accepted)).

The scripts only support Base today. A new chain needs its protocol addresses in `Deploy.s.sol` (routers, Merkl and the sequencer feed), its own deployments file, and a `check-timelock.sh` for its timelock and Safe; its timelock address will differ from Base's. `YieldSeekerPriceOracle` needs an L2 sequencer uptime feed, which Ethereum mainnet doesn't have. zkSync Era is not supported: its CREATE2 addresses and bytecode differ from other EVM chains.

### The Safe's original setup

The Safe `0x403EE3392A40D017a009384D1bE1a2Ca921C2fEa` was created on Base in transaction `0x45dbf6a7237f8547cdf855eaf92cd71700a5b98ee7acf15b570fc065efa2e017` by calling `createProxyWithNonce` on the Safe proxy factory `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67`:

| Field | Value |
|---|---|
| Singleton | `0x41675C099F32341bf84BFc5382aF534df5C7461a` (Safe 1.4.1) |
| Owners | `0xdCf1220Cd53506B1e7137bffC2b8814C6Cc24421`, `0xF3A535cEdf65cB8C287Cb5CAc67E970E94eb372D` |
| Threshold | `2` |
| Setup call | `0xBD89A1CE4DDe368FFAB0eC35506eEcE0b1fFdc54` with `0xfe51f643` (`setupToL2`) for the L2 singleton `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` |
| Fallback handler | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` |
| Payment token, payment, payment receiver | `0x0`, `0`, `0x5afe7A11E7000000000000000000000000000000` |
| Salt nonce | `0` |

Replaying that call with the same arguments creates the Safe at the same address on any chain where these contracts exist; in November 2026 they existed on Ethereum, Optimism, Arbitrum and Polygon, and the replay's address was checked to match. The new copy starts with these two owners at threshold 2, whatever the Base Safe's owners are by then. Both owner keys must therefore stay available for good, even after they are removed from the Base Safe: keep their seed phrases backed up in separate places. Owners added later play no part in any address.

To deploy on a new chain:

1. Recreate the Safe there, with Safe{Wallet}'s "add another network" or by replaying the call above. Anyone can send it.
2. Run `Deploy.s.sol` on that chain with any deployer key. Check that the factory lands at the same address as on Base.
3. The two original owners sign that chain's factory handover, then add the owners and threshold the team uses by then.

## Two vault registries

V2 wallets use `agentWalletV2AdapterRegistry`, V2 adapters and the legacy V2 fee tracker. V3 vault wallets use `vaultAdapterRegistry`, V3 adapters and the V3 vault fee tracker. One registry maps a target to one adapter, so the V2 and V3 vault adapters cannot share a registry. Until all V2 wallets have moved to V3, the two registries must contain the same vault targets, except Moonwell: `mUSDC` and the Moonwell comptroller are mapped in the V2 registry only, because V3 has no Compound V2 or Moonwell adapters.

- `Configure.s.sol` maps every `vaultTargets` entry in both registries, to the V2 and the V3 adapter of its kind, in one timelock batch. The V2-only kinds `compoundV2` and `moonwellReward` are mapped in the V2 registry alone.
- Both profile policies read the same `swapSellPolicy` sell-token list.
- Repeat emergency target removals in every registry that maps the target, including the borrow registry.
- The V3 vault and borrow registries map the agent-transfer adapter to itself as a target. The V2 registry does not.

## Configure: vaults, sellable tokens, price sources and borrow markets

`script/config/base.json` is the desired state of everything routine: `sellableTokens`, `priceSources`, `vaultTargets` (vaults, Merkl and the first-generation routers that both vault registries map, plus the Moonwell market and comptroller, which only the V2 registry maps), `aaveV3Markets`, `aaveV4Markets` and `morphoMarkets`. To add a vault, a reward token, a feed or a market, add an entry and run:

```bash
forge script script/Configure.s.sol:ConfigureScript --rpc-url "$RPC_NODE_URL_8453" --broadcast
```

It compares every entry with the chain and schedules only what is missing or different, as one timelock batch of at most 130 operations (about 75,000 gas each; add larger changes over several runs). With nothing to do it schedules nothing. It never removes anything.

- It prints a `!!` warning for each sellable token, and each target of the V2 or V3 vault registry, on-chain that the config lacks. The V3 vault registry check skips targets mapped to Deploy's own adapters, targets of unregistered adapters don't show, and price sources aren't checked because the oracle can't list them.
- A borrow market on-chain that the config lacks (a borrow registry target of one of the three borrow adapters) stops the run instead, since the market rules below only see markets in the config: keep a market in the config until an emergency removal has taken its target out of the registry. Removal is an emergency-role action, and a run schedules again any entry still in the config, so take an entry out of the config when it is removed in an emergency.
- It reverts while any of the three registries is paused, and refuses a config with an unknown section.

At launch, schedule it straight after `Deploy.s.sol`, with the Deploy batch's operation ID (Deploy prints it) as predecessor: `--sig "run(bytes32)" <DEPLOY_BATCH_ID>`. The predecessor must be a pending timelock operation; V3 adapters that are not registered yet then count as registered (V2 adapters must already be), and the timelock runs the Configure batch only after the Deploy batch, so launch needs one delay, not two. Pass only the Deploy batch that registers those adapters. `dry-run-deploy.sh` runs exactly this on a fork.

Before scheduling, it checks:

- **Sellable tokens:** nonzero, not a target in any registry on-chain or in the config, and `allowSellingAllTokens` off; in the other direction, no new target may be a token that is sellable on-chain. Never set `allowSellingAllTokens`: swap policies reject registry targets, but an allow-all list would let an operator sell any other token a wallet holds with no price floor.
- **Price sources:** a new or changed feed must be an aggregator proxy (`aggregator()` nonzero) with a positive answer, updated within the last four days (or the source's staleness limit, if longer). Four days covers the longest US market closure, so tokenized-stock feeds pass over a weekend; the oracle enforces each source's own staleness limit on every read. `YieldSeekerPriceOracle` also checks answer validity, timestamp and L2 sequencer status on each read and rejects prices during a sequencer outage and for one hour after recovery.
- **Vault targets:** the adapter kind is one of `erc4626`, `aaveV3`, `compoundV3`, `merkl`, `uniswapV3`, `aerodromeV2`, `aerodromeCL`, or the V2-only `compoundV2` and `moonwellReward` (mapped in the V2 registry only), and the adapters are registered (or, for the V3 adapter, the predecessor registers it).
- **Borrow markets:** it builds the canonical market bytes itself and pins the Base Aave V3 pool (eMode `0`), the Aave V4 spoke, and Morpho Blue with its adaptive IRM. It requires:
  - an Aave V3 collateral LTV above zero outside eMode and borrowing enabled on the debt reserve;
  - an existing Morpho market;
  - distinct collateral and debt assets, and a `priceSources` entry for both;
  - one market per Aave pool or spoke and collateral;
  - no borrowed token that is also some market's collateral;
  - for Aave V4, a collateral source equal to the spoke oracle's source for that reserve: for tokenized stocks that is the issuer's total-return feed.

  These market checks run on every run, so an Aave parameter change that breaks one blocks the run until the config is updated. `marketTarget(market)` is the hash-derived target for that encoded market. The same batch maps the market's collateral receipt token, if any, to the same adapter, so swap policies never sell it; the borrow adapter rejects it as a call target (`MarketTargetMismatch`).

Price source settings:

| Asset | Staleness limit |
| --- | --- |
| WETH, cbBTC, cbETH | `3600` seconds |
| USDC, cbXRP, cbZEC, SOL, cbHYPE | `90000` seconds |
| Tokenized stocks (MAG7 and SPCXc) | `43200` seconds |

- Tokenized-stock feeds follow 24/5 trading and update on price moves; on Base (November 2026) weekday gaps reached about 7.6 hours and the weekend gap about 53 hours. The 12-hour limit keeps base-asset swaps working on weekdays and stops them over the weekend, when the price is unknown.
- The cbXRP, cbZEC, SOL and cbHYPE feeds have a 24-hour heartbeat and a 0.5% deviation threshold, like USDC's, so the borrow swap floor can lag the market by up to that threshold. Each uses the proxy that reads the same aggregator as its Morpho market's oracle, so the floor and the market's liquidation price move together.
- These values are deployment settings, not contract constants; recheck feed behaviour before changing them.
- Every feed should be USD-denominated: `quote` divides one asset's USD price by the other's. Use the raw aggregator feed rather than a protocol wrapper that can cap an answer or rewrite its timestamp.
- The tokenized-stock feeds are the "Coinbase <TICKER>" total-return feeds the Aave V4 spoke oracle uses: they price one token (share price × the token's multiplier), not one share, so never use a plain per-share equity feed for them.

The launch config borrows USDC against WETH and cbBTC on Aave V3 and Morpho Blue (LLTV 0.86), against cbETH on Aave V3 and Morpho Blue (LLTV 0.77), against cbXRP, cbZEC, SOL and cbHYPE on Morpho Blue (LLTV 0.625), and against the MAG7 (Aave V4 reserves 0-6) and SPCXc (reserve 8) on Aave V4. SPCXc was listed in October 2026 on harsher terms than the MAG7: 55% collateral factor, 6.5% liquidation bonus and a 10% collateral risk premium on the debt it backs. In November 2026 the cbHYPE market had about $74k of USDC free to borrow and its deepest pool held about $193k, so keep cbHYPE positions small.

Apply these configuration rules; `Configure.s.sol` enforces the first, second and fourth, and does not detect breaches of the third:

- Register no more than one market per `(pool or spoke, collateral)`. Markets on the same Aave pool or spoke and collateral share one collateral balance and cost basis (`collateralPosition`) but keep separate debt positions, so collateral backing one market's debt could leave through another without that debt being reported, and its borrow fee would go uncharged. Aave V4 markets on the same spoke and debt reserve share one debt position (`debtPosition`); give Aave V4 reserves of the same token the same price source, since a shared debt position is valued at the price of whichever market reports it.
- Aave V3 uses eMode `0`. `Configure.s.sol` only builds eMode `0` markets, and `YieldSeekerAaveV3BorrowAdapter` reverts with `EModeNotAllowed` if another category reaches it. USDC has LTV 0 on Base, so it can't be Aave V3 collateral there.
- Do not register a base-asset Aave V3 vault in the borrow registry. It would share the aToken balance with the lending markets on that pool in the same way.
- Do not configure collateral-to-debt cycles, including opposite pairs or longer loops. Each base-to-borrowed swap can lose up to 1% against the oracle, and a cycle repeats that on every hop. Agent transfers move each hop's output to the wallet that sells it next, so a compromised operator can go round the cycle without limit: about 2% per round trip on an opposite pair, compounding until the wallets on the cycle are drained. The launch config borrows only USDC against non-USDC collateral and forms no cycle.

Execute the emitted batch from the Safe after the timelock delay (`./script/check-timelock.sh`).

## Aerodrome Slipstream routers

Aerodrome Slipstream has four pool factories, each with its own router. `YieldSeekerAerodromeCLSwapAdapter` takes its router in the constructor, so `Deploy.s.sol` deploys it once per router (`aerodromeCLSwapAdapter`, `aerodromeCL2SwapAdapter`, `aerodromeCL3SwapAdapter`, `aerodromeCL4SwapAdapter`). It maps the CL2, CL3 and CL4 routers in both V3 registries and the first router in the borrow registry; `Configure.s.sol` maps the first router in both vault registries. Routes may use any tick spacing the router's factory enabled.

The tokenized-stock pools are at spacing 10 on two factories. In November 2026 the fourth (`0x9CB2…`, router `0x9eE3…d418`) held most of their liquidity: about $290k to $580k of USDC per pool against $11k to $47k on the third. `test/fork/SwapFork.t.sol` swaps through the third router at spacing 10 and through the fourth router's WETH/USDC pool, since tokenized stocks can't run in a fork.

## Selective redeployment

Set a contract's address to `0x0000000000000000000000000000000000000000` in `deployments.json` and rerun `Deploy.s.sol` to redeploy a stateless adapter, swap policy or wallet implementation after its code or constructor arguments changed. Contracts are created through CREATE2, so unchanged init code gives the same address, and the script reuses the contract already there instead of deploying a new one. An address in `deployments.json` with no code, which a failed or simulated run can leave behind, counts as not deployed.

The script refuses to replace a registry, fee tracker or fee module already used by a factory or tracker. Those contracts hold per-wallet or per-target state; replace them deliberately through the timelock after planning state import. The sell list (`swapSellPolicy`, also used by the V2 swap adapters) and the price oracle hold configuration too: a new one starts empty, so add its tokens or sources again before the swap policies use it.

Don't rerun `Deploy.s.sol` while its previous configuration batch is still pending. The rerun schedules the same operations again, and executing both batches adds a second copy of each default fee plan, which can't be removed. If it happens, cancel the second batch with `CANCELLER_ROLE`.

A redeployed adapter is registered by `Deploy.s.sol`, which also moves its own fixed targets (routers, Merkl and agent transfers) to it. Vault targets and borrow markets belong to `Configure.s.sol`: after replacing an adapter, rerun it and execute the emitted batch; it moves every configured vault target and market of that kind, including each collateral receipt token. The old adapter remains registered until the emergency role unregisters it from each V3 registry that used it. Unregistering preserves target mappings, so re-registering the old adapter would reactivate them.


## Upgrading wallets and profile configuration


The timelock admin sets the implementation with `factory.setAgentWalletImplementation(newImplementation)`. A deployed wallet does not upgrade automatically. Its owner calls `upgradeToLatest()` or `upgradeToAndCall`; the target must equal the factory's current implementation. `upgradeToLatest()` runs `syncFromFactory()` through the upgrade call, so the new implementation performs the sync.

The timelock admin can replace an agent profile's registry, fee tracker or swap policy with `setAdapterRegistry`, `setFeeTracker` or `setSwapPolicy`. Existing wallets copy the new addresses at their next `syncFromFactory()`. Anyone can trigger that sync. Registry adapter and target changes apply through live lookups and need no wallet sync.

