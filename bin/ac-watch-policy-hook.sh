#!/usr/bin/env bash
# ac-watch-policy-hook.sh - PreToolUse hook (Bash tool): deny broad watcher
# kills before they run. The authoritative spec is the header of
# src/watch-policy-hook.ts; this entry only starts it through bin/ac-bun.sh's
# ac_bun_exec_guard, so the wiring in .claude/settings.json and
# .codex/hooks.json, the cursor adapter, the opencode plugin and the pi
# extension keep this path. No bun on PATH, a missing module or an
# unsourceable ac-bun.sh denies with one stderr line naming it; a module that
# cannot load or a crash allows with one stderr line, the hook's no-op. Exit
# codes: 0 allow, 2 deny. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh" \
  || { printf '%s: REFUSED - bin/ac-bun.sh cannot be sourced, so bun cannot run this guard\n' "${0##*/}" >&2; exit 2; }
ac_bun_exec_guard src/watch-policy-hook.ts "$@"
