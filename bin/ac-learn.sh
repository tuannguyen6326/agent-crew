#!/usr/bin/env bash
# ac-learn.sh - automatic fleet-local Learning: the landing tick and note, the
# level-triggered learning room (autoroom), the DISTILL run and its gated
# maintenance transactions, the full-suite gate (suite), and the operator
# verbs (maintenance, rotate-pending, stale, reinforce, route-propose, land,
# promote). The authoritative spec - the cadence, the EXAMINED accounting, the
# transaction boundary and the escape hatch included - is the header of
# src/learn.ts; this entry only starts it through bin/ac-bun.sh, so every
# caller keeps this path. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/learn.ts "$@"
