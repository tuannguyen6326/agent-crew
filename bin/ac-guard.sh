#!/usr/bin/env bash
# ac-guard.sh - warn-only situational advisory that rides along at the start
# of fleet commands (ac-send, ac-peek, ac-spawn, ac-review-diff,
# ac-merge-local). The authoritative spec is the header of src/guard.ts; this
# entry only starts it through bin/ac-bun.sh, so every caller keeps this path.
# The module is found at <this bin/>/../src physically, so a per-home override
# bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/guard.ts "$@"
