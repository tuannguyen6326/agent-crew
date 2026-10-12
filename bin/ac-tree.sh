#!/usr/bin/env bash
# ac-tree.sh - the herdr fleets' in-repo worktree pool at
# <repo>/.crew/worktrees/<n>: lease a slot (get, lease), read the pool (list),
# release it (return), and drop idle or named slots (prune, remove); the first
# lease also installs the pre-commit and commit-msg guard hooks. The
# authoritative spec is the header of src/tree.ts; this entry only starts it
# through bin/ac-bun.sh, so every caller keeps this path. The module is found at
# <this bin/>/../src physically, so a per-home override bin/ needs a sibling
# src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/tree.ts "$@"
