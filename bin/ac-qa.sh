#!/usr/bin/env bash
# ac-qa.sh - the qa pipeline's state machine and deterministic runner: one call
# per verb (start, step, case, visual, findings, testplan-amend, fixture,
# harness-classify, regression-proposal, curation, store-install, store-curate,
# store-label, store-calibration, infra, baseline, serve, health, boundary-run,
# boundary-register, seed, cmd, config, config-proposal, config-install,
# evidence-dir, store-dir, fix-report, relay-report, fetch-check, agent,
# status, finish). The authoritative spec - the step machine, PROFILE RESOLVE,
# the boundary policy, the knowledge store, the relay contract and the pass
# gate included - is the header of src/qa.ts; this entry only starts it
# through bin/ac-bun.sh, so every caller keeps this path. The module is found
# at <this bin/>/../src physically, so a per-home override bin/ needs a
# sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/qa.ts "$@"
