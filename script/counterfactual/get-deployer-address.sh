#!/usr/bin/env bash
set -euo pipefail

# Derives the deployer address for a given mnemonic derivation index.
# This tells you which address to fund on the target chain before deploying.
#
# The derivation index maps to BIP-44 path m/44'/60'/0'/0/<index>.
# Use a dedicated index that has never sent transactions on any chain.
#
# Usage: ./script/counterfactual/get-deployer-address.sh <derivation-index>
# Requires: .env file with MNEMONIC in the repo root.

# Resolve the repo root relative to this script's location.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ $# -lt 1 ]; then
    echo "Usage: ./script/counterfactual/get-deployer-address.sh <derivation-index>"
    echo "Example: ./script/counterfactual/get-deployer-address.sh 5"
    exit 1
fi

INDEX="$1"

# Source .env from repo root so MNEMONIC is available as an env var.
# `set -a` auto-exports all variables defined in the sourced file.
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

if [ -z "${MNEMONIC:-}" ]; then
    echo "Error: MNEMONIC not found. Ensure .env exists in the repo root with MNEMONIC set."
    exit 1
fi

# Use `cast wallet address` to derive the address from the mnemonic at the given index.
ADDRESS=$(cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index "$INDEX")
echo "Derivation index: $INDEX"
echo "Deployer address: $ADDRESS"
