#!/usr/bin/env bash
# ac-pr-merge.sh - merge a crewmate's PR after captain approval, pinned to the
# head ac-pr-check.sh recorded and behind the qa.require_for_ship gate. The
# authoritative spec is the header of src/pr-merge.ts; this entry only starts
# it through bin/ac-bun.sh, so every caller keeps this path. The module is
# found at <this bin/>/../src physically, so a per-home override bin/ needs a
# sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/pr-merge.ts "$@"
