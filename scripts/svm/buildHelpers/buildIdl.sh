#!/usr/bin/env bash
set -euo pipefail

# Package artifacts always describe production, even after an IS_TEST build.
# Generate test-feature interfaces separately with buildTestIdls.sh.

# Create required directories.
mkdir -p target/idl
mkdir -p target/types

for program in programs/*; do
  [ -d "$program" ] || continue

  dir_name=$(basename "$program")
  program_name=${dir_name//-/_}

  # Test-only programs must not become public package IDLs or TypeScript exports.
  if [[ "$program_name" == "mock_gateway" ]]; then
    rm -f "target/idl/$program_name.json" "target/types/$program_name.ts"
    continue
  fi

  echo "Generating IDL for $program_name"
  anchor idl build \
    --program-name "$program_name" \
    --out "target/idl/$program_name.json" \
    --out-ts "target/types/$program_name.ts" \
    -- --locked
done

# Include schemas carried inside opaque V5 adapter arguments before publishing IDLs and clients.
yarn ts-node scripts/svm/buildHelpers/restoreEventAuthorityPdas.ts
yarn ts-node scripts/svm/buildHelpers/includeV5IdlTypes.ts

echo "Generating external program types"
anchor run generateExternalTypes
