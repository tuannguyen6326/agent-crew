#!/usr/bin/env bash
# ac-peek.sh - bounded tail of a crewmate's pane, each line prefixed `peek| `,
# with the bin/ac-guard.sh advisory riding along. The authoritative spec is
# the header of src/peek.ts; this entry only starts it through bin/ac-bun.sh,
# so every caller keeps this path. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/peek.ts "$@"
