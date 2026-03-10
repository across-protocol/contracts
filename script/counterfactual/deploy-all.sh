#!/usr/bin/env bash
set -euo pipefail

# Deploys all 7 counterfactual contracts from a single deployer in a fixed order.
# The deployer MUST have nonce 0 on the target chain to ensure deterministic addresses.
# By deploying in the same order from the same nonce-0 address, all contracts get the
# same addresses on every chain.
#
# The --index argument specifies the BIP-44 derivation index used to derive the deployer
# private key from the mnemonic (m/44'/60'/0'/0/<index>). Use a dedicated index that has
# never sent transactions on any chain, so the deployer starts at nonce 0 everywhere.
# Use the same index across all chains to get the same deployer address and thus the same
# contract addresses.
#
# The --skip argument takes a comma-separated list of contracts to skip. Skipped contracts
# are not deployed, but a dummy transaction (0-value self-transfer) is sent to burn the
# nonce so that subsequent contracts still land at the correct addresses.
# Valid names: deposit, factory, withdraw, spokepool, cctp, oft, admin
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
#     --skip cctp,oft \
#     --broadcast \
#     --verify

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# --- Source .env from repo root ---
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
VALID_SKIP_NAMES="deposit factory withdraw spokepool cctp oft admin"
if [ -n "$SKIP" ]; then
    IFS=',' read -ra SKIP_ARRAY <<< "$SKIP"
    for name in "${SKIP_ARRAY[@]}"; do
        if ! echo "$VALID_SKIP_NAMES" | grep -qw "$name"; then
            echo "Error: Invalid skip name '$name'. Valid names: $VALID_SKIP_NAMES"
            exit 1
        fi
    done
fi

# Check if a contract name is in the skip list.
is_skipped() {
    echo ",$SKIP," | grep -q ",$1,"
}

# --- Validate required arguments (skip validation for skipped contracts) ---
missing=()
[ -z "$INDEX" ] && missing+=("--index")
[ -z "$RPC_URL" ] && missing+=("--rpc-url")
[ -z "$SIGNER" ] && missing+=("--signer")
[ -z "$OWNER" ] && missing+=("--owner")
[ -z "$DIRECT_WITHDRAWER" ] && missing+=("--direct-withdrawer")
[ -z "$SPOKE_POOL" ] && ! is_skipped spokepool && missing+=("--spoke-pool")
[ -z "$WRAPPED_NATIVE_TOKEN" ] && ! is_skipped spokepool && missing+=("--wrapped-native-token")
[ -z "$CCTP_PERIPHERY" ] && ! is_skipped cctp && missing+=("--cctp-periphery")
[ -z "$CCTP_DOMAIN" ] && ! is_skipped cctp && missing+=("--cctp-domain")
[ -z "$OFT_PERIPHERY" ] && ! is_skipped oft && missing+=("--oft-periphery")
[ -z "$OFT_EID" ] && ! is_skipped oft && missing+=("--oft-eid")

