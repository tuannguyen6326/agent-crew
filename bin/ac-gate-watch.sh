#!/usr/bin/env bash
# ac-gate-watch.sh - ACTIVE-run observer for the second-chief gate: a
# repainting dashboard of the gates running right now, or --tail following the
# newest one's exact prompt and live emitted output. The authoritative spec is
# the header of src/gate-watch.ts; this entry only starts it through
# bin/ac-bun.sh, so every caller keeps this path - and a board pane then runs
# ONE bun process for its whole life, whose cmdline names src/gate-watch.ts.
# The module is found at <this bin/>/../src physically, so a per-home override
# bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/gate-watch.ts "$@"
