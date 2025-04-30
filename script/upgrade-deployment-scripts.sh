#!/bin/bash

# This script updates SpokePool deployment scripts to include proxy deployment functionality
# It adds the necessary imports, constants, and proxy deployment code

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Find all SpokePool deployment scripts
SPOKE_POOL_SCRIPTS=$(find script/deployments -name "Deploy*SpokePool.s.sol" | sort)

total=0
updated=0
failed=0

for script in $SPOKE_POOL_SCRIPTS; do
    total=$((total + 1))
    script_name=$(basename "$script")
    contract_name=$(echo "$script_name" | sed 's/Deploy\(.*\)SpokePool.s.sol/\1/')
    
    echo -e "${YELLOW}Updating $script_name for $contract_name...${NC}"
    
    # Step 1: Update imports to include proxy related imports
    if grep -q "TransparentUpgradeableProxy" "$script"; then
        echo -e "${YELLOW}Script already has proxy imports, skipping import update${NC}"
    else
        # Update ChainUtils import path if needed
        sed -i '' 's|import { ChainUtils } from "../utils/ChainUtils.sol";|import { ChainUtils } from "../../utils/ChainUtils.sol";|g' "$script"
        sed -i '' 's|import { ChainUtils } from "./utils/ChainUtils.sol";|import { ChainUtils } from "../../utils/ChainUtils.sol";|g' "$script"
        
        # Add proxy imports 
        sed -i '' '/import.*ChainUtils.sol";/a\\
import { TransparentUpgradeableProxy } from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";\
import { ProxyAdmin } from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";' "$script"
        
        echo -e "${GREEN}Added proxy imports${NC}"
    fi
    
    # Step 2: Add INITIAL_DEPOSIT_ID constant
    if grep -q "INITIAL_DEPOSIT_ID" "$script"; then
        echo -e "${YELLOW}Script already has INITIAL_DEPOSIT_ID constant, skipping${NC}"
    else
        # Try to find where to insert the constant
        if grep -q "DeployKit" "$script"; then
            echo -e "${YELLOW}Skipping constant for DeployKit.sol${NC}"
        else
            sed -i '' '/contract Deploy.*SpokePool/a\\
    // Constants\
    uint32 constant INITIAL_DEPOSIT_ID = 1_000_000; // To avoid duplicate IDs with deprecated spoke pool' "$script"
            echo -e "${GREEN}Added INITIAL_DEPOSIT_ID constant${NC}"
        fi
    fi
    
    # Step 3: Update implementation deployment and add proxy deployment
    spoke_contract="${contract_name}_SpokePool"
    
    # Check if the script already has proxy deployment code
    if grep -q "TransparentUpgradeableProxy proxy" "$script"; then
        echo -e "${YELLOW}Script already has proxy deployment code, skipping${NC}"
    else
        # Look for implementation deployment line
        impl_line=$(grep -n "new ${spoke_contract}" "$script" | head -1 | cut -d':' -f1)
        
        if [ -z "$impl_line" ]; then
            echo -e "${RED}Could not find implementation deployment line for $spoke_contract${NC}"
            failed=$((failed + 1))
            continue
        fi
        
        # Look for the end of the implementation deployment
        end_impl_line=$(tail -n +$impl_line "$script" | grep -n ");" | head -1)
        end_impl_line=$((impl_line + $(echo "$end_impl_line" | cut -d':' -f1) - 1))
        
        # Look for the console.log line after implementation deployment
        log_line=$(tail -n +$end_impl_line "$script" | grep -n "console.log" | head -1)
        
        if [ -z "$log_line" ]; then
            echo -e "${RED}Could not find console.log line after implementation deployment${NC}"
            failed=$((failed + 1))
            continue
        fi
        
        # Calculate line to insert proxy code
        insert_line=$((end_impl_line + $(echo "$log_line" | cut -d':' -f1)))
        
        # Update the implementation variable name if needed
        sed -i '' "${impl_line}s/= new ${spoke_contract}/= new ${spoke_contract}/g" "$script"
        sed -i '' "${impl_line}s/${spoke_contract} spokePool/${spoke_contract} spokePoolImplementation/g" "$script"
        
        # Update the console.log line
        sed -i '' "${insert_line}s/deployed at/implementation deployed at/g" "$script"
        sed -i '' "${insert_line}s/spokePool/spokePoolImplementation/g" "$script"
        
        # Add proxy deployment code
        proxy_code="        // Deploy ProxyAdmin contract to manage the proxy\n        ProxyAdmin proxyAdmin = new ProxyAdmin();\n        console.log(\"ProxyAdmin deployed at: %s\", address(proxyAdmin));\n        \n        // Create initialization data for the proxy\n        bytes memory initData = abi.encodeWithSelector(\n            ${spoke_contract}.initialize.selector,\n            INITIAL_DEPOSIT_ID,  // Initial deposit ID\n            hubPoolAddress,      // Set hub pool as cross domain admin\n            hubPoolAddress       // Set hub pool as withdrawal recipient\n        );\n        \n        // Deploy the proxy pointing to the implementation with initialization data\n        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(\n            address(spokePoolImplementation),\n            address(proxyAdmin),     // Admin of the proxy\n            initData\n        );\n        console.log(\"${spoke_contract} proxy deployed at: %s\", address(proxy));\n        \n        // Transfer ProxyAdmin ownership to the deployer\n        proxyAdmin.transferOwnership(deployer);\n        console.log(\"ProxyAdmin ownership transferred to: %s\", deployer);"
        
        sed -i '' "${insert_line}a\\
$proxy_code" "$script"
        
        echo -e "${GREEN}Added proxy deployment code${NC}"
        updated=$((updated + 1))
    fi
done

echo 
echo -e "${YELLOW}=== Update Results ===${NC}"
echo -e "${YELLOW}Total scripts: ${total}${NC}"
echo -e "${GREEN}Updated: ${updated}${NC}"
echo -e "${RED}Failed: ${failed}${NC}"

if [ $failed -eq 0 ]; then
    echo -e "${GREEN}All deployment scripts updated successfully!${NC}"
    exit 0
else
    echo -e "${RED}Some deployment scripts could not be updated automatically.${NC}"
    exit 1
fi