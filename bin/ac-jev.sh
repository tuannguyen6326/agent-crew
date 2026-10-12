#!/usr/bin/env bash
# ac-jev.sh - the System One adapter: closed-set questions in, validated typed
# answers with calibrated probabilities out, behind the AC_JEV > config/jev >
# off knob (ask, label, sha, status). The authoritative spec - the knob, the
# provider table, the wire, the shadow log and the fail direction - is the
# header of src/jev.ts; this entry only starts it through bin/ac-bun.sh, so
# every caller keeps this path. It is no harness hook, so a missing bun is the
# standard `ERROR: required tool not found: bun`, exit 1, which every caller
# already reads as no proposal. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/jev.ts "$@"
