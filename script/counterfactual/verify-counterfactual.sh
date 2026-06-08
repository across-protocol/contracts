#!/usr/bin/env bash
# Verify the counterfactual stack on Optimism (10), Base (8453) and HyperEVM (999).
#
# Optimism + Base are Etherscan v2 (one ETHERSCAN_API_KEY, selected by --chain). HyperEVM is NOT Etherscan
# — it uses a Blockscout explorer (hyperscan.com), so it takes --verifier blockscout. Compiler settings come
# from the `counterfactual` foundry profile (the profile the contracts were deployed under), so every call
# is prefixed FOUNDRY_PROFILE=counterfactual.
#
# Usage:  source .env   # must export ETHERSCAN_API_KEY
#         bash script/counterfactual/verify-counterfactual.sh
#
# Notes:
# - Constructor args are passed via `cast abi-encode` (offline) so they match what was deployed.
# - ERC1967Proxy is a standard OZ contract and is usually auto-recognized by explorers; a best-effort
#   command is included but may be skipped if the explorer already flags it as a proxy.
# - AdminWithdrawManager is NOT verified on 999 because it is not deployed there yet (deploy it first).
# - HyperEVM/Blockscout caveat: forge-nightly can ignore --verifier when ETHERSCAN_API_KEY is set (see the
#   monad-sourcify note). If the 999 calls try Etherscan and fail, re-run that block with the key cleared:
#       env -u ETHERSCAN_API_KEY FOUNDRY_PROFILE=counterfactual forge verify-contract ...
#   or upload the standard-json (`--show-standard-json-input`) via the hyperscan.com UI.
set -uo pipefail

SIGNER=0xDDB199Ca909901299aDcAB370C3C8212cea80AFE
DEPLOYER=0x9A8f92a830A5cB89a3816e3D267CB7791c16b04D
PROXY=0x7a4ae4fe9a7867bef4c0e00a1d2e1dc4a9666b79
BEACON_IMPL=0xa6726409b8a53b8fa51c0b414d3718cc79f05e24
DISPATCHER=0xfdde8fe6f4840ba2a32c0ed0339681a9611dd3a7
FACTORY=0x3812a7a9022163b176fc3c794079db7843a70a58
WITHDRAW=0xc1e7a56941f7c91324b2345424ad968121b88b01
ADMIN=0x483b24c646b59537dac194f13cce69c16487db2b
# ERC1967Proxy initialize calldata (initialize(deployer, address(0), bytes32(0))) — from the broadcast artifact.
PROXY_INIT=0x6133f9850000000000000000000000009a8f92a830a5cb89a3816e3d267cb7791c16b04d00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000

CF=contracts/periphery/counterfactual
BEACON_ID=$CF/CounterfactualBeacon.sol:CounterfactualBeacon
DISPATCHER_ID=$CF/CounterfactualDeposit.sol:CounterfactualDeposit
FACTORY_ID=$CF/CounterfactualDepositFactory.sol:CounterfactualDepositFactory
WITHDRAW_ID=$CF/WithdrawImplementation.sol:WithdrawImplementation
ADMIN_ID=$CF/AdminWithdrawManager.sol:AdminWithdrawManager
SPOKE_ID=$CF/CounterfactualDepositSpokePool.sol:CounterfactualDepositSpokePool
CCTP_ID=$CF/CounterfactualDepositCCTP.sol:CounterfactualDepositCCTP
VANILLA_ID=$CF/CounterfactualDepositVanillaCCTP.sol:CounterfactualDepositVanillaCCTP
PROXY_ID='@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol:ERC1967Proxy'

# verify <address> <id> <chain-flags...> [constructor-args-hex]
verify() {
  local addr=$1 id=$2 chainflags=$3 args=${4:-}
  echo ">>> $id @ $addr ($chainflags)"
  if [ -n "$args" ]; then
    FOUNDRY_PROFILE=counterfactual forge verify-contract "$addr" "$id" $chainflags --watch --constructor-args "$args"
  else
    FOUNDRY_PROFILE=counterfactual forge verify-contract "$addr" "$id" $chainflags --watch
  fi
}

