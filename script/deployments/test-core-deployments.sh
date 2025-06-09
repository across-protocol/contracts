#!/bin/bash

# Test core deployment scripts on forked networks
set -e

# Default RPC URLs if not defined in environment
: ${MAINNET_RPC_URL:=https://ethereum.publicnode.com}
: ${OPTIMISM_RPC_URL:=https://mainnet.optimism.io}
: ${BASE_RPC_URL:=https://mainnet.base.org}
: ${BLAST_RPC_URL:=https://rpc.blast.io}

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SCRIPTS_PATH="script/deployments"
TESTED_PATH="$SCRIPTS_PATH/tested"
mkdir -p "$TESTED_PATH"

# Set up environment for testing
export MNEMONIC="test test test test test test test test test test test junk"
export HUB_POOL_ADDRESS="0xc186fa914353c44b2e33ebe05f21846f1048beda"
export ETHERSCAN_API_KEY=1
export YIELD_RECIPIENT="0x0000000000000000000000000000000000000001"

# Test a specific deployment script on a given RPC URL
test_deployment() {
    local script=$1
    local rpc_url=$2
    local script_name=$(basename "$script")
    local log_file="$TESTED_PATH/$(echo $script_name | tr '[:upper:]' '[:lower:]' | sed 's/\.s\.sol/.log/')"
    
    echo -e "${YELLOW}Testing $script_name on $(echo $rpc_url | cut -d'/' -f3)...${NC}"
    
    if forge script "$script" --fork-url $rpc_url -vv > "$log_file" 2>&1; then
        echo -e "${GREEN}✅ $script_name passed${NC}"
        return 0
    else
        echo -e "${RED}❌ $script_name failed${NC}"
        echo -e "${RED}See logs at $log_file${NC}"
        return 1
    fi
}

# Initialize counters
total=0
passed=0
failed=0

# Test HubPool deployment
echo -e "${YELLOW}Testing HubPool deployment...${NC}"
((total++))
if test_deployment "$SCRIPTS_PATH/DeployHubPool.s.sol" "$MAINNET_RPC_URL"; then
    ((passed++))
else
    ((failed++))
fi

# Test Optimism adapter and spoke pool
echo -e "${YELLOW}Testing Optimism adapter and spoke pool...${NC}"
((total++))
if test_deployment "$SCRIPTS_PATH/DeployOptimismAdapter.s.sol" "$MAINNET_RPC_URL"; then
    ((passed++))
else
    ((failed++))
fi

((total++))
if test_deployment "$SCRIPTS_PATH/DeployOptimismSpokePool.s.sol" "$OPTIMISM_RPC_URL"; then
    ((passed++))
else
    ((failed++))
fi

# Test Base adapter and spoke pool
echo -e "${YELLOW}Testing Base adapter and spoke pool...${NC}"
((total++))
if test_deployment "$SCRIPTS_PATH/DeployBaseAdapter.s.sol" "$MAINNET_RPC_URL"; then
    ((passed++))
else
    ((failed++))
fi

((total++))
if test_deployment "$SCRIPTS_PATH/DeployBaseSpokePool.s.sol" "$BASE_RPC_URL"; then
    ((passed++))
else
    ((failed++))
fi

# Test Blast adapter and spoke pool
echo -e "${YELLOW}Testing Blast adapter and spoke pool...${NC}"
((total++))
if test_deployment "$SCRIPTS_PATH/DeployBlastAdapter.s.sol" "$MAINNET_RPC_URL"; then
    ((passed++))
else
    ((failed++))
fi

# Use a public endpoint with better reliability for Blast network
export BLAST_RPC_URL=https://rpc.ankr.com/blast
export TESTING_MODE=true

((total++))
if test_deployment "$SCRIPTS_PATH/DeployBlastSpokePool.s.sol" "$BLAST_RPC_URL"; then
    ((passed++))
else
    ((failed++))
fi

# Reset testing mode
unset TESTING_MODE

# Report results
echo 
echo -e "${YELLOW}=== Test Results ===${NC}"
echo -e "${YELLOW}Total tests: ${total}${NC}"
echo -e "${GREEN}Passed: ${passed}${NC}"
echo -e "${RED}Failed: ${failed}${NC}"

if [ $failed -eq 0 ]; then
    echo -e "${GREEN}All core deployment scripts passed!${NC}"
    exit 0
else
    echo -e "${RED}Some core deployment scripts failed. See logs in $TESTED_PATH directory.${NC}"
    exit 1
fi