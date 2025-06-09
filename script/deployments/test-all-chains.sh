#!/bin/bash

# Script to test deployment scripts for all supported chains
# Note: This script requires RPC URLs for all chains to be set in environment variables

set -e

# Colors for terminal output
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

# Default RPC URLs if not defined in environment
: ${MAINNET_RPC_URL:=https://ethereum.publicnode.com}
: ${SEPOLIA_RPC_URL:=https://ethereum-sepolia.publicnode.com}
: ${OPTIMISM_RPC_URL:=https://mainnet.optimism.io}
: ${OPTIMISM_SEPOLIA_RPC_URL:=https://sepolia.optimism.io}
: ${ARBITRUM_RPC_URL:=https://arb1.arbitrum.io/rpc}
: ${ARBITRUM_SEPOLIA_RPC_URL:=https://sepolia-rollup.arbitrum.io/rpc}
: ${POLYGON_RPC_URL:=https://polygon-rpc.com}
: ${POLYGON_AMOY_RPC_URL:=https://rpc-amoy.polygon.technology}
: ${BASE_RPC_URL:=https://mainnet.base.org}
: ${BASE_SEPOLIA_RPC_URL:=https://sepolia.base.org}
: ${LINEA_RPC_URL:=https://rpc.linea.build}
: ${SCROLL_RPC_URL:=https://rpc.scroll.io}
: ${SCROLL_SEPOLIA_RPC_URL:=https://sepolia-rpc.scroll.io}
: ${BLAST_RPC_URL:=https://rpc.ankr.com/blast}
: ${BLAST_SEPOLIA_RPC_URL:=https://sepolia.blast.io}
: ${MODE_RPC_URL:=https://mainnet.mode.network}
: ${MODE_SEPOLIA_RPC_URL:=https://sepolia.mode.network}
: ${ZKSYNC_RPC_URL:=https://mainnet.era.zksync.io}
: ${ZKSYNC_SEPOLIA_RPC_URL:=https://sepolia.era.zksync.dev}
: ${LISK_RPC_URL:=https://rpc.api.lisk.com}
: ${LISK_SEPOLIA_RPC_URL:=https://rpc.sepolia-api.lisk.com}
: ${REDSTONE_RPC_URL:=https://rpc.redstonechain.com}
: ${WORLDCHAIN_RPC_URL:=https://worldchain-mainnet.g.alchemy.com/public}
: ${ZORA_RPC_URL:=https://rpc.zora.energy}
: ${LENS_RPC_URL:=https://api.lens.matterhosted.dev}
: ${LENS_SEPOLIA_RPC_URL:=https://rpc.testnet.lens.dev}

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

# Test L1 deployments on Ethereum mainnet
echo -e "${YELLOW}=== Testing L1 deployments on Ethereum mainnet ===${NC}"

l1_scripts=(
    "$SCRIPTS_PATH/DeployHubPool.s.sol"
    "$SCRIPTS_PATH/DeployConfigStore.s.sol"
    "$SCRIPTS_PATH/DeploySpokePoolVerifier.s.sol"
    "$SCRIPTS_PATH/DeployBondToken.s.sol"
    "$SCRIPTS_PATH/DeployEthereumSpokePool.s.sol"
    "$SCRIPTS_PATH/DeployMulticall3.s.sol"
    "$SCRIPTS_PATH/DeployAcrossMerkleDistributor.s.sol"
    "$SCRIPTS_PATH/DeployEthereumAdapter.s.sol"
)

# Add all chain adapters
for adapter in $SCRIPTS_PATH/Deploy*Adapter.s.sol; do
    if [[ ! " ${l1_scripts[@]} " =~ " $adapter " ]]; then
        l1_scripts+=("$adapter")
    fi
done

# Test each L1 script
for script in "${l1_scripts[@]}"; do
    if [[ -f "$script" ]]; then
        ((total++))
        if test_deployment "$script" "$MAINNET_RPC_URL"; then
            ((passed++))
        else
            ((failed++))
        fi
    fi
done

# Test L2 deployments
echo -e "${YELLOW}=== Testing L2 deployments ===${NC}"

# Map of chain names to RPC URLs
declare -A chain_rpc_map=(
    ["Optimism"]="$OPTIMISM_RPC_URL"
    ["Arbitrum"]="$ARBITRUM_RPC_URL"
    ["Polygon"]="$POLYGON_RPC_URL"
    ["Base"]="$BASE_RPC_URL"
    ["Linea"]="$LINEA_RPC_URL"
    ["Scroll"]="$SCROLL_RPC_URL"
    ["Mode"]="$MODE_RPC_URL"
    ["ZkSync"]="$ZKSYNC_RPC_URL"
    ["Redstone"]="$REDSTONE_RPC_URL"
    ["Zora"]="$ZORA_RPC_URL"
    ["WorldChain"]="$WORLDCHAIN_RPC_URL"
    ["Lisk"]="$LISK_RPC_URL"
    ["Lens"]="$LENS_RPC_URL"
)

# Special case for Blast testing
export TESTING_MODE=true
chain_rpc_map["Blast"]="$BLAST_RPC_URL"

# Test each L2 SpokePool
for chain in "${!chain_rpc_map[@]}"; do
    rpc_url="${chain_rpc_map[$chain]}"
    script="$SCRIPTS_PATH/Deploy${chain}SpokePool.s.sol"
    
    if [[ -f "$script" ]]; then
        ((total++))
        if test_deployment "$script" "$rpc_url"; then
            ((passed++))
        else
            ((failed++))
        fi
    fi
done

# Reset testing mode
unset TESTING_MODE

# Test auxiliary deployments
echo -e "${YELLOW}=== Testing auxiliary deployments ===${NC}"

aux_scripts=(
    "$SCRIPTS_PATH/DeployMulticallHandler.s.sol"
    "$SCRIPTS_PATH/DeployZkMulticallHandler.s.sol"
    "$SCRIPTS_PATH/DeployERC1155.s.sol"
    "$SCRIPTS_PATH/DeployBlastDaiRetriever.s.sol"
    "$SCRIPTS_PATH/DeployDonationBox.s.sol"
    "$SCRIPTS_PATH/DeploySwapAndBridge.s.sol"
)

for script in "${aux_scripts[@]}"; do
    if [[ -f "$script" ]]; then
        ((total++))
        if test_deployment "$script" "$MAINNET_RPC_URL"; then
            ((passed++))
        else
            ((failed++))
        fi
    fi
done

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