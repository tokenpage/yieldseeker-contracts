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
OPS=$(echo "$LOGS" | jq -r '[.[] | {id: .topics[1], tx: .transactionHash, block: .blockNumber}] | unique_by(.id) | .[] | "\(.id) \(.tx) \(.block)"')
OP_COUNT=$(echo "$OPS" | grep -c .)

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
    BLOCK_DEC=$(printf "%d" "$BLOCK_NUM" 2>/dev/null || echo "0")
    BLK_TS_HEX=$(cast block --rpc-url "$ARCHIVE_RPC" --json "$BLOCK_DEC" 2>/dev/null | jq -r '(.data // .).timestamp // "0x0"')
    BLK_TS=$(printf "%d" "$BLK_TS_HEX" 2>/dev/null || echo "0")
    echo "${BLK_TS:-0}" > "$WORK/$OP_ID.proposed"
  ) &
done <<< "$OPS"

wait

# 3. Build list sorted by proposed date ascending
SORT_FILE="$WORK/sorted.txt"
while IFS=' ' read -r OP_ID TX_HASH BLOCK_NUM; do
  PROPOSED=$(cat "$WORK/$OP_ID.proposed" 2>/dev/null | awk '{print $1}' || echo "0")
  echo "$PROPOSED $OP_ID $TX_HASH"
done <<< "$OPS" | sort -n > "$SORT_FILE"

# 4. Print results in chronological order
READY_COUNT=0
PENDING_COUNT=0
DONE_COUNT=0
WARN_COUNT=0
SKIPPED_COUNT=0
ERROR_COUNT=0
ZERO_HASH="0x0000000000000000000000000000000000000000000000000000000000000000"
BUNDLED_IDS=" "

while IFS=' ' read -r PROPOSED OP_ID TX_HASH; do
  TS=$(cat "$WORK/$OP_ID.ts" 2>/dev/null | awk '{print $1}' || echo "0")
  FROM=$(cat "$WORK/$OP_ID.from" 2>/dev/null | tr -d '[:space:]' || echo "unknown")
  TO=$(cat "$WORK/$OP_ID.to" 2>/dev/null | tr -d '[:space:]' || echo "")
  PROPOSED_DATE=$(date -r "$PROPOSED" "+%Y-%m-%d %H:%M %Z" 2>/dev/null || echo "?")

  # Resolve proposer label
  FROM_L=$(echo "$FROM" | tr '[:upper:]' '[:lower:]')
  TO_L=$(echo "$TO" | tr '[:upper:]' '[:lower:]')
  SAFE_L=$(echo "$SAFE" | tr '[:upper:]' '[:lower:]')
  OLD_L=$(echo "$OLD_DEPLOYER" | tr '[:upper:]' '[:lower:]')
  NEW_L=$(echo "$NEW_DEPLOYER" | tr '[:upper:]' '[:lower:]')
  UNKNOWN_PROPOSER=false

  if [ "$TO_L" = "$SAFE_L" ]; then
    PROPOSER_LABEL="Safe"
  elif [ -z "$OLD_DEPLOYER" ] && [ -z "$NEW_DEPLOYER" ]; then
    PROPOSER_LABEL="$FROM"
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
    else
      SKIPPED_COUNT=$(( SKIPPED_COUNT + 1 ))
      rm -f "$TX_FILE"
      echo "  ⏸  not bundled: predecessor $PREDECESSOR is neither done nor earlier in this bundle"
    fi
    echo ""
  fi
done < "$SORT_FILE"

echo "================================================="
echo "Done: $DONE_COUNT  |  Pending: $PENDING_COUNT  |  Ready: $READY_COUNT  |  Waiting on predecessor: $SKIPPED_COUNT  |  Status unreadable: $ERROR_COUNT"
if [ "$WARN_COUNT" -gt 0 ]; then
  echo "!! WARNING: $WARN_COUNT operation(s) from UNKNOWN proposer(s) !!"
fi
echo "================================================="

# 3. While the Safe still holds the V3 factory roles (Deploy.s.sol creates it that way so its address is the same on
#    every chain), bundle the handover first: the timelock operations need the timelock to be the factory admin
HANDOVER_COUNT=0
FACTORY=$(jq -r '.agentWalletFactory // empty' "$(dirname "$0")/../deployments.json")
if [ -n "$FACTORY" ] && [ "$FACTORY" != "0x0000000000000000000000000000000000000000" ]; then
  HANDOVER=$("$(dirname "$0")/factory-handover.sh" "$FACTORY" "$SAFE" "$TIMELOCK" "${DEPLOYER_ADDRESS:?DEPLOYER_ADDRESS (the emergency admin) is required}" "${SERVER_ADDRESS:?SERVER_ADDRESS is required}" "$RPC")
  while read -r CALL; do
    [ -n "$CALL" ] || continue
    jq -n --arg to "$FACTORY" --arg data "$CALL" '{to: $to, value: "0", data: $data, contractMethod: null, contractInputsValues: null}' > "$WORK/handover-$HANDOVER_COUNT.json"
    HANDOVER_COUNT=$(( HANDOVER_COUNT + 1 ))
  done <<< "$HANDOVER"
  if [ "$HANDOVER_COUNT" -gt 0 ]; then
    echo ""
    echo "🟢 V3 factory handover: the Safe still holds the factory roles; $HANDOVER_COUNT calls bundled first"
    echo "  admin → $TIMELOCK, operator → $SERVER_ADDRESS, emergency → $DEPLOYER_ADDRESS"
  fi
fi

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
