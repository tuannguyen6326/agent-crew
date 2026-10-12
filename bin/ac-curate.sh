#!/usr/bin/env bash
# ac-curate.sh - fleet-local Curate maintenance over the fleet's own ledgers:
# propose-only audits, two compatibility mutators and the automatic `run`
# Learning starts at its cadence. The authoritative spec - the automatic
# policy, the acknowledgements, the shadow and transaction boundary included -
# is the header of src/curate.ts; this entry only starts it through
# bin/ac-bun.sh, so every caller keeps this path. The module is found at
# <this bin/>/../src physically, so a per-home override bin/ needs a sibling
# src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/curate.ts "$@"
