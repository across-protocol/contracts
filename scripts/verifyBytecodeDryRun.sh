#!/bin/bash
set -euo pipefail

# This script verifies an EVM deployment tx by comparing its raw deployment tx input to an existing
# Foundry dry-run receipt at:
#   broadcast/<script_filename>/<chain_id>/dry-run/run-latest.json
#
# Clean and rerun the deployment script in dry-run mode first. Example:
#   forge clean && forge cache clean
#   forge script script/DeployBaseAdapter.s.sol:DeployBaseAdapter --rpc-url "$NODE_URL_1"
#   ./scripts/verifyBytecodeDryRun.sh 0xf9845ddc7ebcf5e00b6ee2073dfb8cf50a774161e1f4562cd5c11a5016f4bb64 "$NODE_URL_1" Base_Adapter script/DeployBaseAdapter.s.sol
#
# You can also pass the dry-run json path directly instead of a script path.
# If you pass a json path here, it should be the dry-run receipt, not the broadcast receipt:
#   ./scripts/verifyBytecodeDryRun.sh <tx_hash> "$NODE_URL_1" <contract_name> broadcast/<Script>.s.sol/<chain_id>/dry-run/run-latest.json
#
# For artifact-based verification against out/, use ./scripts/verifyBytecode.sh instead.

print_first_diff() {
    local a="$1"
    local b="$2"
    local first_diff=-1
    local i
    local max_cmp=${#a}
    if (( ${#b} < max_cmp )); then max_cmp=${#b}; fi

    for ((i=0; i<max_cmp; i++)); do
        if [[ "${a:$i:1}" != "${b:$i:1}" ]]; then
            first_diff=$i
            break
        fi
    done
    if (( first_diff == -1 && ${#a} != ${#b} )); then
        first_diff=$max_cmp
    fi

    if (( first_diff >= 0 )); then
        local byte_index=$((first_diff / 2))
        local start=$((first_diff - 20))
        (( start < 0 )) && start=0
        echo "First differing nibble index: $first_diff (byte ~$byte_index)"
        echo "Onchain snippet: ${a:$start:80}"
        echo "Dry-run snippet: ${b:$start:80}"
    fi
}

if (( $# != 4 )); then
    echo "Usage:"
    echo "  $0 <tx_hash> <rpc_url> <contract_name> <script_path|dry_run_json_path>"
    echo ""
    echo "Note: if passing a json path directly, it should be broadcast/<Script>.s.sol/<chain_id>/dry-run/run-latest.json"
    exit 1
fi

TX="$1"
RPC="$2"
CONTRACT_NAME="$3"
BROADCAST_REF="$4"

if [[ "$BROADCAST_REF" == *.json ]]; then
    [[ "$BROADCAST_REF" == */dry-run/* ]] || {
        echo "Error: JSON path must be a dry-run receipt (path should contain /dry-run/)."
        echo "Got: $BROADCAST_REF"
        exit 1
    }
    RUN_JSON="$BROADCAST_REF"
else
    SCRIPT_FILE="${BROADCAST_REF%%:*}"
    CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
    RUN_JSON="broadcast/$(basename "$SCRIPT_FILE")/$CHAIN_ID/dry-run/run-latest.json"
fi

[[ -f "$RUN_JSON" ]] || {
    echo "dry-run run json not found: $RUN_JSON"
    echo "Run the deployment script in dry-run mode first after a clean rebuild."
    exit 1
}

ONCHAIN_INPUT=$(cast tx "$TX" --rpc-url "$RPC" --json | jq -r '.input // empty' | sed 's/^0x//' | tr '[:upper:]' '[:lower:]')
[[ -n "$ONCHAIN_INPUT" ]] || { echo "unable to fetch tx input for $TX"; exit 1; }

DRY_INPUT=""
DRY_TX_HASH=""
DRY_TX_TYPE=""
SELECTED_BY="last-contract-create"
CANDIDATE_COUNT=0
while IFS= read -r ENTRY; do
    (( CANDIDATE_COUNT += 1 ))
    C_INPUT=$(jq -r '.transaction.input // empty' <<< "$ENTRY" | sed 's/^0x//' | tr '[:upper:]' '[:lower:]')
    [[ -n "$C_INPUT" ]] || continue

    C_TX_HASH=$(jq -r '.hash // ""' <<< "$ENTRY")
    C_TX_TYPE=$(jq -r '.transactionType // ""' <<< "$ENTRY")
    DRY_INPUT="$C_INPUT"
    DRY_TX_HASH="$C_TX_HASH"
    DRY_TX_TYPE="$C_TX_TYPE"

    if [[ "$C_INPUT" == "$ONCHAIN_INPUT" ]]; then
        SELECTED_BY="matched-tx-input"
        break
    fi
done < <(jq -c --arg name "$CONTRACT_NAME" '.transactions[]? | select((.transactionType=="CREATE" or .transactionType=="CREATE2") and .contractName==$name)' "$RUN_JSON")

(( CANDIDATE_COUNT > 0 )) || {
    echo "no CREATE/CREATE2 tx found for $CONTRACT_NAME in $RUN_JSON"
    exit 1
}
[[ -n "$DRY_INPUT" ]] || {
    echo "found CREATE/CREATE2 tx(s), but no transaction.input payload was present"
    exit 1
}

echo "Onchain tx hash         : $TX"
echo "Dry-run tx hash         : ${DRY_TX_HASH:-unknown}"
echo "Dry-run tx type         : ${DRY_TX_TYPE:-unknown}"
echo "Dry-run selection       : $SELECTED_BY"
echo "Onchain input bytes len : ${#ONCHAIN_INPUT}"
echo "Dry-run input bytes len : ${#DRY_INPUT}"

if [[ "$ONCHAIN_INPUT" == "$DRY_INPUT" ]]; then
    echo "✅ Onchain deployment tx matches dry-run deployment tx input"
    exit 0
fi

echo "❌ Onchain deployment tx does not match dry-run deployment tx input"
echo -n "0x$ONCHAIN_INPUT" | cast keccak
echo -n "0x$DRY_INPUT" | cast keccak
print_first_diff "$ONCHAIN_INPUT" "$DRY_INPUT"
exit 1
