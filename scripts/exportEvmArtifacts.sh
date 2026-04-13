#!/bin/sh
# Extracts ABI and bytecode from Foundry's out/ artifacts into dist/evm/artifacts/ for npm publishing.
# This avoids shipping the full out/ directory (~1 GB of ASTs, storage layouts, etc.)
# while still providing ABIs and bytecode for downstream consumers (e.g. typechain, tests).
set -e

OUT_DIR="out"
ARTIFACTS_DIR="dist/evm/artifacts"

if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required but not installed." >&2
  exit 1
fi

if [ ! -d "$OUT_DIR" ]; then
  echo "Error: $OUT_DIR not found. Run 'forge build' first." >&2
  exit 1
fi

exported=0
skipped=0
filtered=0

for sol_dir in "$OUT_DIR"/*.sol; do
  [ -d "$sol_dir" ] || continue
  dir_name=$(basename "$sol_dir")

  # Skip forge test/script artifacts and stdlib.
  case "$dir_name" in
    *.t.sol|*.s.sol) filtered=$(( filtered + 1 )); continue ;;
    Vm.sol|Script.sol|Test.sol|Base.sol|console.sol|console2.sol|\
    StdStyle.sol|StdError.sol|StdAssertions.sol|StdChains.sol|\
    StdCheats.sol|StdInvariant.sol|StdJson.sol|StdMath.sol|\
    StdStorage.sol|StdToml.sol|StdUtils.sol|Std.sol|\
    safeconsole.sol|CommonBase.sol|Components.sol) filtered=$(( filtered + 1 )); continue ;;
  esac

  for json_file in "$sol_dir"/*.json; do
    [ -f "$json_file" ] || continue

    # Extract ABI and bytecode; skip if ABI is empty or absent.
    abi=$(jq -c '.abi // empty | select(length > 0)' "$json_file" 2>/dev/null) || true
    if [ -z "$abi" ]; then
      skipped=$(( skipped + 1 ))
      continue
    fi

    bytecode=$(jq -c '.bytecode.object // empty' "$json_file" 2>/dev/null) || true

    dest_dir="$ARTIFACTS_DIR/$dir_name"
    mkdir -p "$dest_dir"
    if [ -n "$bytecode" ] && [ "$bytecode" != '""' ]; then
      printf '{"abi":%s,"bytecode":%s}' "$abi" "$bytecode" > "$dest_dir/$(basename "$json_file")"
    else
      printf '{"abi":%s}' "$abi" > "$dest_dir/$(basename "$json_file")"
    fi
    exported=$(( exported + 1 ))
  done
done

if [ "$exported" -eq 0 ]; then
  echo "Error: no EVM artifacts were exported. Check that $OUT_DIR contains valid Foundry artifacts." >&2
  exit 1
fi

echo "Exported $exported EVM artifacts to $ARTIFACTS_DIR, skipped $skipped, filtered $filtered"
