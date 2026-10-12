#!/usr/bin/env bash
# ac-review.sh - crewmate CLI for the dashboard's native annotate loop: the
# open/poll/reply/end/url verb set the rich-review skill teaches, over the
# dashboard review API. The authoritative spec is the header of
# src/review.ts; this entry only starts it through bin/ac-bun.sh, so every
# caller keeps this path. The module is found at <this bin/>/../src
# physically, so a per-home override bin/ needs a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/review.ts "$@"
