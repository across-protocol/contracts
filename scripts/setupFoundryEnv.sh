#!/usr/bin/env bash
# Source before invoking Foundry. Preserve the caller's cwd, arguments, and stdin.
_across_setup_foundry_env() {
    local repo_root pinned_path
    command -v mise >/dev/null || {
        echo "mise not found; see Requirements in README.md" >&2
        return 1
    }
    repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || return 1
    pinned_path="$(mise -C "$repo_root" exec -- sh -c 'printf "%s" "$PATH"')" || return 1
    export PATH="$pinned_path"
}

if _across_setup_foundry_env; then
    unset -f _across_setup_foundry_env
else
    unset -f _across_setup_foundry_env
    return 1 2>/dev/null || exit 1
fi
