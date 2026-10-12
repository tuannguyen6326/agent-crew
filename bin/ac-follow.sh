#!/usr/bin/env bash
# ac-follow.sh - realtime, full-fidelity stream of a crewmate's claude
# session, or a one-shot render of a transcript. The authoritative spec - the
# meta resolution, the transcript directory and what is printed - is the
# header of src/follow.ts; this entry only starts it through bin/ac-bun.sh, so
# every caller keeps this path. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/follow.ts "$@"
