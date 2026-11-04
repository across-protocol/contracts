#!/usr/bin/env bash
# Installs the pinned Agave, Anchor CLI and solana-verify Linux x86_64 release binaries into $SVM_TOOLS
# (default ~/svm-tools). Versions come from Anchor.toml [toolchain] and verified-build.json; every asset is
# checked against the SHA-256 pins there on fresh downloads and cache hits alike. Bump pins in those files.
set -euo pipefail

tools="${SVM_TOOLS:-$HOME/svm-tools}"
pin() { node -p "require('./verified-build.json').$1"; }
toolchain() { sed -n "s/^$1 = \"\([0-9.]*\)\"\$/\1/p" Anchor.toml; }
# fetch <url> <file> <sha256>: download once, verify every run.
fetch() {
  [ -f "$2" ] || curl -sSfL --retry 3 "$1" -o "$2"
  echo "$3  $2" | sha256sum --check
}

solana_version=$(toolchain solana_version)
anchor_version=$(toolchain anchor_version)
verify_version=$(pin solana_verify_version)
: "${solana_version:?missing [toolchain] solana_version in Anchor.toml}"
: "${anchor_version:?missing [toolchain] anchor_version in Anchor.toml}"
mkdir -p "$tools/bin"

fetch "https://github.com/anza-xyz/agave/releases/download/v$solana_version/solana-release-x86_64-unknown-linux-gnu.tar.bz2" \
  "$tools/solana-release.tar.bz2" "$(pin agave_release_sha256.linux_x86_64)"
rm -rf "$tools/solana-release" # Discard stale cache contents, including extra executables, before extracting.
tar -xjf "$tools/solana-release.tar.bz2" -C "$tools"
fetch "https://github.com/otter-sec/anchor/releases/download/v$anchor_version/anchor-$anchor_version-x86_64-unknown-linux-gnu" \
  "$tools/bin/anchor" "$(pin anchor_cli_sha256.linux_x86_64)"
fetch "https://github.com/solana-foundation/solana-verifiable-build/releases/download/v$verify_version/solana-verify-$verify_version-linux" \
  "$tools/bin/solana-verify" "$(pin solana_verify_sha256.linux)"
chmod +x "$tools/bin/anchor" "$tools/bin/solana-verify"

"$tools/solana-release/bin/solana" --version | grep -F "solana-cli $solana_version "
test "$("$tools/bin/anchor" --version)" = "anchor-cli $anchor_version"
test "$("$tools/bin/solana-verify" --version)" = "solana-verify $verify_version"

# Expose the tools to later CI steps; local callers add these directories to PATH themselves.
[ -z "${GITHUB_PATH:-}" ] || printf '%s\n' "$tools/solana-release/bin" "$tools/bin" >> "$GITHUB_PATH"
