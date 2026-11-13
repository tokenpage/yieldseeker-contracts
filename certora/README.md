# Local Certora verification

These rules run the open-source Certora Prover on this Mac. They do not use Certora Cloud, a Certora API key, or a hosted prover.

## Local toolchain setup

Install the native dependencies with Homebrew, install Rust tools, and select the repository's exact Solidity compiler:

```sh
brew install openjdk@21 z3 llvm rustup
brew tap cvc5/homebrew-cvc5
brew trust cvc5/cvc5
brew install --cask cvc5/cvc5/cvc5
rustup toolchain install stable
rustup default stable
cargo install rustfilt
uv tool install solc-select
solc-select install 0.8.38
solc-select use 0.8.38
```

Clone and build the open-source prover. `certora/env.sh` defaults to `~/Tools/CertoraProver` for the checkout, `~/Tools/certora-build` for `CERTORA` and Homebrew's JDK 21; override them with `CERTORA_PROVER_DIR`, `CERTORA` and `CERTORA_JAVA_HOME`. It does not edit shell startup files.

```sh
git clone --recurse-submodules https://github.com/Certora/CertoraProver.git ~/Tools/CertoraProver
python3 -m venv ~/Tools/CertoraProver/.venv
~/Tools/CertoraProver/.venv/bin/pip install -r ~/Tools/CertoraProver/scripts/certora_cli_requirements.txt
source certora/env.sh
(cd ~/Tools/CertoraProver && ./gradlew assemble)
test -f "$CERTORA/emv.jar"
```

## Running

From the contracts root:

```sh
make prove-certora
```

This runs every configuration in turn. The open-source CLI runs locally when `$CERTORA/emv.jar` exists and no `--server` is given; `env.sh` unsets `CERTORAKEY`, sets `CERTORA_DISABLE_POPUP` and `CERTORA_DISABLE_NOTIFICATION` so no browser window or tray icon opens, and every configuration passes `-enableEventReporting false` so no telemetry is sent. Reports go to `$CERTORA/runs/<conf>-<timestamp>`. To run one configuration:

```sh
source certora/env.sh && certoraRun.py certora/wallet-authorization.conf --build_dir "$CERTORA/runs/wallet-authorization-$(date +%s)"
```

`make prove-certora-mutation` checks the proofs themselves: it runs every configuration against every Gambit mutant of the contracts it verifies, locally, and records which mutants each proof catches (`certora/mutate.sh`; results in `$RESULTS_DIR`, default `/tmp/yieldseeker-certora-mutation`; it resumes if stopped). It reuses the mutants of a previous `make test-mutation` when `MUTANTS_DIR` points at them.

## What is proven

Every rule below verifies on the production compiler settings (`via_ir`, optimiser on), and each property has a `satisfy` witness or positive control showing its scenario can happen, so none passes vacuously. All configurations use `rule_sanity: basic`; a `rule_sanity: advanced` run (tautology, assertion-structure and redundant-`require` checks) found no tautologies and removed every assumption that turned out to be unnecessary. The `invariant_not_trivial_postcondition` countermodels printed for property 4 are expected: they show the invariant is not trivially true.

