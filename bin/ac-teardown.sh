#!/usr/bin/env bash
# ac-teardown.sh - fail-closed teardown of a finished task: the landed proof
# (or --force), the kind=self knowledge loop, then the state archive, the pane
# kill, the verifier and pane-agent sweeps, every lease returned, a merged
# crew branch dropped and the qa stack downed. The authoritative spec is the
# header of src/teardown.ts; this entry only starts it through bin/ac-bun.sh,
# so every caller keeps this path. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/teardown.ts "$@"
