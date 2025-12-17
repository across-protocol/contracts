#!/bin/bash

# This script verifies that deployed contract bytecode matches what was in the broadcast file.
# It takes the following arguments:
# 1. Contract name to verify (e.g., "DstOFTHandler")
# 2. Path to the broadcast JSON (e.g., "broadcast/DeployDstHandler.s.sol/999/run-latest.json")
# 3. Chain name as configured in foundry.toml [rpc_endpoints] (e.g., "hyperevm")
#
# The script compares the full init code (creation bytecode + constructor args) that was
# sent in the deployment transaction against what's actually on chain.
#
# RPC URLs are resolved from foundry.toml [rpc_endpoints] which reference env vars (e.g., NODE_URL_999).
# The script automatically loads .env if present.
#
# Example:
#   ./scripts/verifyBytecode.sh SponsoredCCTPDstPeriphery broadcast/114DeploySponsoredCCTPDstPeriphery.sol/999/run-latest.json hyperevm

set -e

# Load .env file if it exists
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

args=("$@")

if [ ${#args[@]} -ne 3 ]; then
    echo "Usage: $0 <contract_name> <broadcast_json_path> <chain_name>"
    echo ""
    echo "Example: $0 DstOFTHandler broadcast/DeployDstHandler.s.sol/999/run-latest.json hyperevm"
    echo ""
    echo "Available chains (from foundry.toml):"
    grep -E "^[a-z_-]+ = " foundry.toml | grep NODE_URL | sed 's/ =.*//' | sed 's/^/  /'
    exit 1
fi

CONTRACT_NAME=${args[0]}
BROADCAST_JSON=${args[1]}
CHAIN_NAME=${args[2]}

# Check if broadcast file exists
if [ ! -f "$BROADCAST_JSON" ]; then
    echo "Broadcast file not found: $BROADCAST_JSON"
    exit 1
fi

# Get RPC URL from foundry.toml via environment variable
# The foundry.toml uses format: chain_name = "${NODE_URL_CHAINID}"
# We need to extract the env var name and resolve it
# Filter for NODE_URL to avoid matching [etherscan] section
RPC_ENV_VAR=$(grep "^${CHAIN_NAME} = " foundry.toml | grep NODE_URL | sed 's/.*"\${//' | sed 's/}"//')

if [ -z "$RPC_ENV_VAR" ]; then
    echo "Chain '$CHAIN_NAME' not found in foundry.toml [rpc_endpoints]"
    echo ""
    echo "Available chains:"
    grep -E "^[a-z_-]+ = " foundry.toml | grep NODE_URL | sed 's/ =.*//' | sed 's/^/  /'
    exit 1
fi

RPC_URL="${!RPC_ENV_VAR}"

if [ -z "$RPC_URL" ]; then
    echo "Environment variable $RPC_ENV_VAR is not set"
    echo "Please set it to the RPC URL for $CHAIN_NAME"
    exit 1
fi

echo "Verifying deployment from: $BROADCAST_JSON"
echo "Chain: $CHAIN_NAME (RPC: ${RPC_URL:0:50}...)"
echo "Contract: $CONTRACT_NAME"

# Get the CREATE transaction for the specified contract
TX=$(jq -c --arg name "$CONTRACT_NAME" '.transactions[] | select(.transactionType == "CREATE" and .contractName == $name)' "$BROADCAST_JSON" | head -1)

if [ -z "$TX" ]; then
    echo "No CREATE transaction found for contract '$CONTRACT_NAME'"
    echo "Available contracts in this broadcast:"
    jq -r '.transactions[] | select(.transactionType == "CREATE") | .contractName' "$BROADCAST_JSON" | sed 's/^/  /'
    exit 1
fi

TX_HASH=$(echo "$TX" | jq -r '.hash')
EXPECTED_INPUT=$(echo "$TX" | jq -r '.transaction.input' | sed 's/^0x//')
CONTRACT_ADDRESS=$(echo "$TX" | jq -r '.contractAddress')

echo "Address: $CONTRACT_ADDRESS"
echo "TX: $TX_HASH"

# Get on-chain transaction input
ONCHAIN_INPUT=$(cast tx "$TX_HASH" --rpc-url "$RPC_URL" --json 2>/dev/null | jq -r '.input' | sed 's/^0x//')

if [ -z "$ONCHAIN_INPUT" ] || [ "$ONCHAIN_INPUT" = "null" ]; then
    echo "Failed to fetch transaction from chain"
    exit 1
fi

# Compare full init code (creation bytecode + constructor args)
if [ "$EXPECTED_INPUT" = "$ONCHAIN_INPUT" ]; then
    echo "Full init code matches (including constructor args)"
    
    # Also show the keccak hash for reference
    EXPECTED_HASH=$(cast keccak "0x$EXPECTED_INPUT" 2>/dev/null || echo "error")
    echo "Init code hash: $EXPECTED_HASH"
    echo "✅ Deployment verified successfully!"
else
    echo "❌ Init code MISMATCH!"
    echo "Expected hash: $(cast keccak "0x$EXPECTED_INPUT" 2>/dev/null || echo "error")"
    echo "On-chain hash: $(cast keccak "0x$ONCHAIN_INPUT" 2>/dev/null || echo "error")"
    exit 1
fi
