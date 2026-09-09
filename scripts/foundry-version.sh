#!/bin/sh
# Reconcile the active forge version with the pin in .foundry-version, so local runs and CI use the same toolchain
# (compiler output and gas snapshots are both version-sensitive).
#
# Modes:
#   check (default) — exit non-zero with a hint if the active version differs; used as a guard before
#                     version-sensitive work such as generating gas snapshots.
#   pin             — install + switch to the pinned version (only when the active version differs), then verify
#                     that the forge on PATH really reports it.
#
# Shared verbatim between across-protocol/contracts-v5 (bash-scripts/) and across-protocol/contracts (scripts/):
# keep both copies identical and fix issues here first. Works from any directory; .foundry-version is resolved
# relative to the repository root, one level above this script.
set -eu

cd "$(dirname "$0")/.."
mode="${1:-check}"
want="$(tr -d '[:space:]' < .foundry-version | sed 's/^v//')"
[ -n "$want" ] || { echo ".foundry-version is empty." >&2; exit 1; }
active() { forge --version 2> /dev/null | sed -n 's/^forge Version: \([^[:space:]]*\).*/\1/p'; }
have="$(active)"

if [ "$want" = "$have" ]; then
    if [ "$mode" = "pin" ]; then
        echo "Foundry already on the pinned version ($want)."
    fi
    exit 0
fi

if [ "$mode" != "pin" ]; then
    echo "Foundry version mismatch: active forge is '${have:-none}', pinned is '$want'." >&2
    echo "Run the repo's pin-foundry command (e.g. 'just pin-foundry' or 'yarn pin-foundry') to switch." >&2
    exit 1
fi

command -v foundryup > /dev/null || {
    echo "foundryup not found. Install Foundry (https://getfoundry.sh), then rerun the pin." >&2
    exit 1
}

echo "Switching Foundry: '${have:-none}' -> '$want'..."
foundryup --install "$want"

have="$(active)"
[ "$want" = "$have" ] || {
    echo "forge on PATH reports '${have:-none}' after install, expected '$want'. Check that ~/.foundry/bin comes first in PATH." >&2
    exit 1
}
