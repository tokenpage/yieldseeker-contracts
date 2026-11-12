#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODE="${1:-all}"
RESULTS_DIR="${RESULTS_DIR:-${MUTATION_RESULTS_DIR:-${TMPDIR:-/tmp}/ys-mut-$(date +%Y%m%d-%H%M%S)}}"
BASELINE_STATUS_FILE="${MUTATION_BASELINE_FILE:-$RESULTS_DIR/results-before.csv}"
GENERATOR="$RESULTS_DIR/generator"
JOBS="${MUTATION_JOBS:-3}"
TIMEOUT_SECONDS="${MUTATION_TIMEOUT_SECONDS:-300}"
STARTED_AT=$SECONDS

FILES=(
  src/fees/FeeTracker.sol
  src/fees/YieldFeeModule.sol
  src/fees/BorrowFeeModule.sol
  src/swaps/BorrowSwapPolicy.sol
  src/swaps/IYieldSeekerSwapPolicy.sol
  src/swaps/VaultSwapPolicy.sol
  src/PriceOracle.sol
  src/AgentWalletV3.sol
  src/agentwalletkit/AWKAgentWalletV3.sol
  src/agentwalletkit/AWKAdapterRegistry.sol
  src/agentwalletkit/AWKAgentWalletFactory.sol
  src/agentwalletkit/AWKAdapter.sol
  src/adapters/AgentTransferAdapter.sol
  src/adapters/SwapSellPolicy.sol
  src/adapters/LendingAdapter.sol
  src/adapters/VaultAdapter.sol
  src/adapters/SwapAdapter.sol
  src/adapters/Adapter.sol
  src/agentwalletkit/adapters/AWKSwapAdapter.sol
  src/agentwalletkit/adapters/AWKLendingAdapter.sol
  src/agentwalletkit/adapters/AWKBaseVaultAdapter.sol
)

if [[ "$MODE" == "--worker" ]]; then
  LABEL="$2"
  MUTANT_ID="$3"
  STATUS_FILE="$4"
  MUTANT_DIR="$GENERATOR/gambit_out/mutants/$MUTANT_ID"
  SCRATCH="$RESULTS_DIR/scratch-$LABEL/$MUTANT_ID"
  LOG_DIR="$RESULTS_DIR/logs-$LABEL"
  MUTATED_FILE=""
  for FILE in "${FILES[@]}"; do
    if [[ -f "$MUTANT_DIR/$FILE" ]]; then
      MUTATED_FILE="$FILE"
      break
    fi
  done
  if [[ -z "$MUTATED_FILE" ]]; then
    printf '%s,%s,%s\n' "$MUTANT_ID" "unknown-source" "INVALID" >> "$STATUS_FILE"
    exit 0
  fi

  if [[ "$LABEL" == "before" ]]; then
    SOURCE_ROOT="$GENERATOR"
  else
    SOURCE_ROOT="$ROOT"
  fi
  mkdir -p "$SCRATCH" "$LOG_DIR"
  cp -cR "$SOURCE_ROOT/src" "$SOURCE_ROOT/test" "$SOURCE_ROOT/lib" "$SOURCE_ROOT/foundry.toml" "$SCRATCH/"
  cp "$MUTANT_DIR/$MUTATED_FILE" "$SCRATCH/$MUTATED_FILE"
  set +e
  (
    cd "$SCRATCH"
    FOUNDRY_PROFILE=default gtimeout --signal=TERM --kill-after=10s "${TIMEOUT_SECONDS}s" forge test --no-match-path "test/fork/*"
  ) > "$LOG_DIR/$MUTANT_ID.log" 2>&1
  TEST_STATUS=$?
  set -e
  if [[ "$TEST_STATUS" -eq 0 ]]; then
    RESULT="SURVIVED"
  elif [[ "$TEST_STATUS" -eq 124 || "$TEST_STATUS" -eq 137 ]]; then
    RESULT="TIMEOUT"
  else
    RESULT="KILLED"
  fi
  printf '%s,%s,%s\n' "$MUTANT_ID" "$MUTATED_FILE" "$RESULT" >> "$STATUS_FILE"
  exit 0
fi

