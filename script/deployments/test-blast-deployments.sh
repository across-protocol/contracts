#\!/bin/bash

# Script to test Blast-related Foundry deployment scripts
# Note that these tests are run on forked networks
# Requires environment variables:
# - MAINNET_RPC: URL for Ethereum mainnet RPC
# - SEPOLIA_RPC: URL for Ethereum Sepolia RPC
# - BLAST_RPC: URL for Blast mainnet RPC
# - BLAST_SEPOLIA_RPC: URL for Blast Sepolia RPC
# - MNEMONIC: 12-word mnemonic for testing

set -e # Exit on any error

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Function to run a test
run_test() {
    local script_name=$1
    local network=$2
    local extra_args=$3

    echo "Testing ${script_name} on ${network}..."
    
    # Set HUB_POOL_ADDRESS to a test address
    export HUB_POOL_ADDRESS=0x40f941E48A552bF496B154Af6bf55725f18D77c3
    
    # Run the deployment script with --dry-run to avoid actual transactions
    if forge script script/deployments/${script_name}.s.sol:${script_name} --rpc-url ${network} --broadcast --dry-run ${extra_args}; then
        echo -e "${GREEN}✓ ${script_name} on ${network} passed\!${NC}"
        return 0
    else
        echo -e "${RED}✗ ${script_name} on ${network} failed\!${NC}"
        return 1
    fi
}

# Count successes and failures
total=0
passed=0

# Test Blast adapter on Ethereum mainnet and Sepolia
for network in $MAINNET_RPC $SEPOLIA_RPC; do
    total=$((total+1))
    if run_test "DeployBlastAdapter" $network; then
        passed=$((passed+1))
    fi
done

# Test Blast SpokePool on Blast mainnet and Sepolia
for network in $BLAST_RPC $BLAST_SEPOLIA_RPC; do
    total=$((total+1))
    if run_test "DeployBlastSpokePool" $network; then
        passed=$((passed+1))
    fi
done

# Test Blast DAI Retriever on Ethereum mainnet and Sepolia
for network in $MAINNET_RPC $SEPOLIA_RPC; do
    total=$((total+1))
    if run_test "DeployBlastDaiRetriever" $network; then
        passed=$((passed+1))
    fi
done

# Test Blast Rescue Adapter on Ethereum mainnet and Sepolia
for network in $MAINNET_RPC $SEPOLIA_RPC; do
    total=$((total+1))
    if run_test "DeployBlastRescueAdapter" $network; then
        passed=$((passed+1))
    fi
done

echo -e "${GREEN}Tests passed: ${passed}/${total}${NC}"

if [ $passed -eq $total ]; then
    echo -e "${GREEN}All Blast deployment tests passed\!${NC}"
    exit 0
else
    echo -e "${RED}Some Blast deployment tests failed\!${NC}"
    exit 1
fi
