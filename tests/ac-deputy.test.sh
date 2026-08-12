#!/usr/bin/env bash
# ac-deputy.test.sh - a stale meta naming an unsupported backend (e.g. tmux,
# removed 2026-07-17) must degrade that ONE entry to DOWN, never abort the
# whole `list` - the SUBSHELL isolation in deputy_state (bin/ac-deputy.sh:143)
# is what a "simplify away the parens" edit would break: `list` runs at every
# session start (bin/ac-session-start.sh), so a direct call would take the
# whole digest down over one stale deputy. tests/ac-deputy-registry.test.sh
# (which otherwise exhaustively covers `list`/`validate`) only ever
# constructs backend=herdr entries, so this branch is untested there.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

h="$AC_HOME/crewdeputies/stale"
mkdir -p "$h/state"
: >"$h/.ac-crewdeputy-home"
printf '# Crewdeputies\n\n- stale - duty - home: %s - scope: legacy - projects: none (added 2026-07-19T00:00:00Z)\n' "$h" \
  >"$AC_HOME/records/crewdeputies.md"
printf 'backend=tmux\nkind=crewdeputy\n' >"$AC_HOME/state/stale.meta"
printf 'pSTALE tSTALE\n' >"$AC_HOME/state/.pane-stale"

out="$("$BIN/ac-deputy.sh" list)" || fail "list must never die on an unsupported-backend meta"
assert_contains "$out" "$(printf 'DOWN\tstale')" "an unsupported backend degrades the entry to DOWN, not a crash"

pass
