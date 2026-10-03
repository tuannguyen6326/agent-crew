#!/usr/bin/env bash
# ac-fleets.sh - READ-ONLY cross-fleet overview of every fleet home under the
# homes container (text, --json, --paths). The authoritative spec is the header
# of src/fleets.ts; this entry only starts it through bin/ac-bun.sh, so every
# caller keeps this path. The module finds ac-room.sh beside THIS bin/ (the
# root bun is started in), so a copied bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/fleets.ts "$@"
