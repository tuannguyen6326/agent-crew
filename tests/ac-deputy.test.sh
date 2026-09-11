#!/usr/bin/env bash
# ac-deputy.test.sh - deputy_state (bin/ac-deputy.sh) edge cases.
#
# Part 1: a stale meta naming an unsupported backend (e.g. tmux, removed
# 2026-07-17) must degrade that ONE entry to DOWN, never abort the whole
# `list` - the SUBSHELL isolation in deputy_state is what a "simplify away
# the parens" edit would break: `list` runs at every session start
# (bin/ac-session-start.sh), so a direct call would take the whole digest
# down over one stale deputy. tests/ac-deputy-registry.test.sh (which
# otherwise exhaustively covers `list`/`validate`) only ever constructs
# backend=herdr entries, so this branch is untested there.
#
# Part 2: a SUPPORTED backend (herdr) the fleet genuinely cannot read (rc=2,
# or 127 from a driver that failed to load) is a DIFFERENT variable from
# part 1's malformed meta, and must render its own UNOBSERVABLE state, never
# silently collapse to DOWN (contract: ac-backend.sh WINDOW LIVENESS;
# AGENTS.md section 7 - "NOT a death and no work is lost").

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

# --- A3 / window-liveness contract: deputy_state must distinguish "not ------
# running" from "could not be asked" -----------------------------------------
# A stale meta naming an UNSUPPORTED backend (above) is a DIFFERENT variable
# (a malformed meta - ac_backend_route's `b="$(ac_backend)" || exit 1` degrades
# to rc=1 INSIDE the deliberate subshell, and that degradation to DOWN stays
# correct and untouched) from a SUPPORTED backend the fleet genuinely cannot
# read (rc=2, or 127 from a driver that failed to load) - that second
# variable must render as its own state, never silently as DOWN.
make_fake_herdr

h2="$AC_HOME/crewdeputies/unread"
mkdir -p "$h2/state"
: >"$h2/.ac-crewdeputy-home"
printf -- '- unread - duty - home: %s - scope: legacy - projects: none (added 2026-07-19T00:00:00Z)\n' "$h2" \
  >>"$AC_HOME/records/crewdeputies.md"
printf 'backend=herdr\nkind=crewdeputy\n' >"$AC_HOME/state/unread.meta"

# rc=0 (A4 no-regression floor): a genuinely alive pane still renders LIVE.
printf 'pUNREAD tUNREAD\n' >"$AC_HOME/state/.pane-unread"
printf 'pUNREAD\n' >"$FAKE_HERDR/tabs/tUNREAD"; : >"$FAKE_HERDR/panes/pUNREAD.buf"
out="$("$BIN/ac-deputy.sh" list)" || fail "list must not die on a live herdr-backed deputy"
assert_contains "$out" "$(printf 'LIVE\tunread')" "a genuinely alive pane still renders LIVE (A4)"

# rc=1 (A4 no-regression floor): a genuinely gone pane still renders DOWN.
rm -f "$FAKE_HERDR/tabs/tUNREAD" "$FAKE_HERDR/panes/pUNREAD.buf"
out="$("$BIN/ac-deputy.sh" list)" || fail "list must not die on a gone herdr-backed deputy"
assert_contains "$out" "$(printf 'DOWN\tunread')" "a genuinely gone pane still renders DOWN (A4)"

# rc=2: THE REGRESSION this row closes.
printf 'pUNREAD tUNREAD\n' >"$AC_HOME/state/.pane-unread"
printf 'pUNREAD\n' >"$FAKE_HERDR/tabs/tUNREAD"; : >"$FAKE_HERDR/panes/pUNREAD.buf"
touch "$FAKE_HERDR/.unreachable"
out="$("$BIN/ac-deputy.sh" list)" || fail "list must never die on an unreadable herdr backend"
rm -f "$FAKE_HERDR/.unreachable"
case "$out" in *"$(printf 'DOWN\tunread')"*) \
  fail "THE REGRESSION: an unreadable backend (rc=2) must never render as DOWN" ;; esac
assert_contains "$out" "$(printf 'UNOBSERVABLE\tunread')" "an unreadable backend renders UNOBSERVABLE, not DOWN"

# ...and exit 127 (a driver failed to LOAD) renders the SAME way - the real
# production shape of a driver file that failed to load (ac_backend_route
# dispatches per call to backend_${fn}_herdr, so a missing driver function
# makes bash itself return 127 from the call being classified).
make_loadfail_bin
out="$("$LOADFAIL_BIN/ac-deputy.sh" list)" || fail "list must never die on a 127 driver-load failure"
case "$out" in *"$(printf 'DOWN\tunread')"*) \
  fail "THE REGRESSION: a 127 driver-load failure must never render as DOWN" ;; esac
assert_contains "$out" "$(printf 'UNOBSERVABLE\tunread')" \
  "a 127 driver-load failure renders UNOBSERVABLE, same as rc=2"

pass
