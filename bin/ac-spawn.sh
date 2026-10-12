#!/usr/bin/env bash
# ac-spawn.sh - spawn a crewmate (crew task, scout, roomchief promote,
# crewdeputy) or recover a destroyed pane. The authoritative spec - the
# claim, the cap, the order gate, the kickoff sequence, the cleanup and the
# recovery ladders included - is the header of src/spawn.ts; this entry only
# starts it through bin/ac-bun.sh, so every caller keeps this path. The module
# runs this bin/'s advisory ac-guard.sh first, and is found at
# <this bin/>/../src physically, so a per-home override bin/ needs a sibling
# src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/spawn.ts "$@"
