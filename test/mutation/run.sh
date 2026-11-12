#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/run.sh"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"
MODE="${1:-all}"
if [[ -z "${RESULTS_DIR:-}" ]]; then
  printf 'Set RESULTS_DIR to a fixed directory outside the repository\n' >&2
  exit 2
fi
mkdir -p "$RESULTS_DIR"
RESULTS_DIR="$(cd "$RESULTS_DIR" && pwd)"
if [[ "$RESULTS_DIR" == "$ROOT" || "$RESULTS_DIR" == "$ROOT/"* ]]; then
  printf 'RESULTS_DIR must be outside the repository: %s\n' "$RESULTS_DIR" >&2
  exit 2
fi

BASELINE_STATUS_FILE="${MUTATION_BASELINE_FILE:-$RESULTS_DIR/results.csv}"
AFTER_STATUS_FILE="${MUTATION_AFTER_RESULTS_FILE:-$RESULTS_DIR/results-after.csv}"
GENERATOR="$RESULTS_DIR/generator"
TIMEOUT_SECONDS="${MUTATION_TIMEOUT_SECONDS:-300}"
STARTED_AT=$SECONDS
if [[ "$MODE" != "--worker" ]]; then
  CPU_COUNT="$(sysctl -n hw.ncpu)"
  MEMORY_BYTES="$(sysctl -n hw.memsize)"
  RESERVED_BYTES=$((8 * 1024 * 1024 * 1024))
  WORKER_MEMORY_BYTES=$((8 * 1024 * 1024 * 1024))
  MEMORY_JOBS=$(((MEMORY_BYTES - RESERVED_BYTES) / WORKER_MEMORY_BYTES))
  ((MEMORY_JOBS > 0)) || MEMORY_JOBS=1
  if [[ -n "${MUTATION_JOBS:-}" ]]; then
    JOBS="$MUTATION_JOBS"
  elif ((CPU_COUNT < MEMORY_JOBS)); then
    JOBS="$CPU_COUNT"
  else
    JOBS="$MEMORY_JOBS"
  fi
  printf 'Host capacity: %s CPUs, %s bytes RAM; reserving 8 GiB and budgeting 8 GiB per via-IR worker; using %s jobs.\n' "$CPU_COUNT" "$MEMORY_BYTES" "$JOBS"
fi

