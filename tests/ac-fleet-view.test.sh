#!/usr/bin/env bash
# ac-fleet-view.test.sh - accounting excludes verification agents from
# crewmate rows (contract: ac_crew_metas "verify" skip-class, bin/ac-lib.sh -
# the same class dashboard-verifier-kind-hardcode/ac-dash-crew-heading-
# swallows-verifiers fixed for the OTHER two fleet views).

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

printf 'kind=ship\nproject=alpha\nmode=local-only\nwindow=w1\nbackend=herdr\n' >"$AC_HOME/state/crew1.meta"
printf 'kind=verify-codereview\nproject=alpha\nbackend=herdr\n' >"$AC_HOME/state/vfy1.meta"

out="$("$BIN/ac-fleet-view.sh")"
assert_contains "$out" "crew1" "an ordinary crewmate still renders its row"
case "$out" in *vfy1*) fail "a verify-* pane agent must not render as a crewmate row: $out" ;; esac

pass
