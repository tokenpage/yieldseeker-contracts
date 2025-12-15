#!/bin/bash
# Starts a local anvil fork of Base Mainnet
# Usage: ./start_fork.sh [RPC_URL]

# Default RPC URL from env var or argument
RPC_URL=${1:-$RPC_NODE_URL_8453}

if [ -z "$RPC_URL" ]; then
    echo "Error: RPC_NODE_URL_8453 is not set. Please set it in your .env or pass it as an argument."
    echo "Usage: ./start_fork.sh <ALCHEMY_OR_INFURA_BASE_URL>"
    exit 1
fi

echo "Starting Anvil Base Mainnet Fork..."
echo "Chain ID: 31337 (Local Dev) - Forking Base (8453)"
echo "Forking from: $RPC_URL"

# Start anvil with auto-mining and a decent block time simulation if needed,
# but for dev speed usually instant mining is default.
# We bind to 0.0.0.0 to allow access from other containers/hosts if needed.
anvil --fork-url "$RPC_URL" --chain-id 31337 --host 0.0.0.0
