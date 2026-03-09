#!/usr/bin/env bash
# Combined deployment script for SP1Helios + Universal_SpokePool.
#
# This script automates the full deployment flow for a new Universal SpokePool chain:
#   1. Deploy the SP1Helios light client contract (via DeploySP1Helios.s.sol)
#   2. Deploy the Universal_SpokePool proxy (via DeployUniversalSpokePool.s.sol),
#      passing in the SP1Helios address from step 1
#   3. Transfer the SP1Helios DEFAULT_ADMIN_ROLE from the deployer to the SpokePool,
#      so that admin functions can be called through the cross-chain admin flow
#   4. Verify both contracts on Etherscan (if --etherscan-api-key is provided)
#
# Assumes a fresh deployment — no existing SpokePool on the target chain.
# Each forge script gets its own broadcast directory, preserving the expected
# folder structure for extract-addresses tooling.
#
# Usage:
#   ./script/universal/DeploySP1HeliosAndUniversalSpokePool.sh \
#     --rpc-url <RPC_URL> \
#     --oft-fee-cap <OFT_FEE_CAP> \
#     --etherscan-api-key <API_KEY> \
#     [--broadcast]
#
# Omit --broadcast to do a dry run (simulation only, no on-chain transactions).
#
# Required env vars (loaded automatically from .env):
#   MNEMONIC                - BIP-39 mnemonic; deployer key is derived at index 0
#   SP1_RELEASE             - Genesis binary version (e.g., "0.1.0-alpha.20")
#   SP1_PROVER_MODE         - SP1 prover type: "mock", "cpu", "cuda", or "network"
#   SP1_VERIFIER_ADDRESS    - SP1 verifier contract address (use "0x0" for mock)
#   SP1_STATE_UPDATERS      - Comma-separated state updater addresses
#   SP1_VKEY_UPDATER        - Address authorized to update the verification key
#   SP1_CONSENSUS_RPCS_LIST - Comma-separated Ethereum consensus (beacon) RPC URLs

# Exit immediately on error, treat unset variables as errors, fail on pipe errors.
set -euo pipefail

# ---------------------------------------------------------------------------
# Load environment variables from .env
# set -a / +a causes all variables assigned between them to be exported,
# so they're available to child processes (forge, cast, etc.).
# ---------------------------------------------------------------------------
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
else
  echo "Error: .env file not found"
  exit 1
fi

# ---------------------------------------------------------------------------
# Parse CLI arguments
# ---------------------------------------------------------------------------
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
    # Any unrecognized flags are passed through to forge.
    *) EXTRA_ARGS="$EXTRA_ARGS $1"; shift ;;
  esac
done

if [[ -z "$RPC_URL" || -z "$OFT_FEE_CAP" ]]; then
  echo "Usage: $0 --rpc-url <RPC_URL> --oft-fee-cap <OFT_FEE_CAP> --etherscan-api-key <API_KEY> [--broadcast]"
  exit 1
fi

# Only pass --verify and --etherscan-api-key to forge if an API key was provided.
VERIFY_ARGS=""
if [[ -n "$ETHERSCAN_API_KEY" ]]; then
  VERIFY_ARGS="--etherscan-api-key $ETHERSCAN_API_KEY"
fi

# ---------------------------------------------------------------------------
# Derive deployer info from mnemonic using cast (Foundry CLI)
# ---------------------------------------------------------------------------
DEPLOYER_PRIVATE_KEY=$(cast wallet private-key "$MNEMONIC")
DEPLOYER_ADDRESS=$(cast wallet address "$DEPLOYER_PRIVATE_KEY")
CHAIN_ID=$(cast chain-id --rpc-url "$RPC_URL")
echo "Deployer address: $DEPLOYER_ADDRESS"
echo "Chain ID: $CHAIN_ID"

# ---------------------------------------------------------------------------
# Safety check: abort if a SpokePool already exists on this chain.
# This script is intended for fresh deployments only.
# ---------------------------------------------------------------------------
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

# ---------------------------------------------------------------------------
# Helper: ensure run-latest.json symlink exists in a broadcast directory.
# Some Forge nightly builds don't create this symlink automatically, but we
# need it to reliably read the most recent broadcast output with jq.
# ---------------------------------------------------------------------------
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

# When not broadcasting, Foundry writes to chain_id/dry-run/run-latest.json.
# Use that path so we can still parse addresses and run Step 2 (simulation).
HELIOS_RUN_DIR="broadcast/DeploySP1Helios.s.sol/$CHAIN_ID"
SPOKE_RUN_DIR="broadcast/DeployUniversalSpokePool.s.sol/$CHAIN_ID"
if [[ -z "$BROADCAST" ]]; then
  HELIOS_RUN_DIR="$HELIOS_RUN_DIR/dry-run"
  SPOKE_RUN_DIR="$SPOKE_RUN_DIR/dry-run"
fi

# Full build so Step 2's OpenZeppelin upgrades-core validation succeeds (it requires
# build-info from a full compilation; incremental builds can make it revert).
echo ""
echo "=== Ensuring full build (required for Universal_SpokePool proxy validation) ==="
forge clean && forge build

