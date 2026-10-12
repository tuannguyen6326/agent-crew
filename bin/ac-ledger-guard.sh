#!/usr/bin/env bash
# ac-ledger-guard.sh - PreToolUse hook: refuse a SCOPED session (a roomchief,
# AC_SCOPE set) writing records/backlog.md, records/projects.md or
# records/captain.md. The authoritative spec - the canonical path shape, the
# crewdomain exemption, the fence and the fail-open set - is the header of
# src/ledger-guard.ts; this entry only starts it through bin/ac-bun.sh's
# ac_bun_exec_hook, so the wiring in .claude/settings.json and
# .codex/hooks.json keeps this path, and no bun on PATH, a module that cannot
# load or a crash exits 0, the hook's no-op. Exit codes: 0 allow, 2 deny. The
# module is found at <this bin/>/../src physically, so a per-home override
# bin/ needs a sibling src/.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh" || exit 0
ac_bun_exec_hook src/ledger-guard.ts "$@"
