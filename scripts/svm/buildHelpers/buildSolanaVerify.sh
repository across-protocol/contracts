#!/usr/bin/env bash
set -euo pipefail

# The reviewed image/compiler recipe targets Linux x86_64, including on ARM hosts.
export DOCKER_DEFAULT_PLATFORM=linux/amd64

if [[ "${IS_TEST:-}" == "true" ]]; then
  echo "Using test feature build"
  CARGO_OPTIONS="--features test"
else
  CARGO_OPTIONS=""
fi

# Solana SDK crate versions no longer identify the compiler/image version.
# Pin the release compiler independently of the test validator.
BUILD_IMAGE=$(node -p 'require("./verified-build.json").image')
BUILD_ARCH=$(node -p 'require("./verified-build.json").arch')
VERIFY_VERSION=$(node -p 'require("./verified-build.json").solana_verify_version')
[[ "$(solana-verify --version)" == "solana-verify $VERIFY_VERSION" ]] || {
  echo "Use solana-verify $VERIFY_VERSION" >&2
  exit 1
}

for program in programs/*; do
  [ -d "$program" ] || continue

  dir_name=$(basename "$program")
  program_name=${dir_name//-/_}

  # Build the mock only for validator tests, never as a production verified artifact.
  if [[ "$program_name" == "mock_gateway" && "${IS_TEST:-}" != "true" ]]; then
    continue
  fi

  echo "Running verified build for $program_name"
  binary="target/deploy/$program_name.so"
  # Older verifiers can swallow compiler failures and hash a leftover binary instead.
  rm -f "$binary"
  if bash scripts/svm/buildHelpers/runSbfBuild.sh solana-verify build --library-name "$program_name" --base-image "$BUILD_IMAGE" --arch "$BUILD_ARCH" -- $CARGO_OPTIONS; then
    if [[ ! -s "$binary" ]]; then
      echo "Verified build failed: missing or empty $binary" >&2
      rm -f "$binary"
      exit 1
    fi
  else
    status=$?
    rm -f "$binary"
    exit "$status"
  fi

  # We don't need keypair files from the verified build and they cause permission issues on CI when Swatinem/rust-cache
  # tries to delete them.
  if [[ "${CI:-}" == "true" ]]; then
    echo "Removing target/deploy/$program_name-keypair.json"
    sudo rm -f "target/deploy/$program_name-keypair.json"
  fi

done
