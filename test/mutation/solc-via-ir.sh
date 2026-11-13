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
  case "$ARG" in
    '@openzeppelin/contracts='*) ARG='@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/' ;;
    '@openzeppelin/contracts-upgradeable='*) ARG='@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/' ;;
    'account-abstraction='*) ARG='account-abstraction/=lib/account-abstraction/contracts/' ;;
    'forge-std='*) ARG='forge-std/=lib/forge-std/src/' ;;
  esac
  ARGS+=("$ARG")
  shift
done

if [[ -n "$SOLC_BASE_PATH" ]]; then
  cd "$SOLC_BASE_PATH"
fi

SOLC_BIN="${MUTATION_REAL_SOLC:-$(command -v solc)}"
exec "$SOLC_BIN" "${ARGS[@]}" --via-ir
