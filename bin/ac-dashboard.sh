#!/usr/bin/env bash
# ac-dashboard.sh - launch the agent-crew local web dashboard: foreground by
# default, or the start|stop|restart|status daemon verbs. The authoritative
# spec - the arguments, the busy-port check, the pidfile lifecycle and its
# recycled-pid check - is the header of src/dashboard.ts; this entry only
# starts it through bin/ac-bun.sh, so every caller keeps this path. The module
# is found at <this bin/>/../src physically, so a per-home override bin/ needs
# a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/dashboard.ts "$@"
