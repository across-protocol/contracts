#!/usr/bin/env bash
# Source before invoking Foundry. Preserve the caller's cwd, arguments, and stdin.
_across_foundry_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH="$(mise -C "$_across_foundry_root" exec -- sh -c 'printf "%s" "$PATH"')" || exit $?
export PATH
