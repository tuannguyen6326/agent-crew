#!/usr/bin/env bash
# ac-dispatch-select.sh - resolve a crew-dispatch profile for ac-spawn. The
# authoritative spec is the header of src/dispatch-select.ts; this entry only
# locates it and execs bun, so every caller keeps this path. The module is
# found at <this bin/>/../src physically, so a per-home override bin/ needs a
# sibling src/.
set -euo pipefail

command -v bun >/dev/null 2>&1 || { printf 'ERROR: required tool not found: bun\n' >&2; exit 1; }
# cd -P: a fleet home symlinks bin/, and the logical parent of that link is the
# home, which has no src/; CDPATH= keeps an exported CDPATH from redirecting it.
# The trailing x keeps a directory name that ends in a newline intact.
root="$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P && printf x)"
root="${root%?x}"
caller="$(pwd -P 2>/dev/null && printf x)" && caller="${caller%?x}" || caller=""
# bun takes runtime knobs from the environment (BUN_OPTIONS can preload code,
# JSC_* tune its engine) and config from its cwd - ./.env, ./bunfig.toml, a
# tsconfig whose paths swap the entry module - and a caller's cwd is often a
# project worktree. So bun starts in the distro root with none of those knobs
# and no .env, and the module moves back to the caller's cwd (its first
# argument, "" when it has no name) before reading any relative input.
for v in $(compgen -e); do
  case "$v" in BUN_* | JSC_*) unset "$v" ;; esac
done
cd "$root" 2>/dev/null
exec bun --no-env-file "$root/src/dispatch-select.ts" "$caller" "$@"
