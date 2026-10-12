#!/usr/bin/env bash
# ac-gate.sh - obtain ONE independent second-chief decision: a staged design
# gate (<family> <spec|architecture|plan|design>) or a maintenance gate over
# one Learning or Curate action plan. The authoritative spec - the receipts,
# the round contract, the board and the busy declaration included - is the
# header of src/gate.ts; this entry only starts it through bin/ac-bun.sh, so
# every caller keeps this path. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/gate.ts "$@"
