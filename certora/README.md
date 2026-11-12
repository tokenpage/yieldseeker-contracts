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

This runs every configuration in turn. The open-source CLI runs locally when `$CERTORA/emv.jar` exists and no `--server` is given; `env.sh` unsets `CERTORAKEY`, and every configuration passes `-enableEventReporting false` so no telemetry is sent. Reports go to `$CERTORA/runs/<conf>-<timestamp>`. To run one configuration:

```sh
source certora/env.sh && certoraRun.py certora/wallet-authorization.conf --build_dir "$CERTORA/runs/wallet-authorization-$(date +%s)"
```


## What is proven

Every rule below verifies, and each has a `satisfy` witness showing its scenario can happen, so none passes vacuously. All configurations use `rule_sanity: basic`. The `invariant_not_trivial_postcondition` countermodels printed for property 4 are expected: they show the invariant is not trivially true, not a counterexample to it.

| Property | Config | Rules | Witnesses |
| --- | --- | --- | --- |
| 1 | `yield-fees.conf` | `yieldFeeChargedEqualsOwedPlusPaid`, `yieldFeePaymentDoesNotExceedLimit` on the real `YieldSeekerYieldFeeModule` | A fee is charged and paid |
| 1 | `borrow-fees.conf` | `borrowFeeChargedEqualsOwedPlusPaid`, `borrowFeePaymentDoesNotExceedLimit` on the real `YieldSeekerBorrowFeeModule` | A debt fee is charged and paid |
| 1 | `fee-tracker.conf` | `trackerPaymentDoesNotExceedWalletBalance`: whatever the modules report, `reportAction` reverts or asks for at most the wallet's base asset; `trackerRejectsModuleOverpayment` | A non-zero payment; a forced overpayment reverts |
| 4 | `borrow-debt-invariant.conf` | `borrowTokenDebtMatchesPositionSum` holds initially and after `reportAction`, `onAction` and every debt change | `lastDebt` and `tokenDebt` both change |
| 7 | `wallet-authorization.conf` | `untrustedCallerCannotChangeWalletAuthorityOrReduceBalances` over every non-view wallet method except `syncFromFactory` | An untrusted call reaches each method; the owner can change blocklists, withdraw ETH and withdraw the base asset |

## Assumptions and limits

- **Property 7 caller:** "untrusted" means not the owner, an EntryPoint, an operator or the wallet itself. The wallet only calls itself (`settleFeesForWithdrawal`) inside owner and executor flows.
- **Property 7 excludes `syncFromFactory`:** anyone may call it by design; it copies the factory's admin-set registry, operators, tracker and policy.
- **Property 7 upgrades:** the harness is the implementation contract, not a proxy, so OpenZeppelin's `onlyProxy` makes `upgradeToAndCall` and `upgradeToLatest` revert for every caller here. The implementation check is therefore not meaningful for those two methods; upgrade authorization is covered by the Foundry test `testFuzz_attackerCannotCallAnyPrivilegedWalletFunction` on real proxies.
- **Property 7 adapters:** adapter `execute` calls are summarised as `HAVOC_ALL`; they are only reachable behind `onlyExecutors`. The base asset is a mock ERC-20 in the scene, and balances are read from it.
- **Fee tracker:** two modules with arbitrary return values; loop bound 2.
- **Property 4:** fee maths and `walletPlan` are summarised because they do not affect debt bookkeeping; one debt token per market.
- **Compiler:** properties 4 and 7 use the legacy pipeline with CSE, peephole and inlining off, so they check the source logic rather than the production `via_ir` bytecode.
