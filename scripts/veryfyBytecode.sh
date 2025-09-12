#!/bin/bash

# This script verifies the bytecode of a contract onchain matches the bytecode in the artifact
# It takes the following arguments:
# 1. The transaction hash of the contract deployment
# 2. The RPC URL to use
# 3. The name of the contract

# Note that this script doesn't take into account any link libraries that are used in the contract

args=("$@")

if [ ${#args[@]} -ne 3 ]; then
    echo "Usage: $0 <tx_hash> <rpc_url> <contract_name>"
    exit 1
fi

TX=${args[0]}
RPC=${args[1]}
CONTRACT_NAME=${args[2]}

ONCHAIN=$(cast tx $TX --rpc-url $RPC --json | jq -r '.input' | sed 's/^0x//')

ART=out/$CONTRACT_NAME.sol/$CONTRACT_NAME.json

CREATION=$(jq -r '.bytecode.object' "$ART" | sed 's/^0x//')

CODE_ONCHAIN=${ONCHAIN:0:${#CREATION}}

cast keccak $CODE_ONCHAIN
cast keccak $CREATION

if [[ $CODE_ONCHAIN == $CREATION ]]; then
    echo "✅ Code match"
else
    echo "❌ Code mismatch"
fi
