#!/usr/bin/env bash
set -euo pipefail

if [[ "${IS_TEST:-}" == "true" ]]; then
  CARGO_OPTIONS="--features test"
else
  CARGO_OPTIONS=""
fi

# Create required directories.
mkdir -p target/idl
mkdir -p target/types

for program in programs/*; do
  [ -d "$program" ] || continue

  dir_name=$(basename "$program")
  program_name=${dir_name//-/_}

  echo "Generating IDL for $program_name"
  anchor idl build \
    --program-name "$program_name" \
    --out "target/idl/$program_name.json" \
    --out-ts "target/types/$program_name.ts" \
    -- $CARGO_OPTIONS
done

echo "Generating external program types"
anchor run generateExternalTypes
