#!/usr/bin/env bash
# ac-qa-watch.sh - live dashboard for a qa run: the run header, the step table
# with the ACTIVE step marked, the case ledger, per-step findings and the tail
# of the run log, once (--once) or repainted until the run finishes or idles.
# The authoritative spec is the header of src/qa-watch.ts (its shared body:
# src/watch-dash.ts); this entry only starts it through bin/ac-bun.sh, so every
# caller keeps this path - bin/ac-qa.sh types it into a herdr pane. The module
# is found at <this bin/>/../src physically, so a per-home override bin/ needs a
# sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/qa-watch.ts "$@"
