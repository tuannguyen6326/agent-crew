#!/usr/bin/env bash
# ac-brief.sh - scaffold one crewmate brief: the task-data layout, the
# delivery mode, the epic/feature fence, the review obligation, the
# escalation gate, then one of seven stage templates and, with
# --qa-required-profile, the family's qa manifest. The authoritative spec -
# the task-data layout included - is the header of src/brief.ts; this entry
# only starts it through bin/ac-bun.sh, so every caller keeps this path. The
# module is found at <this bin/>/../src physically, so a per-home override
# bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/brief.ts "$@"
