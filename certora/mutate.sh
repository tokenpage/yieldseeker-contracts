#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/mutate.sh"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

CONFS=(
  "yield-fees:src/fees/YieldFeeModule.sol"
  "borrow-fees:src/fees/BorrowFeeModule.sol"
  "borrow-debt-invariant:src/fees/BorrowFeeModule.sol"
  "fee-tracker:src/fees/FeeTracker.sol"
  "wallet-authorization:src/AgentWalletV3.sol src/agentwalletkit/AWKAgentWalletV3.sol"
  "wallet-state-changes:src/AgentWalletV3.sol src/agentwalletkit/AWKAgentWalletV3.sol"
)

if [[ "${1:-}" == "--worker" ]]; then
  CONF="$2"
  MUTANT_ID="$3"
  MUTATED_FILE="$4"
  SCRATCH="$RESULTS_DIR/scratch/$CONF-$MUTANT_ID"
  LOG="$RESULTS_DIR/logs/$CONF-$MUTANT_ID.log"
  rm -rf "$SCRATCH"
  trap 'rm -rf "$SCRATCH"' EXIT
  mkdir -p "$SCRATCH"
  cp -cR "$ROOT/src" "$ROOT/certora" "$ROOT/lib" "$SCRATCH/"
  cp "$MUTANTS_DIR/$MUTANT_ID/$MUTATED_FILE" "$SCRATCH/$MUTATED_FILE"
  STARTED=$SECONDS
  set +e
  (
    cd "$SCRATCH"
    gtimeout --signal=TERM --kill-after=30s "${TIMEOUT_SECONDS}s" certoraRun.py "certora/$CONF.conf" --build_dir "$SCRATCH/build"
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

if [[ -z "${MUTANTS_DIR:-}" ]]; then
  GENERATOR="$RESULTS_DIR/generator"
  MUTANTS_DIR="$GENERATOR/gambit_out/mutants"
  if [[ ! -f "$GENERATOR/.generation-complete" ]]; then
    rm -rf "$GENERATOR"
    mkdir -p "$GENERATOR"
    cp -cR "$ROOT/src" "$ROOT/test" "$ROOT/lib" "$ROOT/foundry.toml" "$GENERATOR/"
    jq '[.[] | select(.filename | test("(YieldFeeModule|BorrowFeeModule|FeeTracker|/AgentWalletV3|AWKAgentWalletV3)\\.sol$"))]' "$ROOT/test/mutation/gambit.json" > "$GENERATOR/test/mutation/certora-gambit.json"
    MUTATION_REAL_SOLC="$(command -v solc)"
    export MUTATION_REAL_SOLC
    (cd "$GENERATOR" && gambit mutate --json "$GENERATOR/test/mutation/certora-gambit.json")
    touch "$GENERATOR/.generation-complete"
  fi
fi

TIMEOUT_SECONDS="${MUTATION_TIMEOUT_SECONDS:-1800}"
JOBS="${MUTATION_JOBS:-3}"
export RESULTS_DIR MUTANTS_DIR TIMEOUT_SECONDS
mkdir -p "$RESULTS_DIR/scratch" "$RESULTS_DIR/logs"
[[ -f "$RESULTS_DIR/results.csv" ]] || printf 'conf,mutant_id,source,result,seconds,violated_rules\n' > "$RESULTS_DIR/results.csv"

TASKS=()
for ENTRY in "${CONFS[@]}"; do
  CONF="${ENTRY%%:*}"
  for FILE in ${ENTRY#*:}; do
    for MUTANT_PATH in "$MUTANTS_DIR"/*/"$FILE"; do
      [[ -f "$MUTANT_PATH" ]] || continue
      MUTANT_ID="${MUTANT_PATH#"$MUTANTS_DIR"/}"
      MUTANT_ID="${MUTANT_ID%%/*}"
      grep -q "^$CONF,$MUTANT_ID," "$RESULTS_DIR/results.csv" && continue
      TASKS+=("$CONF $MUTANT_ID $FILE")
    done
  done
done

printf 'Running %s Prover jobs (%s parallel, %s-second timeout). Results: %s\n' "${#TASKS[@]}" "$JOBS" "$TIMEOUT_SECONDS" "$RESULTS_DIR/results.csv"
[[ "${#TASKS[@]}" -eq 0 ]] && exit 0
printf '%s\n' "${TASKS[@]}" | xargs -P "$JOBS" -L 1 "$SCRIPT_PATH" --worker
printf 'Done in %s seconds.\n' "$SECONDS"
