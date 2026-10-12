#!/usr/bin/env bash
# ac-pane-agent.sh - run ONE agent turn in a backend pane for the mechanisms
# that verify (the ship reviewer, qa, the learning scout, the gate judge), plus
# its close, reap-pane, reap and steer verbs and the JSON helper subcommands.
# The authoritative spec - the three arms, the NDJSON protocol, the pane
# profile, the harness arms, steer, and the turn-end, await, idle-fallback and
# stall contracts included - is the header of src/pane-agent.ts; this entry
# only starts it through bin/ac-bun.sh, so every caller keeps this path. The
# module is found at <this bin/>/../src physically, so a per-home override bin/
# needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/pane-agent.ts "$@"
