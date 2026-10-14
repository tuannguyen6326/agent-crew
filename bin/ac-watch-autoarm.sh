#!/usr/bin/env bash
# ac-watch-autoarm.sh - Stop-hook watcher continuity: the fleet re-arms its own
# watcher instead of the chief remembering to. The authoritative spec is the
# header of src/watch-autoarm.ts (`-h` prints it); this entry only starts it
# through bin/ac-bun.sh's ac_bun_exec_hook, so the Stop wiring in
# .claude/settings.json keeps this path, and no bun on PATH, a module that
# cannot load or a crash exits 0 with one stderr line, the hook's no-op. Exit
# codes: 0 nothing to hand back, 2 wake the chief (reason on stderr). The module is found at
# <this bin/>/../src physically, so a per-home override bin/ needs a sibling
# src/.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh" || exit 0
ac_bun_exec_hook src/watch-autoarm.ts "$@"
