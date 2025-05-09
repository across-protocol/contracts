#!/usr/bin/env bash
set -euo pipefail

if [[ "${IS_TEST:-}" == "true" ]]; then
  echo "Using test feature build"
  CARGO_OPTIONS="--features test"
else
  CARGO_OPTIONS=""
fi

echo "Building all programs using local toolchain"
anchor build -- $CARGO_OPTIONS
