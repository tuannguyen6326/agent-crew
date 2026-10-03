#!/usr/bin/env bash
# ac-dash.sh - the captain dashboard, run in the terminal: fleet header, crew
# states, the rooms inbox, backlog counts and per-project worktree pools, once
# or redrawn with --watch. The authoritative spec is the header of
# src/dash.ts; this entry only starts it through bin/ac-bun.sh, so every
# caller keeps this path. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/dash.ts "$@"
