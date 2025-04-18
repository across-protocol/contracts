#!/bin/sh

echo "🔨 Building anchor programs (with test feature, no IDL)..."
anchor build --no-idl -- --features test

echo "📦 Generating IDLs (using nightly)..."

for program in programs/*; do
  [ -d "$program" ] || continue

  dir_name=$(basename "$program")
  program_name=$(echo "$dir_name" | tr '-' '_')

  echo "→ IDL for $program_name"
  RUSTUP_TOOLCHAIN="nightly-2025-04-01" anchor idl build -p "$dir_name" -o "target/idl/$program_name.json" -t "target/types/$program_name.ts"
done

echo "🧪 Running anchor tests..."
anchor test --skip-build
