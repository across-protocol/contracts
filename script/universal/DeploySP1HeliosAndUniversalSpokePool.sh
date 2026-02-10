#!/usr/bin/env bash
# Combined deployment script for SP1Helios + Universal_SpokePool.
# Assumes a fresh deployment — no existing SpokePool on the target chain.
# Replaces the manual 3-step process with a single command, while preserving
# the correct broadcast folder structure for each sub-script.
#
# Usage:
#   ./script/universal/deploy_universal_spoke_pool_full.sh \
#     --rpc-url <RPC_URL> \
#     --oft-fee-cap <OFT_FEE_CAP> \
#     --etherscan-api-key <API_KEY> \
#     [--broadcast]
#
# Required env vars (loaded from .env):
#   MNEMONIC, SP1_RELEASE, SP1_PROVER_MODE, SP1_VERIFIER_ADDRESS,
#   SP1_STATE_UPDATERS, SP1_VKEY_UPDATER, SP1_CONSENSUS_RPCS_LIST

set -euo pipefail

# Load and export .env variables
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
else
  echo "Error: .env file not found"
  exit 1
fi

# Parse arguments
BROADCAST=""
RPC_URL=""
OFT_FEE_CAP=""
ETHERSCAN_API_KEY=""
EXTRA_ARGS=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --rpc-url) RPC_URL="$2"; shift 2 ;;
    --oft-fee-cap) OFT_FEE_CAP="$2"; shift 2 ;;
    --etherscan-api-key) ETHERSCAN_API_KEY="$2"; shift 2 ;;
    --broadcast) BROADCAST="--broadcast"; shift ;;
    *) EXTRA_ARGS="$EXTRA_ARGS $1"; shift ;;
  esac
done

if [[ -z "$RPC_URL" || -z "$OFT_FEE_CAP" ]]; then
  echo "Usage: $0 --rpc-url <RPC_URL> --oft-fee-cap <OFT_FEE_CAP> --etherscan-api-key <API_KEY> [--broadcast]"
  exit 1
fi

VERIFY_ARGS=""
if [[ -n "$ETHERSCAN_API_KEY" ]]; then
  VERIFY_ARGS="--etherscan-api-key $ETHERSCAN_API_KEY"
fi

# Derive deployer address from mnemonic
DEPLOYER_PRIVATE_KEY=$(cast wallet private-key "$MNEMONIC")
DEPLOYER_ADDRESS=$(cast wallet address "$DEPLOYER_PRIVATE_KEY")
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
echo "Deployer address: $DEPLOYER_ADDRESS"
echo "Chain ID: $CHAIN_ID"

# Check that no SpokePool is already deployed on this chain
DEPLOYED_ADDRESSES="broadcast/deployed-addresses.json"
if [[ -f "$DEPLOYED_ADDRESSES" ]]; then
  EXISTING_SPOKE_POOL=$(jq -r ".chains[\"$CHAIN_ID\"].contracts[\"SpokePool\"].address // empty" "$DEPLOYED_ADDRESSES")
  if [[ -n "$EXISTING_SPOKE_POOL" ]]; then
    echo "Error: SpokePool already deployed on chain $CHAIN_ID at $EXISTING_SPOKE_POOL"
    echo "This script is intended for fresh deployments only."
    echo "Remove the chain $CHAIN_ID entry from $DEPLOYED_ADDRESSES if you want to redeploy."
    exit 1
  fi
fi

# Ensure run-latest.json symlink exists for a broadcast directory.
# Some Forge nightly builds don't create it automatically.
ensure_run_latest() {
  local dir="$1"
  if [[ -d "$dir" && ! -e "$dir/run-latest.json" ]]; then
    local latest
    latest=$(ls -t "$dir"/run-*.json 2>/dev/null | head -1)
    if [[ -n "$latest" ]]; then
      ln -sf "$(basename "$latest")" "$dir/run-latest.json"
      echo "Created run-latest.json symlink -> $(basename "$latest")"
    fi
  fi
}

