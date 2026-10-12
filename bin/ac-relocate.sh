#!/usr/bin/env bash
# ac-relocate.sh <id> [--family <fam> | --root] - move a live task window to
# another herdr workspace and resume its claude session there. The
# authoritative spec is the header of src/relocate.ts; this entry only starts
# it through bin/ac-bun.sh, so every caller keeps this path. The module is
# found at <this bin/>/../src physically, so a per-home override bin/ needs a
# sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/relocate.ts "$@"
