#!/usr/bin/env bash
# ac-github.sh - the GitHub intake DETECTOR: `poll` records a clone's open
# PRs/issues and wakes the crewchief once per new item; `comment` posts a
# caller-authored verdict once per exact text. The authoritative spec is the
# header of src/github.ts; this entry only starts it through bin/ac-bun.sh, so
# every caller keeps this path. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/github.ts "$@"
