# Incident response


## Revoking an operator

Wallets cache operators because ERC-4337 validation does not read the factory. Removing an operator in the factory does not clear each wallet's cache until it syncs.

1. Optionally call `pause()` on `vaultAdapterRegistry` and `borrowAdapterRegistry` with `EMERGENCY_ROLE`. A pause blocks adapter execution through that registry, including owner position exits.
2. Call `factory.removeAgentOperator(operator)` with `EMERGENCY_ROLE`. The removal is immediate. Only the timelock admin can add operators.
3. Call `syncFromFactory()` on every V3 wallet. Any account can do this. Check `isAgentOperator(operator)` on each wallet after sync.
4. If either registry was paused, schedule `unpause()` directly on the timelock and execute it after the delay. `Deploy.s.sol` and `Configure.s.sol` can't do it: they read the registry, so they revert while it is paused.
5. Before rerunning `Deploy.s.sol`, set `SERVER_ADDRESS` to the operator that should remain: a rerun grants `SERVER_ADDRESS` again if it is missing. Cancel any scheduled batch that would re-grant a revoked operator.

V2 wallets use the V2 factory and registry. Pause `agentWalletV2AdapterRegistry`, revoke the operator through the timelock, have owners or operators sync the affected wallets, then unpause through the timelock. `Configure.s.sol` reverts until the V2 registry is unpaused.

## Compromised deployer key

The deployer key is a timelock proposer and canceller and an emergency admin of the V3 contracts. If it is compromised:

1. The Safe, as timelock admin, revokes the key's `PROPOSER_ROLE` and `CANCELLER_ROLE` on the timelock. This takes effect at once, and from then on the key can't cancel the Safe's operations.
2. Run `./script/check-timelock.sh` with `DEPLOYER_ADDRESS` set (and, before the factory handover, `SERVER_ADDRESS`) and cancel every pending operation not labelled `Safe`. The script labels an operation `Safe` only when a trace shows that the Safe, and no other account, made the call that emitted its `CallScheduled` event, and warns on any other operation sent through a Safe transaction. Operations the key sent itself are labelled `DEPLOYER_ADDRESS`.
3. At once, schedule one `unpause()` operation for each registry the key can pause (`vaultAdapterRegistry`, `borrowAdapterRegistry`, and `agentWalletV2AdapterRegistry` for keys that hold its role), each on its own. `schedule` doesn't call the target, so this works while the registry is unpaused. Once ready, executing it reverts with `ExpectedPause` and leaves it ready until the registry is paused; then the Safe can undo the pause as soon as its owners sign, without waiting for the delay. Executing it uses it up, so schedule a new one with a fresh salt afterwards. `check-timelock.sh` leaves a ready `unpause()` out of its bundle while its registry isn't paused and bundles at most one per registry.
4. Schedule one batch that revokes the key's `EMERGENCY_ROLE` on `vaultAdapterRegistry`, `borrowAdapterRegistry`, `priceOracle` and, after the handover, the factory, and then makes the re-grants of step 6. krishan711.eth keeps its emergency role, so pausing and operator removal stay available; grant the role to a new key too if krishan711.eth should not be the only one.
   - If step 2 cancelled the `Deploy.s.sol` or `Configure.s.sol` batch before it ran, everything in it is gone, not just the krishan711.eth grants: profile wiring, fee modules and plans, adapters, targets, price sources and markets. A cancelled Deploy batch also leaves a Configure batch scheduled behind it unable to run. Have the Safe grant a new deployer key `PROPOSER_ROLE` and `CANCELLER_ROLE`, then, once no registry is paused, rerun `Deploy.s.sol` with that key and `Configure.s.sol` with the new Deploy batch's ID as predecessor (or without one once that batch has run).
   - If the factory handover hasn't run yet, `check-timelock.sh` leaves it out of the bundle with a warning once the key is no longer a timelock proposer, and leaves out ready operations that call the factory. Have the Safe send the calls `factory-handover.sh <factory> <safe> <timelock> <new emergency admin> <server> <rpc>` prints first.
   - `Deploy.s.sol` makes the deployer an emergency admin of anything it deploys later, so rotate the deployer key too.
