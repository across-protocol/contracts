#!/usr/bin/env bash
set -euo pipefail

if [[ "${IS_TEST:-}" == "true" ]]; then
  CARGO_OPTIONS="--features test"
else
  CARGO_OPTIONS=""
fi

for program in programs/*; do
  [ -d "$program" ] || continue

  dir_name=$(basename "$program")
  program_name=${dir_name//-/_}

  # Regular build first so that it generates required IDL and types for the tests
  # echo "Building program $program_name"
  # anchor build -p "$dir_name" -- $CARGO_OPTIONS
  echo "Generating IDL for $program_name"
  anchor idl build \
    --program-name "$program_name" \
    --out "target/idl/$program_name.json" \
    --out-ts "target/types/$program_name.ts" \
    -- $CARGO_OPTIONS

  echo "Running verified build for $program_name"
  solana-verify build --library-name "$program_name" -- $CARGO_OPTIONS
done

echo "Generating external program types"
anchor run generateExternalTypes
