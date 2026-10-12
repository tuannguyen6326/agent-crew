#!/usr/bin/env bash
# ac-epic-branch.sh - the per-epic integration-branch verbs (create, verify,
# show, retire). The authoritative spec is the header of src/epic-branch.ts;
# this entry only starts it through bin/ac-bun.sh, so every caller keeps this
# path. The module is found at <this bin/>/../src physically, so a per-home
# override bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/epic-branch.ts "$@"
