#!/usr/bin/env bash
# ac-watch.sh - the zero-token fleet watcher a chief arms as its harness's own
# background task: `ac-watch.sh [--once | --release <pid>]`. The authoritative
# spec - every wake and exit reason, the refusals, the signals, the arming
# contract and the push channel - is the header of src/watch.ts; this entry
# only starts it through bin/ac-bun.sh, so every caller keeps this path, and
# the exec keeps this pid, the one the lock, the nudge and --release name. The
# module is found at <this bin/>/../src physically, so a per-home override
# bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/watch.ts "$@"
