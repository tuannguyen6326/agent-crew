#!/usr/bin/env bash
# ac-rig.sh - the rig manifest (records/rig.json) and its drift check. The
# authoritative spec is the header of src/rig.ts; this entry only starts it
# through bin/ac-bun.sh, so every caller keeps this path. The module is found
# at <this bin/>/../src physically, so a per-home override bin/ needs a
# sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/rig.ts "$@"
