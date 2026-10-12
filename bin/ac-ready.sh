#!/usr/bin/env bash
# ac-ready.sh - the queued-work scheduler primitive and DAG validator: the
# READY / STUCK / HELD report, queued, watch-set, validate and the overlap
# checks. The authoritative spec - the scheduling rules, the hold grammar, both
# overlap verbs and the usage text - is the header of src/ready.ts; this entry
# only starts it through bin/ac-bun.sh, so every caller keeps this path. The
# module is found at <this bin/>/../src physically, so a per-home override bin/
# needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/ready.ts "$@"
