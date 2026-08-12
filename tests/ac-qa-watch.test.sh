#!/usr/bin/env bash
# ac-qa-watch.test.sh - RUN_BASE must resolve to .crew/qa, never accidentally
# to its sibling .crew/ship (bin/ac-qa-watch.sh:24) - ac-qa.test.sh and
# tests/ac-watch-dash.test.sh only ever exercise a run that already exists at
# the RIGHT path, so a copy-paste RUN_BASE regression between the two
# near-identical watch scripts (ac-ship-watch.sh is the twin) would go
# uncaught.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

repo="$(make_repo qawatchrepo)"
# A ship run exists, but no qa run - the qa watch must still report "no
# active run", proving it looks at .crew/qa and not .crew/ship.
mkdir -p "$repo/.crew/ship/s1"
printf 'outcome=running\n' >"$repo/.crew/ship/s1/run.meta"
ln -sfn s1 "$repo/.crew/ship/current"

out="$("$BIN/ac-qa-watch.sh" --repo "$repo" --once)"
assert_eq "$out" "no active qa run in $repo" \
  "ac-qa-watch.sh must read .crew/qa, not a sibling ship run"

pass
