#!/bin/bash
set -euo pipefail

# Usage:
#   1. source .env (needs MNEMONIC and the relevant NODE_URL_*)
#   2. ./script/mintburn/cctp/setUpTokens.sh <chain> <dst_periphery_address> <rpc_url>
#   Example: ./script/mintburn/cctp/setUpTokens.sh 999 0xF962E0e485A5B9f8aDa9a438cEecc35c0020B6e7 http://localhost:8545

CHAIN="${1:?Usage: $0 <chain> <dst_periphery_address> <rpc_url>}"
DST_PERIPHERY="${2:?Usage: $0 <chain> <dst_periphery_address> <rpc_url>}"
RPC_URL="${3:?Usage: $0 <chain> <dst_periphery_address> <rpc_url>}"
CONFIG_FILE="./script/mintburn/cctp/config.toml"

# Parse a value from a TOML [chain.section] given a key.
parse_toml() {
	local section="$1" key="$2"
	awk -v section="$section" -v key="$key" '
    $0 ~ "^\\[" section "\\]" { in_section=1; next }
    /^\[/ { in_section=0 }
    in_section && $1 == key && $2 == "=" { gsub(/["[:space:]]/, "", $3); print $3 }
  ' "$CONFIG_FILE"
}

# Read config values
BASE_TOKEN=$(parse_toml "${CHAIN}.address" "baseToken")
: "${BASE_TOKEN:?baseToken not found in config for chain $CHAIN}"

CORE_INDEX=$(parse_toml "${CHAIN}.uint" "coreIndex")
: "${CORE_INDEX:?coreIndex not found in config for chain $CHAIN}"

ACCOUNT_ACTIVATION_FEE_CORE=$(parse_toml "${CHAIN}.uint" "accountActivationFeeCore")
: "${ACCOUNT_ACTIVATION_FEE_CORE:?accountActivationFeeCore not found in config for chain $CHAIN}"

BRIDGE_SAFETY_BUFFER_CORE=$(parse_toml "${CHAIN}.uint" "bridgeSafetyBufferCore")
: "${BRIDGE_SAFETY_BUFFER_CORE:?bridgeSafetyBufferCore not found in config for chain $CHAIN}"

CAN_BE_USED_FOR_ACCOUNT_ACTIVATION=$(parse_toml "${CHAIN}.bool" "canBeUsedForAccountActivation")
: "${CAN_BE_USED_FOR_ACCOUNT_ACTIVATION:?canBeUsedForAccountActivation not found in config for chain $CHAIN}"

echo "# Check DEFAULT_ADMIN_ROLE:"
echo "cast call $DST_PERIPHERY \"DEFAULT_ADMIN_ROLE()(bytes32)\" --rpc-url $RPC_URL"
echo ""
echo "# Check if deployer has DEFAULT_ADMIN_ROLE (replace <DEPLOYER> and <ROLE>):"
echo "cast call $DST_PERIPHERY \"hasRole(bytes32,address)(bool)\" <ROLE> <DEPLOYER> --rpc-url $RPC_URL"
echo ""
echo "# Set core token info:"
echo "cast send $DST_PERIPHERY \\"
echo "  \"setCoreTokenInfo(address,uint32,bool,uint64,uint64)\" \\"
echo "  $BASE_TOKEN \\"
echo "  $CORE_INDEX \\"
echo "  $CAN_BE_USED_FOR_ACCOUNT_ACTIVATION \\"
echo "  $ACCOUNT_ACTIVATION_FEE_CORE \\"
echo "  $BRIDGE_SAFETY_BUFFER_CORE \\"
echo "  --account dev \\"
echo "  --rpc-url $RPC_URL"
