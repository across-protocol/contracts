#!/usr/bin/env bash
set -euo pipefail

# Deploys all 7 counterfactual contracts from a single deployer in a fixed order.
#
# WHY: CREATE addresses are determined by (sender, nonce). By deploying from the same
# address starting at nonce 0 on every chain, each contract lands at the same address
# across all chains regardless of constructor arguments.
#
# The --index argument specifies the BIP-44 derivation index used to derive the deployer
# private key from the mnemonic (m/44'/60'/0'/0/<index>). Use a dedicated index that has
# never sent transactions on any chain, so the deployer starts at nonce 0 everywhere.
# Use the same index across all chains to get the same deployer address and thus the same
# contract addresses.
#
# The --skip argument takes a comma-separated list of deployment indices (0-6) to skip.
# Skipped deployments are not deployed, but a dummy transaction (0-value self-transfer) is
# sent to burn the nonce so that subsequent contracts still land at the correct addresses.
#
# Deployment indices:
#   0 = CounterfactualDeposit
#   1 = CounterfactualDepositFactory
#   2 = WithdrawImplementation
#   3 = CounterfactualDepositSpokePool
#   4 = CounterfactualDepositCCTP
#   5 = CounterfactualDepositOFT
#   6 = AdminWithdrawManager
#
# Requires: .env file with MNEMONIC (and ETHERSCAN_API_KEY if using --verify) in the repo root.
#
# Usage:
#   ./script/counterfactual/deploy-all.sh \
#     --index 5 \
#     --rpc-url $NODE_URL \
#     --spoke-pool 0x... \
#     --signer 0x... \
#     --wrapped-native-token 0x... \
#     --cctp-periphery 0x... \
#     --cctp-domain 0 \
#     --oft-periphery 0x... \
#     --oft-eid 30101 \
#     --owner 0x... \
#     --direct-withdrawer 0x... \
#     --skip 4,5 \
#     --broadcast \
#     --verify

# Resolve the repo root relative to this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Source .env from repo root so MNEMONIC and ETHERSCAN_API_KEY are available.
# `set -a` auto-exports all variables defined in the sourced file.
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

# --- Parse arguments ---
INDEX=""
RPC_URL=""
SPOKE_POOL=""
SIGNER=""
WRAPPED_NATIVE_TOKEN=""
CCTP_PERIPHERY=""
CCTP_DOMAIN=""
OFT_PERIPHERY=""
OFT_EID=""
OWNER=""
DIRECT_WITHDRAWER=""
BROADCAST=""
VERIFY=""
SKIP=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --index|-i) INDEX="$2"; shift 2 ;;
        --rpc-url|-r) RPC_URL="$2"; shift 2 ;;
        --spoke-pool) SPOKE_POOL="$2"; shift 2 ;;
        --signer) SIGNER="$2"; shift 2 ;;
        --wrapped-native-token) WRAPPED_NATIVE_TOKEN="$2"; shift 2 ;;
        --cctp-periphery) CCTP_PERIPHERY="$2"; shift 2 ;;
        --cctp-domain) CCTP_DOMAIN="$2"; shift 2 ;;
        --oft-periphery) OFT_PERIPHERY="$2"; shift 2 ;;
        --oft-eid) OFT_EID="$2"; shift 2 ;;
        --owner) OWNER="$2"; shift 2 ;;
        --direct-withdrawer) DIRECT_WITHDRAWER="$2"; shift 2 ;;
        --broadcast) BROADCAST="--broadcast"; shift ;;
        --verify) VERIFY="--verify"; shift ;;
        --skip) SKIP="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Validate skip list ---
# Ensure every value in the comma-separated --skip list is a valid index (0-6).
if [ -n "$SKIP" ]; then
    IFS=',' read -ra SKIP_ARRAY <<< "$SKIP"
    for idx in "${SKIP_ARRAY[@]}"; do
        if ! echo "$idx" | grep -qE '^[0-6]$'; then
            echo "Error: Invalid skip index '$idx'. Must be 0-6."
            exit 1
        fi
    done
fi

# Check if a deployment index (0-6) is in the comma-separated skip list.
# Works by wrapping both the list and the index with commas so that partial matches
# (e.g. "1" matching "10") are avoided.
is_skipped() {
    echo ",$SKIP," | grep -q ",$1,"
}