| Property | Config | Rules | Witnesses |
| --- | --- | --- | --- |
| 1 | `yield-fees.conf` | `yieldFeeChargedEqualsOwedPlusPaid`, `yieldFeePaymentDoesNotExceedLimit`, `yieldFeeStateChangesOnlyThroughTrackerActions` on the real `YieldSeekerYieldFeeModule` | A fee is charged and paid |
| 2 | `yield-fees.conf` | `fullWithdrawalChargesPlanRateOfGainAndClearsBasis` (exactly `ceil(gain × rate / 10,000)`), `halfWithdrawalReleasesHalfTheBasis`, `withdrawalFromAnEmptyPositionIsAllYield`, `depositAddsItsAssetsToCostBasisAndChargesNothing`, `baseAssetClaimsAndRewardSalesAreYield` (other tokens are not), `otherActionsAreNotYield`, `plansAreValidExactlyUpToTheMaximumRate` | A non-zero gain; half the basis released; a base-asset claim |
| 8 | `yield-fees.conf` | `withdrawalAtALossNeverRevertsAndChargesNothing` | — (a liveness rule: asserts the call never reverts) |
| 1, 4 | `borrow-fees.conf` | `borrowFeeChargedEqualsOwedPlusPaid`, `borrowFeePaymentDoesNotExceedLimit`, `borrowFeeStateChangesOnlyThroughTrackerActions`, `nonDebtActionsLeaveDebtAndFeesAlone`, `debtChangeRecordsTheNewDebtTimeAndBorrowedToken` on the real `YieldSeekerBorrowFeeModule` | A debt fee is charged and paid; a borrow and repay in one report |
| 5 | `borrow-fees.conf` | `checkpointChargesPlanRateOnLastDebtForAYear`, `checkpointValuesTheFeeAtTheReportedPrice`, `checkpointKeepsTheLastUsablePrice` | Non-zero debt; a price above 1:1; a zero price keeping the last one |
| 1 | `fee-tracker.conf` | `trackerPaymentDoesNotExceedWalletBalance`: whatever the modules report, `reportAction` reverts or asks for at most the wallet's base asset; `trackerRejectsModuleOverpayment` | A non-zero payment; a forced overpayment reverts |
| 7 | `fee-tracker.conf` | `trackerConfigurationChangesOnlyThroughAuthorisedSetters`: collector, factory, modules and plans change only through the admin's setters, wallet plans only through the factory; `adminSettersStoreWhatTheyAreGiven`; `setFeeModuleAddsNewTypesAndReplacesExistingOnes` | The admin changes the collector and adds a plan; a module is replaced |
| 4 | `borrow-debt-invariant.conf` | `borrowTokenDebtMatchesPositionSum` holds initially and after every method, including `onAction` from any caller | `lastDebt` and `tokenDebt` both change |
| 7 | `wallet-authorization.conf` | `untrustedCallerCannotChangeWalletAuthorityOrReduceBalances` over every non-view wallet method except `syncFromFactory` | An untrusted call reaches each method; the owner can change blocklists, withdraw ETH and withdraw the base asset |
| 7 | `wallet-state-changes.conf` | For any caller: `walletOwnerNeverChanges`, `walletRegistryAndOperatorsChangeOnlyThroughSync`, `walletBlocklistsChangeOnlyByOwner` | A factory sync changes the operator set; an operator runs an adapter |
| 8, 9 | `wallet-state-changes.conf` | `ownerWithdrawalMovesExactlyTheAmount` (never reverts, moves exactly `amount`), `withdrawableBalanceIsTheBaseAssetLessFeesOwed` | — (liveness and exact-value rules) |

## Assumptions and limits

- **Property 7 caller:** "untrusted" means not the owner, an EntryPoint, an operator or the wallet itself. The wallet only calls itself (`settleFeesForWithdrawal`) inside owner and executor flows.
- **Property 7 excludes `syncFromFactory`:** anyone may call it by design; it copies the factory's admin-set registry, operators, tracker and policy. `wallet-state-changes.conf` proves it is the only way they change.
- **Upgrades:** the harness is the implementation contract, not a proxy, so OpenZeppelin's `onlyProxy` makes `upgradeToAndCall` and `upgradeToLatest` revert for every caller here; `wallet-state-changes.conf` excludes them. Upgrade authorization is covered by the Foundry test `testFuzz_attackerCannotCallAnyPrivilegedWalletFunction` on real proxies.
- **Adapters and owner calls:** adapter `execute` calls are summarised as `HAVOC_ALL` and are only reachable behind `onlyExecutors`. `wallet-state-changes.conf` excludes adapter execution and the owner's `execute`/`executeBatch`, which run trusted code inside the wallet, and `initialize`, which always reverts once initialized.
- **External calls in `wallet-state-changes.conf`:** unresolved calls to the factory, tokens and EntryPoint return arbitrary values without calling back into the wallet (the withdrawals are `nonReentrant`; the factory is admin-controlled and only read); token calls go to the mock base asset, fees owed come from a ghost, and the fee tracker reports no payment due, so the withdrawal rule covers withdrawals with no fees to settle (fee settlement is covered by the Foundry tests). `wallet-authorization.conf` does not make these assumptions.
- **Loops:** `fee-tracker.conf` and `wallet-state-changes.conf` use `optimistic_loop` with a bound of 2, so they consider at most two modules, plan words, operators or assets per call.
- **Fee amounts:** the exact-fee rules fix the plan rate (and, for borrow fees, the elapsed time, debt or price) so the solver reasons about one symbolic factor at a time; with all factors symbolic the solver times out. The Foundry fuzz tests and Halmos vary every factor.
- **Harness tracker and wallet:** each fee module harness is its own fee tracker and wallet; `walletPlan` and `baseAsset` lookups are routed to it with `DISPATCHER`. Property 4 summarises fee maths and `walletPlan` because they do not affect debt bookkeeping, and fixes one debt token per market.
