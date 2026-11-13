#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/mutate.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# NOTE(krishan711): configurations are listed fastest first; a mutant stops at the first configuration that catches it.
CONFS_FOR_FILE=(
  "src/fees/YieldFeeModule.sol:yield-fees"
  "src/fees/BorrowFeeModule.sol:borrow-debt-invariant borrow-fees"
  "src/fees/FeeTracker.sol:fee-tracker"
  "src/AgentWalletV3.sol:wallet-state-changes wallet-authorization"
  "src/agentwalletkit/AWKAgentWalletV3.sol:wallet-behaviour wallet-state-changes wallet-authorization"
)

confs_for() {
  local ENTRY
  for ENTRY in "${CONFS_FOR_FILE[@]}"; do
    [[ "${ENTRY%%:*}" == "$1" ]] && printf '%s\n' ${ENTRY#*:}
  done
}

if [[ "${1:-}" == "--worker" ]]; then
  MUTANT_ID="$2"
  MUTATED_FILE="$3"
  SCRATCH="$RESULTS_DIR/scratch/$MUTANT_ID"
  rm -rf "$SCRATCH"
  trap 'rm -rf "$SCRATCH"' EXIT
  mkdir -p "$SCRATCH"
  cp -cR "$ROOT/src" "$ROOT/certora" "$ROOT/lib" "$SCRATCH/"
  cp "$MUTANTS_DIR/$MUTANT_ID/$MUTATED_FILE" "$SCRATCH/$MUTATED_FILE"
  for CONF in $(confs_for "$MUTATED_FILE"); do
    grep -q "^$CONF,$MUTANT_ID," "$RESULTS_DIR/results.csv" && continue
    LOG="$RESULTS_DIR/logs/$CONF-$MUTANT_ID.log"
    STARTED=$SECONDS
    set +e
    (
      cd "$SCRATCH"
      gtimeout --signal=TERM --kill-after=30s "${TIMEOUT_SECONDS}s" certoraRun.py "certora/$CONF.conf" --build_dir "$SCRATCH/build-$CONF"
    ) > "$LOG" 2>&1
    STATUS=$?
    set -e
    RULES="$( { grep -aoE "^Violated: [A-Za-z0-9_-]+" "$LOG" || true; } | sed 's/^Violated: //' | grep -vE "rule_not_vacuous|invariant_not_trivial|not_tautological|not_redundant|operand_check" | sort -u | tr '\n' ' ' || true)"
    if [[ "$STATUS" -eq 0 ]]; then
      RESULT="SURVIVED"
    elif [[ "$STATUS" -eq 124 || "$STATUS" -eq 137 ]]; then
      RESULT="TIMEOUT"
    elif grep -aqE "Compiler error|solc.*failed|Failed to run solc|ParserError|TypeError" "$LOG"; then
      RESULT="INVALID"
    else
      RESULT="CAUGHT"
    fi
    printf '%s,%s,%s,%s,%s,%s\n' "$CONF" "$MUTANT_ID" "$MUTATED_FILE" "$RESULT" "$((SECONDS - STARTED))" "$RULES" >> "$RESULTS_DIR/results.csv"
    [[ "$RESULT" == "SURVIVED" ]] || exit 0
  done
  exit 0
fi

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
# shellcheck source=/dev/null
. "$SCRIPT_DIR/env.sh"
test -f "$CERTORA/emv.jar" || { printf 'Build the Certora Prover first; see certora/README.md\n' >&2; exit 2; }

TARGET_FILES=()
for ENTRY in "${CONFS_FOR_FILE[@]}"; do
  TARGET_FILES+=("${ENTRY%%:*}")
done
if [[ "${FULL:-}" != "1" ]]; then
  BASE="${MUTATION_BASE:-origin/main}"
  CHANGED="$(git -C "$ROOT" diff --name-only "$BASE" -- src)"
  CHANGED_TARGETS=()
  for FILE in "${TARGET_FILES[@]}"; do
    grep -qxF "$FILE" <<< "$CHANGED" && CHANGED_TARGETS+=("$FILE")
  done
  if [[ "${#CHANGED_TARGETS[@]}" -eq 0 ]]; then
    printf 'No proven contract changed since %s, so there is nothing to mutate. Set FULL=1 to mutate every proven contract.\n' "$BASE"
    exit 0
  fi
  TARGET_FILES=("${CHANGED_TARGETS[@]}")
fi
printf '%s\n' "${TARGET_FILES[@]}" > "$RESULTS_DIR/targets.next"
if ! cmp -s "$RESULTS_DIR/targets.next" "$RESULTS_DIR/targets" 2>/dev/null; then
  rm -rf "$RESULTS_DIR/generator" "$RESULTS_DIR/results.csv" "$RESULTS_DIR/logs"
  mv "$RESULTS_DIR/targets.next" "$RESULTS_DIR/targets"
else
  rm "$RESULTS_DIR/targets.next"
fi
printf 'Mutating %s contract(s):\n' "${#TARGET_FILES[@]}"
printf '  %s\n' "${TARGET_FILES[@]}"

if [[ -z "${MUTANTS_DIR:-}" ]]; then
  GENERATOR="$RESULTS_DIR/generator"
  MUTANTS_DIR="$GENERATOR/gambit_out/mutants"
  if [[ ! -f "$GENERATOR/.generation-complete" ]]; then
    rm -rf "$GENERATOR"
    mkdir -p "$GENERATOR"
    cp -cR "$ROOT/src" "$ROOT/test" "$ROOT/lib" "$ROOT/foundry.toml" "$GENERATOR/"
    jq --rawfile targets "$RESULTS_DIR/targets" '[.[] | select(.filename[6:] as $file | $targets | split("\n") | index($file))]' "$ROOT/test/mutation/gambit.json" > "$GENERATOR/test/mutation/certora-gambit.json"
    MUTATION_REAL_SOLC="$(command -v solc)"
    export MUTATION_REAL_SOLC
    (cd "$GENERATOR" && gambit mutate --json "$GENERATOR/test/mutation/certora-gambit.json")
    touch "$GENERATOR/.generation-complete"
  fi
fi

TIMEOUT_SECONDS="${MUTATION_TIMEOUT_SECONDS:-1800}"
JOBS="${MUTATION_JOBS:-2}"
export RESULTS_DIR MUTANTS_DIR TIMEOUT_SECONDS
mkdir -p "$RESULTS_DIR/scratch" "$RESULTS_DIR/logs"
[[ -f "$RESULTS_DIR/results.csv" ]] || printf 'conf,mutant_id,source,result,seconds,violated_rules\n' > "$RESULTS_DIR/results.csv"

TASKS=()
for FILE in "${TARGET_FILES[@]}"; do
  for MUTANT_PATH in "$MUTANTS_DIR"/*/"$FILE"; do
    [[ -f "$MUTANT_PATH" ]] || continue
    MUTANT_ID="${MUTANT_PATH#"$MUTANTS_DIR"/}"
    MUTANT_ID="${MUTANT_ID%%/*}"
    grep -qE "^[^,]+,$MUTANT_ID,[^,]+,(CAUGHT|INVALID|TIMEOUT)," "$RESULTS_DIR/results.csv" && continue
    TASKS+=("$MUTANT_ID $FILE")
  done
done

printf 'Running %s mutants (%s parallel, %s-second timeout per configuration). Results: %s\n' "${#TASKS[@]}" "$JOBS" "$TIMEOUT_SECONDS" "$RESULTS_DIR/results.csv"
[[ "${#TASKS[@]}" -eq 0 ]] && exit 0
# NOTE(krishan711): background QoS keeps the Prover on the efficiency cores so a run doesn't drain the battery.
printf '%s\n' "${TASKS[@]}" | taskpolicy -b xargs -P "$JOBS" -L 1 "$SCRIPT_PATH" --worker
printf 'Done in %s seconds.\n' "$SECONDS"
