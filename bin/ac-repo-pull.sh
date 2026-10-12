#!/usr/bin/env bash
# ac-repo-pull.sh <repo-root> - fetch + FAST-FORWARD-ONLY sync of a project
# clone's checked-out branch, the dashboard Pull button's whole authority. The
# authoritative spec is the header of src/repo-pull.ts; this entry only starts
# it through bin/ac-bun.sh, so every caller keeps this path. The module is found
# at <this bin/>/../src physically, so a per-home override bin/ needs a
# sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/repo-pull.ts "$@"
