#!/bin/sh
# Extracts ABI arrays from Foundry's out/ artifacts into dist/abi/ for npm publishing.
# This avoids shipping the full out/ directory (~1 GB of bytecode, ASTs, etc.)
# while still providing ABIs for downstream consumers (e.g. typechain).
set -e

OUT_DIR="out"
ABI_DIR="dist/abi"

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

  # Skip non-production artifacts: tests, scripts, mocks, and forge stdlib.
  case "$dir_name" in
    *.t.sol|*.s.sol) filtered=$(( filtered + 1 )); continue ;;
    *Mock*|*Mocks*) filtered=$(( filtered + 1 )); continue ;;
    Vm.sol|Script.sol|Test.sol|Base.sol|console.sol|console2.sol|\
    StdStyle.sol|StdError.sol|StdAssertions.sol|StdChains.sol|\
    StdCheats.sol|StdInvariant.sol|StdJson.sol|StdMath.sol|\
    StdStorage.sol|StdToml.sol|StdUtils.sol|Std.sol|\
    safeconsole.sol|CommonBase.sol|Components.sol) filtered=$(( filtered + 1 )); continue ;;
  esac

  for json_file in "$sol_dir"/*.json; do
    [ -f "$json_file" ] || continue

    # Extract ABI; skip if empty or absent.
    abi=$(jq -c '.abi // empty | select(length > 0)' "$json_file" 2>/dev/null) || true
    if [ -z "$abi" ]; then
      skipped=$(( skipped + 1 ))
      continue
    fi

    dest_dir="$ABI_DIR/$dir_name"
    mkdir -p "$dest_dir"
    printf '{"abi":%s}' "$abi" > "$dest_dir/$(basename "$json_file")"
    exported=$(( exported + 1 ))
  done
done

if [ "$exported" -eq 0 ]; then
  echo "Error: no ABIs were exported. Check that $OUT_DIR contains valid Foundry artifacts." >&2
  exit 1
fi

echo "Exported $exported ABIs to $ABI_DIR, skipped $skipped, filtered $filtered"
