#!/usr/bin/env bash
# ac-turnend-guard.sh - "no turn ends blind": the Stop hook that holds a turn
# end (exit 2, the reasons on stderr) while this session's wakes are pending
# or its watcher's beacon is stale, plus the standing-coverage, landing-receipt,
# HANDBACK and PARKED checks and the SOLO notice. The authoritative spec is the
# header of src/turnend-guard.ts; this entry only starts it through
# bin/ac-bun.sh's ac_bun_exec_hook, so every wiring (claude, codex, the cursor
# adapter, the opencode and pi surfaces) keeps this path, and no bun on PATH,
# a module that cannot load or a crash exits 0 with one stderr line - a fault
# never holds a stop. Exit codes: 0 no block, 2 block. The module is found at
# <this bin/>/../src physically, so a per-home override bin/ needs a sibling
# src/.
set -uo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh" || exit 0
ac_bun_exec_hook src/turnend-guard.ts "$@"
