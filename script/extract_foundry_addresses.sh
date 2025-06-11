#!/bin/bash

# Extract deployed contract addresses from Foundry broadcast files
# This script reads from the broadcast folder and generates files with the latest 
# deployed smart contract addresses.

set -e

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

echo "Extracting deployed contract addresses..."
echo "Project root: $PROJECT_ROOT"

# Run the Python script from the script folder
python3 "$PROJECT_ROOT/script/ExtractDeployedFoundryAddresses.py"

echo ""
echo "Generated files:"
echo "  - $PROJECT_ROOT/broadcast/deployed-addresses.md (Markdown format)"
echo "  - $PROJECT_ROOT/broadcast/deployed-addresses.json (JSON format)" 