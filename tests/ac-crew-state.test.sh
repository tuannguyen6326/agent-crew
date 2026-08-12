#!/usr/bin/env bash
# ac-crew-state.test.sh - the one-line deterministic state renderer: window
# liveness is THREE-STATE (gone/unobservable/alive, contract: ac-backend.sh
# WINDOW LIVENESS) - only a definite rc=1 renders gone, rc=2 must name the
# BACKEND as the unknown instead (F12); and the re-emitted last-status-log
# line must never match a live AC_CAPTAIN_RE marker into whatever pane calls
# this (F13).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_home

mk_crewmate() {
  # mk_crewmate <id> <pane> <tab> - a live crewmate: meta + handle + fake pane.
  printf 'backend=herdr\n' >"$AC_HOME/state/$1.meta"
  printf '%s %s\n' "$2" "$3" >"$AC_HOME/state/.pane-$1"
  printf '%s\n' "$2" >"$FAKE_HERDR/tabs/$3"
  : >"$FAKE_HERDR/panes/$2.buf"
}

# --- F12: rc=2 (unobservable) must not render as gone -------------------------

mk_crewmate c1 pC1 tC1
touch "$FAKE_HERDR/.unreachable"
out="$("$BIN/ac-crew-state.sh" c1)"
case "$out" in gone|gone*) fail "an unreadable backend must never render as gone: $out" ;; esac
assert_contains "$out" "unobservable" "an unreadable backend names itself unobservable"
assert_contains "$out" "backend" "the state names the BACKEND as the unknown, not the pane"
rm -f "$FAKE_HERDR/.unreachable"

# A REAL gone window keeps the old wording exactly.
rm -f "$FAKE_HERDR/panes/pC1.buf" "$FAKE_HERDR/tabs/tC1"
assert_eq "$("$BIN/ac-crew-state.sh" c1)" "gone" "a real gone window is reported exactly as before"

# --- F13: the last status line must not re-emit a bare captain marker ---------

mk_crewmate c2 pC2 tC2
printf '2026-07-29T00:00:00Z needs-decision: which prefix should I use?\n' >"$AC_HOME/state/c2.status"
out="$("$BIN/ac-crew-state.sh" c2)"
. "$BIN/ac-lib.sh"
case "$out" in *"needs-decision: which prefix"*) ;; *) fail "the marker text itself must survive, only its column-0 position is neutralized: $out" ;; esac
if grep -qE "$AC_CAPTAIN_RE" <<<"$out"; then
  fail "ac-crew-state.sh must not re-emit a line matching the LIVE AC_CAPTAIN_RE: $out"
fi

pass
