#!/usr/bin/env bash
# ac-primary-guard.sh - PreToolUse hook: refuse a crewmate/roomchief EDITING a
# file that lives in the PRIMARY checkout but outside its own tree. The
# authoritative spec - who is fenced, the physical target, the own-tree and
# primary geometry and the fail-open set - is the header of
# src/primary-guard.ts; this entry only starts it through bin/ac-bun.sh's
# ac_bun_exec_guard, so the wiring in .claude/settings.json and
# .codex/hooks.json keeps this path. No bun on PATH, a missing module or an
# unsourceable ac-bun.sh denies with one stderr line naming it; a module that
# cannot load or a crash allows with one stderr line, the hook's no-op. Exit
# codes: 0 allow, 2 deny. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh" \
  || { printf '%s: REFUSED - bin/ac-bun.sh cannot be sourced, so bun cannot run this guard\n' "${0##*/}" >&2; exit 2; }
ac_bun_exec_guard src/primary-guard.ts "$@"
