#!/usr/bin/env bash
set -euo pipefail

if [[ "${IS_TEST:-}" == "true" ]]; then
  echo "Using test feature build"
  CARGO_OPTIONS="--features test"
else
  CARGO_OPTIONS=""
fi

for program in programs/*; do
  [ -d "$program" ] || continue

  dir_name=$(basename "$program")
  program_name=${dir_name//-/_}

  echo "Running verified build for $program_name"
  solana-verify build --library-name "$program_name" -- $CARGO_OPTIONS

  # We don't need keypair files from the verified build and they cause permission issues on CI when Swatinem/rust-cache
  # tries to delete them.
  echo "Removing target/deploy/$program_name-keypair.json"
  sudo rm -f "target/deploy/$program_name-keypair.json"

done
