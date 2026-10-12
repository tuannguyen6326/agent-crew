#!/usr/bin/env bash
# ac-room.sh - per-task-family rooms, the captain-facing thread of one task:
# post, show, list (the captain's inbox), close, open, pending, handback and
# the gate-route / gate-verify / disposition receipt verbs. The authoritative
# spec is the header of src/room.ts; this entry only starts it through
# bin/ac-bun.sh, so every caller keeps this path. The module is found at
# <this bin/>/../src physically, so a per-home override bin/ needs a sibling
# src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/room.ts "$@"
