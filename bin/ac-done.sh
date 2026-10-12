#!/usr/bin/env bash
# ac-done.sh - the agent-side PUSH of a completion: the dedup stamp, one
# durable `report` wake record, the watcher nudge. The authoritative spec is
# the header of src/done.ts; this entry only starts it through bin/ac-bun.sh,
# so every brief keeps this path (bin/ac-brief.sh bakes it). The module is
# found at <this bin/>/../src physically, so a per-home override bin/ needs a
# sibling src/. A pane without bun on PATH fails here, before any stamp or
# record exists - the printed marker line stays the backup channel.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/done.ts "$@"
