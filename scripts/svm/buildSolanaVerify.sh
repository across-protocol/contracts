#!/usr/bin/env bash
set -euo pipefail

if [[ "${IS_TEST:-}" == "true" ]]; then
  CARGO_OPTIONS="--features test"
else
  CARGO_OPTIONS=""
fi

# Determine current user and group
USER_ID=$(id -u)
GROUP_ID=$(id -g)

for program in programs/*; do
  [ -d "$program" ] || continue

  dir_name=$(basename "$program")
  program_name=${dir_name//-/_}

  echo "Running verified build for $program_name"
  solana-verify build --library-name "$program_name" -- $CARGO_OPTIONS

- #Fix target/ permissions after Docker build
  sudo chown -R "$USER_ID:$GROUP_ID" target

  echo "Building IDL for $program_name"
  anchor idl build -p "$dir_name" -o "target/idl/$program_name.json" -t "target/types/$program_name.ts" -- $CARGO_OPTIONS
done

echo "Generating external program types"
anchor run generateExternalTypes
