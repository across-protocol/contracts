#!/usr/bin/env bash
set -euo pipefail

# Keep test-only artifacts in target so they cannot leak into package assets.
anchor idl build \
  --program-name svm_spoke \
  --out target/idl/svm_spoke.json \
  --out-ts target/types/svm_spoke.ts \
  -- --features test
anchor idl build \
  --program-name mock_gateway \
  --out target/idl/mock_gateway.json \
  --out-ts target/types/mock_gateway.ts \
  -- --features test
