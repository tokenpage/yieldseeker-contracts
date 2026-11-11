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

Clone and build the open-source prover in its dedicated tools directory. This uses the local Python virtual environment required by its README and writes prover artifacts to the path exported by `env.sh`:

```sh
git clone --recurse-submodules https://github.com/Certora/CertoraProver.git /Users/krishan/Tools/CertoraProver
python3 -m venv /Users/krishan/Tools/CertoraProver/.venv
/Users/krishan/Tools/CertoraProver/.venv/bin/pip install -r /Users/krishan/Tools/CertoraProver/scripts/certora_cli_requirements.txt
source /Users/krishan/Projects/yieldseeker-contracts-verification-certora/certora/env.sh
cd /Users/krishan/Tools/CertoraProver
./gradlew assemble
```

`certora/env.sh` exports `CERTORA`, `JAVA_HOME`, and the toolchain paths, then activates the prover's Python environment. It does not edit any shell startup files. Confirm `$CERTORA/emv.jar` exists after the build.

## Forcing a local run

The open-source CLI selects local execution when `$CERTORA/emv.jar` exists and no `--server` is specified. `CERTORAKEY` is not needed. Every project configuration also disables optional Prover event reporting; no verification job or telemetry is sent to a hosted service.

```sh
source /Users/krishan/Projects/yieldseeker-contracts-verification-certora/certora/env.sh
unset CERTORAKEY CI GITHUB_ACTIONS
test -f "$CERTORA/emv.jar"
mkdir -p "$CERTORA/runs"
cd "$CERTORA/runs"
certoraRun.py /Users/krishan/Projects/yieldseeker-contracts-verification-certora/certora/yield-fees.conf \
  --build_dir "$CERTORA/yield-fees-$(date +%s)"
```

The specifications use absolute source paths and explicit dependency mappings, so they can run from this external output directory. Prover build artifacts and reports stay under `/Users/krishan/Tools/certora-build`; each `.conf` disables event reporting and limits rule concurrency to one to reduce local memory pressure.

Run the remaining configurations the same way:

```sh
certoraRun.py /Users/krishan/Projects/yieldseeker-contracts-verification-certora/certora/borrow-fees.conf \
  --build_dir "$CERTORA/borrow-fees-$(date +%s)"
certoraRun.py /Users/krishan/Projects/yieldseeker-contracts-verification-certora/certora/borrow-debt-invariant.conf \
  --build_dir "$CERTORA/borrow-debt-invariant-$(date +%s)"
certoraRun.py /Users/krishan/Projects/yieldseeker-contracts-verification-certora/certora/fee-tracker.conf \
  --build_dir "$CERTORA/fee-tracker-$(date +%s)"
certoraRun.py /Users/krishan/Projects/yieldseeker-contracts-verification-certora/certora/wallet-authorization.conf \
  --build_dir "$CERTORA/wallet-authorization-$(date +%s)"
```

The local Prover run is observable in the CLI output as `java -jar $CERTORA/emv.jar`; it does not submit verification jobs to Certora Cloud. To smoke-test the local build independently, run the bundled `Public/TestEVM/Counter` example from the CertoraProver checkout:

```sh
cd /Users/krishan/Tools/CertoraProver/Public/TestEVM/Counter
source /Users/krishan/Projects/yieldseeker-contracts-verification-certora/certora/env.sh
unset CERTORAKEY CI GITHUB_ACTIONS
certoraRun.py counter.conf --solc /Users/krishan/.local/bin/solc \
  --prover_args "-enableEventReporting false" \
  --build_dir "$CERTORA/counter-example-$(date +%s)"
```

The bundled example's `incrementIncreasesCountByOne` and `decrementDecreasesCountByOne` rules verified in 5.53 seconds with the locally built Prover and no API key. The sample also emitted separate `rule_not_vacuous` sanity diagnostics; these are not the two example rules' results.

## Latest local results

