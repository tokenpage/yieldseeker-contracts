#!/usr/bin/env bash
set -euo pipefail

ARGS=()
SOLC_BASE_PATH=""
while (($#)); do
  ARG="$1"
  if [[ "$ARG" == "--base-path" ]]; then
    SOLC_BASE_PATH="$2"
    ARGS+=("$1" "$2")
    shift 2
    continue
  fi
  if [[ "$ARG" != --* && "$ARG" == *=*/lib/* ]]; then
    REMAP_KEY="${ARG%%=*}"
    REMAP_PATH="${ARG#*=}"
    ARG="${REMAP_KEY%/}/=lib/${REMAP_PATH#*/lib/}"
    ARG="${ARG%/}/"
  fi
  ARGS+=("$ARG")
  shift
done

if [[ -n "$SOLC_BASE_PATH" ]]; then
  cd "$SOLC_BASE_PATH"
fi

SOLC_BIN="${MUTATION_REAL_SOLC:-$(command -v solc)}"
exec "$SOLC_BIN" "${ARGS[@]}" --via-ir
