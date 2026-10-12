#!/usr/bin/env bash
# ac-domain.sh - the crewdomain verb layer: build a domain package (new),
# stamp or strip the domain:<name> token on fleet backlog rows (assign,
# unassign), print a domain's slice (queue), declare its e2e repository
# (qa-repo), retire it fail-closed (retire), and render or check the routing
# table (list, validate). The authoritative spec is the header of
# src/domain.ts; this entry only starts it through bin/ac-bun.sh, so every
# caller keeps this path. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/domain.ts "$@"
