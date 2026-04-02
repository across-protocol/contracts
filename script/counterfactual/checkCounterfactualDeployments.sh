#!/usr/bin/env bash
# Verifies counterfactual contract deployments across all chains.
# Reads deployed addresses from broadcast/, expected values from config.toml and constants.json,
# and queries on-chain state via cast. Outputs a markdown report.
#
# Usage:
#   ./script/counterfactual/checkCounterfactualDeployments.sh                  # All chains
#   ./script/counterfactual/checkCounterfactualDeployments.sh --chain 42161    # Single chain
#
# Requires: cast, jq, python3
# Environment: NODE_URL_<chainId> for each chain (e.g. NODE_URL_1, NODE_URL_42161)
#   Tip: use `set -a && source .env && set +a` to export all env vars before running.

set -eo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BROADCAST_DIR="$ROOT/broadcast"
CONSTANTS_FILE="$ROOT/generated/constants.json"
CONFIG_FILE="$ROOT/script/counterfactual/config.toml"
OUTPUT_FILE="$ROOT/script/counterfactual/deployment-report.md"

# All chains with counterfactual deployments.
ALL_CHAINS=(1 10 56 130 137 143 232 324 480 999 1135 1868 4217 4326 8453 9745 42161 57073 59144 81457 534352 7777777)

# Map contract name to deploy script name.
script_name_for() {
    case "$1" in
        CounterfactualDeposit) echo "DeployCounterfactualDeposit" ;;
        CounterfactualDepositFactory) echo "DeployCounterfactualDepositFactory" ;;
        WithdrawImplementation) echo "DeployWithdrawImplementation" ;;
        CounterfactualDepositSpokePool) echo "DeployCounterfactualDepositSpokePool" ;;
        CounterfactualDepositCCTP) echo "DeployCounterfactualDepositCCTP" ;;
        CounterfactualDepositOFT) echo "DeployCounterfactualDepositOFT" ;;
        AdminWithdrawManager) echo "DeployAdminWithdrawManager" ;;
        *) echo "" ;;
    esac
}

# Options.
FILTER_CHAIN=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --chain) FILTER_CHAIN="$2"; shift 2 ;;
        --help)
            echo "Usage: $0 [--chain <chainId>]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Helpers ---

normalize_addr() {
    echo "$1" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}

rpc_url_for_chain() {
    local chain_id="$1"
    python3 -c "import os; print(os.environ.get('NODE_URL_${chain_id}', ''))"
}

chain_name() {
    local chain_id="$1"
    jq -r ".PUBLIC_NETWORKS.\"${chain_id}\".name // \"Chain ${chain_id}\"" "$CONSTANTS_FILE"
}

block_explorer() {
    local chain_id="$1"
    # Override for chains where constants.json has the wrong explorer.
    case "$chain_id" in
        4326) echo "https://mega.etherscan.io" ;;
        7777777) echo "https://explorer.zora.energy" ;;
        *) jq -r ".PUBLIC_NETWORKS.\"${chain_id}\".blockExplorer // \"\"" "$CONSTANTS_FILE" ;;
    esac
}

explorer_link() {
    local chain_id="$1"
    local addr="$2"
    local base
    base=$(block_explorer "$chain_id")
    if [[ -n "$base" ]]; then
        base="${base%/}"
        echo "[${addr}](${base}/address/${addr})"
    else
        echo "$addr"
    fi
}

# Get deployed address from broadcast JSON.
get_deployed_address() {
    local contract_name="$1"
    local chain_id="$2"
    local script_name
    script_name=$(script_name_for "$contract_name")
    local broadcast_file="$BROADCAST_DIR/${script_name}.s.sol/${chain_id}/run-latest.json"

    if [[ ! -f "$broadcast_file" ]]; then
        echo ""
        return
    fi

    jq -r '.transactions[0].contractAddress // ""' "$broadcast_file"
}

# Get constructor arguments from broadcast JSON.
get_constructor_args() {
    local contract_name="$1"
    local chain_id="$2"
    local script_name
    script_name=$(script_name_for "$contract_name")
    local broadcast_file="$BROADCAST_DIR/${script_name}.s.sol/${chain_id}/run-latest.json"

    if [[ ! -f "$broadcast_file" ]]; then
        echo ""
        return
    fi

    jq -r '.transactions[0].arguments // [] | .[]' "$broadcast_file"
}

