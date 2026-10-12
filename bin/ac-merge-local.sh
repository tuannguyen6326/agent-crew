#!/usr/bin/env bash
# ac-merge-local.sh - land a local-only crewmate task from crew/<id> into the
# project's local default branch (or the recorded epic/feature integration
# branch), with the bin/ac-guard.sh advisory riding along. Writes into a
# project clone - one of the few sanctioned writes. The authoritative spec is
# the header of src/merge-local.ts; this entry only starts it through
# bin/ac-bun.sh, so every caller keeps this path. The module is found at
# <this bin/>/../src physically, so a per-home override bin/ needs a sibling
# src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/merge-local.ts "$@"