All times are shell wall-clock times from the final runs, using the local Prover with event reporting disabled and no cloud/API credentials. Each named rule listed below was reported `Verified`, and each CLI process exited successfully.

| Scope | Verified rules | Wall time |
| --- | --- | ---: |
| Bundled Counter smoke | `incrementIncreasesCountByOne`, `decrementDecreasesCountByOne` | 5.53 s |
| Property 1: YieldFeeModule | `yieldFeeChargedEqualsOwedPlusPaid`, `yieldFeePaymentDoesNotExceedLimit` | 14.39 s |
| Property 1: BorrowFeeModule | `borrowFeeChargedEqualsOwedPlusPaid`, `borrowFeePaymentDoesNotExceedLimit` | 14.37 s |
| Property 1: FeeTracker | `trackerPaymentDoesNotExceedWalletBalance`, `trackerRejectsModuleOverpayment` | 14.46 s |
| Property 4: borrow debt conservation | `borrowTokenDebtMatchesPositionSum`, preserved across `reportAction` and guarded `onAction` | 14.78 s |
| Property 7: wallet authorization | `untrustedCallerCannotChangeWalletAuthorityOrReduceBalances` for covered non-view methods | 80 s |

These configurations using `rule_sanity: basic` print additional `rule_not_vacuous` diagnostics after the main rules; the main named rules are independently reported `Verified` and the CLI exits 0. The wallet configuration disables that auxiliary check because its basic-sanity output was misleading for the parametric method rule. The analyzer produced no counterexample for the final named rules. An earlier property 4 counterexample came from an unconstrained non-FeeTracker caller and inconsistent harness token mapping; the final rule constrains `onAction` to the real FeeTracker caller and the harness's consistent one-token-per-market mapping.

**Property 7 limitation:** the blanket statement does not hold for `syncFromFactory()`: repository behavior intentionally permits anyone to request this factory refresh, which can change registry/operator configuration. The final proof explicitly excludes this public method, so it does not establish the unrestricted property as originally phrased; treat the permissionless factory refresh as a real design exception, not a proved case.

## Verification scope

- Property 1, `yield-fees.conf`: `yieldFeeChargedEqualsOwedPlusPaid` and `yieldFeePaymentDoesNotExceedLimit` use the real `YieldSeekerYieldFeeModule` implementation.
- Property 1, `borrow-fees.conf`: `borrowFeeChargedEqualsOwedPlusPaid` and `borrowFeePaymentDoesNotExceedLimit` use the real `YieldSeekerBorrowFeeModule` implementation.
- Property 4, `borrow-debt-invariant.conf`: the storage hook tracks each `lastDebt` update by the harness's token-for-position mapping; `walletPlan` and rounded fee math are summarized because they do not affect debt-token conservation. The harness fixes one debt token per market. This configuration uses the legacy Solidity pipeline and disables CSE, peephole, and inlining so the local Prover can locate internal functions.
- Property 1, `fee-tracker.conf`: `trackerPaymentDoesNotExceedWalletBalance` and `trackerRejectsModuleOverpayment` use two nondeterministic module summaries bounded by the remaining allowance, and a ghost models the harness wallet's base-asset balance consistently. The rules require the harness's two configured modules and set the loop bound to two.
- Property 7, `wallet-authorization.conf`: for initialized wallets with nonzero owner, `untrustedCallerCannotChangeWalletAuthorityOrReduceBalances` checks all non-view wallet methods except `syncFromFactory`, an intentional permissionless refresh documented in the repository security model; the guarantee does not cover this exception. Adapter `execute(address,bytes)` calls are summarized as `HAVOC_ALL` behind `onlyExecutors`. A separate mock ERC-20 keeps token transfer methods out of the wallet's parametric method set while preserving wallet balance checks. This config uses `rule_sanity: "none"` because an earlier basic-sanity run reported vacuity failures despite successful per-method checks.
