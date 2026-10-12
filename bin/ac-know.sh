#!/usr/bin/env bash
# ac-know.sh - the per-project REPO-KNOWLEDGE record: what earlier families
# verified about a codebase, durable in the fleet home and re-checkable
# (add, retire, cite, recall, verify, scope-proposal, scope-install). The
# authoritative spec - the record's grammar and the false-FRESH class
# included - is the header of src/know.ts; this entry only starts it through
# bin/ac-bun.sh, so every caller keeps this path. The module is found at
# <this bin/>/../src physically, so a per-home override bin/ needs a sibling
# src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/know.ts "$@"
