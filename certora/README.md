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

The open-source CLI selects local execution when `$CERTORA/emv.jar` exists and no `--server` is specified. `CERTORAKEY` is not needed. For a no-key, local-only run, source the environment, unset any inherited cloud/CI selectors, and do not pass a server option:

```sh
source /Users/krishan/Projects/yieldseeker-contracts-verification-certora/certora/env.sh
unset CERTORAKEY CI GITHUB_ACTIONS
test -f "$CERTORA/emv.jar"
mkdir -p "$CERTORA/runs"
cd "$CERTORA/runs"
certoraRun.py /Users/krishan/Projects/yieldseeker-contracts-verification-certora/certora/yield-fees.conf \
  --build_dir "$CERTORA/yield-fees-$(date +%s)"
```

The specifications use absolute source paths and explicit dependency mappings, so they can run from this external output directory. Prover build artifacts and reports stay under `/Users/krishan/Tools/certora-build`; each `.conf` also limits rule concurrency to one to reduce local memory pressure.

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
  --build_dir "$CERTORA/counter-example-$(date +%s)"
```

The bundled example's `incrementIncreasesCountByOne` and `decrementDecreasesCountByOne` rules verified in 7.35 seconds with the locally built Prover and no API key. The sample also emitted its separate `rule_not_vacuous` sanity diagnostics; those are not the two example rules' results.

## Verification scope

- `yield-fees.conf`: fee charges recorded by `YieldRecorded` equal the change in fees owed plus payments returned by `onAction`; returned payment never exceeds `maxPayment`.
- `borrow-fees.conf`: the same conservation and payment-bound rules for base-asset borrow fees.
- `borrow-debt-invariant.conf`: `tokenDebt[wallet][token]` equals the sum of hook-tracked position debts assigned to that token.
- `fee-tracker.conf`: fee tracker total payment does not exceed the wallet's measured base-asset balance, with two module calls summarized nondeterministically.
- `wallet-authorization.conf`: a caller who is not the owner, EntryPoint, or operator cannot change wallet authority, registry, blocklists, implementation, or reduce the modeled base-asset or native balance.
