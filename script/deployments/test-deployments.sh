#!/bin/bash

# Script to test all deployment scripts on forked networks
# Must be run from the repository root directory
# Prerequisites: 
# - .env file with RPC URLs and MNEMONIC
# - Foundry installed

set -e

# Use provided environment variables if .env doesn't exist
if [ -f .env ]; then
    source .env
fi

# Set default values for RPC URLs if not defined
: ${MAINNET_RPC_URL:=https://ethereum.publicnode.com}
: ${OPTIMISM_RPC_URL:=https://mainnet.optimism.io}
: ${ARBITRUM_RPC_URL:=https://arb1.arbitrum.io/rpc}
: ${POLYGON_RPC_URL:=https://polygon-rpc.com}
: ${BASE_RPC_URL:=https://mainnet.base.org}
: ${BLAST_RPC_URL:=https://blast.blockpi.network/v1/rpc/public}
: ${LINEA_RPC_URL:=https://rpc.linea.build}
: ${SCROLL_RPC_URL:=https://rpc.scroll.io}
: ${MODE_RPC_URL:=https://mainnet.mode.network}
: ${ZKSYNC_RPC_URL:=https://mainnet.era.zksync.io}

# Colors for terminal output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPTS_PATH="script/deployments"
TESTED_PATH="$SCRIPTS_PATH/tested"
mkdir -p "$TESTED_PATH"

# Collect all deployment scripts
SCRIPTS=$(find "$SCRIPTS_PATH" -name "Deploy*.s.sol" | sort)

# Test each script
total=0
passed=0
failed=0

# Ethereum mainnet deployments
test_mainnet_deployments() {
    echo -e "${YELLOW}Testing mainnet deployments...${NC}"
    
    for script in $SCRIPTS; do
        # Skip scripts that are for L2s
        if [[ $script == *"SpokePool"* ]] && 
           [[ $script != *"EthereumSpokePool"* ]]; then
            continue
        fi
        
        script_name=$(basename "$script")
        contract=$(echo "$script_name" | sed 's/\.s\.sol//' | tr '[:upper:]' '[:lower:]')
        
        echo -e "${YELLOW}Testing $script_name...${NC}"
        
        # Set environment variables needed for the test
        export HUB_POOL_ADDRESS="0xc186fa914353c44b2e33ebe05f21846f1048beda"
        export MNEMONIC="test test test test test test test test test test test junk"
        
        # Create temporary API key env vars to avoid errors
        export ETHERSCAN_API_KEY=1
        export ARBITRUM_ETHERSCAN_API_KEY=1
        export OPTIMISM_ETHERSCAN_API_KEY=1
        export POLYGON_ETHERSCAN_API_KEY=1
        export BASE_ETHERSCAN_API_KEY=1
        export LINEA_ETHERSCAN_API_KEY=1
        export SCROLL_ETHERSCAN_API_KEY=1
        export BLAST_ETHERSCAN_API_KEY=1
        
        total=$((total + 1))
        
        # Run the test
        if forge script "$script" --fork-url $MAINNET_RPC_URL -vv > "$TESTED_PATH/$contract.log" 2>&1; then
            echo -e "${GREEN}✅ $script_name passed${NC}"
            passed=$((passed + 1))
        else
            echo -e "${RED}❌ $script_name failed${NC}"
            failed=$((failed + 1))
            echo -e "${RED}See logs at $TESTED_PATH/$contract.log${NC}"
        fi
    done
}

# Function to test a spoke pool deployment
test_spoke_pool() {
    local chain=$1
    local rpc_url=$2
    local spoke_name="Deploy${chain}SpokePool.s.sol"
    local log_name=$(echo "${chain}spokepool" | tr '[:upper:]' '[:lower:]').log
    
    if [[ -f "$SCRIPTS_PATH/$spoke_name" ]]; then
        echo -e "${YELLOW}Testing $spoke_name on $chain...${NC}"
        export HUB_POOL_ADDRESS="0xc186fa914353c44b2e33ebe05f21846f1048beda"
        export MNEMONIC="test test test test test test test test test test test junk"
        export YIELD_RECIPIENT="0x0000000000000000000000000000000000000001"
        
        total=$((total + 1))
        if forge script "$SCRIPTS_PATH/$spoke_name" --fork-url $rpc_url -vv > "$TESTED_PATH/$log_name" 2>&1; then
            echo -e "${GREEN}✅ $spoke_name passed${NC}"
            passed=$((passed + 1))
        else
            echo -e "${RED}❌ $spoke_name failed${NC}"
            failed=$((failed + 1))
            echo -e "${RED}See logs at $TESTED_PATH/$log_name${NC}"
        fi
    fi
}

# L2 spoke pool deployments
test_l2_deployments() {
    echo -e "${YELLOW}Testing L2 deployments...${NC}"
    
    # Test each chain's spoke pool
    test_spoke_pool "Optimism" "$OPTIMISM_RPC_URL"
    test_spoke_pool "Arbitrum" "$ARBITRUM_RPC_URL"
    test_spoke_pool "Polygon" "$POLYGON_RPC_URL"
    test_spoke_pool "Base" "$BASE_RPC_URL"
    test_spoke_pool "Blast" "$BLAST_RPC_URL"
    test_spoke_pool "Linea" "$LINEA_RPC_URL"
    test_spoke_pool "Scroll" "$SCROLL_RPC_URL"
    test_spoke_pool "Mode" "$MODE_RPC_URL"
    test_spoke_pool "ZkSync" "$ZKSYNC_RPC_URL"
}

# Run tests
test_mainnet_deployments
test_l2_deployments

# Report results
echo 
echo -e "${YELLOW}=== Test Results ===${NC}"
echo -e "${YELLOW}Total tests: ${total}${NC}"
echo -e "${GREEN}Passed: ${passed}${NC}"
echo -e "${RED}Failed: ${failed}${NC}"

if [ $failed -eq 0 ]; then
    echo -e "${GREEN}All deployment scripts passed!${NC}"
    exit 0
else
    echo -e "${RED}Some deployment scripts failed. See logs in $TESTED_PATH directory.${NC}"
    exit 1
fi