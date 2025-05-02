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
mkdir -p target/deploy

for program in programs/*; do
  [ -d "$program" ] || continue

  dir_name=$(basename "$program")
  program_name=${dir_name//-/_}

  # Verified build does not save IDL and types, so generate them here.
  echo "Generating IDL for $program_name"
  anchor idl build \
    --program-name "$program_name" \
    --out "target/idl/$program_name.json" \
    --out-ts "target/types/$program_name.ts" \
    -- $CARGO_OPTIONS

  echo "Running verified build for $program_name"
  solana-verify build --library-name "$program_name" -- $CARGO_OPTIONS

  # We don't need keypair files from the verified build and they cause permission issues on CI
  echo "Removing target/deploy/$program_name-keypair.json"
  sudo rm -f "target/deploy/$program_name-keypair.json"

done

echo "Generating external program types"
anchor run generateExternalTypes
