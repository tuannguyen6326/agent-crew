#!/usr/bin/env bash
# ac-notify.sh - best-effort captain notification over config/wedge-alarm
# (off, herdr, osascript, bell, command:<cmd>, auto); never fails. The
# authoritative spec is the header of src/notify.ts, whose notify() the room's
# post calls in-process; this entry only starts it through bin/ac-bun.sh, so
# every caller keeps this path. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/notify.ts "$@"
