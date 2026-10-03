#!/usr/bin/env bash
# ac-archive.sh - move CLOSED task families out of the flat data/ namespace.
# The authoritative spec is the header of src/archive.ts; this entry only
# starts it through bin/ac-bun.sh, so every caller keeps this path. The module
# is found at <this bin/>/../src physically, so a per-home override bin/ needs
# a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/archive.ts "$@"
