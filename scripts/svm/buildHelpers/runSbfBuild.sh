#!/usr/bin/env bash
set -euo pipefail

: "${1:?Usage: runSbfBuild.sh command [args...]}"
build_log=$(mktemp)
trap 'rm -f "$build_log"' EXIT

# SBF compilers can report stack overflows while returning success. Preserve both output streams and exit failures.
"$@" 2>&1 | tee "$build_log"
if grep -Eiq 'Stack offset .*exceeded max offset|stack frame size .*exceeds.*limit|A function call .*overwrites values in the frame' "$build_log"; then
  echo "SBF build failed: stack-overflow diagnostics found in compiler output." >&2
  exit 1
fi
