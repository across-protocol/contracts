#!/bin/bash
# AcrossOriginSettler Deployment and Verification Script
# Usage: ./deploy_across_origin_settler.sh [CHAIN_ID] [RPC_URL]
# Example: ./deploy_across_origin_settler.sh 1 https://mainnet.infura.io/v3/YOUR_API_KEY

set -e # Exit on error

# Default parameters
CHAIN_ID=${1:-1}
RPC_URL=${2:-""}
API_KEY=${3:-""}

echo "=== AcrossOriginSettler Deployment and Verification ==="
echo "Chain ID: $CHAIN_ID"
echo "RPC URL: $RPC_URL"

# Step 1: Deployment
echo "Deploying AcrossOriginSettler..."
# forge script script/deployments/DeployAcrossOriginSettler.s.sol \
#   --rpc-url "$RPC_URL" \
#   $WALLET_FLAG \
#   --broadcast \
#   --skip-simulation \
#   -vvv
DEPLOYMENT_OUTPUT=$(forge script script/deployments/DeployAcrossOriginSettler.s.sol \
  --rpc-url "$RPC_URL" \
  $WALLET_FLAG \
  --broadcast \
  --skip-simulation \
  -vvv 2>&1)

echo "$DEPLOYMENT_OUTPUT"

# Extract contract address and constructor args
SETTLER_ADDRESS=$(echo "$DEPLOYMENT_OUTPUT" | grep -A 3 "=== DEPLOYMENT SUMMARY ===" | grep "AcrossOriginSettler deployed at:" | awk '{print $NF}')
SPOKE_POOL_ADDRESS=$(echo "$DEPLOYMENT_OUTPUT" | grep "SpokePool:" | awk '{print $NF}')
PERMIT2_ADDRESS="0x000000000022D473030F116dDEE9F6B43aC78BA3" # Standard address
QUOTE_BEFORE_DEADLINE=$(echo "$DEPLOYMENT_OUTPUT" | grep "Quote Before Deadline:" | awk '{print $NF}')
BLOCK_NUMBER=$(echo "$DEPLOYMENT_OUTPUT" | grep "Block number:" | awk '{print $NF}')

if [ -z "$SETTLER_ADDRESS" ]; then
  echo "Failed to extract AcrossOriginSettler address from deployment output"
  exit 1
fi

echo "Deployment successful!"
echo "AcrossOriginSettler address: $SETTLER_ADDRESS"
echo "SpokePool address: $SPOKE_POOL_ADDRESS"
echo "Block number: $BLOCK_NUMBER"

# Step 2: Add deployment details to deployments.json
echo """
Use the following snippet to update deployments.json:
{
  \"$CHAIN_ID\": {
    \"AcrossOriginSettler\": {
      \"address\": \"$SETTLER_ADDRESS\",
      \"blockNumber\": $BLOCK_NUMBER
    }
  }
}
"""

# Step 3: Contract verification
echo "Verifying contract on block explorer..."
CONSTRUCTOR_ARGS=$(cast abi-encode "constructor(address,address,uint256)" "$SPOKE_POOL_ADDRESS" "$PERMIT2_ADDRESS" "$QUOTE_BEFORE_DEADLINE")

# Wait a bit for the transaction to be properly indexed
echo "Waiting 12 seconds for the transaction to be indexed..."
sleep 12

forge verify-contract \
  --chain "$CHAIN_ID" \
  --constructor-args "$CONSTRUCTOR_ARGS" \
  "$SETTLER_ADDRESS" \
  contracts/erc7683/AcrossOriginSettler.sol:AcrossOriginSettler \
  --etherscan-api-key "$API_KEY" \
  --watch

echo "Verification submitted! Check the block explorer for status."


echo "=== Deployment Process Complete ==="