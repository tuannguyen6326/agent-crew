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
# found: bun` when bun is not on PATH. A closed stdout or stderr reaches the
# module as /dev/null opened read-only: bun opens /dev/null read-write over a
# closed fd 0, 1 or 2, so a write the bash original failed on (`write error`,
# 1 under errexit) would land silently; read-only, it fails EBADF as the
# original's did. A closed stdin stays bun's - an original read one as at EOF
# (`read` returns 1) or hung on it (`$(cat)` put its own pipe there) - and so
# does a closed channel of a module whose original ran without errexit: a
# write lost there left that run and its status alone.
#
# ac_bun_exec_hook <module relpath> [args...] - ac_bun_exec for a harness hook,
#   which must never wedge the harness nor refuse on a fault of its own: no bun
#   on PATH exits 0 at once, silently and reading no stdin (the hook's no-op).
#   Otherwise the module runs as a child - a closed channel left to bun, as
#   every hook original ran without errexit - started as ac_bun_exec starts
#   one, and only its 0 or 2 is the hook's answer - 2 is the hook's refusal (a
#   PreToolUse tool denied, a Stop held, an asyncRewake wake). Every other
#   status exits 0: a module that cannot load or throws (bun's 1), a signal
#   (128+n), a bun that cannot start (126), so no fault ever reads as a
#   refusal, on a harness that blocks on any non-zero as on one that does not.
#   What the child wrote to stdout and stderr stays as it wrote it. A hook
#   shim sources this file under `set -uo pipefail`, never -e: bash 3.2's
#   errexit ends the shell 1 on a `.` that cannot find its file whatever
#   guards it, which would kill the shim's `|| exit 0`.

ac_bun_exec() {
  case "$1" in
    src/gate-watch.ts | src/guard.ts | src/notify.ts | src/page-lint.ts | \
      src/pane-agent.ts | src/qa-watch.ts | src/ship-watch.ts) ;;
    *)
      # Not `2>/dev/null` on the stderr probe: that would open the fd it
      # tests, and a closed fd 2 swallows the complaint by itself.
      { : 3>&1; } 2>/dev/null || exec 1</dev/null
      : 3>&2 || exec 2</dev/null
      ;;
  esac
  ac_bun_start "$@"
}

ac_bun_start() {
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

ac_bun_exec_hook() {
  local rc=0
  command -v bun >/dev/null 2>&1 || exit 0
  (ac_bun_start "$@") || rc=$?
  case "$rc" in 0 | 2) exit "$rc" ;; *) exit 0 ;; esac
}
