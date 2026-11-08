#!/usr/bin/env bash
# Runs Deploy.s.sol against a local fork of Base, schedules Configure.s.sol behind its timelock batch, executes both
# batches as the Safe, and checks that a second run of each has nothing left to configure. deployments.json and the
# scripts' broadcast directories are restored afterwards.
#
# Usage: ./script/dry-run-deploy.sh
# Requires: anvil, cast, forge, jq; RPC_NODE_URL_8453

set -euo pipefail

cd "$(dirname "$0")/.."
PORT=8546
RPC="http://127.0.0.1:$PORT"
SAFE=0x403EE3392A40D017a009384D1bE1a2Ca921C2fEa
TIMELOCK=$(jq -r .adminTimelock deployments.json)
# anvil's well-known default accounts, only ever used on the local fork
DEPLOYER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
DEPLOYER=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
WORK=$(mktemp -d)

cp deployments.json "$WORK/deployments.json"
for SCRIPT in Deploy Configure; do
  [ -d "broadcast/$SCRIPT.s.sol" ] && cp -R "broadcast/$SCRIPT.s.sol" "$WORK/broadcast-$SCRIPT"
done
cleanup() {
  [ -n "${ANVIL_PID:-}" ] && kill "$ANVIL_PID" 2>/dev/null || true
  cp "$WORK/deployments.json" deployments.json
  for SCRIPT in Deploy Configure; do
    rm -rf "broadcast/$SCRIPT.s.sol"
    [ -d "$WORK/broadcast-$SCRIPT" ] && cp -R "$WORK/broadcast-$SCRIPT" "broadcast/$SCRIPT.s.sol"
  done
  rm -rf "$WORK"
}
trap cleanup EXIT

anvil --fork-url "$RPC_NODE_URL_8453" --port "$PORT" --silent &
ANVIL_PID=$!
until cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; do sleep 1; done

cast rpc anvil_impersonateAccount "$SAFE" --rpc-url "$RPC" >/dev/null
cast rpc anvil_setBalance "$SAFE" 0x56BC75E2D63100000 --rpc-url "$RPC" >/dev/null
cast send "$TIMELOCK" "grantRole(bytes32,address)" "$(cast keccak PROPOSER_ROLE)" "$DEPLOYER" --from "$SAFE" --unlocked --rpc-url "$RPC" >/dev/null
SERVER="${SERVER_ADDRESS:-0x70997970C51812dc3A010C7d01b50e0d17dc79C8}"

run_deploy() {
  SERVER_ADDRESS="$SERVER" \
  FEE_COLLECTOR_ADDRESS="${FEE_COLLECTOR_ADDRESS:-0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC}" \
  MULTISIG_ADMIN_ADDRESS="$SAFE" \
  DEPLOYER_PRIVATE_KEY="$DEPLOYER_KEY" \
  forge script script/Deploy.s.sol:DeployScript --rpc-url "$RPC" --broadcast --skip "test/**" --out "$WORK/out" --cache-path "$WORK/cache" 2>&1
}

run_configure() {
  DEPLOYER_PRIVATE_KEY="$DEPLOYER_KEY" \
  forge script script/Configure.s.sol:ConfigureScript --rpc-url "$RPC" --broadcast --skip "test/**" --out "$WORK/out" --cache-path "$WORK/cache" --sig "run(bytes32)" "$1" 2>&1
}

# Executes the last batch a script scheduled, as the Safe, and adds its gas to TOTAL_GAS
TOTAL_GAS=0
execute_scheduled_batch() {
  local SCHEDULE RECEIPT
  SCHEDULE=$(jq -c '[.transactions[] | select(.function // "" | startswith("scheduleBatch"))] | last | .arguments' "broadcast/$1.s.sol/8453/run-latest.json")
  RECEIPT=$(cast send "$TIMELOCK" "executeBatch(address[],uint256[],bytes[],bytes32,bytes32)" \
    "$(echo "$SCHEDULE" | jq -r '.[0]')" "$(echo "$SCHEDULE" | jq -r '.[1]')" "$(echo "$SCHEDULE" | jq -r '.[2]')" \
    "$(echo "$SCHEDULE" | jq -r '.[3]')" "$(echo "$SCHEDULE" | jq -r '.[4]')" \
    --from "$SAFE" --unlocked --gas-limit 16000000 --rpc-url "$RPC" --json)
  [ "$(jq -r .status <<< "$RECEIPT")" = "0x1" ] || { echo "$1 executeBatch failed"; exit 1; }
  TOTAL_GAS=$(( TOTAL_GAS + $(jq -r .gasUsed <<< "$RECEIPT") ))
  echo "$1 batch executed as the Safe ($(( $(jq -r .gasUsed <<< "$RECEIPT") )) gas)"
}

batch_id() {
  local SCHEDULE
  SCHEDULE=$(jq -c '[.transactions[] | select(.function // "" | startswith("scheduleBatch"))] | last | .arguments' "broadcast/$1.s.sol/8453/run-latest.json")
  cast call "$TIMELOCK" "hashOperationBatch(address[],uint256[],bytes[],bytes32,bytes32)(bytes32)" \
    "$(echo "$SCHEDULE" | jq -r '.[0]')" "$(echo "$SCHEDULE" | jq -r '.[1]')" "$(echo "$SCHEDULE" | jq -r '.[2]')" \
    "$(echo "$SCHEDULE" | jq -r '.[3]')" "$(echo "$SCHEDULE" | jq -r '.[4]')" --rpc-url "$RPC"
}

