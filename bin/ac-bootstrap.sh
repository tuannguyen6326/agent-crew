#!/usr/bin/env bash
# ac-bootstrap.sh - toolchain doctor: verify every tool agent-crew leans on
# and say exactly what is missing and why it matters.
#
# Usage:
#   ac-bootstrap.sh [--quiet]
#
# Output contract (one line per check, stable prefixes the orchestrator can
# act on):
#   OK: <tool>                     present and usable
#   MISSING: <tool> - <hint>       required tool absent -> exit 1
#   NEEDS_GH_AUTH: <hint>          gh present but not authenticated
#   OPTIONAL: <tool> missing - <what it unlocks>
#
# --quiet suppresses OK lines (problems only). Exit 1 only when a REQUIRED
# tool is missing; auth and optional gaps are advisory.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

quiet=0
[ "${1:-}" = "--quiet" ] && quiet=1

rc=0

ok() { [ "$quiet" = 1 ] || printf 'OK: %s\n' "$1"; }

need() {
  # need <tool> <hint>
  if command -v "$1" >/dev/null 2>&1; then ok "$1"; else
    printf 'MISSING: %s - %s\n' "$1" "$2"
    rc=1
  fi
}

opt() {
  # opt <tool> <what it unlocks>
  if command -v "$1" >/dev/null 2>&1; then ok "$1"; else
    printf 'OPTIONAL: %s missing - %s\n' "$1" "$2"
  fi
}

need git "brew install git"
need jq "brew install jq (worktree pool state, herdr backend)"

# Session backend: the configured one is required, the others stay optional.
backend="$(ac_config_read backend herdr)"
case "$backend" in
  herdr) : ;;
  *)
    printf 'MISSING: config/backend names unsupported backend %s (herdr is the only backend)\n' "$backend"
    rc=1
    backend=herdr
    ;;
esac
# The hint names herdr outright rather than "$backend": the case above already
# forced any other value back to herdr, so this can only ever report herdr - and
# "MISSING: herdr - configured session backend (config/backend)" told an
# operator the one thing they already knew, while withholding the one thing they
# needed. It is the fleet's only backend; nothing runs without it.
need "$backend" "brew install herdr (the fleet's session backend; nothing spawns without it)"

# Present is not enough: a client/server PROTOCOL mismatch (brew upgrades the CLI
# while the old server keeps running - herdr's README: a running server keeps its
# process until stopped) fails EVERY socket call, so nothing can be spawned, seen
# or steered. Lived 2026-07-25, and it cost a diagnosis instead of one digest
# line. herdr reports the condition itself, so ask it - and flag ONLY an explicit
# `false`: an absent binary, an old herdr with no --json, or any unparseable reply
# says NOTHING about compatibility, and a doctor that grounds the fleet on silence
# is worse than the outage. Neither jq shorthand can express that: `jq -e` exits 0
# on EMPTY input (silence would read as a mismatch), and `// empty` swallows the
# very value being looked for (jq's alternative operator fires on false as well as
# null). So the field is printed raw and compared here - "" or "null" is silence.
compat="$(herdr status server --json 2>/dev/null | jq -r '.compatible' 2>/dev/null || true)"
if [ "$compat" = false ]; then
  printf 'MISSING: herdr protocol compat - the running server disagrees with the client (herdr status server: compatible false), so EVERY socket call fails and no pane can be spawned, read or steered; restart the herdr server (it exits every pane, the captain owns that call)\n'
  rc=1
fi

if command -v gh >/dev/null 2>&1; then
  if gh auth status >/dev/null 2>&1; then
    ok "gh (authenticated)"
  else
    printf 'NEEDS_GH_AUTH: run gh auth login (PR + CI steps need it)\n'
  fi
else
  printf 'MISSING: gh - brew install gh (PR + CI steps)\n'
  rc=1
fi

opt bun "web dashboard + native review loop (bin/ac-dashboard.sh runs bin/dashboard.ts)"
opt node "npx-driven helpers (crew-qa's playwright screenshots)"
# Not "dev only" any more: with no CI workflow, a local run is the ONLY thing
# that ever lints this repo, so an absent shellcheck means nothing is checked.
opt shellcheck "brew install shellcheck - bin/ac-lint.sh is the only lint there is; nothing else runs it"
opt docker "qa pipeline infra (bin/ac-qa.sh: postgres/redis/temporal/mock profiles)"

exit "$rc"
