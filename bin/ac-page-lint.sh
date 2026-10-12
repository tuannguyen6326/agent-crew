#!/usr/bin/env bash
# ac-page-lint.sh - PAGE-SYNTAX LINT: boot a dashboard, fetch its fixed page
# list and compile every inline <script> with `bun build --no-bundle`, so a
# syntax error inside a page's template-literal script is caught before it
# reaches the browser. The authoritative spec is the header of
# src/page-lint.ts; this entry only starts it through bin/ac-bun.sh, so every
# caller keeps this path. The module boots the dashboard/ of the checkout this
# bin/ sits in physically and is found at <this bin/>/../src, so a copy of this
# bin/ needs ac-bun.sh beside it and a sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/page-lint.ts "$@"