# ===========================================================================
# Step 1: Deploy SP1Helios
# Runs DeploySP1Helios.s.sol which downloads a genesis binary via FFI,
# generates genesis parameters, and deploys the SP1Helios light client.
# ===========================================================================
echo ""
echo "=== Step 1: Deploying SP1Helios ==="
forge script script/universal/DeploySP1Helios.s.sol \
  --rpc-url "$RPC_URL" \
  $BROADCAST --ffi -vvvv $EXTRA_ARGS
ensure_run_latest "$HELIOS_RUN_DIR"

# Wait for in-flight transactions to confirm before the next deployment,
# so the RPC node has an up-to-date nonce for the deployer.
if [[ -n "$BROADCAST" ]]; then
  echo "Waiting for transactions to confirm..."
  sleep 10
fi

# ===========================================================================
# Step 2: Deploy Universal_SpokePool
# Parse the SP1Helios address from the Step 1 broadcast output, then pass it
# as a constructor argument to the SpokePool deployment script.
# The SpokePool is deployed behind an ERC1967 proxy via DeploymentUtils.
# ===========================================================================
SP1_HELIOS=$(jq -r '.transactions[] | select(.contractName == "SP1Helios") | .contractAddress' \
  "$HELIOS_RUN_DIR/run-latest.json")
if [[ -z "$SP1_HELIOS" || "$SP1_HELIOS" == "null" ]]; then
  echo "Error: Could not find SP1Helios address in broadcast output"
  exit 1
fi
echo ""
echo "SP1Helios deployed at: $SP1_HELIOS"

# When broadcasting, pin Step 2 simulation to the block where Step 1 confirmed (--fork-block-number
# is a forge script CLI flag; it is not passed into the Solidity run()).
# Some RPCs (e.g. Hyperliquid) return "invalid block height" when Forge forks at "latest".
FORK_BLOCK_ARGS=""
if [[ -n "$BROADCAST" ]]; then
  FORK_BLOCK_HEX=$(jq -r '.receipts[0].blockNumber // empty' "$HELIOS_RUN_DIR/run-latest.json")
  if [[ -n "$FORK_BLOCK_HEX" && "$FORK_BLOCK_HEX" != "null" ]]; then
    FORK_BLOCK_ARGS="--fork-block-number $((FORK_BLOCK_HEX))"
    echo "Using fork block from Step 1 for simulation: $((FORK_BLOCK_HEX))"
  fi
fi

echo ""
echo "=== Step 2: Deploying Universal_SpokePool ==="
forge script script/universal/DeployUniversalSpokePool.s.sol:DeployUniversalSpokePool \
  --sig "run(address,uint256)" "$SP1_HELIOS" "$OFT_FEE_CAP" \
  --rpc-url "$RPC_URL" \
  $FORK_BLOCK_ARGS \
  $BROADCAST -vvvv $EXTRA_ARGS
ensure_run_latest "$SPOKE_RUN_DIR"

# The SpokePool is deployed behind an ERC1967Proxy, so we look for that
# contract name in the broadcast output to get the proxy address.
SPOKE_POOL=$(jq -r '.transactions[] | select(.contractName == "ERC1967Proxy") | .contractAddress' \
  "$SPOKE_RUN_DIR/run-latest.json")
if [[ -z "$SPOKE_POOL" || "$SPOKE_POOL" == "null" ]]; then
  echo "Error: Could not find SpokePool address in broadcast output"
  exit 1
fi

# ===========================================================================
# Step 3: Transfer SP1Helios admin role to the SpokePool
# The SP1Helios contract uses OpenZeppelin AccessControl. After deployment,
# the deployer holds DEFAULT_ADMIN_ROLE. We grant that role to the SpokePool
# (so cross-chain admin calls can manage SP1Helios), then renounce it from
# the deployer so the deployer no longer has admin access.
# Skipped in simulation mode (no --broadcast).
# ===========================================================================
echo ""
echo "=== Step 3: Transferring SP1Helios admin role ==="
echo "SP1Helios: $SP1_HELIOS"
echo "SpokePool: $SPOKE_POOL"

DEFAULT_ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"

if [[ -n "$BROADCAST" ]]; then
  # Grant DEFAULT_ADMIN_ROLE to the SpokePool
  cast send "$SP1_HELIOS" \
    "grantRole(bytes32,address)" "$DEFAULT_ADMIN_ROLE" "$SPOKE_POOL" \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY"

  # Brief pause so the RPC node's nonce tracking catches up after the previous tx.
  sleep 5

  # Renounce DEFAULT_ADMIN_ROLE from the deployer
  cast send "$SP1_HELIOS" \
    "renounceRole(bytes32,address)" "$DEFAULT_ADMIN_ROLE" "$DEPLOYER_ADDRESS" \
    --rpc-url "$RPC_URL" \
    --private-key "$DEPLOYER_PRIVATE_KEY"

  echo "Admin role transferred successfully."
else
  echo "(Skipping admin role transfer in simulation mode — add --broadcast to execute)"
fi

# ===========================================================================
# Step 4: Verify contracts on Etherscan
# Uses --resume to re-run the forge scripts without broadcasting, which tells
# forge to pick up the existing broadcast artifacts and submit them for
# verification. Non-blocking — verification failures are warnings, not errors,
# since contracts may already be verified or the explorer may be slow.
# Only runs if both --broadcast and --etherscan-api-key were provided.
# ===========================================================================
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
