#!/usr/bin/env bash
# ac-delegation-guard.sh - PreToolUse hook: refuse harness-native delegation
# (tool shapes `Task`, `*Agent*`, `*Workflow*`) from a CHIEF's own checkout.
# The authoritative spec - the three scope arms, the shape rule, the
# AC_ALLOW_DELEGATION hatch and the fail-open set - is the header of
# src/delegation-guard.ts; this entry only starts it through bin/ac-bun.sh's
# ac_bun_exec_guard, so the wiring in .claude/settings.json and
# .codex/hooks.json keeps this path. No bun on PATH, a missing module or an
# unsourceable ac-bun.sh denies with one stderr line naming it; a module that
# cannot load or a crash allows with one stderr line, the hook's no-op. Exit
# codes: 0 allow, 2 deny. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh" \
  || { printf '%s: REFUSED - bin/ac-bun.sh cannot be sourced, so bun cannot run this guard\n' "${0##*/}" >&2; exit 2; }
ac_bun_exec_guard src/delegation-guard.ts "$@"
