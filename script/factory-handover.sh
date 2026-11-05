#!/usr/bin/env bash
# Prints the calls the Safe makes on the V3 factory to hand its roles to the timelock, the server and the emergency
# admin, one calldata per line, or nothing once the handover is done. Matches _factoryHandoverCalls in Deploy.s.sol.
#
# Usage: ./script/factory-handover.sh <factory> <safe> <timelock> <emergency admin> <server> <rpc>
# Requires: cast

set -euo pipefail

FACTORY=$1
SAFE=$2
TIMELOCK=$3
EMERGENCY_ADMIN=$4
SERVER=$5
RPC=$6
ADMIN_ROLE=0x0000000000000000000000000000000000000000000000000000000000000000
OPERATOR_ROLE=$(cast keccak AGENT_OPERATOR_ROLE)
EMERGENCY_ROLE=$(cast keccak EMERGENCY_ROLE)
same() { [ "$(cast to-check-sum-address "$1")" = "$(cast to-check-sum-address "$2")" ]; }

SAFE_HOLDS_ADMIN=$(cast call "$FACTORY" "hasRole(bytes32,address)(bool)" "$ADMIN_ROLE" "$SAFE" --rpc-url "$RPC")
[ "$SAFE_HOLDS_ADMIN" = "true" ] || exit 0
TIMELOCK_CODE=$(cast code "$TIMELOCK" --rpc-url "$RPC")
[ "$TIMELOCK_CODE" != "0x" ] || { echo "The timelock $TIMELOCK has no code on this chain; refusing to hand the factory to it" >&2; exit 1; }
cast calldata "grantRole(bytes32,address)" "$ADMIN_ROLE" "$TIMELOCK"
cast calldata "grantRole(bytes32,address)" "$OPERATOR_ROLE" "$SERVER"
cast calldata "grantRole(bytes32,address)" "$EMERGENCY_ROLE" "$EMERGENCY_ADMIN"
same "$SAFE" "$SERVER" || cast calldata "revokeRole(bytes32,address)" "$OPERATOR_ROLE" "$SAFE"
same "$SAFE" "$EMERGENCY_ADMIN" || cast calldata "revokeRole(bytes32,address)" "$EMERGENCY_ROLE" "$SAFE"
cast calldata "renounceRole(bytes32,address)" "$ADMIN_ROLE" "$SAFE"
