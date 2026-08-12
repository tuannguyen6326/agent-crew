#!/usr/bin/env bash
# ac-peek.test.sh - peek output must NEUTRALIZE a reprinted captain marker
# (contract: bin/ac-peek.sh:25-29, "prefixed, never merely indented" - an
# indent alone still matches AC_CAPTAIN_RE at line start, the same F13
# class tests/ac-crew-state.test.sh pins for ac-crew-state.sh).

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

mk_crewmate c1 pC1 tC1
printf 'needs-decision: which prefix should I use?\n' >"$FAKE_HERDR/panes/pC1.buf"

out="$("$BIN/ac-peek.sh" c1)"
assert_contains "$out" "needs-decision: which prefix" "the marker text itself must survive the peek prefix"
. "$BIN/ac-lib.sh"
if grep -qE "$AC_CAPTAIN_RE" <<<"$out"; then
  fail "ac-peek.sh must not re-emit a line matching the LIVE AC_CAPTAIN_RE: $out"
fi

pass