if [[ "$MODE" == "all" ]]; then
  export PATH="$HOME/.cargo/bin:$PATH"
  if ! command -v gambit >/dev/null || ! command -v gtimeout >/dev/null; then
    printf 'gambit and gtimeout are required on PATH\n' >&2
    exit 2
  fi
  if [[ "$(solc --version)" != *"0.8.38"* ]]; then
    printf 'solc 0.8.38 is required; select it with solc-select\n' >&2
    exit 2
  fi
  if [[ -e "$GENERATOR" || -e "$RESULTS_DIR/gambit_out" ]]; then
    printf 'mutation results path already exists: %s\n' "$RESULTS_DIR" >&2
    exit 2
  fi
  mkdir -p "$GENERATOR" "$RESULTS_DIR"
  cp -cR "$ROOT/src" "$ROOT/test" "$ROOT/lib" "$ROOT/foundry.toml" "$GENERATOR/"
  mkdir -p "$GENERATOR/@openzeppelin" "$GENERATOR/account-abstraction" "$GENERATOR/forge-std"
  ln -s "$GENERATOR/lib/openzeppelin-contracts/contracts" "$GENERATOR/@openzeppelin/contracts"
  ln -s "$GENERATOR/lib/openzeppelin-contracts-upgradeable/contracts" "$GENERATOR/@openzeppelin/contracts-upgradeable"
  ln -s "$GENERATOR/lib/account-abstraction/contracts" "$GENERATOR/account-abstraction"
  ln -s "$GENERATOR/lib/forge-std/src" "$GENERATOR/forge-std"
  cd "$GENERATOR"
  gambit mutate --json "$GENERATOR/test/mutation/gambit.json"
  LABEL="before"
  STATUS_FILE="$RESULTS_DIR/results-before.csv"
elif [[ "$MODE" == "baseline-existing" ]]; then
  LABEL="before"
  STATUS_FILE="$RESULTS_DIR/results-before-rerun.csv"
  if [[ ! -d "$GENERATOR/gambit_out/mutants" ]]; then
    printf 'missing generated mutants: %s/generator/gambit_out/mutants\n' "$RESULTS_DIR" >&2
    exit 2
  fi
elif [[ "$MODE" == "survivors" ]]; then
  LABEL="after"
  STATUS_FILE="$RESULTS_DIR/results-after.csv"
  if [[ ! -f "$BASELINE_STATUS_FILE" ]]; then
    printf 'missing baseline result file: %s\n' "$BASELINE_STATUS_FILE" >&2
    exit 2
  fi
else
  printf 'usage: %s [all|baseline-existing|survivors]\n' "$0" >&2
  exit 2
fi

export RESULTS_DIR TIMEOUT_SECONDS
mkdir -p "$RESULTS_DIR/scratch-$LABEL" "$RESULTS_DIR/logs-$LABEL"
MUTANT_IDS=()
if [[ "$MODE" == "all" || "$MODE" == "baseline-existing" ]]; then
  for MUTANT_DIR in "$GENERATOR/gambit_out"/mutants/*; do
    [[ -d "$MUTANT_DIR" ]] || continue
    MUTANT_IDS+=("${MUTANT_DIR##*/}")
  done
else
  while IFS=, read -r MUTANT_ID _FILE RESULT; do
    [[ "$RESULT" == "SURVIVED" ]] && MUTANT_IDS+=("$MUTANT_ID")
  done < "$BASELINE_STATUS_FILE"
fi

if [[ "${#MUTANT_IDS[@]}" -eq 0 ]]; then
  if [[ "$MODE" == "all" || "$MODE" == "baseline-existing" ]]; then
    printf 'Gambit generated no compilable mutants; inspect the generator configuration\n' >&2
    exit 2
  fi
  printf 'No mutants to run in %s mode. Results: %s\n' "$MODE" "$RESULTS_DIR"
  exit 0
fi
printf '%s\0' "${MUTANT_IDS[@]}" | xargs -0 -P "$JOBS" -I {} "$0" --worker "$LABEL" {} "$STATUS_FILE"
printf 'Completed %s mutant runs (%s mode, %s parallel, %s-second timeout). Results: %s\n' "${#MUTANT_IDS[@]}" "$MODE" "$JOBS" "$TIMEOUT_SECONDS" "$RESULTS_DIR"
printf 'Elapsed: %s seconds\n' "$((SECONDS - STARTED_AT))"