5. Until that batch runs, the key can still pause the registries, remove operators, targets and adapters, remove price sources and, if it holds the role on the sell list, remove sell tokens. Owner position exits stay frozen while a registry is paused, until the step 3 operation is ready.
6. Restore anything the key removed with calls scheduled directly on the timelock, in or after the step 4 batch so that the key can't undo them: `grantRole(AGENT_OPERATOR_ROLE, operator)` on the factory and then `syncFromFactory()` on every wallet, `registerAdapter`, `setTargetAdapter`, `setSource`, `addSellableTokens`. `Deploy.s.sol` and `Configure.s.sol` revert while a registry is paused.

## Other compromised keys

- The old deployer `0xF8CBf6437d2473eC59885299Af38D9A13cE97ecA` holds no timelock roles. It still holds `EMERGENCY_ROLE` on the sell list and the V2 vault registry, alongside krishan711.eth once the `Deploy.s.sol` batch has run. If it is compromised, revoke its role on those two contracts in one batch and follow steps 3, 5 and 6 of [Compromised deployer key](#compromised-deployer-key).
- If the krishan711.eth key is compromised, schedule a batch that revokes its `EMERGENCY_ROLE` on the factory, both V3 registries, the price oracle, the sell list and the V2 vault registry, and follow steps 3, 5 and 6 of [Compromised deployer key](#compromised-deployer-key). Before the next `Deploy.s.sol` run, remove or replace `KRISHAN711_ETH` in `Deploy.s.sol`: a rerun grants it again whenever it is missing.

## Emergency target removal and recovery

After an emergency target removal, cancel any scheduled timelock operation that would restore it with `cancel(id)` and `CANCELLER_ROLE`, and repeat the removal in every registry that maps the target or registers the adapter: the V2 vault registry, the V3 vault registry and the borrow registry. The routers, Merkl and the agent-transfer adapter are in the borrow registry too. Scripts can put a removed target back:

- `Configure.s.sol` schedules every entry of `script/config/base.json` that is missing on-chain, so a run puts back a removed vault, market, price source or sellable token unless its entry is taken out of the config first.
- `Deploy.s.sol` schedules its fixed targets again whenever they are missing: the routers, Merkl and agent transfers in the borrow registry, and the CL2, CL3 and CL4 routers and agent transfers in the vault registry.
- `Deploy.s.sol` re-registers any V3 adapter in `deployments.json` that is not registered, so a rerun undoes an emergency unregistration unless that operation is cancelled or the adapter's key is replaced. It never registers V2 adapters.
- After an emergency `unregisterAdapter`, `Configure.s.sol` reverts for every config entry that uses that adapter until it is registered again (by a Deploy rerun for V3 adapters, by `registerAdapter` scheduled directly on the timelock for V2 adapters), or until those entries are taken out of the config.
- `Deploy.s.sol` grants `EMERGENCY_ROLE` to `KRISHAN711_ETH` again wherever it is missing, so a rerun undoes a revocation unless the constant is changed.

After an emergency removal, check the batch a rerun prints and cancel it if it would restore a removed target.

A removed position target can be restored by registering it again through the timelock. The owner or operator can then unwind the position through its adapter; the yield fee uses the target's recorded cost basis. If an adapter was unregistered, registering it again reactivates its previous target mappings. Unregistering an adapter is a pause mechanism, not a permanent target removal.

An unlisted reward token cannot be sold. Add it to `sellableTokens` in `script/config/base.json` and run `Configure.s.sol`, then an operator can sell it for the base asset. Other unaccounted tokens, such as unsolicited airdrops, cannot be withdrawn by the owner and remain in the wallet. A reward token that is itself a registry target, such as another base asset's vault share or aToken, can't be sold even when listed and can't be withdrawn, so it stays in the wallet for good.