# Etherscan v2 flag set per chain; HyperEVM uses Blockscout.
ETHERSCAN() { echo "--chain $1 --etherscan-api-key ${ETHERSCAN_API_KEY:?set ETHERSCAN_API_KEY}"; }
BLOCKSCOUT_999="--chain 999 --verifier blockscout --verifier-url https://www.hyperscan.com/api/"

# ---- Chain-invariant anchors (same address + args on every chain) ----
DISPATCHER_ARGS=$(cast abi-encode "constructor(address)" $PROXY)
FACTORY_ARGS=$(cast abi-encode "constructor(address)" $PROXY)
ADMIN_ARGS=$(cast abi-encode "constructor(address,address,address)" $DEPLOYER $DEPLOYER $SIGNER)
PROXY_ARGS=$(cast abi-encode "constructor(address,bytes)" $BEACON_IMPL $PROXY_INIT)
VANILLA_ARGS=$(cast abi-encode "constructor(address,address)" 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d $SIGNER)
VANILLA=0xa629cdca38ff7a4f5f96c7c4bd622e72d3fda8cb

verify_common() {  # $1 = chain flags, $2 = include admin? (yes/no)
  local F=$1
  verify $BEACON_IMPL "$BEACON_ID" "$F"
  verify $PROXY       "$PROXY_ID"  "$F" "$PROXY_ARGS"
  verify $DISPATCHER  "$DISPATCHER_ID" "$F" "$DISPATCHER_ARGS"
  verify $FACTORY     "$FACTORY_ID" "$F" "$FACTORY_ARGS"
  verify $WITHDRAW    "$WITHDRAW_ID" "$F"
  verify $VANILLA     "$VANILLA_ID" "$F" "$VANILLA_ARGS"
  [ "$2" = yes ] && verify $ADMIN "$ADMIN_ID" "$F" "$ADMIN_ARGS"
}

# =================== Optimism (10) ===================
F=$(ETHERSCAN 10)
verify_common "$F" yes
verify 0x7985313182cbab6bec76c3a61854dbcf17a24627 "$SPOKE_ID" "$F" \
  "$(cast abi-encode 'constructor(address,address,address)' 0x6f26Bf09B1C792e3228e5467807a900A503c0281 $SIGNER 0x4200000000000000000000000000000000000006)"
verify 0x0aacd99029ae96a7725c8608edf38d1b9c401014 "$CCTP_ID" "$F" \
  "$(cast abi-encode 'constructor(address,uint32,address)' 0x4d11A23E4408eF08Ae1216B3917560e0001CD000 2 $SIGNER)"

# =================== Base (8453) ===================
F=$(ETHERSCAN 8453)
verify_common "$F" yes
verify 0xe7f176646950b955234f7064063862474d0240b0 "$SPOKE_ID" "$F" \
  "$(cast abi-encode 'constructor(address,address,address)' 0x09aea4b2242abC8bb4BB78D537A67a245A7bEC64 $SIGNER 0x4200000000000000000000000000000000000006)"
verify 0x7acf53df522853f3a641bc47fec9340aa81a3826 "$CCTP_ID" "$F" \
  "$(cast abi-encode 'constructor(address,uint32,address)' 0xa30968D3468316D957B9115EAad3C1c8E450116d 6 $SIGNER)"

# =================== HyperEVM (999) — Blockscout, no AdminWithdrawManager (not deployed there) ===================
F="$BLOCKSCOUT_999"
verify_common "$F" no
verify 0x1cba6a7c4b9ce54e060320fc138426d155302340 "$SPOKE_ID" "$F" \
  "$(cast abi-encode 'constructor(address,address,address)' 0x35E63eA3eb0fb7A3bc543C71FB66412e1F6B0E04 $SIGNER 0x5555555555555555555555555555555555555555)"
verify 0x97211d3be4df104d6eae18a050b3866215f888ed "$CCTP_ID" "$F" \
  "$(cast abi-encode 'constructor(address,uint32,address)' 0xF4E32c4aC479f0B007BC005Ec0F481A2C78Ba1B4 19 $SIGNER)"

echo "Done. Re-run is idempotent (already-verified contracts report 'already verified')."
