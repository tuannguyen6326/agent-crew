#!/usr/bin/env bash
# ac-verify.sh - synchronous exact-ref independent verification facade: one
# isolated verifier pane per call (codereview or qa) at the exact ref, its
# verdict published to --output and stdout. The authoritative spec - the
# lease and neutralization, the history disposition contract, the correction
# turn, the scout lanes, the qa reconciliation and export, the busy
# declaration and the exit cleanup included - is the header of src/verify.ts;
# this entry only starts it through bin/ac-bun.sh, so every caller keeps this
# path. The module is found at <this bin/>/../src physically, so a per-home
# override bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/verify.ts "$@"
