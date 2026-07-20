#!/bin/bash
set -uo pipefail

# Deploys the chain-specific CounterfactualBeacon implementation (via
# script/counterfactual/DeployCounterfactualBeaconImpl.s.sol) on every chain in
# script/counterfactual/config.toml except Tron, or only on the chains given as arguments.
# Each chain's full forge output is appended to a log file and a per-chain PASS/FAIL summary is
# printed (and logged) at the end; the script exits non-zero if any chain failed.
#
# Usage:
#   ./scripts/deployCounterfactualBeaconImpls.sh [options] [chainId ...]
#
# Options:
#   --broadcast    Actually deploy. Without it every chain runs as a forge dry-run (simulation).
#   --verify       Verify on the block explorer (passed through to forge; needs ETHERSCAN_API_KEY).
#   --env <file>   Env file for MNEMONIC / NODE_URL_<chainId> variables (default: .env if it exists)
#   --log <file>   Log file path (default: deploy-beacon-impls-<UTC timestamp>.log in the repo root)
#
# Prerequisites:
#   - MNEMONIC set (directly or via the env file)
#   - NODE_URL_<chainId> set for every targeted chain whose config.toml endpoint_url references it
#
# Note the beacon impl deploy self-validates: it cross-checks config.toml's [N.bool] declared
# support flags against constants.json + deployed-addresses.json and reverts on any mismatch, so a
# FAIL here can mean a config disagreement rather than an RPC/gas problem — read the log.
#
# After a broadcast run, verify the deployed impls across all chains with
# script/counterfactual/CheckCounterfactualBeaconImpls.s.sol before asking the owner to upgrade.
# On chains where the dev wallet still owns the beacon, ./scripts/upgradeCounterfactualBeacons.sh
# performs the upgrade; multisig-owned chains use the calldata printed by the check script.

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$REPO_ROOT/script/counterfactual/config.toml"
DEPLOY_SCRIPT="script/counterfactual/DeployCounterfactualBeaconImpl.s.sol:DeployCounterfactualBeaconImpl"
GLOBALS_CHAIN_ID=0
TRON_CHAIN_ID=728126428

ENV_FILE=""
LOG_FILE=""
BROADCAST=0
VERIFY=0
REQUESTED_CHAINS=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --broadcast) BROADCAST=1; shift ;;
        --verify) VERIFY=1; shift ;;
        --env) ENV_FILE="$2"; shift 2 ;;
        --log) LOG_FILE="$2"; shift 2 ;;
        -h|--help) sed -n '/^# Deploys/,/read the log\.$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)
            if [[ "$1" =~ ^[0-9]+$ ]]; then
                REQUESTED_CHAINS="$REQUESTED_CHAINS $1"; shift
            else
                echo "Unknown argument: $1" >&2; exit 1
            fi
            ;;
    esac
done

# Source env file (explicit --env, else .env if present) without clobbering already-set variables.
if [ -z "$ENV_FILE" ] && [ -f "$REPO_ROOT/.env" ]; then ENV_FILE="$REPO_ROOT/.env"; fi
if [ -n "$ENV_FILE" ]; then
    if [ ! -f "$ENV_FILE" ]; then echo "Env file not found: $ENV_FILE" >&2; exit 1; fi
    set -a; source "$ENV_FILE"; set +a
fi
if [ -z "${MNEMONIC:-}" ]; then
    echo "MNEMONIC is not set (directly or via --env). Aborting." >&2
    exit 1
fi

LOG_FILE="${LOG_FILE:-$REPO_ROOT/deploy-beacon-impls-$(date -u +%Y%m%d-%H%M%S).log}"

# Chain list: every top-level [N] section in config.toml minus globals and Tron, unless an explicit
# list was given (which is still validated against config.toml so typos fail fast).
# (Space-separated strings, not arrays: macOS ships bash 3.2, where empty arrays trip `set -u`.)
CONFIG_CHAINS=$(grep -oE '^\[[0-9]+\]' "$CONFIG" | tr -d '[]')
config_has_chain() { echo "$CONFIG_CHAINS" | grep -qx "$1"; }

