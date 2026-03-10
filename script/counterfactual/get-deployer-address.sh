#!/usr/bin/env bash
set -euo pipefail

# Derives the deployer address for a given mnemonic derivation index.
# Usage: ./script/counterfactual/get-deployer-address.sh <derivation-index>
# Requires: .env file with MNEMONIC in the repo root.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [ $# -lt 1 ]; then
    echo "Usage: ./script/counterfactual/get-deployer-address.sh <derivation-index>"
    echo "Example: ./script/counterfactual/get-deployer-address.sh 5"
    exit 1
fi

INDEX="$1"

# Source .env from repo root.
if [ -f "$REPO_ROOT/.env" ]; then
    set -a
    source "$REPO_ROOT/.env"
    set +a
fi

if [ -z "${MNEMONIC:-}" ]; then
    echo "Error: MNEMONIC not found. Ensure .env exists in the repo root with MNEMONIC set."
    exit 1
fi

ADDRESS=$(cast wallet address --mnemonic "$MNEMONIC" --mnemonic-index "$INDEX")
echo "Derivation index: $INDEX"
echo "Deployer address: $ADDRESS"
