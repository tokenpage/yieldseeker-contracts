#!/usr/bin/env bash
# Prints the status of all timelock operations sorted by proposed date,
# with Safe Transaction Builder instructions for any that are ready to execute.
#
# Usage: ./script/check-timelock.sh
# Requires: cast (Foundry), jq

set -euo pipefail

TIMELOCK="0x8E074B7636F6A56097F1f719e708E2C932E23bAB"
SAFE="0x403EE3392A40D017a009384D1bE1a2Ca921C2fEa"
RPC="${RPC_NODE_URL_8453}"
ARCHIVE_RPC="${RPC_ARCHIVE_NODE_URL_8453}"
NOW=$(date +%s)
WORK=$(mktemp -d)
trap "rm -rf $WORK" EXIT

OLD_DEPLOYER="${DEPLOYER_ADDRESS_OLD1:-}"
NEW_DEPLOYER="${DEPLOYER_ADDRESS:-}"

echo "================================================="
echo "TIMELOCK OPERATION STATUS"
echo "Timelock: $TIMELOCK"
echo "================================================="
echo ""

# 1. Get all CallScheduled and CallSalt events in two archive calls; execute calls are rebuilt from them, so an
#    operation can be executed whoever proposed it (the deployer directly or the Safe through execTransaction)
LOGS=$(cast logs \
  --rpc-url "$ARCHIVE_RPC" \
  --address "$TIMELOCK" \
  --from-block 0 \
  --json \
  "CallScheduled(bytes32 indexed id, uint256 indexed index, address target, uint256 value, bytes data, bytes32 predecessor, uint256 delay)")
SALT_LOGS=$(cast logs \
  --rpc-url "$ARCHIVE_RPC" \
  --address "$TIMELOCK" \
  --from-block 0 \
  --json \
  "CallSalt(bytes32 indexed id, bytes32 salt)")

