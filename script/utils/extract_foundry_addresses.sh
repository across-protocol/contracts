#!/bin/bash

# Extract deployed contract addresses from Foundry broadcast files using TypeScript
# This script reads from the broadcast folder and generates files with the latest 
# deployed smart contract addresses.

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Extracting deployed contract addresses using TypeScript..."
echo "Project root: $PROJECT_ROOT"

# Check if TypeScript is available
if ! command -v npx &> /dev/null; then
    echo "Error: npx is not available. Please install Node.js and npm."
    exit 1
fi

# Run the TypeScript script using ts-node
if command -v ts-node &> /dev/null; then
    echo "Using ts-node to run TypeScript script..."
    ts-node "$PROJECT_ROOT/utils/ExtractDeployedFoundryAddresses.ts"
elif command -v npx &> /dev/null; then
    echo "Using npx ts-node to run TypeScript script..."
    npx ts-node "$PROJECT_ROOT/utils/ExtractDeployedFoundryAddresses.ts"
else
    echo "Error: ts-node is not available. Please install it with: npm install -g ts-node"
    echo "Or install it locally: npm install --save-dev ts-node"
    exit 1
fi

echo ""
echo "Generated files:"
echo "  - $PROJECT_ROOT/broadcast/deployed-addresses.md (Markdown format)"
echo "  - $PROJECT_ROOT/broadcast/deployed-addresses.json (JSON format)"
echo "  - $PROJECT_ROOT/script/DeployedAddresses.sol (Foundry smart contract with all addresses)"
echo ""
echo "You can now import DeployedAddresses.sol in your other Foundry scripts to use the deployed addresses." 