#!/usr/bin/env bash
# ac-lock.sh - per-home chief session lock: one fleet-driving session at a
# time. The authoritative spec is the header of src/lock.ts; this entry only
# starts it through bin/ac-bun.sh, so every caller keeps this path (and `exec`
# keeps this pid, the one the ancestry walk starts from). The module is found
# at <this bin/>/../src physically, so a per-home override bin/ needs a
# sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/lock.ts "$@"