TOTAL=$(echo "$LOGS" | jq 'length')
# An id cancelled and scheduled again has several schedule transactions; the latest one is the live operation. Operations
# are ordered by when they were scheduled (block, then log index), so operations from one block keep their order
OPS=$(echo "$LOGS" | jq -r 'def hex: ltrimstr("0x") | ascii_downcase | explode | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end));
  [.[] | {id: .topics[1], tx: .transactionHash, block: .blockNumber, log: .logIndex}] | group_by(.id) | map(last) | sort_by((.block | hex), (.log | hex)) | .[] | "\(.id) \(.tx) \(.block)"')
OP_COUNT=$(echo "$OPS" | grep -c . || true)

echo "Found $TOTAL event(s) across $OP_COUNT unique operation(s)"
echo "Fetching status for all in parallel..."
echo ""

# 2. Fire all RPC calls in parallel — timestamp + tx details + block timestamp per op
while IFS=' ' read -r OP_ID TX_HASH BLOCK_NUM; do
  (
    TS=$(cast call --rpc-url "$RPC" "$TIMELOCK" "getTimestamp(bytes32)(uint256)" "$OP_ID" 2>/dev/null | awk '{print $1}')
    echo "$TS" > "$WORK/$OP_ID.ts"
  ) &

  (
    TX_JSON=$(cast tx --rpc-url "$ARCHIVE_RPC" --json "$TX_HASH" 2>/dev/null | jq -c '.data // .')
    echo "$TX_JSON" | jq -r '.from // "unknown"' > "$WORK/$OP_ID.from"
    echo "$TX_JSON" | jq -r '.to // ""'          > "$WORK/$OP_ID.to"
  ) &

  (
    # Safe{Wallet} can relay execTransaction, so `to` may be a relayer, and any proposer can put a Safe transaction (or a
    # reverted Safe.simulateAndRevert call, or a Safe-signed cancel of the same id) in its own transaction. So the Safe
    # counts as proposer only if it called every frame that emitted this id's CallScheduled log inside no failed frame
    RECEIPT=$(cast receipt --rpc-url "$ARCHIVE_RPC" --json "$TX_HASH" 2>/dev/null | jq -c '.data // .')
    HAS_SAFE_LOG=$(echo "$RECEIPT" | jq -r --arg safe "$(echo "$SAFE" | tr '[:upper:]' '[:lower:]')" \
      '((.to // "") | ascii_downcase) == $safe or ([.logs[]? | select((.address | ascii_downcase) == $safe and .topics[0] == "0x442e715f626346e8c54381002da614f62bee8d27386535b2521ec8540898556e")] | length > 0)')
    echo "$HAS_SAFE_LOG" > "$WORK/$OP_ID.safe"
    if [ "$HAS_SAFE_LOG" = "true" ]; then
      cast rpc --rpc-url "$ARCHIVE_RPC" debug_traceTransaction "$TX_HASH" '{"tracer":"callTracer","tracerConfig":{"withLog":true}}' 2>/dev/null \
        | jq -r --arg tl "$(echo "$TIMELOCK" | tr '[:upper:]' '[:lower:]')" --arg id "$OP_ID" \
          --arg cs "0x4cf4410cc57040e44862ef0f45f3dd5a5e02db8eb8add648d4b0e236f1d07dca" \
          'def live: select(.error == null) | ., (.calls[]? | live);
           live | select(any(.logs[]?; (.address | ascii_downcase) == $tl and .topics[0] == $cs and .topics[1] == $id)) | .from | ascii_downcase' \
        | sort -u > "$WORK/$OP_ID.scheduler" || true
    fi
  ) &

  (
    BLOCK_DEC=$(printf "%d" "$BLOCK_NUM" 2>/dev/null || echo "0")
    BLK_TS_HEX=$(cast block --rpc-url "$ARCHIVE_RPC" --json "$BLOCK_DEC" 2>/dev/null | jq -r '(.data // .).timestamp // "0x0"')
    BLK_TS=$(printf "%d" "$BLK_TS_HEX" 2>/dev/null || echo "0")
    echo "${BLK_TS:-0}" > "$WORK/$OP_ID.proposed"
  ) &
done <<< "$OPS"

wait

# 3. Keep the scheduling order from step 1
SORT_FILE="$WORK/sorted.txt"
while IFS=' ' read -r OP_ID TX_HASH BLOCK_NUM; do
  PROPOSED=$(cat "$WORK/$OP_ID.proposed" 2>/dev/null | awk '{print $1}' || echo "0")
  echo "$PROPOSED $OP_ID $TX_HASH"
done <<< "$OPS" > "$SORT_FILE"

# 4. Print results in chronological order
READY_COUNT=0
PENDING_COUNT=0
DONE_COUNT=0
WARN_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0
ZERO_HASH="0x0000000000000000000000000000000000000000000000000000000000000000"
BUNDLED_IDS=" "
UNPAUSE_TARGETS=" "
LEFT_READY_COUNT=0
SAFE_HOLDS_FACTORY=false
HANDOVER_BLOCKED=""

# While the Safe still holds the V3 factory roles (Deploy.s.sol creates it that way so its address is the same on every
# chain), bundle the handover first: the timelock operations need the timelock to be the factory admin
HANDOVER_COUNT=0
FACTORY=$(jq -r '.agentWalletFactory // empty' "$(dirname "$0")/../deployments.json")
if [ -n "$FACTORY" ] && [ "$FACTORY" != "0x0000000000000000000000000000000000000000" ]; then
  SAFE_HOLDS_FACTORY=$(cast call "$FACTORY" "hasRole(bytes32,address)(bool)" "$ZERO_HASH" "$SAFE" --rpc-url "$RPC")
  if [ "$SAFE_HOLDS_FACTORY" = "true" ]; then
    : "${DEPLOYER_ADDRESS:?DEPLOYER_ADDRESS (the emergency admin) is required for the V3 factory handover}"
    : "${SERVER_ADDRESS:?SERVER_ADDRESS is required for the V3 factory handover}"
    VAULT_REGISTRY=$(jq -r '.vaultAdapterRegistry // empty' "$(dirname "$0")/../deployments.json")
    IS_EMERGENCY_ADMIN=$(cast call "$VAULT_REGISTRY" "hasRole(bytes32,address)(bool)" "$(cast keccak EMERGENCY_ROLE)" "$DEPLOYER_ADDRESS" --rpc-url "$RPC")
    IS_PROPOSER=$(cast call "$TIMELOCK" "hasRole(bytes32,address)(bool)" "$(cast keccak PROPOSER_ROLE)" "$DEPLOYER_ADDRESS" --rpc-url "$RPC")
    V2_FACTORY=$(jq -r '.agentWalletV2Factory // empty' "$(dirname "$0")/../deployments.json")
    IS_LIVE_OPERATOR=$(cast call "$V2_FACTORY" "hasRole(bytes32,address)(bool)" "$(cast keccak AGENT_OPERATOR_ROLE)" "$SERVER_ADDRESS" --rpc-url "$RPC")
    HANDOVER_BLOCKED=""
    [ "$IS_EMERGENCY_ADMIN" = "true" ] || HANDOVER_BLOCKED="DEPLOYER_ADDRESS $DEPLOYER_ADDRESS is not the emergency admin of the V3 vault registry"
    [ "$IS_PROPOSER" = "true" ] || HANDOVER_BLOCKED="DEPLOYER_ADDRESS $DEPLOYER_ADDRESS is no longer a timelock proposer (revoked as compromised?), so it must not get the factory's emergency role"
    [ "$IS_LIVE_OPERATOR" = "true" ] || HANDOVER_BLOCKED="SERVER_ADDRESS $SERVER_ADDRESS is not an operator of the V2 factory"
  fi
  if [ "$SAFE_HOLDS_FACTORY" = "true" ] && [ -n "$HANDOVER_BLOCKED" ]; then
    echo ""
    echo "⚠️  V3 factory handover NOT bundled: $HANDOVER_BLOCKED."
    echo "  Ready operations that call the factory $FACTORY are left out until the handover runs; have the Safe send the calls script/factory-handover.sh prints, with the right emergency admin, first"
  elif [ "$SAFE_HOLDS_FACTORY" = "true" ]; then
    HANDOVER=$("$(dirname "$0")/factory-handover.sh" "$FACTORY" "$SAFE" "$TIMELOCK" "$DEPLOYER_ADDRESS" "$SERVER_ADDRESS" "$RPC")
    while read -r CALL; do
      [ -n "$CALL" ] || continue
      jq -n --arg to "$FACTORY" --arg data "$CALL" '{to: $to, value: "0", data: $data, contractMethod: null, contractInputsValues: null}' > "$WORK/handover-$HANDOVER_COUNT.json"
      HANDOVER_COUNT=$(( HANDOVER_COUNT + 1 ))
    done <<< "$HANDOVER"
    echo ""
    echo "🟢 V3 factory handover: the Safe still holds the factory roles; $HANDOVER_COUNT calls bundled first"
    echo "  admin → $TIMELOCK, operator → $SERVER_ADDRESS, emergency → $DEPLOYER_ADDRESS"
  fi
fi

while IFS=' ' read -r PROPOSED OP_ID TX_HASH; do
  TS=$(cat "$WORK/$OP_ID.ts" 2>/dev/null | awk '{print $1}' || echo "0")
  FROM=$(cat "$WORK/$OP_ID.from" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
  TO=$(cat "$WORK/$OP_ID.to" 2>/dev/null | tr -d '[:space:]' || echo "")
  PROPOSED_DATE=$(date -r "$PROPOSED" "+%Y-%m-%d %H:%M %Z" 2>/dev/null || echo "?")

  # Resolve proposer label
  FROM_L=$(echo "$FROM" | tr '[:upper:]' '[:lower:]')
  SAFE_L=$(echo "$SAFE" | tr '[:upper:]' '[:lower:]')
  OLD_L=$(echo "$OLD_DEPLOYER" | tr '[:upper:]' '[:lower:]')
  NEW_L=$(echo "$NEW_DEPLOYER" | tr '[:upper:]' '[:lower:]')
  UNKNOWN_PROPOSER=false

  SCHEDULERS=$(cat "$WORK/$OP_ID.scheduler" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//' || true)

  if [ "$SCHEDULERS" = "$SAFE_L" ]; then
    PROPOSER_LABEL="Safe"
  elif [ -n "$SCHEDULERS" ]; then
    FROM="$SCHEDULERS"
    PROPOSER_LABEL="⚠️  NOT THE SAFE: scheduled by $SCHEDULERS inside a Safe transaction"
    UNKNOWN_PROPOSER=true
    WARN_COUNT=$(( WARN_COUNT + 1 ))
  elif [ "$(cat "$WORK/$OP_ID.safe" 2>/dev/null)" = "true" ]; then
    PROPOSER_LABEL="⚠️  UNVERIFIED: a Safe transaction sent by $FROM to $TO and the trace is unavailable; decode it to see who called schedule"
    UNKNOWN_PROPOSER=true
    WARN_COUNT=$(( WARN_COUNT + 1 ))
  elif [ -n "$OLD_DEPLOYER" ] && [ "$FROM_L" = "$OLD_L" ]; then
    PROPOSER_LABEL="DEPLOYER_ADDRESS_OLD1"
  elif [ -n "$NEW_DEPLOYER" ] && [ "$FROM_L" = "$NEW_L" ]; then
    PROPOSER_LABEL="DEPLOYER_ADDRESS"
  else
    PROPOSER_LABEL="⚠️  UNKNOWN ($FROM)"
    UNKNOWN_PROPOSER=true
    WARN_COUNT=$(( WARN_COUNT + 1 ))
  fi

  if ! [[ "$TS" =~ ^[0-9]+$ ]]; then
    ERROR_COUNT=$(( ERROR_COUNT + 1 ))
    echo "⚠️  $OP_ID — status read failed; not bundled (rerun the script)"
    echo "  proposed: $PROPOSED_DATE  proposer: $PROPOSER_LABEL"

  elif [ "$TS" = "0" ]; then
    DONE_COUNT=$(( DONE_COUNT + 1 ))
    echo "❌ $OP_ID"
    echo "  proposed: $PROPOSED_DATE  proposer: $PROPOSER_LABEL"

  elif [ "$TS" = "1" ]; then
    DONE_COUNT=$(( DONE_COUNT + 1 ))
    echo "✅ $OP_ID"
    echo "  proposed: $PROPOSED_DATE  proposer: $PROPOSER_LABEL"

  elif [[ "$TS" =~ ^[0-9]+$ ]] && [ "$TS" -gt "$NOW" ]; then
    PENDING_COUNT=$(( PENDING_COUNT + 1 ))
    SECS=$(( TS - NOW ))
    HRS=$(( SECS / 3600 ))
    MIN=$(( (SECS % 3600) / 60 ))
    READY_AT=$(date -r "$TS" "+%Y-%m-%d %H:%M %Z" 2>/dev/null || echo "?")
    echo "⏳ $OP_ID — ${HRS}h ${MIN}m (ready $READY_AT)"
    echo "  proposed: $PROPOSED_DATE  proposer: $PROPOSER_LABEL"

  else
    echo ""

    if $UNKNOWN_PROPOSER; then
      echo ""
      echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      echo "  !! ⚠️  WARNING: OPERATION FROM UNKNOWN PROPOSER      !!"
      echo "  !!   from:     $FROM (to $TO)"
      echo "  !!   expected: the Safe $SAFE"
      [ -n "$OLD_DEPLOYER" ] && echo "  !!          or $OLD_DEPLOYER (DEPLOYER_ADDRESS_OLD1)"
      [ -n "$NEW_DEPLOYER" ] && echo "  !!          or $NEW_DEPLOYER (DEPLOYER_ADDRESS)"
      echo "  !!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
      echo ""
    fi

    echo "🟢 $OP_ID"
    echo "  proposed: $PROPOSED_DATE  proposer: $PROPOSER_LABEL"
    TX_FILE="$WORK/tx-$(printf '%05d' "$READY_COUNT").json"

    CALLS=$(echo "$LOGS" | jq -r --arg id "$OP_ID" '[.[] | select(.topics[1] == $id)] | unique_by(.topics[2]) | sort_by(.topics[2]) | .[].data')
    TARGETS=()
    VALUES=()
    PAYLOADS=()
    PREDECESSOR=""
    while read -r CALL_DATA; do
      DECODED=$(cast abi-decode "f()(address,uint256,bytes,bytes32,uint256)" "$CALL_DATA")
      TARGETS+=("$(echo "$DECODED" | sed -n '1p' | awk '{print $1}')")
      VALUES+=("$(echo "$DECODED" | sed -n '2p' | awk '{print $1}')")
      PAYLOADS+=("$(echo "$DECODED" | sed -n '3p' | awk '{print $1}')")
      PREDECESSOR=$(echo "$DECODED" | sed -n '4p' | awk '{print $1}')
    done <<< "$CALLS"
    SALT=$(echo "$SALT_LOGS" | jq -r --arg id "$OP_ID" '[.[] | select(.topics[1] == $id) | .data][0] // empty')
    SALT="${SALT:-$ZERO_HASH}"

    # Leave out an operation that would make the whole Safe transaction revert: a call to the factory while the handover
    # is not in the bundle, an unpause() of a registry that is not paused, or a second unpause() of the same registry
    SKIP_REASON=""
    OP_UNPAUSES=""
    FACTORY_L=$(echo "${FACTORY:-}" | tr '[:upper:]' '[:lower:]')
    for i in "${!TARGETS[@]}"; do
      TARGET_L=$(echo "${TARGETS[$i]}" | tr '[:upper:]' '[:lower:]')
      if [ "$SAFE_HOLDS_FACTORY" = "true" ] && [ -n "$HANDOVER_BLOCKED" ] && [ "$TARGET_L" = "$FACTORY_L" ]; then
        SKIP_REASON="it calls the factory, and the factory handover is not in this bundle"
      elif [ "${PAYLOADS[$i]}" = "0x3f4ba83a" ]; then
        IS_PAUSED=$(cast call "${TARGETS[$i]}" "paused()(bool)" --rpc-url "$RPC" 2>/dev/null || true)
        if [ "$IS_PAUSED" = "false" ]; then
          SKIP_REASON="${TARGETS[$i]} is not paused, so its unpause() would revert (a standing unpause)"
        elif [ "$IS_PAUSED" != "true" ]; then
          SKIP_REASON="paused() of ${TARGETS[$i]} could not be read; rerun the script"
        elif [[ "$UNPAUSE_TARGETS$OP_UNPAUSES" == *" $TARGET_L "* ]]; then
          SKIP_REASON="another unpause() of ${TARGETS[$i]} is already in this bundle, and a second would revert it"
        else
          OP_UNPAUSES="$OP_UNPAUSES$TARGET_L "
        fi
      fi
    done
    if [ -n "$SKIP_REASON" ]; then
      LEFT_READY_COUNT=$(( LEFT_READY_COUNT + 1 ))
      echo "  ⏸  left ready, not bundled: $SKIP_REASON"
      echo ""
      continue
    fi

    SINGLE_ID=""
    if [ "${#TARGETS[@]}" -eq 1 ]; then
      SINGLE_ID=$(cast keccak "$(cast abi-encode "f(address,uint256,bytes,bytes32,bytes32)" "${TARGETS[0]}" "${VALUES[0]}" "${PAYLOADS[0]}" "$PREDECESSOR" "$SALT")")
    fi

    if [ "$SINGLE_ID" = "$OP_ID" ]; then
      jq -n \
        --arg to "$TIMELOCK" \
        --arg target "${TARGETS[0]}" \
        --arg value "${VALUES[0]}" \
        --arg payload "${PAYLOADS[0]}" \
        --arg predecessor "$PREDECESSOR" \
        --arg salt "$SALT" \
        '{
          to: $to,
          value: "0",
          data: null,
          contractMethod: {
            inputs: [
              {internalType: "address", name: "target", type: "address"},
              {internalType: "uint256", name: "value", type: "uint256"},
              {internalType: "bytes", name: "payload", type: "bytes"},
              {internalType: "bytes32", name: "predecessor", type: "bytes32"},
              {internalType: "bytes32", name: "salt", type: "bytes32"}
            ],
            name: "execute",
            payable: false
          },
          contractInputsValues: {
            target: $target,
            value: $value,
            payload: $payload,
            predecessor: $predecessor,
            salt: $salt
          }
        }' > "$TX_FILE"
    else
      jq -n \
        --arg to "$TIMELOCK" \
        --arg targets "[$(printf '%s, ' "${TARGETS[@]}" | sed 's/, $//')]" \
        --arg values "[$(printf '%s, ' "${VALUES[@]}" | sed 's/, $//')]" \
        --arg payloads "[$(printf '%s, ' "${PAYLOADS[@]}" | sed 's/, $//')]" \
        --arg predecessor "$PREDECESSOR" \
        --arg salt "$SALT" \
        '{
          to: $to,
          value: "0",
          data: null,
          contractMethod: {
            inputs: [
              {internalType: "address[]", name: "targets", type: "address[]"},
              {internalType: "uint256[]", name: "values", type: "uint256[]"},
              {internalType: "bytes[]", name: "payloads", type: "bytes[]"},
              {internalType: "bytes32", name: "predecessor", type: "bytes32"},
              {internalType: "bytes32", name: "salt", type: "bytes32"}
            ],
            name: "executeBatch",
            payable: false
          },
          contractInputsValues: {
            targets: $targets,
            values: $values,
            payloads: $payloads,
            predecessor: $predecessor,
            salt: $salt
          }
        }' > "$TX_FILE"
    fi

    PREDECESSOR_READY=true
    if [ -n "$PREDECESSOR" ] && [ "$PREDECESSOR" != "$ZERO_HASH" ] && [[ "$BUNDLED_IDS" != *" $PREDECESSOR "* ]]; then
      PREDECESSOR_DONE=$(cast call --rpc-url "$RPC" "$TIMELOCK" "isOperationDone(bytes32)(bool)" "$PREDECESSOR" 2>/dev/null || echo "false")
      [ "$PREDECESSOR_DONE" = "true" ] || PREDECESSOR_READY=false
    fi
    if $PREDECESSOR_READY; then
      READY_COUNT=$(( READY_COUNT + 1 ))
      BUNDLED_IDS="$BUNDLED_IDS$OP_ID "
      UNPAUSE_TARGETS="$UNPAUSE_TARGETS$OP_UNPAUSES"
      for UNPAUSED in $OP_UNPAUSES; do
        echo "  ⚠️  this bundle UNPAUSES $UNPAUSED: leave it out if the registry was paused on purpose (e.g. while wallets sync after an operator revocation)"
      done
    else
      SKIPPED_COUNT=$(( SKIPPED_COUNT + 1 ))
      rm -f "$TX_FILE"
      echo "  ⏸  not bundled: predecessor $PREDECESSOR is neither done nor earlier in this bundle"
    fi
    echo ""
  fi
done < "$SORT_FILE"

echo "================================================="
echo "Done: $DONE_COUNT  |  Pending: $PENDING_COUNT  |  Ready: $READY_COUNT  |  Waiting on predecessor: $SKIPPED_COUNT  |  Ready but left out: $LEFT_READY_COUNT  |  Status unreadable: $ERROR_COUNT"
if [ "$WARN_COUNT" -gt 0 ]; then
  echo "!! WARNING: $WARN_COUNT operation(s) from UNKNOWN proposer(s) !!"
fi
echo "================================================="

if [ "$READY_COUNT" -gt 0 ] || [ "$HANDOVER_COUNT" -gt 0 ]; then
  OUTPUT_JSON="timelock-execute-$(date +%Y%m%d-%H%M%S).json"
  HANDOVER_FILES=()
  for (( i = 0; i < HANDOVER_COUNT; i++ )); do HANDOVER_FILES+=("$WORK/handover-$i.json"); done
  TX_ARRAY=$(jq -s '.' ${HANDOVER_FILES[@]+"${HANDOVER_FILES[@]}"} $(ls "$WORK"/tx-*.json 2>/dev/null | sort))
  jq -n \
    --argjson transactions "$TX_ARRAY" \
    --argjson createdAt "$(( $(date +%s) * 1000 ))" \
    --arg safe "$SAFE" \
    '{
      version: "1.0",
      chainId: "8453",
      createdAt: $createdAt,
      meta: {
        name: "Execute Timelock Operations",
        description: "",
        txBuilderVersion: "1.16.5",
        createdFromSafeAddress: $safe,
        createdFromOwnerAddress: ""
      },
      transactions: $transactions
    }' > "$OUTPUT_JSON"
  echo ""
  echo "Safe Transaction Builder JSON: $OUTPUT_JSON"
  echo "Upload at: app.safe.global → New transaction → Transaction Builder"
fi
