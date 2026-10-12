#!/usr/bin/env bash
# ac-fleet-view.sh - render the fleet as one line per crewmate. The
# authoritative spec is the header of src/fleet-view.ts; this entry only starts
# it through bin/ac-bun.sh, so every caller keeps this path. The module is
# found at <this bin/>/../src physically, so a per-home override bin/ needs a
# sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/fleet-view.ts "$@"