if [ ${#missing[@]} -gt 0 ]; then
    echo "Error: Missing required arguments: ${missing[*]}"
    echo ""
    echo "Usage: ./script/counterfactual/deploy-all.sh --index <N> --rpc-url <URL> \\"
    echo "  --spoke-pool <ADDR> --signer <ADDR> --wrapped-native-token <ADDR> \\"
    echo "  --cctp-periphery <ADDR> --cctp-domain <N> --oft-periphery <ADDR> --oft-eid <N> \\"
    echo "  --owner <ADDR> --direct-withdrawer <ADDR> [--skip name1,name2] [--broadcast] [--verify]"
    exit 1
fi

if [ -z "${MNEMONIC:-}" ]; then
    echo "Error: MNEMONIC not found. Ensure .env exists in the repo root with MNEMONIC set."
    exit 1
fi

# --- Derive deployer address and private key ---
DEPLOYER=$(cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index "$INDEX")
DEPLOYER_PRIVATE_KEY=$(cast wallet private-key --mnemonic "$MNEMONIC" --mnemonic-index "$INDEX")
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

if [ "$NONCE" -gt 6 ]; then
    echo "ERROR: Deployer nonce is $NONCE — all 7 contracts have already been deployed."
    exit 1
elif [ "$NONCE" != "0" ]; then
    echo "WARNING: Deployer nonce is $NONCE, expected 0. Skipping first $NONCE deployment(s)."
fi

# --- Common forge flags ---
FORGE_FLAGS="--rpc-url $RPC_URL $BROADCAST $VERIFY -vvvv"

export DEPLOYER_INDEX="$INDEX"

# Burn a nonce by sending a 0-value self-transfer.
burn_nonce() {
    local step="$1"
    local expected_nonce=$((step - 1))
    local description="$2"

    echo ""
    echo "--- Step $step/7: $description (nonce $expected_nonce) — SKIPPED (burning nonce) ---"

    if [ -n "$BROADCAST" ]; then
        cast send "$DEPLOYER" --value 0 \
            --private-key "$DEPLOYER_PRIVATE_KEY" \
            --rpc-url "$RPC_URL" > /dev/null
    fi
}

run_deploy() {
    local step="$1"
    local expected_nonce=$((step - 1))
    local skip_name="$2"
    local description="$3"
    local script_path="$4"
    local contract_name="$5"
    shift 5
    # Remaining args are --sig and its arguments, if any.

    # Check current nonce and skip if this contract was already deployed.
    local current_nonce
    current_nonce=$(cast nonce "$DEPLOYER" --rpc-url "$RPC_URL")
    if [ "$current_nonce" -gt "$expected_nonce" ]; then
        echo ""
        echo "--- Step $step/7: $description (nonce $expected_nonce) — SKIPPED (current nonce: $current_nonce) ---"
        return
    fi

    # If this contract is in the skip list, burn the nonce instead.
    if is_skipped "$skip_name"; then
        burn_nonce "$step" "$description"
        return
    fi

    echo ""
    echo "--- Step $step/7: $description (nonce $expected_nonce) ---"

    forge script "$script_path:$contract_name" \
        "$@" \
        $FORGE_FLAGS

    # Verify nonce incremented (only when broadcasting).
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

# Nonce 0
run_deploy 1 "deposit" "CounterfactualDeposit" \
    "$REPO_ROOT/script/counterfactual/DeployCounterfactualDeposit.s.sol" \
    "DeployCounterfactualDeposit"

# Nonce 1
run_deploy 2 "factory" "CounterfactualDepositFactory" \
    "$REPO_ROOT/script/counterfactual/DeployCounterfactualDepositFactory.s.sol" \
    "DeployCounterfactualDepositFactory"

# Nonce 2
run_deploy 3 "withdraw" "WithdrawImplementation" \
    "$REPO_ROOT/script/counterfactual/DeployWithdrawImplementation.s.sol" \
    "DeployWithdrawImplementation"

# Nonce 3
run_deploy 4 "spokepool" "CounterfactualDepositSpokePool" \
    "$REPO_ROOT/script/counterfactual/DeployCounterfactualDepositSpokePool.s.sol" \
    "DeployCounterfactualDepositSpokePool" \
    --sig "run(address,address,address)" "$SPOKE_POOL" "$SIGNER" "$WRAPPED_NATIVE_TOKEN"

# Nonce 4
run_deploy 5 "cctp" "CounterfactualDepositCCTP" \
    "$REPO_ROOT/script/counterfactual/DeployCounterfactualDepositCCTP.s.sol" \
    "DeployCounterfactualDepositCCTP" \
    --sig "run(address,uint32)" "$CCTP_PERIPHERY" "$CCTP_DOMAIN"

# Nonce 5
run_deploy 6 "oft" "CounterfactualDepositOFT" \
    "$REPO_ROOT/script/counterfactual/DeployCounterfactualDepositOFT.s.sol" \
    "DeployCounterfactualDepositOFT" \
    --sig "run(address,uint32)" "$OFT_PERIPHERY" "$OFT_EID"

# Nonce 6
run_deploy 7 "admin" "AdminWithdrawManager" \
    "$REPO_ROOT/script/counterfactual/DeployAdminWithdrawManager.s.sol" \
    "DeployAdminWithdrawManager" \
    --sig "run(address,address,address)" "$OWNER" "$DIRECT_WITHDRAWER" "$SIGNER"

echo ""
echo "============================================"
echo "All deployments complete!"
echo "============================================"
