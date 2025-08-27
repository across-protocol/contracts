#!/bin/bash

args=("$@")

if [ ${#args[@]} -ne 3 ]; then
    echo "Usage: $0 <tx_hash> <rpc_url> <contract_name>"
    exit 1
fi

TX=${args[0]}
RPC=${args[1]}
CONTRACT_NAME=${args[2]}

ONCHAIN=$(cast tx $TX --rpc-url $RPC --json | jq -r '.input' | sed 's/^0x//')
echo "$ONCHAIN" > onchain_creation.hex

ART=out/$CONTRACT_NAME.sol/$CONTRACT_NAME.json

CREATION=$(jq -r '.bytecode.object' "$ART" | sed 's/^0x//')

TAIL=${ONCHAIN:${#CREATION}}
CODE_ONCHAIN=${ONCHAIN:0:${#CREATION}}



cast keccak $CODE_ONCHAIN
cast keccak $CREATION

if [[ $CODE_ONCHAIN == $CREATION ]]; then 
    echo "✅ Code match"; 
else 
    echo "❌ Code mismatch"; 
fi





