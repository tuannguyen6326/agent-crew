#!/usr/bin/env bash
# ac-home-carriers.sh - the fleet home names itself to every harness's hooks:
# five real per-home dot-dirs, the distro content linked in, one home-owned
# carrier per harness holding AC_HOME=<home>. The authoritative spec is the
# header of src/home-carriers.ts; this entry only starts it through
# bin/ac-bun.sh, so every caller keeps this path. The module is found at
# <this bin/>/../src physically, so a per-home override bin/ needs a sibling
# src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/home-carriers.ts "$@"
