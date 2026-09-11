#!/usr/bin/env bash
set -euo pipefail

if [[ "${IS_TEST:-}" == "true" ]]; then
  echo "Using test feature build"
  CARGO_OPTIONS="--features test"
else
  CARGO_OPTIONS=""
fi

SOLANA_VERSION=$(grep -A 2 'name = "solana-program"' Cargo.lock | grep 'version' | head -n 1 | cut -d'"' -f2)

for program in programs/*; do
  [ -d "$program" ] || continue

  dir_name=$(basename "$program")
  program_name=${dir_name//-/_}

  # Build the mock only for validator tests, never as a production verified artifact.
  if [[ "$program_name" == "mock_gateway" && "${IS_TEST:-}" != "true" ]]; then
    continue
  fi

  echo "Running verified build for $program_name"
  solana-verify build --library-name "$program_name" --base-image "solanafoundation/solana-verifiable-build:$SOLANA_VERSION" -- $CARGO_OPTIONS

  # We don't need keypair files from the verified build and they cause permission issues on CI when Swatinem/rust-cache
  # tries to delete them.
  if [[ "${CI:-}" == "true" ]]; then
    echo "Removing target/deploy/$program_name-keypair.json"
    sudo rm -f "target/deploy/$program_name-keypair.json"
  fi

done
