#!/usr/bin/env bash
# ac-brain.sh - CLI for the per-home memory engine: ac-brain.sh <verb>
# [args...] [--home <abs path>]. The authoritative spec - the verbs, the home
# resolution (--home > $AC_HOME) and every JSON refusal - is the header of
# src/brain.ts; this entry only starts it through bin/ac-bun.sh, so every
# caller keeps this path. The one refusal printed here is bun missing from
# PATH: no module can run then, so none can print its JSON line. The module is
# found at <this bin/>/../src physically, so a per-home override bin/ needs a
# sibling src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
command -v bun >/dev/null 2>&1 || {
  printf '{"error":"unavailable","message":"bun not on PATH","suggestion":"install bun (https://bun.sh) - the engine runs on it"}\n'
  exit 1
}
ac_bun_exec src/brain.ts entry "$@"