# Step 1: Deploy SP1Helios
echo ""
echo "=== Step 1: Deploying SP1Helios ==="
forge script script/universal/DeploySP1Helios.s.sol \
  --rpc-url "$RPC_URL" \
  $BROADCAST --slow --ffi -vvvv $EXTRA_ARGS
ensure_run_latest "broadcast/DeploySP1Helios.s.sol/$CHAIN_ID"

# Wait for in-flight transactions to clear before next deployment
if [[ -n "$BROADCAST" ]]; then
  echo "Waiting for transactions to confirm..."
  sleep 10
fi

# Step 2: Extract SP1Helios address from broadcast and deploy Universal_SpokePool
SP1_HELIOS=$(jq -r '.transactions[] | select(.contractName == "SP1Helios") | .contractAddress' \
  "broadcast/DeploySP1Helios.s.sol/$CHAIN_ID/run-latest.json")
if [[ -z "$SP1_HELIOS" || "$SP1_HELIOS" == "null" ]]; then
  echo "Error: Could not find SP1Helios address in broadcast output"
  exit 1
fi
echo ""
echo "SP1Helios deployed at: $SP1_HELIOS"

echo ""
echo "=== Step 2: Deploying Universal_SpokePool ==="
forge script script/universal/DeployUniversalSpokePool.s.sol:DeployUniversalSpokePool \
  --sig "run(address,uint256)" "$SP1_HELIOS" "$OFT_FEE_CAP" \
  --rpc-url "$RPC_URL" \
  $BROADCAST --slow -vvvv $EXTRA_ARGS
ensure_run_latest "broadcast/DeployUniversalSpokePool.s.sol/$CHAIN_ID"

# Extract SpokePool proxy address from broadcast
SPOKE_POOL=$(jq -r '.transactions[] | select(.contractName == "ERC1967Proxy") | .contractAddress' \
  "broadcast/DeployUniversalSpokePool.s.sol/$CHAIN_ID/run-latest.json")
if [[ -z "$SPOKE_POOL" || "$SPOKE_POOL" == "null" ]]; then
  echo "Error: Could not find SpokePool address in broadcast output"
  exit 1
fi

echo ""
echo "=== Step 3: Transferring SP1Helios admin role ==="
echo "SP1Helios: $SP1_HELIOS"
echo "SpokePool: $SPOKE_POOL"

DEFAULT_ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"

if [[ -n "$BROADCAST" ]]; then
  cast send "$SP1_HELIOS" \
    "grantRole(bytes32,address)" "$DEFAULT_ADMIN_ROLE" "$SPOKE_POOL" \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY"

  # Brief pause so the RPC node's nonce tracking catches up after the previous tx
  sleep 5

  cast send "$SP1_HELIOS" \
    "renounceRole(bytes32,address)" "$DEFAULT_ADMIN_ROLE" "$DEPLOYER_ADDRESS" \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY"

  echo "Admin role transferred successfully."
else
  echo "(Skipping admin role transfer in simulation mode — add --broadcast to execute)"
fi

# Step 4: Verify contracts (non-blocking — verification failures don't stop the script)
if [[ -n "$VERIFY_ARGS" && -n "$BROADCAST" ]]; then
  echo ""
  echo "=== Step 4: Verifying contracts ==="
  forge script script/universal/DeploySP1Helios.s.sol \
    --rpc-url "$RPC_URL" --verify $VERIFY_ARGS --ffi -vvvv --resume \
    --private-key "$DEPLOYER_PRIVATE_KEY" $EXTRA_ARGS || \
    echo "Warning: SP1Helios verification failed (may already be verified)"

  forge script script/universal/DeployUniversalSpokePool.s.sol:DeployUniversalSpokePool \
    --sig "run(address,uint256)" "$SP1_HELIOS" "$OFT_FEE_CAP" \
    --rpc-url "$RPC_URL" --verify $VERIFY_ARGS -vvvv --resume \
    --private-key "$DEPLOYER_PRIVATE_KEY" $EXTRA_ARGS || \
    echo "Warning: Universal_SpokePool verification failed (may already be verified)"
fi

echo ""
echo "=== Deployment Complete ==="
echo "SP1Helios: $SP1_HELIOS"
echo "SpokePool: $SPOKE_POOL"