CHAINS=""
if [ -n "${REQUESTED_CHAINS:-}" ]; then
    for cid in $REQUESTED_CHAINS; do
        if ! config_has_chain "$cid"; then
            echo "Chain $cid is not in $CONFIG. Aborting." >&2; exit 1
        fi
        if [ "$cid" -eq "$TRON_CHAIN_ID" ]; then
            echo "Chain $cid is Tron — forge cannot broadcast there (use the Tron TS script). Aborting." >&2
            exit 1
        fi
        CHAINS="$CHAINS $cid"
    done
else
    for cid in $CONFIG_CHAINS; do
        [ "$cid" -eq "$GLOBALS_CHAIN_ID" ] || [ "$cid" -eq "$TRON_CHAIN_ID" ] || CHAINS="$CHAINS $cid"
    done
fi
CHAINS=${CHAINS# }
if [ -z "$CHAINS" ]; then echo "No chains to deploy." >&2; exit 1; fi

# Section-scoped config.toml lookups: chain display name from the [N] header comment, endpoint_url
# from the line inside section [N] (with ${NODE_URL_N}-style env indirection resolved here).
chain_name() {
    awk -v sec="[$1]" '$1 == sec { if (match($0, /# */)) print substr($0, RSTART + RLENGTH); exit }' "$CONFIG"
}
chain_rpc_url() {
    local raw
    raw=$(awk -v sec="[$1]" '$1 == sec {found=1; next} /^\[/ {found=0} found && $1 == "endpoint_url" {gsub(/.*= *"|"$/, ""); print; exit}' "$CONFIG")
    if [[ "$raw" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
        local var="${BASH_REMATCH[1]}"
        echo "${!var:-}"
    else
        echo "$raw"
    fi
}

FORGE_FLAGS=(-vvv)
[ "$BROADCAST" -eq 1 ] && FORGE_FLAGS+=(--broadcast)
[ "$VERIFY" -eq 1 ] && FORGE_FLAGS+=(--verify)
MODE=$([ "$BROADCAST" -eq 1 ] && echo "BROADCAST" || echo "DRY-RUN (pass --broadcast to deploy)")

{
    echo "CounterfactualBeacon impl deployment run — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Mode: $MODE"
    echo "Chains: $CHAINS"
    echo
} | tee "$LOG_FILE"

RESULTS=""
ATTEMPTED=0
FAILURES=0
for cid in $CHAINS; do
    ATTEMPTED=$((ATTEMPTED + 1))
    name=$(chain_name "$cid")
    label="chain $cid${name:+ ($name)}"
    echo "==================== $label ====================" >> "$LOG_FILE"
    echo "--- $label ..."

    rpc_url=$(chain_rpc_url "$cid")
    if [ -z "$rpc_url" ]; then
        msg="FAIL  $label — endpoint_url unresolved (is NODE_URL_$cid set?)"
        echo "$msg" >> "$LOG_FILE"; echo "$msg"
        RESULTS="$RESULTS$msg"$'\n'; FAILURES=$((FAILURES + 1))
        continue
    fi

    if output=$(cd "$REPO_ROOT" && forge script "$DEPLOY_SCRIPT" --rpc-url "$rpc_url" "${FORGE_FLAGS[@]}" 2>&1); then
        impl=$(echo "$output" | grep -oE 'Beacon impl: 0x[0-9a-fA-F]{40}' | head -1 | awk '{print $3}')
        msg="OK    $label — impl ${impl:-<address not found in output>}"
    else
        msg="FAIL  $label — forge script exited non-zero (see log for output)"
        FAILURES=$((FAILURES + 1))
    fi
    echo "$output" >> "$LOG_FILE"
    echo "$msg" | tee -a "$LOG_FILE"
    RESULTS="$RESULTS$msg"$'\n'
done

{
    echo
    echo "==================== SUMMARY ($MODE) ===================="
    printf '%s' "$RESULTS"
    echo "----------------------------------------------------------"
    echo "$ATTEMPTED chain(s) attempted, $FAILURES failure(s). Full output: $LOG_FILE"
} | tee -a "$LOG_FILE"

[ "$FAILURES" -eq 0 ] || exit 1
