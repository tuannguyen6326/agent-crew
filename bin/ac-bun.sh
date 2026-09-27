#!/usr/bin/env bash
# ac-bun.sh - start a TypeScript module under bun so that nothing in the
# caller's cwd or environment configures bun itself. Sourced by every bin/
# script that starts a module under src/ or dashboard/; the module's half of the
# protocol is enterCaller in src/lib.ts, and bunChild there starts a further
# module the same way.
#
# ac_bun_exec <module relpath> [args...] - replaces the shell with
#   bun --no-env-file <root>/<module> <caller cwd> <args...>
# run in the distro root with every BUN_*/JSC_* variable unset. bun reads
# ./.env, ./bunfig.toml (whose preload runs code) and a tsconfig whose paths
# swap the entry module from its cwd, and BUN_OPTIONS/JSC_* from the
# environment - and a caller's cwd is often a project worktree. <caller cwd> is
# the caller's physical cwd, "" when it has no name; the module returns there
# before reading any relative input. Exits 1 with `ERROR: required tool not
# found: bun` when bun is not on PATH.

ac_bun_exec() {
  local module="$1" root caller v
  shift
  command -v bun >/dev/null 2>&1 || { printf 'ERROR: required tool not found: bun\n' >&2; exit 1; }
  # cd -P: a fleet home symlinks bin/, and the logical parent of that link is
  # the home; CDPATH= keeps an exported CDPATH from redirecting it. The
  # trailing x keeps a directory name that ends in a newline intact.
  root="$(CDPATH= cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P && printf x)"
  root="${root%?x}"
  caller="$(pwd -P 2>/dev/null && printf x)" && caller="${caller%?x}" || caller=""
  for v in $(compgen -e); do
    case "$v" in BUN_* | JSC_*) unset "$v" ;; esac
  done
  cd "$root" 2>/dev/null
  exec bun --no-env-file "$root/$module" "$caller" "$@"
}
