#!/usr/bin/env bash
# ac-dispatch-select.sh - resolve a crew-dispatch profile for ac-spawn. The
# authoritative spec is the header of src/dispatch-select.ts; this entry only
# starts it through bin/ac-bun.sh, so every caller keeps this path. The module
# is found at <this bin/>/../src physically, so a per-home override bin/ needs
# a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/dispatch-select.ts "$@"
