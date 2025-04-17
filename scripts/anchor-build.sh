#!/bin/sh

echo "🔨 Building anchor programs (no IDL)..."
anchor build --no-idl

echo "📦 Generating IDLs (using nightly)..."

for program in programs/*; do
  [ -d "$program" ] || continue

  dir_name=$(basename "$program")
  program_name=$(echo "$dir_name" | tr '-' '_')

  echo "→ IDL for $program_name"
  RUSTUP_TOOLCHAIN="nightly-2025-04-01" anchor idl build -p "$dir_name" -o "target/idl/$program_name.json" -t "target/types/$program_name.ts"
done
