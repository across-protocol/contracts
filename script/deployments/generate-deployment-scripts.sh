#!/bin/bash

# Script to generate remaining deployment scripts from templates
# Must be run from the repository root directory

set -e

SCRIPTS_PATH="script/deployments"
TEMPLATES_PATH="$SCRIPTS_PATH/template"
DEPLOY_TS_PATH="deploy"

# Colors for terminal output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Create output directory if it doesn't exist
mkdir -p "$SCRIPTS_PATH"

# Function to generate adapter scripts
generate_adapter_scripts() {
    echo -e "${YELLOW}Generating L1 adapter deployment scripts...${NC}"
    
    # Get all adapter script names
    ADAPTER_SCRIPTS=$(find $DEPLOY_TS_PATH -name "*_deploy_*_adapter.ts" | sort)
    
    for script in $ADAPTER_SCRIPTS; do
        # Extract adapter name
        ADAPTER_NAME=$(echo "$script" | grep -o "[a-zA-Z0-9]*_adapter" | sed 's/_adapter//')
        ADAPTER_NAME="$(tr '[:lower:]' '[:upper:]' <<< ${ADAPTER_NAME:0:1})${ADAPTER_NAME:1}"
        
        # Skip already implemented adapters
        if [ -f "$SCRIPTS_PATH/Deploy${ADAPTER_NAME}Adapter.s.sol" ]; then
            echo "Skipping $ADAPTER_NAME adapter - already implemented"
            continue
        fi
        
        echo "Generating deployment script for ${ADAPTER_NAME}_Adapter"
        
        # Copy template and replace generic name
        cp "$TEMPLATES_PATH/DeployGenericAdapter.s.sol" "$SCRIPTS_PATH/Deploy${ADAPTER_NAME}Adapter.s.sol"
        sed -i "" "s/Generic/$ADAPTER_NAME/g" "$SCRIPTS_PATH/Deploy${ADAPTER_NAME}Adapter.s.sol"
        sed -i "" "s/generic/$(echo "$ADAPTER_NAME" | tr '[:upper:]' '[:lower:]')/g" "$SCRIPTS_PATH/Deploy${ADAPTER_NAME}Adapter.s.sol"
        
        echo -e "${GREEN}Created $SCRIPTS_PATH/Deploy${ADAPTER_NAME}Adapter.s.sol${NC}"
    done
}

# Function to generate spoke pool scripts
generate_spokepool_scripts() {
    echo -e "${YELLOW}Generating L2 spoke pool deployment scripts...${NC}"
    
    # Get all spoke pool script names
    SPOKE_SCRIPTS=$(find $DEPLOY_TS_PATH -name "*_deploy_*_spokepool.ts" | sort)
    
    for script in $SPOKE_SCRIPTS; do
        # Extract spoke pool name
        SPOKE_NAME=$(echo "$script" | grep -o "[a-zA-Z0-9]*_spokepool" | sed 's/_spokepool//')
        SPOKE_NAME="$(tr '[:lower:]' '[:upper:]' <<< ${SPOKE_NAME:0:1})${SPOKE_NAME:1}"
        
        # Skip already implemented spoke pools
        if [ -f "$SCRIPTS_PATH/Deploy${SPOKE_NAME}SpokePool.s.sol" ]; then
            echo "Skipping $SPOKE_NAME spoke pool - already implemented"
            continue
        fi
        
        echo "Generating deployment script for ${SPOKE_NAME}_SpokePool"
        
        # Copy template and replace generic name
        cp "$TEMPLATES_PATH/DeployGenericSpokePool.s.sol" "$SCRIPTS_PATH/Deploy${SPOKE_NAME}SpokePool.s.sol"
        sed -i "" "s/Generic/$SPOKE_NAME/g" "$SCRIPTS_PATH/Deploy${SPOKE_NAME}SpokePool.s.sol"
        sed -i "" "s/generic/$(echo "$SPOKE_NAME" | tr '[:upper:]' '[:lower:]')/g" "$SCRIPTS_PATH/Deploy${SPOKE_NAME}SpokePool.s.sol"
        
        echo -e "${GREEN}Created $SCRIPTS_PATH/Deploy${SPOKE_NAME}SpokePool.s.sol${NC}"
    done
}

# Function to generate utility contract scripts
generate_utility_scripts() {
    echo -e "${YELLOW}Generating utility contract deployment scripts...${NC}"
    
    # Define utility contracts to generate
    UTILITIES=(
        "Multicall3"
        "MulticallHandler"
        "ERC1155"
        "ZkMulticallHandler"
        "BlastDaiRetriever"
        "DonationBox"
        "AcrossMerkleDistributor"
        "SwapAndBridge"
    )
    
    for utility in "${UTILITIES[@]}"; do
        # Skip already implemented utilities
        if [ -f "$SCRIPTS_PATH/Deploy${utility}.s.sol" ]; then
            echo "Skipping $utility - already implemented"
            continue
        fi
        
        echo "Generating deployment script for $utility"
        
        # Copy template and replace utility name
        cp "$TEMPLATES_PATH/DeployUtilityContract.s.sol" "$SCRIPTS_PATH/Deploy${utility}.s.sol"
        sed -i "" "s/UtilityContract/$utility/g" "$SCRIPTS_PATH/Deploy${utility}.s.sol"
        sed -i "" "s/utilitycontract/$(echo "$utility" | tr '[:upper:]' '[:lower:]')/g" "$SCRIPTS_PATH/Deploy${utility}.s.sol"
        
        echo -e "${GREEN}Created $SCRIPTS_PATH/Deploy${utility}.s.sol${NC}"
    done
}

# Run the generation functions
generate_adapter_scripts
generate_spokepool_scripts
generate_utility_scripts

echo -e "${GREEN}Script generation complete! Review the generated scripts and customize as needed.${NC}"