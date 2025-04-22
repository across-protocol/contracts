#!/usr/bin/env bash

echo "🔨 Deterministic build (test feature, no IDL)…"
anchor build --verifiable --no-idl -- --features test

echo "📦 Generating IDLs (using nightly)…"
for program in programs/*; do
  [ -d "$program" ] || continue

  dir_name=$(basename "$program")
  program_name=${dir_name//-/_}

  echo "→ IDL for $program_name"
  RUSTUP_TOOLCHAIN="nightly-2025-04-01" \
    anchor idl build \
      -p "$dir_name" \
      -o "target/idl/$program_name.json" \
      -t "target/types/$program_name.ts"
done

echo "🧪 Running tests (reuse build, no IDL)…"
anchor test --skip-build