# --- Validate required arguments ---
# Arguments for skipped contracts are not required (e.g. --cctp-periphery can be
# omitted when --skip 4 is used).
missing=()
[ -z "$INDEX" ] && missing+=("--index")
[ -z "$RPC_URL" ] && missing+=("--rpc-url")
[ -z "$SIGNER" ] && missing+=("--signer")
[ -z "$OWNER" ] && missing+=("--owner")
[ -z "$DIRECT_WITHDRAWER" ] && missing+=("--direct-withdrawer")
[ -z "$SPOKE_POOL" ] && ! is_skipped 3 && missing+=("--spoke-pool")
[ -z "$WRAPPED_NATIVE_TOKEN" ] && ! is_skipped 3 && missing+=("--wrapped-native-token")
[ -z "$CCTP_PERIPHERY" ] && ! is_skipped 4 && missing+=("--cctp-periphery")
[ -z "$CCTP_DOMAIN" ] && ! is_skipped 4 && missing+=("--cctp-domain")
[ -z "$OFT_PERIPHERY" ] && ! is_skipped 5 && missing+=("--oft-periphery")
[ -z "$OFT_EID" ] && ! is_skipped 5 && missing+=("--oft-eid")

if [ ${#missing[@]} -gt 0 ]; then
    echo "Error: Missing required arguments: ${missing[*]}"
    echo ""
    echo "Usage: ./script/counterfactual/deploy-all.sh --index <N> --rpc-url <URL> \\"
    echo "  --spoke-pool <ADDR> --signer <ADDR> --wrapped-native-token <ADDR> \\"
    echo "  --cctp-periphery <ADDR> --cctp-domain <N> --oft-periphery <ADDR> --oft-eid <N> \\"
    echo "  --owner <ADDR> --direct-withdrawer <ADDR> [--skip 4,5] [--broadcast] [--verify]"
    exit 1
fi

if [ -z "${MNEMONIC:-}" ]; then
    echo "Error: MNEMONIC not found. Ensure .env exists in the repo root with MNEMONIC set."
    exit 1
fi

# --- Derive deployer address and private key ---
# The address is derived from the mnemonic at the given BIP-44 index.
# The private key is needed by burn_nonce() to send dummy transactions for skipped contracts.
DEPLOYER=$(cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index "$INDEX")
DEPLOYER_PRIVATE_KEY=$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index "$INDEX")

# Query the deployer's current nonce on-chain.
NONCE=$(cast nonce "$DEPLOYER" --rpc-url "$RPC_URL")

echo "============================================"
echo "Counterfactual Contracts Deployment"
echo "============================================"
echo "Deployer:  $DEPLOYER"
echo "Index:     $INDEX"
echo "Nonce:     $NONCE"
echo "Chain RPC: $RPC_URL"
echo "Mode:      ${BROADCAST:-simulation}"
[ -n "$SKIP" ] && echo "Skip:      $SKIP"
echo "============================================"

# All 7 contracts use nonces 0-6. If the nonce is already past 6, everything is deployed.
if [ "$NONCE" -gt 6 ]; then
    echo "ERROR: Deployer nonce is $NONCE — all 7 contracts have already been deployed."
    exit 1
elif [ "$NONCE" != "0" ]; then
    echo "WARNING: Deployer nonce is $NONCE, expected 0. Skipping first $NONCE deployment(s)."
fi

# --- Common forge flags ---
# These are appended to every `forge script` invocation.
FORGE_FLAGS="--rpc-url $RPC_URL $BROADCAST $VERIFY -vvvv"

# Export the derivation index so the Solidity deploy scripts can read it via vm.envUint().
export DEPLOYER_INDEX="$INDEX"

# --- Helper functions ---

# Sends a 0-value self-transfer to consume a nonce without deploying a contract.
# Used for skipped contracts so that subsequent contracts still get the correct addresses.
burn_nonce() {
    local step="$1"
    local expected_nonce=$((step - 1))
    local description="$2"

    echo ""
    echo "--- Step $step/7: $description (nonce $expected_nonce) — SKIPPED (burning nonce) ---"

    # Only send the transaction when actually broadcasting. In simulation mode,
    # forge script doesn't broadcast either, so we stay consistent.
    if [ -n "$BROADCAST" ]; then
        cast send "$DEPLOYER" --value 0 \
            --private-key "$DEPLOYER_PRIVATE_KEY" \
            --rpc-url "$RPC_URL" > /dev/null
    fi
}

# Deploys a single contract by running its forge script.
#
# Arguments:
#   $1 - step number (1-7), used for display and nonce verification
#   $2 - human-readable description for logging
#   $3 - path to the .s.sol script file
#   $4 - contract name within the script file
#   $5+ - additional forge arguments (e.g. --sig "run(address)" 0x...)
run_deploy() {
    local step="$1"
    local expected_nonce=$((step - 1))
    local description="$2"
    local script_path="$3"
    local contract_name="$4"
    shift 4
    # Remaining args are --sig and its arguments, if any.

    # If the on-chain nonce is already past this step, the contract was deployed
    # in a previous run. Skip without sending any transaction.
    local current_nonce
    current_nonce=$(cast nonce "$DEPLOYER" --rpc-url "$RPC_URL")
    if [ "$current_nonce" -gt "$expected_nonce" ]; then
        echo ""
        echo "--- Step $step/7: $description (nonce $expected_nonce) — SKIPPED (current nonce: $current_nonce) ---"
        return
    fi

    # If this deployment index is in the --skip list, burn the nonce with a dummy tx
    # instead of deploying, so subsequent contracts still get correct addresses.
    if is_skipped "$expected_nonce"; then
        burn_nonce "$step" "$description"
        return
    fi

    echo ""
    echo "--- Step $step/7: $description (nonce $expected_nonce) ---"

    forge script "$script_path:$contract_name" \
        "$@" \
        $FORGE_FLAGS

    # After broadcasting, verify the nonce incremented to the expected value.
    # This catches issues like failed transactions that didn't actually deploy.
    if [ -n "$BROADCAST" ]; then
        local new_nonce
        new_nonce=$(cast nonce "$DEPLOYER" --rpc-url "$RPC_URL")
        if [ "$new_nonce" != "$step" ]; then
            echo "ERROR: Expected nonce $step after step $step, got $new_nonce"
            exit 1
        fi
    fi
}

# --- Deploy all contracts in fixed order ---
# Each contract is assigned a fixed nonce (0-6). The order must be identical
# across all chains to produce the same addresses.

# Nonce 0: Base implementation that all clones proxy to.
run_deploy 1 "CounterfactualDeposit" \
    "$REPO_ROOT/script/counterfactual/DeployCounterfactualDeposit.s.sol" \
    "DeployCounterfactualDeposit"

# Nonce 1: Factory that deploys deterministic clones via CREATE2.
run_deploy 2 "CounterfactualDepositFactory" \
    "$REPO_ROOT/script/counterfactual/DeployCounterfactualDepositFactory.s.sol" \
    "DeployCounterfactualDepositFactory"

# Nonce 2: Withdraw implementation, included as a merkle leaf in each clone.
run_deploy 3 "WithdrawImplementation" \
    "$REPO_ROOT/script/counterfactual/DeployWithdrawImplementation.s.sol" \
    "DeployWithdrawImplementation"

# Nonce 3: Deposit implementation for Across SpokePool bridge type.
run_deploy 4 "CounterfactualDepositSpokePool" \
    "$REPO_ROOT/script/counterfactual/DeployCounterfactualDepositSpokePool.s.sol" \
    "DeployCounterfactualDepositSpokePool" \
    --sig "run(address,address,address)" "$SPOKE_POOL" "$SIGNER" "$WRAPPED_NATIVE_TOKEN"

# Nonce 4: Deposit implementation for Circle CCTP bridge type.
run_deploy 5 "CounterfactualDepositCCTP" \
    "$REPO_ROOT/script/counterfactual/DeployCounterfactualDepositCCTP.s.sol" \
    "DeployCounterfactualDepositCCTP" \
    --sig "run(address,uint32)" "$CCTP_PERIPHERY" "$CCTP_DOMAIN"

# Nonce 5: Deposit implementation for LayerZero OFT bridge type.
run_deploy 6 "CounterfactualDepositOFT" \
    "$REPO_ROOT/script/counterfactual/DeployCounterfactualDepositOFT.s.sol" \
    "DeployCounterfactualDepositOFT" \
    --sig "run(address,uint32)" "$OFT_PERIPHERY" "$OFT_EID"

# Nonce 6: Admin contract for managing withdrawals from clones.
run_deploy 7 "AdminWithdrawManager" \
    "$REPO_ROOT/script/counterfactual/DeployAdminWithdrawManager.s.sol" \
    "DeployAdminWithdrawManager" \
    --sig "run(address,address,address)" "$OWNER" "$DIRECT_WITHDRAWER" "$SIGNER"

echo ""
echo "============================================"
echo "All deployments complete!"
echo "============================================"
