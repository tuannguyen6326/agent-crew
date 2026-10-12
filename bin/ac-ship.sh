#!/usr/bin/env bash
# ac-ship.sh - the crew-ship pipeline's state machine and deterministic
# runner: one call per verb (start, step, findings, meta, cmd, attest-test,
# attest-check, push, base, evidence-dir, skip-remaining, config, fix-report,
# review-agent, review-residual, status, finish). The authoritative spec -
# the step machine, the review adapter, the attestation, the receipt, the push
# guard and the finish gate included - is the header of src/ship.ts; this
# entry only starts it through bin/ac-bun.sh, so every caller keeps this path.
# The module is found at <this bin/>/../src physically, so a per-home override
# bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/ship.ts "$@"
