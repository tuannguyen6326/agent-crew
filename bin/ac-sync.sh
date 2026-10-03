#!/usr/bin/env bash
# ac-sync.sh - keep project clones fresh: bounded fetch, fast-forward of the
# clean default branch, prune of gone-upstream branches no worktree or pool
# lease needs. The authoritative spec is the header of src/sync.ts; this entry
# only starts it through bin/ac-bun.sh, so every caller keeps this path. The
# module is found at <this bin/>/../src physically, so a per-home override
# bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/sync.ts "$@"