FILES=(
  src/fees/FeeTracker.sol
  src/fees/YieldFeeModule.sol
  src/fees/BorrowFeeModule.sol
  src/swaps/BorrowSwapPolicy.sol
  src/swaps/VaultSwapPolicy.sol
  src/PriceOracle.sol
  src/adapters/AgentTransferAdapter.sol
  src/AgentWalletV3.sol
  src/agentwalletkit/AWKAgentWalletV3.sol
  src/agentwalletkit/AWKAgentWalletFactory.sol
  src/agentwalletkit/AWKAdapterRegistry.sol
  src/agentwalletkit/AWKAdapter.sol
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
    printf '%s,%s,%s,%s\n' "$MUTANT_ID" "unknown-source" "INVALID" "0" >> "$STATUS_FILE"
    exit 0
  fi

  if [[ "$LABEL" == "before" ]]; then
    SOURCE_ROOT="$GENERATOR"
  else
    SOURCE_ROOT="$ROOT"
  fi
  mkdir -p "$RESULTS_DIR/scratch-$LABEL" "$LOG_DIR"
  rm -rf "$SCRATCH"
  trap 'rm -rf "$SCRATCH"' EXIT
  mkdir -p "$SCRATCH"
  cp -cR "$SOURCE_ROOT/src" "$SOURCE_ROOT/test" "$SOURCE_ROOT/lib" "$SOURCE_ROOT/foundry.toml" "$SCRATCH/"
  cp "$MUTANT_DIR/$MUTATED_FILE" "$SCRATCH/$MUTATED_FILE"
  WORKER_STARTED=$SECONDS
  set +e
  (
    cd "$SCRATCH"
    FOUNDRY_PROFILE=default gtimeout --signal=TERM --kill-after=10s "${TIMEOUT_SECONDS}s" forge test --no-match-path "test/fork/*"
  ) > "$LOG_DIR/$MUTANT_ID.log" 2>&1
  TEST_STATUS=$?
  set -e
  ELAPSED_SECONDS=$((SECONDS - WORKER_STARTED))
  if [[ "$TEST_STATUS" -eq 0 ]]; then
    RESULT="SURVIVED"
  elif [[ "$TEST_STATUS" -eq 124 || "$TEST_STATUS" -eq 137 ]]; then
    RESULT="TIMEOUT"
  else
    RESULT="KILLED"
  fi
  printf '%s,%s,%s,%s\n' "$MUTANT_ID" "$MUTATED_FILE" "$RESULT" "$ELAPSED_SECONDS" >> "$STATUS_FILE"
  exit 0
fi

if [[ "$MODE" != "all" ]] && { ! command -v gtimeout >/dev/null || ! command -v forge >/dev/null; }; then
  printf 'gtimeout and forge are required on PATH\n' >&2
  exit 2
fi

if [[ "$MODE" == "all" ]]; then
  if ! command -v gambit >/dev/null || ! command -v gtimeout >/dev/null || ! command -v forge >/dev/null; then
    printf 'gambit, gtimeout, and forge are required on PATH\n' >&2
    exit 2
  fi
  if [[ "$(solc --version)" != *"0.8.38"* ]]; then
    printf 'solc 0.8.38 is required; select it with solc-select\n' >&2
    exit 2
  fi

  if [[ ! -f "$GENERATOR/.generation-complete" ]]; then
    rm -rf "$GENERATOR"
    mkdir -p "$GENERATOR"
    cp -cR "$ROOT/src" "$ROOT/test" "$ROOT/lib" "$ROOT/foundry.toml" "$GENERATOR/"
    MUTATION_REAL_SOLC="$(command -v solc)"
    export MUTATION_REAL_SOLC
    (
      cd "$GENERATOR"
      gambit mutate --json "$GENERATOR/test/mutation/gambit.json"
    )
    MANIFEST="$RESULTS_DIR/mutants-per-file.csv"
    printf 'source,total\n' > "$MANIFEST"
    for FILE in "${FILES[@]}"; do
      COUNT=0
      for MUTANT_DIR in "$GENERATOR/gambit_out"/mutants/*; do
        [[ -d "$MUTANT_DIR" ]] || continue
        if [[ -f "$MUTANT_DIR/$FILE" ]]; then
          COUNT=$((COUNT + 1))
        fi
      done
      printf '%s,%s\n' "$FILE" "$COUNT" >> "$MANIFEST"
      if ((COUNT == 0)); then
        printf 'Gambit generated no mutants for %s\n' "$FILE" >&2
        exit 2
      fi
    done
    touch "$GENERATOR/.generation-complete"
  fi
  LABEL="before"
  STATUS_FILE="$RESULTS_DIR/results.csv"
elif [[ "$MODE" == "baseline-existing" ]]; then
  LABEL="before"
  STATUS_FILE="$RESULTS_DIR/results-rerun.csv"
  if [[ ! -d "$GENERATOR/gambit_out/mutants" ]]; then
    printf 'missing generated mutants: %s/gambit_out/mutants\n' "$GENERATOR" >&2
    exit 2
  fi
elif [[ "$MODE" == "survivors" ]]; then
  LABEL="after"
  STATUS_FILE="$AFTER_STATUS_FILE"
  if [[ ! -f "$BASELINE_STATUS_FILE" ]]; then
    printf 'missing baseline result file: %s\n' "$BASELINE_STATUS_FILE" >&2
    exit 2
  fi
else
  printf 'usage: %s [all|baseline-existing|survivors]\n' "$0" >&2
  exit 2
fi

if [[ ! -d "$GENERATOR/gambit_out/mutants" ]]; then
  printf 'missing generated mutants: %s/gambit_out/mutants\n' "$GENERATOR" >&2
  exit 2
fi
if [[ ! -f "$STATUS_FILE" ]]; then
  printf 'mutant_id,source,result,seconds\n' > "$STATUS_FILE"
fi

SCORED_IDS=()
has_scored_id() {
  local SOUGHT_ID="$1"
  local EXISTING_ID
  for EXISTING_ID in "${SCORED_IDS[@]}"; do
    [[ "$EXISTING_ID" == "$SOUGHT_ID" ]] && return 0
  done
  return 1
}
while IFS=, read -r OLD_ID _OLD_FILE _OLD_RESULT _OLD_SECONDS; do
  [[ "$OLD_ID" =~ ^[0-9]+$ ]] && SCORED_IDS+=("$OLD_ID")
done < "$STATUS_FILE"

MUTANT_IDS=()
if [[ "$MODE" == "survivors" ]]; then
  while IFS=, read -r MUTANT_ID _FILE RESULT _SECONDS; do
    if [[ "$RESULT" == "SURVIVED" ]] && ! has_scored_id "$MUTANT_ID"; then
      MUTANT_IDS+=("$MUTANT_ID")
      SCORED_IDS+=("$MUTANT_ID")
    fi
  done < "$BASELINE_STATUS_FILE"
else
  for MUTANT_DIR in "$GENERATOR/gambit_out"/mutants/*; do
    [[ -d "$MUTANT_DIR" ]] || continue
    MUTANT_ID="${MUTANT_DIR##*/}"
    if ! has_scored_id "$MUTANT_ID"; then
      MUTANT_IDS+=("$MUTANT_ID")
    fi
  done
fi

if [[ "${#MUTANT_IDS[@]}" -eq 0 ]]; then
  printf 'No unscored mutants in %s mode. Results: %s\n' "$MODE" "$STATUS_FILE"
  exit 0
fi

export RESULTS_DIR TIMEOUT_SECONDS
mkdir -p "$RESULTS_DIR/scratch-$LABEL" "$RESULTS_DIR/logs-$LABEL"
printf 'Running %s unscored mutants (%s mode, %s parallel, %s-second timeout). Results: %s\n' "${#MUTANT_IDS[@]}" "$MODE" "$JOBS" "$TIMEOUT_SECONDS" "$STATUS_FILE"
printf '%s\0' "${MUTANT_IDS[@]}" | xargs -0 -P "$JOBS" -I {} "$SCRIPT_PATH" --worker "$LABEL" {} "$STATUS_FILE"
printf 'Completed %s mutant runs (%s mode). Elapsed: %s seconds.\n' "${#MUTANT_IDS[@]}" "$MODE" "$((SECONDS - STARTED_AT))"
