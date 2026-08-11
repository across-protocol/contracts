#!/usr/bin/env bash
#
# Deploys AdminWithdrawManager to every EVM chain in script/counterfactual/config.toml, by invoking
# DeployAdminWithdrawManager.s.sol once per chain.
#
# WHY A SHELL LOOP RATHER THAN A MULTI-CHAIN FORGE SCRIPT: a single forge run that broadcasts to two or more
# chains writes ONE combined sequence to broadcast/multi/<Script>.s.sol-latest/run.json instead of the
# per-chain broadcast/<Script>.s.sol/<chainId>/run-latest.json files. forge also replaces that -latest folder
# wholesale on every rerun, so an idempotent re-run drops the chains it skipped. Invoking the script once per
# chain keeps each deployment in its own durable per-chain file, which is what the address extractor and the
# repo's history expect.
#
# The contract is deployed via CREATE2 with (deployer, deployer, signer): the deployer is BOTH `owner` and
# `directWithdrawer` and stays that way — this script performs no role transfer. All three constructor args
# are chain-invariant, so the address is identical on every chain.
#
# Tron is excluded: forge cannot broadcast to it (use the yarn tron-* scripts).
#
# Reads .env from the repo root automatically (MNEMONIC, NODE_URL_<chainId>, ETHERSCAN_API_KEY); no need to
# source it first, and sourcing it without `export` would not reach this script anyway.
#
# Usage:
#   ./scripts/deployAdminWithdrawManagers.sh                        # dry run, every EVM chain
#   ./scripts/deployAdminWithdrawManagers.sh --broadcast --verify   # deploy for real
#   ./scripts/deployAdminWithdrawManagers.sh --broadcast 8453 42161 # only these chains
#
# Re-running is safe: the deploy is CREATE2 and skips a chain where the contract already exists.

set -uo pipefail

CONFIG="script/counterfactual/config.toml"
SCRIPT="script/counterfactual/DeployAdminWithdrawManager.s.sol:DeployAdminWithdrawManager"
TRON_CHAIN_ID=728126428

if [[ ! -f "$CONFIG" ]]; then
  echo "Error: $CONFIG not found — run this from the repo root." >&2
  exit 1
fi
# Load .env ourselves when the caller has not exported it. `source .env` alone sets shell-local variables,
# which a child process never sees — so without this every NODE_URL_<chainId> reads empty and every chain
# silently SKIPs. `set -a` marks everything sourced as exported so forge inherits it too.
if [[ -z "${MNEMONIC:-}" && -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source ./.env
  set +a
fi
if [[ -z "${MNEMONIC:-}" ]]; then
  echo "Error: MNEMONIC is unset and no .env file was found in $(pwd)." >&2
  exit 1
fi

FORGE_FLAGS=()
CHAINS=()
for arg in "$@"; do
  case "$arg" in
    --broadcast) FORGE_FLAGS+=("--broadcast") ;;
    --verify)    FORGE_FLAGS+=("--verify" "--etherscan-api-key" "${ETHERSCAN_API_KEY:-}") ;;
    --*)         FORGE_FLAGS+=("$arg") ;;
    *)           CHAINS+=("$arg") ;;
  esac
done

# Default to every chain declared in config.toml (minus the [0] globals section and Tron), so this stays in
# step with the config rather than carrying its own hardcoded list.
if [[ ${#CHAINS[@]} -eq 0 ]]; then
  while read -r id; do
    [[ "$id" == "0" || "$id" == "$TRON_CHAIN_ID" ]] && continue
    CHAINS+=("$id")
  done < <(grep -oE '^\[[0-9]+\]' "$CONFIG" | tr -d '[]')
fi

echo "============================================"
echo "AdminWithdrawManager — ${#CHAINS[@]} chain(s)"
echo "Flags: ${FORGE_FLAGS[*]:-(dry run — pass --broadcast to deploy)}"
echo "============================================"

PASSED=(); FAILED=(); SKIPPED=()
for id in "${CHAINS[@]}"; do
  var="NODE_URL_${id}"
  url="${!var:-}"
  echo ""
  echo "--- Chain ${id} ---"
  if [[ -z "$url" ]]; then
    echo "  SKIP: ${var} is unset"
    SKIPPED+=("$id")
    continue
  fi

  # `${arr[@]+"${arr[@]}"}` so an empty flag array does not trip `set -u` on bash 3.2 (macOS default).
  log="$(mktemp)"
  FOUNDRY_PROFILE=counterfactual forge script "$SCRIPT" --rpc-url "$url" \
    ${FORGE_FLAGS[@]+"${FORGE_FLAGS[@]}"} >"$log" 2>&1
  status=$?

  grep -E "AdminWithdrawManager deployed to|Already deployed at" "$log" | sed 's/^/  /'
  if [[ $status -eq 0 ]]; then
    PASSED+=("$id")
    echo "  PASS"
  else
    FAILED+=("$id")
    echo "  FAIL — last lines:"
    tail -5 "$log" | sed 's/^/    /'
  fi
  rm -f "$log"
done

echo ""
echo "============================================"
echo "passed:  ${#PASSED[@]}  ${PASSED[*]:-}"
echo "failed:  ${#FAILED[@]}  ${FAILED[*]:-}"
echo "skipped: ${#SKIPPED[@]}  ${SKIPPED[*]:-}"
echo "============================================"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  echo "Re-run the failures individually to see their full output; the deploy is idempotent."
  exit 1
fi
