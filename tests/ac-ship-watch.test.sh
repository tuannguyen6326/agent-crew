#!/usr/bin/env bash
# ac-ship-watch.test.sh - RUN_BASE must resolve to .crew/ship, never
# accidentally to its sibling .crew/qa (bin/ac-ship-watch.sh:24) - the
# mirror image of tests/ac-qa-watch.test.sh, and the same gap: ac-ship.test.sh
# and tests/ac-watch-dash.test.sh only ever exercise a run that already
# exists at the RIGHT path.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

repo="$(make_repo shipwatchrepo)"
# A qa run exists, but no ship run - the ship watch must still report "no
# active run", proving it looks at .crew/ship and not .crew/qa.
mkdir -p "$repo/.crew/qa/q1"
printf 'outcome=running\n' >"$repo/.crew/qa/q1/run.meta"
ln -sfn q1 "$repo/.crew/qa/current"

out="$("$BIN/ac-ship-watch.sh" --repo "$repo" --once)"
assert_eq "$out" "no active crew-ship run in $repo" \
  "ac-ship-watch.sh must read .crew/ship, not a sibling qa run"

pass