# Read config.toml value for a chain.
config_value() {
    local chain_id="$1"
    local key="$2"
    python3 -c "
import re, sys

chain_id = '${chain_id}'
key = '${key}'
in_chain = False
in_address = False

with open('${CONFIG_FILE}') as f:
    for line in f:
        line = line.strip()
        if line == f'[{chain_id}]':
            in_chain = True
            in_address = False
            continue
        if line == f'[{chain_id}.address]':
            in_chain = True
            in_address = True
            continue
        if line.startswith('[') and line != f'[{chain_id}]' and line != f'[{chain_id}.address]':
            if in_chain:
                in_chain = False
                in_address = False
        if in_address:
            m = re.match(rf'^{key}\s*=\s*\"(.+?)\"', line)
            if m:
                print(m.group(1))
                sys.exit(0)
print('')
" 2>/dev/null
}

# Check bytecode existence.
check_bytecode() {
    local rpc="$1"
    local addr="$2"
    local code=""

    for attempt in 1 2 3; do
        code=$(cast code "$addr" --rpc-url "$rpc" 2>/dev/null | tr -d '[:space:]') && break
        sleep 0.3
    done

    if [[ -n "$code" && "$code" != "0x" ]]; then
        echo "deployed"
    else
        echo "no code"
    fi
}

# Query on-chain view function with retry.
try_cast_call() {
    local rpc="$1"
    local addr="$2"
    local sig="$3"
    local result=""

    for attempt in 1 2 3; do
        result=$(cast call "$addr" "$sig" --rpc-url "$rpc" 2>/dev/null | grep -v '^\s*$' | head -1 | sed 's/\[.*\]//' | tr -d '[:space:]') && break
        sleep 0.3
    done

    echo "$result"
}

# --- Report building ---

REPORT_LINES=()

add_row() {
    local chain_id="$1"
    local contract="$2"
    local addr="$3"
    local field="$4"
    local value="$5"
    local is_address="$6"

    local addr_display
    addr_display=$(explorer_link "$chain_id" "$addr")

    local value_display
    if [[ "$is_address" == "true" && -n "$value" ]]; then
        value_display=$(explorer_link "$chain_id" "$value")
    else
        value_display="\`${value}\`"
    fi

    REPORT_LINES+=("| ${contract} | ${addr_display} | ${field} | ${value_display} |")
}

# --- Per-chain check ---

check_chain() {
    local chain_id="$1"
    local name
    name=$(chain_name "$chain_id")
    local rpc
    rpc=$(rpc_url_for_chain "$chain_id")

    REPORT_LINES+=("")
    REPORT_LINES+=("## ${name} (Chain ${chain_id})")
    REPORT_LINES+=("")
    REPORT_LINES+=("| Contract | Address | Field | Value |")
    REPORT_LINES+=("| --- | --- | --- | --- |")

    if [[ -z "$rpc" ]]; then
        REPORT_LINES+=("| - | - | RPC | NODE_URL_${chain_id} not set |")
        return
    fi

    # --- Bytecode-only contracts ---
    for contract in CounterfactualDeposit CounterfactualDepositFactory WithdrawImplementation; do
        local addr
        addr=$(get_deployed_address "$contract" "$chain_id")
        if [[ -n "$addr" ]]; then
            local code_status
            code_status=$(check_bytecode "$rpc" "$addr")
            add_row "$chain_id" "$contract" "$addr" "bytecode" "$code_status" "false"
        fi
    done

    # --- CounterfactualDepositSpokePool ---
    local sp_addr
    sp_addr=$(get_deployed_address "CounterfactualDepositSpokePool" "$chain_id")
    if [[ -n "$sp_addr" ]]; then
        local actual
        actual=$(try_cast_call "$rpc" "$sp_addr" "spokePool()(address)")
        add_row "$chain_id" "CounterfactualDepositSpokePool" "$sp_addr" "spokePool" "$actual" "true"

        actual=$(try_cast_call "$rpc" "$sp_addr" "signer()(address)")
        add_row "$chain_id" "CounterfactualDepositSpokePool" "$sp_addr" "signer" "$actual" "true"

        actual=$(try_cast_call "$rpc" "$sp_addr" "wrappedNativeToken()(address)")
        add_row "$chain_id" "CounterfactualDepositSpokePool" "$sp_addr" "wrappedNativeToken" "$actual" "true"
    fi

    # --- CounterfactualDepositCCTP ---
    local cctp_addr
    cctp_addr=$(get_deployed_address "CounterfactualDepositCCTP" "$chain_id")
    if [[ -z "$cctp_addr" ]]; then
        REPORT_LINES+=("| CounterfactualDepositCCTP | - | - | \`not deployed\` |")
    elif [[ -n "$cctp_addr" ]]; then
        local actual
        actual=$(try_cast_call "$rpc" "$cctp_addr" "srcPeriphery()(address)")
        add_row "$chain_id" "CounterfactualDepositCCTP" "$cctp_addr" "srcPeriphery" "$actual" "true"

        actual=$(try_cast_call "$rpc" "$cctp_addr" "sourceDomain()(uint32)")
        add_row "$chain_id" "CounterfactualDepositCCTP" "$cctp_addr" "sourceDomain" "$actual" "false"
    fi

    # --- CounterfactualDepositOFT ---
    local oft_addr
    oft_addr=$(get_deployed_address "CounterfactualDepositOFT" "$chain_id")
    if [[ -z "$oft_addr" ]]; then
        REPORT_LINES+=("| CounterfactualDepositOFT | - | - | \`not deployed\` |")
    elif [[ -n "$oft_addr" ]]; then
        local actual
        actual=$(try_cast_call "$rpc" "$oft_addr" "oftSrcPeriphery()(address)")
        add_row "$chain_id" "CounterfactualDepositOFT" "$oft_addr" "oftSrcPeriphery" "$actual" "true"

        actual=$(try_cast_call "$rpc" "$oft_addr" "srcEid()(uint32)")
        add_row "$chain_id" "CounterfactualDepositOFT" "$oft_addr" "srcEid" "$actual" "false"
    fi

    # --- AdminWithdrawManager ---
    local awm_addr
    awm_addr=$(get_deployed_address "AdminWithdrawManager" "$chain_id")
    if [[ -n "$awm_addr" ]]; then
        local actual
        actual=$(try_cast_call "$rpc" "$awm_addr" "owner()(address)")
        add_row "$chain_id" "AdminWithdrawManager" "$awm_addr" "owner" "$actual" "true"

        actual=$(try_cast_call "$rpc" "$awm_addr" "directWithdrawer()(address)")
        add_row "$chain_id" "AdminWithdrawManager" "$awm_addr" "directWithdrawer" "$actual" "true"

        actual=$(try_cast_call "$rpc" "$awm_addr" "signer()(address)")
        add_row "$chain_id" "AdminWithdrawManager" "$awm_addr" "signer" "$actual" "true"
    fi
}

