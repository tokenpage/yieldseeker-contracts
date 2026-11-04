#!/usr/bin/env bash
# Runs Deploy.s.sol against a local fork of Base, executes its timelock batch as the Safe, and checks that a second
# run has nothing left to configure. deployments.json and broadcast/Deploy.s.sol are restored afterwards.
#
# Usage: ./script/dry-run-deploy.sh
# Requires: anvil, cast, forge, jq; RPC_NODE_URL_8453

set -euo pipefail

cd "$(dirname "$0")/.."
PORT=8546
RPC="http://127.0.0.1:$PORT"
SAFE="${MULTISIG_ADMIN_ADDRESS:-0x403EE3392A40D017a009384D1bE1a2Ca921C2fEa}"
TIMELOCK=$(jq -r .adminTimelock deployments.json)
# anvil's well-known default accounts, only ever used on the local fork
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
WORK=$(mktemp -d)

cp deployments.json "$WORK/deployments.json"
[ -d broadcast/Deploy.s.sol ] && cp -R broadcast/Deploy.s.sol "$WORK/broadcast-deploy"
cleanup() {
  [ -n "${ANVIL_PID:-}" ] && kill "$ANVIL_PID" 2>/dev/null || true
  cp "$WORK/deployments.json" deployments.json
  rm -rf broadcast/Deploy.s.sol
  [ -d "$WORK/broadcast-deploy" ] && cp -R "$WORK/broadcast-deploy" broadcast/Deploy.s.sol
  rm -rf "$WORK"
}
trap cleanup EXIT

anvil --fork-url "$RPC_NODE_URL_8453" --port "$PORT" --silent &
ANVIL_PID=$!
until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do sleep 1; done

cast rpc anvil_impersonateAccount "$SAFE" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$SAFE" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
cast send "$TIMELOCK" "grantRole(bytes32,address)" "$(cast keccak PROPOSER_ROLE)" "$DEPLOYER" --from "$SAFE" --unlocked --rpc-url "$RPC" >/dev/null

run_deploy() {
  SERVER_ADDRESS="${SERVER_ADDRESS:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}" \
  FEE_COLLECTOR_ADDRESS="${FEE_COLLECTOR_ADDRESS:-0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC}" \
  MULTISIG_ADMIN_ADDRESS="$SAFE" \
  DEPLOYER_PRIVATE_KEY="$DEPLOYER_KEY" \
  forge script script/Deploy.s.sol:DeployScript --rpc-url "$RPC" --broadcast --skip "test/**" --out "$WORK/out" --cache-path "$WORK/cache" 2>&1
}

FIRST=$(run_deploy)
echo "$FIRST" | grep -E "Refusing|Error|revert" && exit 1
OPS=$(echo "$FIRST" | sed -n 's/.*Executing \([0-9]*\) operations in batch.*/\1/p')
if [ -z "$OPS" ]; then
  echo "First run: nothing to configure"
else
  echo "First run: scheduled $OPS operations"
  DELAY=$(cast call "$TIMELOCK" "getMinDelay()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
  cast rpc evm_increaseTime $(( DELAY + 1 )) --rpc-url "$RPC" >/dev/null
  cast rpc evm_mine --rpc-url "$RPC" >/dev/null
  SCHEDULE=$(jq -c '[.transactions[] | select(.function // "" | startswith("scheduleBatch"))] | last | .arguments' broadcast/Deploy.s.sol/8453/run-latest.json)
  STATUS=$(cast send "$TIMELOCK" "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)" \
    "$(echo "$SCHEDULE" | jq -r '.[0]')" "$(echo "$SCHEDULE" | jq -r '.[1]')" "$(echo "$SCHEDULE" | jq -r '.[2]')" \
    "$(echo "$SCHEDULE" | jq -r '.[3]')" "$(echo "$SCHEDULE" | jq -r '.[4]')" \
    --from "$SAFE" --unlocked --gas-limit 29000000 --rpc-url "$RPC" | awk '/^status/ {print $2}')
  [ "$STATUS" = "1" ] || { echo "executeBatch failed"; exit 1; }
  echo "Batch executed as the Safe"
fi

SECOND=$(run_deploy)
echo "$SECOND" | grep -q "No configuration needed" || { echo "Second run still has configuration to do:"; echo "$SECOND" | grep -E "Executing|Preparing"; exit 1; }
echo "Second run: no configuration needed. Dry run passed."
