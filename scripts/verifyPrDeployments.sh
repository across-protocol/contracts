#!/bin/bash
set -euo pipefail

# Verifies all contract deployments in a GitHub PR by delegating to verifyBytecode.sh.
#
# Usage:
#   ./scripts/verifyPrDeployments.sh <pr_number> [--env <env_file>]
#
# Options:
#   --env <file>   Source an env file for NODE_URL_<chainId> variables (default: .env if it exists)
#
# Prerequisites:
#   - PR branch checked out locally (broadcast files + build artifacts must exist)
#   - gh CLI authenticated
#   - Contracts built (forge build)

REPO="across-protocol/contracts"

# Parse arguments.
ENV_FILE=""
PR=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --env)
            ENV_FILE="$2"
            shift 2
            ;;
        *)
            if [ -z "$PR" ]; then
                PR="$1"
            else
                echo "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [ -z "$PR" ]; then
    echo "Usage: $0 <pr_number> [--env <env_file>]"
    exit 1
fi

# Source env file: explicit --env flag, or .env if it exists.
if [ -n "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
elif [ -f .env ]; then
    # shellcheck disable=SC1091
    source .env
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Verifying deployments in PR #$PR ($REPO)"
echo "============================================="
echo ""

# Find broadcast run-latest.json files changed in the PR.
BROADCAST_FILES=$(gh pr view "$PR" --repo "$REPO" --json files --jq '.files[].path' | grep 'broadcast/.*run-latest\.json$' || true)

if [ -z "$BROADCAST_FILES" ]; then
    echo "No broadcast files found in PR #$PR"
    exit 0
fi

FILE_COUNT=$(echo "$BROADCAST_FILES" | wc -l | tr -d ' ')
echo "Found $FILE_COUNT broadcast file(s)"
echo ""

PASS=0
FAIL=0
SKIP=0

while IFS= read -r FILE; do
    [ -z "$FILE" ] && continue

    if [ ! -f "$FILE" ]; then
        echo "⚠️  Not found locally: $FILE (is the PR branch checked out?)"
        SKIP=$((SKIP + 1))
        continue
    fi

    # Extract chain ID from path: broadcast/<Script>.s.sol/<chainId>/run-latest.json
    CHAIN_ID=$(echo "$FILE" | sed -n 's|broadcast/[^/]*/\([0-9]*\)/run-latest.json|\1|p')
    if [ -z "$CHAIN_ID" ]; then
        echo "⚠️  Could not parse chain ID from: $FILE"
        SKIP=$((SKIP + 1))
        continue
    fi

    # Resolve RPC URL from NODE_URL_<chainId> env var.
    RPC_VAR="NODE_URL_${CHAIN_ID}"
    RPC="${!RPC_VAR:-}"
    if [ -z "$RPC" ]; then
        echo "⚠️  Skipping chain $CHAIN_ID - \$$RPC_VAR not set"
        SKIP=$((SKIP + 1))
        continue
    fi

    # Extract unique deployed contract names from this broadcast file.
    CONTRACTS=$(jq -r '[.transactions[] | select(.transactionType==("CREATE","CREATE2") and .contractName != null) | .contractName] | unique[]' "$FILE")
    if [ -z "$CONTRACTS" ]; then
        continue
    fi

    while IFS= read -r CONTRACT; do
        [ -z "$CONTRACT" ] && continue
        echo "--- $CONTRACT | Chain $CHAIN_ID ---"
        if "$SCRIPT_DIR/verifyBytecode.sh" --broadcast "$RPC" "$CONTRACT" "$FILE"; then
            PASS=$((PASS + 1))
        else
            FAIL=$((FAIL + 1))
        fi
        echo ""
    done <<< "$CONTRACTS"
done <<< "$BROADCAST_FILES"

echo "============================================="
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
