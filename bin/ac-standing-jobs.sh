#!/usr/bin/env bash
# ac-standing-jobs.sh - render the standing-jobs digest block for the
# session-start digest (`--ids` lists the declared ids). The authoritative
# spec is the header of src/standing-jobs.ts; this entry only starts it
# through bin/ac-bun.sh, so every caller keeps this path. The module is found
# at <this bin/>/../src physically, so a per-home override bin/ needs a
# sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/standing-jobs.ts "$@"
