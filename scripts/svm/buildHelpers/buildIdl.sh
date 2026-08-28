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

  # Test-only programs must not become public package IDLs or TypeScript exports.
  if [[ "$program_name" == "mock_gateway" && "${IS_TEST:-}" != "true" ]]; then
    rm -f "target/idl/$program_name.json" "target/types/$program_name.ts"
    continue
  fi

  echo "Generating IDL for $program_name"
  anchor idl build \
    --program-name "$program_name" \
    --out "target/idl/$program_name.json" \
    --out-ts "target/types/$program_name.ts" \
    -- $CARGO_OPTIONS
done

echo "Generating external program types"
anchor run generateExternalTypes