# --- Main ---

echo "Checking counterfactual deployments..."

if [[ -n "$FILTER_CHAIN" ]]; then
    CHAINS=("$FILTER_CHAIN")
else
    CHAINS=("${ALL_CHAINS[@]}")
fi

for chain_id in "${CHAINS[@]}"; do
    name=$(chain_name "$chain_id")
    echo "  Checking ${name} (${chain_id})..."
    check_chain "$chain_id" || {
        REPORT_LINES+=("| - | - | error | Script error for chain ${chain_id} |")
        echo "    ERROR: check failed for chain ${chain_id}, continuing..."
    }
done

# --- Write report ---

# Build new content for the chains we just checked.
NEW_CONTENT=""
for line in "${REPORT_LINES[@]}"; do
    NEW_CONTENT="${NEW_CONTENT}${line}
"
done

TIMESTAMP=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

if [[ -n "$FILTER_CHAIN" && -f "$OUTPUT_FILE" ]]; then
    # Merge: replace just this chain's section in the existing report.
    # Write new content to a temp file to avoid quoting issues.
    TMPFILE=$(mktemp)
    for line in "${REPORT_LINES[@]}"; do
        echo "$line" >> "$TMPFILE"
    done

    python3 - "$FILTER_CHAIN" "$OUTPUT_FILE" "$TMPFILE" "$TIMESTAMP" <<'PYEOF'
import re, sys

chain_id = sys.argv[1]
output_file = sys.argv[2]
tmpfile = sys.argv[3]
timestamp = sys.argv[4]

with open(tmpfile, 'r') as f:
    new_content = f.read()

with open(output_file, 'r') as f:
    existing = f.read()

# Pattern: ## ChainName (Chain <id>) ... up to next ## or end of file.
pattern = r'\n## [^\n]+ \(Chain ' + chain_id + r'\)\n.*?(?=\n## |\Z)'
match = re.search(pattern, existing, re.DOTALL)

if match:
    updated = existing[:match.start()] + '\n' + new_content.rstrip('\n') + existing[match.end():]
else:
    # Insert in sorted order by chain ID.
    chain_sections = list(re.finditer(r'\n## [^\n]+ \(Chain (\d+)\)', existing))
    insert_pos = len(existing)
    for m in chain_sections:
        if int(m.group(1)) > int(chain_id):
            insert_pos = m.start()
            break
    updated = existing[:insert_pos] + '\n' + new_content.rstrip('\n') + existing[insert_pos:]

updated = re.sub(r'Generated: .+', 'Generated: ' + timestamp, updated, count=1)

with open(output_file, 'w') as f:
    f.write(updated)
PYEOF

    rm -f "$TMPFILE"
else
    # Full run: write entire report.
    {
        echo "# Counterfactual Deployment Report"
        echo ""
        echo "Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo "$NEW_CONTENT"
    } > "$OUTPUT_FILE"
fi

echo ""
echo "Report written to: $OUTPUT_FILE"