FIRST=$(run_deploy) || { echo "$FIRST"; exit 1; }
echo "$FIRST" | grep -E "Refusing|Error|revert" && exit 1
OPS=$(echo "$FIRST" | sed -n 's/.*Executing \([0-9]*\) operations in batch.*/\1/p')
FACTORY=$(jq -r .agentWalletFactory deployments.json)
HANDOVER=$(./script/factory-handover.sh "$FACTORY" "$SAFE" "$TIMELOCK" "$DEPLOYER" "$SERVER" "$RPC")
if [ -n "$HANDOVER" ]; then
  while read -r CALL; do
    grep -qi -- "$CALL" <<< "$FIRST" || { echo "Deploy.s.sol did not print the handover call $CALL"; exit 1; }
    TOTAL_GAS=$(( TOTAL_GAS + $(cast send "$FACTORY" --data "$CALL" --from "$SAFE" --unlocked --rpc-url "$RPC" --json | jq -r .gasUsed) ))
  done <<< "$HANDOVER"
  echo "Safe handed the factory over ($(echo "$HANDOVER" | grep -c .) calls)"
fi
DEPLOY_BATCH=0x0000000000000000000000000000000000000000000000000000000000000000
if [ -z "$OPS" ]; then
  echo "First Deploy run: nothing to configure"
else
  echo "First Deploy run: scheduled $OPS operations"
  DEPLOY_BATCH=$(batch_id Deploy)
fi

CONFIGURE=$(run_configure "$DEPLOY_BATCH") || { echo "$CONFIGURE"; exit 1; }
if grep -E "^[[:space:]]*!!|replacing the adapter of" <<< "$CONFIGURE"; then
  echo "Configure found on-chain entries the config lacks, or would re-route a target to another adapter; fix script/config/base.json"
  exit 1
fi
CONFIGURE_OPS=$(echo "$CONFIGURE" | sed -n 's/.*Scheduling \([0-9]*\) operations in one batch.*/\1/p')
echo "First Configure run: scheduled ${CONFIGURE_OPS:-0} operations behind the Deploy batch"

DELAY=$(cast call "$TIMELOCK" "getMinDelay()(uint256)" --rpc-url "$RPC" | awk '{print $1}')
cast rpc evm_increaseTime $(( DELAY + 1 )) --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null
[ -z "$OPS" ] || execute_scheduled_batch Deploy
[ -z "$CONFIGURE_OPS" ] || execute_scheduled_batch Configure
# check-timelock.sh puts the handover and every ready batch in one Safe transaction; keep a margin for the Safe and MultiSend
echo "Handover and batches together: $TOTAL_GAS gas"
[ "$TOTAL_GAS" -le 15000000 ] || { echo "Over 15,000,000 gas: one Safe transaction would come too close to Base's 16,777,216 cap; execute the batches in separate Safe transactions"; exit 1; }

SECOND=$(run_deploy) || { echo "$SECOND"; exit 1; }
grep -q "No configuration needed" <<< "$SECOND" || { echo "Second Deploy run still has configuration to do:"; grep -E "Executing|Preparing" <<< "$SECOND"; exit 1; }
echo "Second Deploy run: no configuration needed."
SECOND_CONFIGURE=$(run_configure 0x0000000000000000000000000000000000000000000000000000000000000000) || { echo "$SECOND_CONFIGURE"; exit 1; }
grep -q "Nothing to configure" <<< "$SECOND_CONFIGURE" || { echo "Second Configure run still has configuration to do:"; grep -E "^[[:space:]]*\+" <<< "$SECOND_CONFIGURE"; exit 1; }
echo "Second Configure run: nothing to configure."

INIT_CODE="$(forge inspect src/AgentWalletFactory.sol:YieldSeekerAgentWalletFactory bytecode)$(cast abi-encode "f(address,address,address)" "$SAFE" "$SAFE" "$SAFE" | sed 's/^0x//')"
CREATE2_HASH=$(cast keccak "0xff4e59b44847b379578588920cA78FbF26c0B4956C$(cast to-uint256 0x711 | sed 's/^0x//')$(cast keccak "$INIT_CODE" | sed 's/^0x//')")
EXPECTED_FACTORY=$(cast to-check-sum-address "0x${CREATE2_HASH:26}")
[ "$(cast to-check-sum-address "$FACTORY")" = "$EXPECTED_FACTORY" ] || { echo "Factory $FACTORY is not at the chain-independent address $EXPECTED_FACTORY"; exit 1; }
has_role() { cast call "$FACTORY" "hasRole(bytes32,address)(bool)" "$1" "$2" --rpc-url "$RPC"; }
ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
OPERATOR_ROLE=$(cast keccak AGENT_OPERATOR_ROLE)
EMERGENCY_ROLE=$(cast keccak EMERGENCY_ROLE)
[ "$(has_role $ADMIN_ROLE "$TIMELOCK")" = "true" ] && [ "$(has_role $ADMIN_ROLE "$SAFE")" = "false" ] || { echo "Factory admin was not handed to the timelock"; exit 1; }
[ "$(has_role "$OPERATOR_ROLE" "$SERVER")" = "true" ] && [ "$(has_role "$OPERATOR_ROLE" "$SAFE")" = "false" ] || { echo "Factory operator role was not handed to the server"; exit 1; }
[ "$(has_role "$EMERGENCY_ROLE" "$DEPLOYER")" = "true" ] && [ "$(has_role "$EMERGENCY_ROLE" "$SAFE")" = "false" ] || { echo "Factory emergency role was not handed to the deployer"; exit 1; }
[ "$(has_role "$EMERGENCY_ROLE" 0xcec34E6E3babc36Ef72e31bd5808B87214F4A3A8)" = "true" ] || { echo "Factory emergency role was not granted to krishan711.eth"; exit 1; }
echo "Factory $FACTORY depends only on the Safe, so it has this address on every chain where the Safe exists; its roles are handed over. Dry run passed."
