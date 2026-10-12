#!/usr/bin/env bash
# ac-deputy.sh - the crewdeputy routing layer: render the routing table
# (list), check it strictly (validate), answer a routed order back to the
# parent (report), and hand queued backlog items over to a deputy (handoff).
# The authoritative spec is the header of src/deputy.ts; this entry only
# starts it through bin/ac-bun.sh, so every caller keeps this path. The module
# is found at <this bin/>/../src physically, so a per-home override bin/ needs
# a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/deputy.ts "$@"
