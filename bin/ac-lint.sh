#!/usr/bin/env bash
# ac-lint.sh - the single lint definition: `bash -n` then the external linter
# over the scripts this checkout owns, the changed ones by default, `--all` for
# the whole set. The authoritative spec is the header of src/lint.ts; this
# entry only starts it through bin/ac-bun.sh, so every caller keeps this path.
# The module lints the checkout this bin/ sits in physically and is found at
# <this bin/>/../src, so a copy of this bin/ needs ac-bun.sh beside it and a
# sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/lint.ts "$@"
