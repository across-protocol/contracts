#!/bin/bash
set -euo pipefail

# This script verifies the bytecode of a contract onchain matches the bytecode in the artifact
# It takes the following arguments:
# 1. The transaction hash of the contract deployment
# 2. The RPC URL to use
# 3. The name of the contract

# Note that this script doesn't take into account any link libraries that are used in the contract

# Example commands:
# ./scripts/verifyBytecode.sh 0x2015905f5cbdb4afeba30deb6dc0f0f779ba4af5bc43edceabf0bf4343cb290b "$NODE_URL_1" SponsoredCCTPSrcPeriphery script/mintburn/cctp/DeploySponsoredCCTPSrcPeriphery.s.sol
# ./scripts/verifyBytecode.sh --broadcast "$NODE_URL_1" SponsoredCCTPSrcPeriphery script/mintburn/cctp/DeploySponsoredCCTPSrcPeriphery.s.sol

strip_cbor_metadata() {
    local hex="$1"
    local n=${#hex}
    if (( n < 4 )); then
        echo "$hex"
        return
    fi

    local len_hex="${hex:$((n - 4)):4}"
    [[ "$len_hex" =~ ^[0-9a-fA-F]{4}$ ]] || { echo "$hex"; return; }

    local metadata_bytes=$((16#$len_hex))
    local remove_nibbles=$((metadata_bytes * 2 + 4))
    if (( remove_nibbles >= n )); then
        echo "$hex"
        return
    fi

    echo "${hex:0:$((n - remove_nibbles))}"
}

if [[ "$1" != "--broadcast" && $# -ne 4 ]] || [[ "$1" == "--broadcast" && $# -ne 4 ]]; then
    echo "Usage:"
    echo "  $0 <tx_hash> <rpc_url> <contract_name> <script_path|run_json_path>"
    echo "  $0 --broadcast <rpc_url> <contract_name> <script_path|run_json_path>"
    exit 1
fi

if [[ "$1" == "--broadcast" ]]; then
    RPC="$2"
    CONTRACT_NAME="$3"
    BROADCAST_REF="$4"
    if [[ "$BROADCAST_REF" == *.json ]]; then
        RUN_JSON="$BROADCAST_REF"
    else
        CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
        RUN_JSON="broadcast/$(basename "$BROADCAST_REF")/$CHAIN_ID/run-latest.json"
        [[ -f "$RUN_JSON" ]] || RUN_JSON="broadcast/$(basename "$BROADCAST_REF")/$CHAIN_ID/dry-run/run-latest.json"
    fi
    [[ -f "$RUN_JSON" ]] || { echo "run json not found: $RUN_JSON"; exit 1; }

    TX_ENTRY=$(jq -c --arg name "$CONTRACT_NAME" '[.transactions[] | select(.transactionType=="CREATE" and .contractName==$name)][-1]' "$RUN_JSON")
    [[ "$TX_ENTRY" != "null" ]] || { echo "no CREATE tx found for $CONTRACT_NAME in $RUN_JSON"; exit 1; }
    TX=$(jq -r '.hash' <<< "$TX_ENTRY")
else
    TX="$1"
    RPC="$2"
    CONTRACT_NAME="$3"
    BROADCAST_REF="$4"
    if [[ "$BROADCAST_REF" == *.json ]]; then
        RUN_JSON="$BROADCAST_REF"
    else
        CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
        RUN_JSON="broadcast/$(basename "$BROADCAST_REF")/$CHAIN_ID/run-latest.json"
        [[ -f "$RUN_JSON" ]] || RUN_JSON="broadcast/$(basename "$BROADCAST_REF")/$CHAIN_ID/dry-run/run-latest.json"
    fi
    [[ -f "$RUN_JSON" ]] || { echo "run json not found: $RUN_JSON"; exit 1; }

    TX_ENTRY=$(jq -c --arg tx "$TX" --arg name "$CONTRACT_NAME" '[.transactions[]? | select((((.hash // "") | tostring | ascii_downcase) == ($tx | ascii_downcase)) and .transactionType=="CREATE" and .contractName==$name)][0]' "$RUN_JSON")
    [[ "$TX_ENTRY" != "null" ]] || {
        echo "tx $TX for CREATE $CONTRACT_NAME not found in $RUN_JSON"
        echo "Hint: run-latest.json may have an incorrect/stale CREATE tx hash. You can try to FIX MANUALLY."
        echo "Hint: pass the exact broadcast run JSON that contains this tx hash."
        exit 1
    }
fi

ONCHAIN=$(cast tx "$TX" --rpc-url "$RPC" --json | jq -r '.input' | sed 's/^0x//')

ART=out/$CONTRACT_NAME.sol/$CONTRACT_NAME.json
[[ -f "$ART" ]] || { echo "artifact not found: $ART"; exit 1; }

CREATION=$(jq -r '.bytecode.object' "$ART" | sed 's/^0x//')

LOCAL_INIT="$CREATION"

if [[ -n "${TX_ENTRY:-}" && "$TX_ENTRY" != "null" ]]; then
    CONSTRUCTOR_TYPES=$(jq -r '([.abi[]? | select(.type=="constructor")][0].inputs // []) | map(.type) | join(",")' "$ART")
    CONSTRUCTOR_SIG="constructor($CONSTRUCTOR_TYPES)"
    CONSTRUCTOR_ARGS=()
    while IFS= read -r arg; do
        CONSTRUCTOR_ARGS+=("$arg")
    done < <(jq -cr '.arguments[]?' <<< "$TX_ENTRY")
    ENCODED_ARGS=$(cast abi-encode "$CONSTRUCTOR_SIG" "${CONSTRUCTOR_ARGS[@]}" | sed 's/^0x//')
    LOCAL_INIT="${CREATION}${ENCODED_ARGS}"
    [[ -n "${RUN_JSON:-}" ]] && echo "Using constructor args from: $RUN_JSON"
fi

echo -n "0x$ONCHAIN" | cast keccak
echo -n "0x$LOCAL_INIT" | cast keccak

if [[ "$ONCHAIN" == "$LOCAL_INIT" ]]; then
    echo "✅ Code match"
elif [[ -n "${ENCODED_ARGS:-}" ]]; then
    ONCHAIN_CREATION="${ONCHAIN:0:${#CREATION}}"
    ONCHAIN_ARGS="${ONCHAIN:${#CREATION}:${#ENCODED_ARGS}}"
    STRIPPED_ONCHAIN_CREATION=$(strip_cbor_metadata "$ONCHAIN_CREATION")
    STRIPPED_LOCAL_CREATION=$(strip_cbor_metadata "$CREATION")
    if [[ "$ONCHAIN_ARGS" == "$ENCODED_ARGS" && "$STRIPPED_ONCHAIN_CREATION" == "$STRIPPED_LOCAL_CREATION" ]]; then
        echo "✅ Code match (metadata hash differs)"
        exit 0
    fi
    echo "❌ Code mismatch"
    echo "Onchain bytes : ${#ONCHAIN}"
    echo "Local bytes   : ${#LOCAL_INIT}"
    echo "Hint: compare verified compiler settings (solc/optimizer runs/via-ir/evmVersion) against your local build."
    echo "Hint: metadata-only drift is common; if constructor args match, check explorer verification details."

    # Focused diagnostics: avoid printing giant payloads.
    echo -n "0x$ONCHAIN_CREATION" | cast keccak
    echo -n "0x$CREATION" | cast keccak

    echo -n "0x$ONCHAIN_ARGS" | cast keccak
    echo -n "0x$ENCODED_ARGS" | cast keccak
    if [[ "$ONCHAIN_ARGS" == "$ENCODED_ARGS" ]]; then
        echo "Constructor args: ✅ match"
    else
        echo "Constructor args: ❌ mismatch"
    fi

    FIRST_DIFF=-1
    for ((i=0; i<${#ONCHAIN}; i++)); do
        if [[ "${ONCHAIN:$i:1}" != "${LOCAL_INIT:$i:1}" ]]; then
            FIRST_DIFF=$i
            break
        fi
    done
    if [[ $FIRST_DIFF -ge 0 ]]; then
        BYTE_INDEX=$((FIRST_DIFF / 2))
        START=$((FIRST_DIFF - 20))
        (( START < 0 )) && START=0
        echo "First differing nibble index: $FIRST_DIFF (byte ~$BYTE_INDEX)"
        echo "Onchain snippet: ${ONCHAIN:$START:80}"
        echo "Local snippet  : ${LOCAL_INIT:$START:80}"
    fi
    exit 1
else
    echo "❌ Code mismatch"
    echo "Onchain bytes : ${#ONCHAIN}"
    echo "Local bytes   : ${#LOCAL_INIT}"
    echo "Hint: compare verified compiler settings (solc/optimizer runs/via-ir/evmVersion) against your local build."
    echo "Hint: metadata-only drift is common; if constructor args match, check explorer verification details."
    FIRST_DIFF=-1
    for ((i=0; i<${#ONCHAIN}; i++)); do
        if [[ "${ONCHAIN:$i:1}" != "${LOCAL_INIT:$i:1}" ]]; then
            FIRST_DIFF=$i
            break
        fi
    done
    if [[ $FIRST_DIFF -ge 0 ]]; then
        BYTE_INDEX=$((FIRST_DIFF / 2))
        START=$((FIRST_DIFF - 20))
        (( START < 0 )) && START=0
        echo "First differing nibble index: $FIRST_DIFF (byte ~$BYTE_INDEX)"
        echo "Onchain snippet: ${ONCHAIN:$START:80}"
        echo "Local snippet  : ${LOCAL_INIT:$START:80}"
    fi
    exit 1
fi