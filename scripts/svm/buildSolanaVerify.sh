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
  mkdir -p target/idl
  mkdir -p target/types
  mkdir -p target/deploy
  echo "target/idl/ before"
  ls -la target/idl
  echo "target/types/ before"
  ls -la target/types
  anchor idl build \
    --program-name "$program_name" \
    --out "target/idl/$program_name.json" \
    --out-ts "target/types/$program_name.ts" \
    -- $CARGO_OPTIONS
  echo "target/idl/ after"
  ls -la target/idl
  echo "target/types/ after"
  ls -la target/types

  echo "Running verified build for $program_name"
  echo "target/deploy/ before"
  ls -la target/deploy
  solana-verify build --library-name "$program_name" -- $CARGO_OPTIONS
  echo "target/deploy/ after"
  ls -la target/deploy

  echo "Removing target/deploy/$program_name-keypair.json"
  sudo rm -f "target/deploy/$program_name-keypair.json"

done

echo "Generating external program types"
anchor run generateExternalTypes
