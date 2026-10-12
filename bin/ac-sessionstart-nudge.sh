#!/usr/bin/env bash
# ac-sessionstart-nudge.sh - the SessionStart hook (claude and cursor): the
# run-session-start reminder for an unowned home, the SOLO orientation, the
# compact re-orientation and the homeless-session signal; silent where a
# session must not be nudged. The authoritative spec is the header of
# src/sessionstart-nudge.ts; this entry only starts it through bin/ac-bun.sh's
# ac_bun_exec_hook, so the wiring keeps this path, and no bun on PATH, a
# module that cannot load or a crash exits 0 - it never blocks session init.
# Always exits 0. The module is found at <this bin/>/../src physically, so a
# per-home override bin/ needs a sibling src/.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh" || exit 0
ac_bun_exec_hook src/sessionstart-nudge.ts "$@"
