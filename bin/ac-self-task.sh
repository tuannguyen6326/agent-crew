#!/usr/bin/env bash
# ac-self-task.sh - make a SMALL chief-side edit VISIBLE: `start` leases a
# worktree, seeds the crewmate layer, opens a pane tailing the progress log and
# writes a kind=self meta before the first edit; `log` appends to that log. A
# solo session and a solo chief open every slice through it. The authoritative
# spec - the branch collision refusal, the lease, the seed, the fleet-memory
# read, the pane, the meta, the rollback and its signals included - is the
# header of src/self-task.ts, which also names the ESCAPE HATCH (the frozen
# original run from a scratch bin/); this entry only starts it through
# bin/ac-bun.sh, so every caller keeps this path. The module is found at
# <this bin/>/../src physically, so a per-home override bin/ needs a sibling
# src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/self-task.ts "$@"
