#!/usr/bin/env bash
set -euo pipefail

if [[ "${IS_TEST:-}" == "true" ]]; then
  CARGO_OPTIONS="--features test"
else
  CARGO_OPTIONS=""
fi

# Ensures anchor builds test feature under the target directory.
cargo metadata --locked --no-deps > /dev/null 2>&1

# Pull in IDL and types for external programs.
echo "Generating IDL and types for external programs"
anchor run generateExternalTypes

echo "Building all programs"
anchor build -- $CARGO_OPTIONS
