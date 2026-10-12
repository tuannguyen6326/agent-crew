#!/usr/bin/env bash
# ac-epic-ship.sh - the EPIC GATE + 2-PR exit of a branch-recorded epic:
# stories terminal, partial-epic captain receipts, one review round at the
# tip, qa when pinned, then `branch -> staging` and `branch -> default`. The
# authoritative spec is the header of src/epic-ship.ts; this entry only
# starts it through bin/ac-bun.sh, so every caller keeps this path. The module
# is found at <this bin/>/../src physically, so a per-home override bin/ needs
# a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/epic-ship.ts "$@"
