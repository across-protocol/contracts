#!/bin/bash
set -euo pipefail

# Verifies a zkSync deployment tx by comparing its create(bytes32,bytes32,bytes)
# calldata to the latest dry-run output at:
# broadcast/<script_filename>/<chain_id>/dry-run/run-latest.json
#
# Usage:
#   ./scripts/verifyBytecodeZksync2.sh <tx_hash> <rpc_url> <script_path_or_script_spec>
#
# Example (recommended two-step flow):
# yarn forge-script-zksync script/DeployZkSyncSpokePool.s.sol:DeployZkSyncSpokePool --rpc-url "$NODE_URL_324" && \
# ./scripts/verifyBytecodeZksync2.sh 0x0ca83c1523292bcd5bdff9eb7aee5c17ec4ab2147d23e648384b14ed400a7317 "$NODE_URL_324" script/DeployZkSyncSpokePool.s.sol:DeployZkSyncSpokePool

ZKSYNC_CREATE_SELECTOR="0x9c4d535b" # create(bytes32,bytes32,bytes)

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

if (( $# != 3 )); then
    echo "Usage:"
    echo "  $0 <tx_hash> <rpc_url> <script_path_or_script_spec>"
    exit 1
fi

TX="$1"
RPC="$2"
SCRIPT_SPEC="$3"
if [[ "$SCRIPT_SPEC" == *.json ]]; then
    echo "Pass a script path/spec, not a json file. This script always uses dry-run/run-latest.json."
    exit 1
fi

if [[ "$SCRIPT_SPEC" != *:* ]]; then
    BASE=$(basename "$SCRIPT_SPEC")
    CONTRACT="${BASE%.s.sol}"
    SCRIPT_SPEC="$SCRIPT_SPEC:$CONTRACT"
fi

SCRIPT_FILE="${SCRIPT_SPEC%%:*}"
CHAIN_ID=$(cast chain-id --rpc-url "$RPC")
RUN_JSON="broadcast/$(basename "$SCRIPT_FILE")/$CHAIN_ID/dry-run/run-latest.json"

ONCHAIN_TX_INPUT=$(cast tx "$TX" --rpc-url "$RPC" --json | jq -r '.input // empty')
[[ -n "$ONCHAIN_TX_INPUT" ]] || { echo "unable to fetch tx input for $TX"; exit 1; }

ONCHAIN_SELECTOR=$(echo "${ONCHAIN_TX_INPUT:0:10}" | tr '[:upper:]' '[:lower:]')
[[ "$ONCHAIN_SELECTOR" == "$ZKSYNC_CREATE_SELECTOR" ]] || {
    echo "tx $TX selector is $ONCHAIN_SELECTOR (expected $ZKSYNC_CREATE_SELECTOR)"
    exit 1
}

ONCHAIN_DECODED=$(cast calldata-decode 'create(bytes32,bytes32,bytes)' "$ONCHAIN_TX_INPUT")
ONCHAIN_SALT=$(sed -n '1p' <<< "$ONCHAIN_DECODED" | tr '[:upper:]' '[:lower:]')
ONCHAIN_HASH=$(sed -n '2p' <<< "$ONCHAIN_DECODED" | sed 's/^0x//' | tr '[:upper:]' '[:lower:]')
ONCHAIN_INPUT=$(sed -n '3p' <<< "$ONCHAIN_DECODED" | sed 's/^0x//' | tr '[:upper:]' '[:lower:]')

[[ -f "$RUN_JSON" ]] || {
    echo "run json not found: $RUN_JSON"
    echo "Run the script in dry-run mode first:"
    echo "  FOUNDRY_PROFILE=zksync forge script --zksync --suppress-errors sendtransfer \"$SCRIPT_SPEC\" --rpc-url \"$RPC\""
    exit 1
}

DRY_TX_HASH=""
DRY_SALT=""
DRY_HASH=""
DRY_INPUT=""
SELECTED_BY="last-create-call"
CANDIDATE_COUNT=0
while IFS= read -r ENTRY; do
    (( CANDIDATE_COUNT += 1 ))
    INP=$(jq -r '.transaction.input // empty' <<< "$ENTRY")
    [[ -n "$INP" ]] || continue

    DEC=$(cast calldata-decode 'create(bytes32,bytes32,bytes)' "$INP" 2>/dev/null || true)
    [[ -n "$DEC" ]] || continue

    C_SALT=$(sed -n '1p' <<< "$DEC" | tr '[:upper:]' '[:lower:]')
    C_HASH=$(sed -n '2p' <<< "$DEC" | sed 's/^0x//' | tr '[:upper:]' '[:lower:]')
    C_INPUT=$(sed -n '3p' <<< "$DEC" | sed 's/^0x//' | tr '[:upper:]' '[:lower:]')
    C_TX_HASH=$(jq -r '.hash // ""' <<< "$ENTRY")

    DRY_TX_HASH="$C_TX_HASH"
    DRY_SALT="$C_SALT"
    DRY_HASH="$C_HASH"
    DRY_INPUT="$C_INPUT"

    if [[ "$C_INPUT" == "$ONCHAIN_INPUT" ]]; then
        SELECTED_BY="matched-constructor-input"
        break
    fi
    if [[ "$C_HASH" == "$ONCHAIN_HASH" ]]; then
        SELECTED_BY="matched-bytecode-hash"
    fi
done < <(jq -c '.transactions[]? | select(.transactionType=="CALL" and ((.transaction.input // "" | tostring | ascii_downcase | ltrimstr("0x"))[0:8] == "9c4d535b"))' "$RUN_JSON")

(( CANDIDATE_COUNT > 0 )) || {
    echo "no create(bytes32,bytes32,bytes) CALL tx found in $RUN_JSON"
    exit 1
}
[[ -n "$DRY_HASH" ]] || {
    echo "found candidate CALL tx(s), but failed to decode create(bytes32,bytes32,bytes) calldata"
    exit 1
}

echo "Onchain tx hash         : $TX"
echo "Dry-run tx hash         : ${DRY_TX_HASH:-unknown}"
echo "Dry-run selection       : $SELECTED_BY"
echo "Onchain salt            : $ONCHAIN_SALT"
echo "Dry-run salt            : $DRY_SALT"
echo "Onchain bytecode hash   : 0x$ONCHAIN_HASH"
echo "Dry-run bytecode hash   : 0x$DRY_HASH"
echo "Onchain input bytes len : ${#ONCHAIN_INPUT}"
echo "Dry-run input bytes len : ${#DRY_INPUT}"

OK=true
if [[ "$ONCHAIN_SALT" != "$DRY_SALT" ]]; then
    OK=false
    echo "Salt: ❌ mismatch"
else
    echo "Salt: ✅ match"
fi

if [[ "$ONCHAIN_HASH" != "$DRY_HASH" ]]; then
    OK=false
    echo "Bytecode hash: ❌ mismatch"
else
    echo "Bytecode hash: ✅ match"
fi

if [[ "$ONCHAIN_INPUT" != "$DRY_INPUT" ]]; then
    OK=false
    echo "Constructor/input: ❌ mismatch"
    echo -n "0x$ONCHAIN_INPUT" | cast keccak
    echo -n "0x$DRY_INPUT" | cast keccak
    print_first_diff "$ONCHAIN_INPUT" "$DRY_INPUT"
else
    echo "Constructor/input: ✅ match"
fi

if [[ "$OK" == "true" ]]; then
    echo "✅ Onchain tx matches dry-run create calldata"
    exit 0
fi

echo "❌ Onchain tx does not match dry-run create calldata"
exit 1
