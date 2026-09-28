#!/usr/bin/env bash
# run-suite.test.sh - proves tests/run-suite.sh actually detects a red, not
# just prints green: a deliberately-failing fixture, checked for a non-zero
# exit and its name appearing in the output (untruncated); a cwd-independence
# check; and a signal-disposition regression fixture (see below). Points
# run-suite.sh at throwaway fixture dirs (its optional <tests-dir> arg)
# instead of mutating tests/ itself.
#
# The real suite (tests/sh/*.test.sh, this file included) passing
# under this runner, with a matching count, is NOT asserted here: that run
# exceeds a crewmate's 2-minute Bash budget (repo-knowledge/agent-crew.md)
# and is the landing-gate's job, not this file's.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

RUNNER="$ROOT/tests/run-suite.sh"
assert_file "$RUNNER" "run-suite.sh must exist"

run_runner() {
  # run_runner <args...> - prints "<rc>|<output>". set +e/-e bracket the
  # capture so a non-zero runner exit (the expected case for a red fixture)
  # does not abort this test file under errexit - same wrapper stress.sh's
  # own run_stress test helper uses, for the same reason.
  local out rc
  set +e
  out="$(bash "$RUNNER" "$@" 2>&1)"
  rc=$?
  set -e
  printf '%s|%s' "$rc" "$out"
}

# --- fixture: one passing, one deliberately-failing test --------------------

fixdir="$TMP/fixture-tests"
mkdir -p "$fixdir"
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$fixdir/ok.test.sh"
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\nfail "deliberately red"\n' "$ROOT" >"$fixdir/broken.test.sh"

res="$(run_runner "$fixdir")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "1" "runner must exit non-zero when a fixture fails"
assert_contains "$out" "broken.test.sh" "failing fixture must be named in the output"
assert_contains "$out" "deliberately red" "the fixture's own failure text must surface (no truncating tail)"
assert_contains "$out" "ok.test.sh" "the passing fixture is still reported"
assert_contains "$out" "1/2 passed" "count must reflect exactly one failure"

# --- RUNNING <name>: printed for each fixture test, before its PASS/FAIL line -

assert_contains "$out" "RUNNING ok.test.sh" "a RUNNING line must be printed for the passing fixture"
assert_contains "$out" "RUNNING broken.test.sh" "a RUNNING line must be printed for the failing fixture"

running_line="$(printf '%s\n' "$out" | grep -n "^RUNNING ok\.test\.sh$" | head -1 | cut -d: -f1)"
pass_line="$(printf '%s\n' "$out" | grep -n "^PASS ok\.test\.sh$" | head -1 | cut -d: -f1)"
[ -n "$running_line" ] && [ -n "$pass_line" ] || fail "RUNNING/PASS lines for ok.test.sh not found"
[ "$running_line" -lt "$pass_line" ] || fail "RUNNING ok.test.sh must appear before its PASS line"

running_line="$(printf '%s\n' "$out" | grep -n "^RUNNING broken\.test\.sh$" | head -1 | cut -d: -f1)"
fail_line="$(printf '%s\n' "$out" | grep -n "^FAIL broken\.test\.sh" | head -1 | cut -d: -f1)"
[ -n "$running_line" ] && [ -n "$fail_line" ] || fail "RUNNING/FAIL lines for broken.test.sh not found"
[ "$running_line" -lt "$fail_line" ] || fail "RUNNING broken.test.sh must appear before its FAIL line"

# --- a clean fixture dir reports green and exits 0 ---------------------------

cleandir="$TMP/fixture-clean"
mkdir -p "$cleandir"
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$cleandir/a.test.sh"
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$cleandir/b.test.sh"
res="$(run_runner "$cleandir")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "an all-green fixture dir must exit 0"
assert_contains "$out" "2/2 passed" "count must match the fixture file count"

# --- same verdict from a different cwd ---------------------------------------

set +e
out2="$(cd "$TMP" && bash "$ROOT/tests/run-suite.sh" "$fixdir" 2>&1)"
rc2=$?
set -e
assert_eq "$rc2" "1" "verdict must not depend on the caller's cwd"
assert_contains "$out2" "broken.test.sh" "failing fixture named regardless of cwd"

# --- a bad --jobs value is a runner setup error, not a silent fake pass ------

res="$(run_runner --jobs abc "$fixdir")"
rc="${res%%|*}"
assert_eq "$rc" "2" "a malformed --jobs must refuse (exit 2), never read as green or as a test failure"

# --- --changed: mapping + widen rule, against a throwaway git-backed fixture -
#
# setup_changed_fixture builds a repo shaped just enough like the real one to
# exercise the mapping: bin/<name>.sh <-> tests/sh/<name>.test.sh, plus a
# bin/ac-util.sh standing in for a shared library - deliberately named
# nothing like "lib", because sourcers_of is a LIVE dot-source check, not a
# name match: bin/ac-bar.sh and bin/ac-baz.sh actually DOT-SOURCE
# bin/ac-util.sh, and that sourcing relationship - not the filename - is what
# must drive the selection (gate-finding run-suite-changed-file-selection,
# 2026-07-25 #2: a hand-maintained name list missed bin/ac-backend.sh,
# sourced by 14 scripts but named nothing like the three that WERE listed).
# TWO sourcers (ac-bar.sh, ac-baz.sh), each with its own colocated test, are
# what prove a shared-lib change selects EXACTLY its sourcers' tests, not
# "the whole suite happens to include them": a fixture with only one sourcer
# cannot tell "selected the sourcer's test" apart from "widened to
# everything, which happens to contain it" (family
# run-suite-changed-widens-on-any-shared-lib-so-the-ac-lib-split-buys-nothing-yet).
# bin/ac-util.sh also has its own colocated tests/sh/ac-util.test.sh, mirroring
# the real repo (every real shared library here - ac-lib.sh,
# ac-pipeline-lib.sh, ac-backend.sh - has one too): it is part of the
# selection too, per the same rule.
# Everything is committed as the baseline HEAD; each scenario below then
# mutates/adds a file UNCOMMITTED (staged/unstaged/untracked, mirroring
# ac-lint's changed set) to simulate "changed", and resets before the next
# scenario.
setup_changed_fixture() {
  local repo="$1"
  mkdir -p "$repo/bin" "$repo/tests/sh"
  git -C "$repo" init -q
  git -C "$repo" config user.email test@test
  git -C "$repo" config user.name test
  printf '#!/usr/bin/env bash\n# fixture ac-foo\n' >"$repo/bin/ac-foo.sh"
  printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$repo/tests/sh/ac-foo.test.sh"
  # shellcheck disable=SC2016 # fixture CONTENT for ac-bar.sh/ac-baz.sh: must
  # NOT expand now (that would resolve $0 to this test file, not the fixture
  # script) - it expands later, when the fixture's own bash process runs it.
  printf '#!/usr/bin/env bash\n. "$(dirname "$0")/ac-util.sh"\n# fixture ac-bar\n' >"$repo/bin/ac-bar.sh"
  printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$repo/tests/sh/ac-bar.test.sh"
  printf '#!/usr/bin/env bash\n. "$(dirname "$0")/ac-util.sh"\n# fixture ac-baz\n' >"$repo/bin/ac-baz.sh"
  printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$repo/tests/sh/ac-baz.test.sh"
  printf '#!/usr/bin/env bash\n# fixture shared util, sourced by ac-bar.sh and ac-baz.sh above\n' >"$repo/bin/ac-util.sh"
  printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$repo/tests/sh/ac-util.test.sh"
  chmod +x "$repo"/bin/*.sh "$repo"/tests/sh/*.test.sh
  git -C "$repo" add -A
  git -C "$repo" commit -q -m baseline
}

changedrepo="$TMP/fixture-changed-repo"
setup_changed_fixture "$changedrepo"

# 1) touching only bin/ac-foo.sh (uncommitted) selects only its colocated test
printf '#!/usr/bin/env bash\n# touched\n' >"$changedrepo/bin/ac-foo.sh"
res="$(run_runner --changed "$changedrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed selecting the mapped test alone must still be green"
assert_contains "$out" "RUNNING ac-foo.test.sh" "--changed must select ac-foo.test.sh, mapped from bin/ac-foo.sh"
assert_contains "$out" "1/1 passed" "--changed must select ONLY the mapped test, not the whole fixture set"
case "$out" in
  *"RUNNING ac-bar.test.sh"*) fail "--changed must NOT select ac-bar.test.sh, unrelated to the touched file" ;;
esac

# 2) bare invocation (no --changed) on the SAME touched fixture still runs the
#    full set - the default polarity never flips, even with a change present.
res="$(run_runner "$changedrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "bare invocation over the fixture must still be green"
assert_contains "$out" "4/4 passed" "bare run-suite.sh (no --changed) must run the FULL set regardless of changed files"
git -C "$changedrepo" checkout -q -- bin/ac-foo.sh

# 3) a shared-library change (bin/ac-util.sh, actually sourced by ac-bar.sh AND
#    ac-baz.sh) NARROWS to exactly its sourcers' tests plus its own colocated
#    test - never the whole suite - and never ac-foo.test.sh, unrelated to
#    ac-util.sh entirely. TWO sourcers, not one, is what proves this is a
#    selection and not a widen that happens to contain the right names: a
#    single-sourcer fixture cannot distinguish "selected the sourcer" from
#    "widened to everything, which includes it" (family
#    run-suite-changed-widens-on-any-shared-lib-so-the-ac-lib-split-buys-nothing-yet).
printf '#!/usr/bin/env bash\n# touched shared util\n' >"$changedrepo/bin/ac-util.sh"
res="$(run_runner --changed "$changedrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed by a shared-lib change to its sourcers must still be green"
assert_contains "$out" "RUNNING ac-bar.test.sh" "a shared-lib change must select sourcer A's (ac-bar.sh) test"
assert_contains "$out" "RUNNING ac-baz.test.sh" "a shared-lib change must select sourcer B's (ac-baz.sh) test"
assert_contains "$out" "RUNNING ac-util.test.sh" "a shared-lib change must select its OWN colocated test too"
assert_contains "$out" "3/3 passed" "a shared-lib change must select EXACTLY its sourcers' tests plus its own, not the whole fixture set"
case "$out" in
  *"RUNNING ac-foo.test.sh"*) fail "a shared-lib change must NOT select ac-foo.test.sh, not a sourcer of ac-util.sh" ;;
esac
git -C "$changedrepo" checkout -q -- bin/ac-util.sh

# 4) an owned file with no colocated test WIDENS rather than selecting nothing
printf '#!/usr/bin/env bash\n# fixture unmapped\n' >"$changedrepo/bin/ac-unmapped.sh"
chmod +x "$changedrepo/bin/ac-unmapped.sh"
res="$(run_runner --changed "$changedrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed widened by an unmapped file must still be green"
assert_contains "$out" "4/4 passed" "an unmapped owned file must WIDEN to the full set, never select nothing"
assert_contains "$out" "ac-unmapped.sh has no colocated test" "the widen reason printed must name the NO-COLOCATED-TEST mechanism, not just the filename"
rm -f "$changedrepo/bin/ac-unmapped.sh"

# --- --changed: a shared-lib change with a sourcer that has NO colocated test
#     still WIDENS to the full set - clause 2 (unknown blast radius) must
#     keep firing through the sourcer closure, never let narrowing turn an
#     unmapped sourcer into silence. bin/ac-nolib.sh sources bin/ac-shared.sh
#     but has no tests/sh/ac-nolib.test.sh of its own; bin/ac-shared.sh DOES have
#     its own colocated test, so this fixture isolates the "unmapped SOURCER"
#     mechanism from clause 2 firing on the changed file itself.
unmappedsourcerrepo="$TMP/fixture-unmapped-sourcer"
mkdir -p "$unmappedsourcerrepo/bin" "$unmappedsourcerrepo/tests/sh"
git -C "$unmappedsourcerrepo" init -q
git -C "$unmappedsourcerrepo" config user.email test@test
git -C "$unmappedsourcerrepo" config user.name test
printf '#!/usr/bin/env bash\n# fixture unrelated\n' >"$unmappedsourcerrepo/bin/ac-other.sh"
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$unmappedsourcerrepo/tests/sh/ac-other.test.sh"
printf '#!/usr/bin/env bash\n# fixture shared lib with an unmapped sourcer\n' >"$unmappedsourcerrepo/bin/ac-shared.sh"
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$unmappedsourcerrepo/tests/sh/ac-shared.test.sh"
# shellcheck disable=SC2016 # must NOT expand now, see the changedrepo fixtures above
printf '#!/usr/bin/env bash\n. "$(dirname "$0")/ac-shared.sh"\n# fixture sourcer with no colocated test\n' >"$unmappedsourcerrepo/bin/ac-nolib.sh"
chmod +x "$unmappedsourcerrepo"/bin/*.sh "$unmappedsourcerrepo"/tests/sh/*.test.sh
git -C "$unmappedsourcerrepo" add -A
git -C "$unmappedsourcerrepo" commit -q -m baseline

printf '#!/usr/bin/env bash\n# touched shared lib\n' >"$unmappedsourcerrepo/bin/ac-shared.sh"
res="$(run_runner --changed "$unmappedsourcerrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed widened by a shared-lib change with an unmapped sourcer must still be green"
assert_contains "$out" "2/2 passed" "a shared-lib change with an unmapped sourcer must WIDEN to the full fixture set, not narrow into silence"
assert_contains "$out" "bin/ac-shared.sh is a shared library with a sourcer that has no colocated test" "the widen reason printed must name both the changed shared-lib file AND the SOURCER mechanism, distinct from the changed file's own no-colocated-test reason"

# --- --changed: the documented split-name map narrows ac-spawn.sh/ac-teardown.sh
# instead of widening (F29, repo-deep-review) ---------------------------------
#
# ac-spawn.sh and ac-teardown.sh are each split across several concern-named
# test files rather than one exact-name file - the repo's own convention - so
# the exact-name mapping alone widened every change to either script to the
# full suite, with a "has no colocated test" message that is false in spirit.
# The map is a SMALL, DELIBERATE exception list keyed on these two real
# script names (not a live derivation like sourcers_of), so this fixture
# must use those literal names to exercise it. bin/ac-other.sh is an
# unrelated, ordinarily-mapped file included only to prove the map NARROWS
# (selects just the mapped split tests) rather than widening (which would
# also run ac-other.test.sh).
splitrepo="$TMP/fixture-split-map"
mkdir -p "$splitrepo/bin" "$splitrepo/tests/sh"
git -C "$splitrepo" init -q
git -C "$splitrepo" config user.email test@test
git -C "$splitrepo" config user.name test
printf '#!/usr/bin/env bash\n# fixture ac-spawn\n' >"$splitrepo/bin/ac-spawn.sh"
printf '#!/usr/bin/env bash\n# fixture ac-teardown\n' >"$splitrepo/bin/ac-teardown.sh"
printf '#!/usr/bin/env bash\n# fixture ac-other, unrelated - proves the map NARROWS instead of widening\n' >"$splitrepo/bin/ac-other.sh"
printf '#!/usr/bin/env bash\n# fixture ac-qa-lib, pinned inside ac-qa.test.sh\n' >"$splitrepo/bin/ac-qa-lib.sh"
printf '#!/usr/bin/env bash\n# fixture ac-maintenance-lib, pinned inside ac-maintenance-core.test.sh\n' >"$splitrepo/bin/ac-maintenance-lib.sh"
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$splitrepo/tests/sh/ac-other.test.sh"
for t in ac-spawn-branch-collision ac-spawn-dead-pane ac-spawn-model-effort ac-spawn-teardown ac-qa ac-maintenance-core; do
  printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$splitrepo/tests/sh/$t.test.sh"
done
chmod +x "$splitrepo"/bin/*.sh "$splitrepo"/tests/sh/*.test.sh
git -C "$splitrepo" add -A
git -C "$splitrepo" commit -q -m baseline

# 1) touching bin/ac-spawn.sh alone selects its FOUR mapped split-name tests,
#    excludes the unrelated colocated ac-other.test.sh, and does not widen.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-spawn.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-spawn.sh's split tests must still be green"
assert_contains "$out" "RUNNING ac-spawn-branch-collision.test.sh" "ac-spawn.sh's split map must select ac-spawn-branch-collision.test.sh"
assert_contains "$out" "RUNNING ac-spawn-dead-pane.test.sh" "ac-spawn.sh's split map must select ac-spawn-dead-pane.test.sh"
assert_contains "$out" "RUNNING ac-spawn-model-effort.test.sh" "ac-spawn.sh's split map must select ac-spawn-model-effort.test.sh"
assert_contains "$out" "RUNNING ac-spawn-teardown.test.sh" "ac-spawn.sh's split map must select ac-spawn-teardown.test.sh"
assert_contains "$out" "4/4 passed" "must select exactly the four mapped tests, not widen to the full fixture set"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-spawn.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
  *"has no colocated test"*) fail "ac-spawn.sh must not print the false widen reason once its split-name map exists" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-spawn.sh

# ac-qa-lib.sh keeps its pins inside ac-qa.test.sh: touching it selects that
# test, never a widen for want of an ac-qa-lib.test.sh.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-qa-lib.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-qa-lib.sh's test must still be green"
assert_contains "$out" "RUNNING ac-qa.test.sh" "ac-qa-lib.sh maps to ac-qa.test.sh"
assert_contains "$out" "1/1 passed" "ac-qa-lib.sh selects exactly ac-qa.test.sh"
git -C "$splitrepo" checkout -q -- bin/ac-qa-lib.sh

# ac-maintenance-lib.sh keeps its pins inside ac-maintenance-core.test.sh, the
# same shape as ac-qa-lib.sh.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-maintenance-lib.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-maintenance-lib.sh's test must still be green"
assert_contains "$out" "RUNNING ac-maintenance-core.test.sh" "ac-maintenance-lib.sh maps to ac-maintenance-core.test.sh"
assert_contains "$out" "1/1 passed" "ac-maintenance-lib.sh selects exactly ac-maintenance-core.test.sh"
git -C "$splitrepo" checkout -q -- bin/ac-maintenance-lib.sh

# 2) touching bin/ac-teardown.sh alone selects its ONE mapped split-name test.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-teardown.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-teardown.sh's split test must still be green"
assert_contains "$out" "RUNNING ac-spawn-teardown.test.sh" "ac-teardown.sh's split map must select ac-spawn-teardown.test.sh"
assert_contains "$out" "1/1 passed" "must select exactly the one mapped test, not widen"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-teardown.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
  *"has no colocated test"*) fail "ac-teardown.sh must not print the false widen reason once its split-name map exists" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-teardown.sh

# 3) the failure shape split_map's own comment names: add a NEW
#    ac-spawn-<concern>.test.sh file (committed, so it is present on disk but
#    not itself "changed"), then touch bin/ac-spawn.sh alone. A hand-written
#    exact-name list (the old code) has no entry for the new file and would
#    silently run without it, still green; the live glob must pick it up.
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$splitrepo/tests/sh/ac-spawn-newconcern.test.sh"
chmod +x "$splitrepo/tests/sh/ac-spawn-newconcern.test.sh"
git -C "$splitrepo" add -A
git -C "$splitrepo" commit -q -m "add a new split-name test file"
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-spawn.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-spawn.sh's split tests, plus the new one, must still be green"
assert_contains "$out" "RUNNING ac-spawn-newconcern.test.sh" "a NEW ac-spawn-*.test.sh file must join ac-spawn.sh's split map without anyone adding it by hand"
assert_contains "$out" "5/5 passed" "must select the four original mapped tests PLUS the new one, not silently miss it"
git -C "$splitrepo" checkout -q -- bin/ac-spawn.sh

# --- --changed: TypeScript under src/ maps like bin/*.sh does ------------
#
# A ported script keeps its bin/ac-<n>.sh entry (a shim) and moves its logic
# to src/<n>.ts, whose Bun unit tests (tests/ts/*.test.ts) run through ONE
# wrapper, tests/sh/src.test.sh. So src/<n>.ts selects that wrapper plus the
# black-box tests of every bin script that starts it (its entry, and any
# other script running a mode of it), a changed tests/ts/*.test.ts selects the
# wrapper, and a module other src/ files IMPORT is a shared library: it
# narrows to its importers' tests the way a sourced bash lib narrows to its
# sourcers'. The fixture wrapper is a plain pass - no bun needed here.
tsrepo="$TMP/fixture-changed-ts"
mkdir -p "$tsrepo/bin" "$tsrepo/src" "$tsrepo/tests/sh" "$tsrepo/tests/ts"
git -C "$tsrepo" init -q
git -C "$tsrepo" config user.email test@test
git -C "$tsrepo" config user.name test
printf '#!/usr/bin/env bash\nexec bun "$root/src/qux.ts" -- "$@"\n' >"$tsrepo/bin/ac-qux.sh"
# A bash script and its test that merely SHARE a src module's name - even
# one whose comment names that module - are no entry of it: only a bin
# script with a non-comment line naming src/<n>.ts starts it.
printf '#!/usr/bin/env bash\n# fixture bash lib; its TypeScript twin is src/util.ts\n' >"$tsrepo/bin/ac-util.sh"
printf 'import { u } from "./util.ts";\n' >"$tsrepo/src/qux.ts"
printf 'export const u = 1;\n' >"$tsrepo/src/util.ts"
printf 'import { u } from "../../src/util.ts";\n' >"$tsrepo/tests/ts/util.test.ts"
# src/pth.ts has no entry of its own: two scripts run modes of it, the shape
# of src/paths.ts under bin/ac-qa.sh and bin/ac-verify.sh.
printf 'export const p = 1;\n' >"$tsrepo/src/pth.ts"
# The long tail after the starting line is bin/ac-qa.sh's shape: a pipe that
# stops reading at the first match SIGPIPEs its writer there.
{
  # shellcheck disable=SC2016 # fixture CONTENT, expanded only if the fixture ran
  printf '#!/usr/bin/env bash\nwithin() { ( ac_bun_exec src/pth.ts within "$1" "$2" ); }\n'
  awk 'BEGIN { for (i = 0; i < 20000; i++) print ": filler" }'
} >"$tsrepo/bin/ac-check.sh"
# shellcheck disable=SC2016 # fixture CONTENT, as above
printf '#!/usr/bin/env bash\nport="$(ac_bun_exec src/pth.ts free-port)"\n' >"$tsrepo/bin/ac-audit.sh"
for t in ac-qux src ac-other ac-util ac-check ac-audit; do
  printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$tsrepo/tests/sh/$t.test.sh"
done
chmod +x "$tsrepo"/bin/*.sh "$tsrepo"/tests/sh/*.test.sh
git -C "$tsrepo" add -A
git -C "$tsrepo" commit -q -m baseline

printf 'export const q = 2;\n' >>"$tsrepo/src/qux.ts"
res="$(run_runner --changed "$tsrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed on a src/*.ts change must still be green"
assert_contains "$out" "RUNNING ac-qux.test.sh" "src/qux.ts must select its entry's black-box test"
assert_contains "$out" "RUNNING src.test.sh" "src/qux.ts must select the Bun unit-test wrapper"
assert_contains "$out" "2/2 passed" "src/qux.ts must select exactly its two tests, not widen"
git -C "$tsrepo" checkout -q -- src/qux.ts

printf 'export const v = 2;\n' >>"$tsrepo/src/util.ts"
res="$(run_runner --changed "$tsrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed on an imported src module must still be green"
assert_contains "$out" "RUNNING ac-qux.test.sh" "an imported src module must select its importer's entry test"
assert_contains "$out" "2/2 passed" "an imported src module must narrow to its importers' tests plus the wrapper"
git -C "$tsrepo" checkout -q -- src/util.ts

printf '// touched\n' >>"$tsrepo/tests/ts/util.test.ts"
res="$(run_runner --changed "$tsrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed on a tests/ts/*.test.ts change must still be green"
assert_contains "$out" "RUNNING src.test.sh" "a changed Bun unit test must select its wrapper"
assert_contains "$out" "1/1 passed" "a changed Bun unit test must select only the wrapper"
git -C "$tsrepo" checkout -q -- tests/ts/util.test.ts

printf 'export const q = 2;\n' >>"$tsrepo/src/pth.ts"
res="$(run_runner --changed "$tsrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed on a module other scripts start must still be green"
assert_contains "$out" "RUNNING ac-check.test.sh" "src/pth.ts must select the test of a script that runs a mode of it"
assert_contains "$out" "RUNNING ac-audit.test.sh" "src/pth.ts must select EVERY starting script's test"
assert_contains "$out" "3/3 passed" "src/pth.ts must select exactly the wrapper and its starters' tests, not widen"
git -C "$tsrepo" checkout -q -- src/pth.ts

# A starting script with no colocated test is unknown blast radius: widen,
# naming the starter mechanism. Committed first, so the new script is not
# itself a changed file widening on its own.
# shellcheck disable=SC2016 # fixture CONTENT, as above
printf '#!/usr/bin/env bash\nac_bun_exec src/pth.ts realpath "$1"\n' >"$tsrepo/bin/ac-nocheck.sh"
git -C "$tsrepo" add -A
git -C "$tsrepo" commit -q -m "a starter with no colocated test"
printf 'export const q = 2;\n' >>"$tsrepo/src/pth.ts"
res="$(run_runner --changed "$tsrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed widened by an untested starter must still be green"
assert_contains "$out" "6/6 passed" "a module started by a script with no colocated test must WIDEN to the full set"
assert_contains "$out" "src/pth.ts is started by a bin script that has no colocated test" "the widen reason must name the starter mechanism, not claim the module itself lacks a test"
git -C "$tsrepo" checkout -q -- src/pth.ts

# ...and still widens once another module imports it, making it a shared
# library whose importers' tests alone would read as a safe narrowing.
printf 'import { p } from "./pth.ts";\n' >"$tsrepo/src/imp.ts"
git -C "$tsrepo" add -A
git -C "$tsrepo" commit -q -m "an importer of the module"
printf 'export const q = 2;\n' >>"$tsrepo/src/pth.ts"
res="$(run_runner --changed "$tsrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_contains "$out" "6/6 passed" "an imported module with an untested starter must WIDEN, not narrow to its importers"
assert_contains "$out" "src/pth.ts is started by a bin script that has no colocated test" "the imported module's widen names the starter mechanism too"
git -C "$tsrepo" checkout -q -- src/pth.ts

# --- --changed: a clean, fully-committed tree exits non-zero, runs nothing --
#
# DEFECT HISTORY: select_changed narrows `tests` in place; an empty
# changed_files set (nothing uncommitted at all - everything already
# committed) narrows `tests` to zero. First cut read that as "no changed test
# targets" + exit 0 - a false green that ran ZERO tests. Second cut (@5ed7446)
# WIDENED to the full set instead - but the post-commit tree is exactly the
# state a chief verifies in (a crewmate commits before handback), so the
# ALLOWED narrow mode (captain.md's NO BARE FULL-SUITE RUN standing order)
# reliably re-triggered the FORBIDDEN full run in the single most common verify
# situation (family run-suite-empty-selection-must-not-run-the-full-suite).
# Neither exit-0-silent nor widen-to-full is honest here: an empty mapped
# selection means --changed has nothing safe to narrow ON, so it exits
# non-zero (2, same family as "no *.test.sh files found" - the runner itself
# could not proceed) and runs nothing at all.
cleancommittedrepo="$TMP/fixture-changed-clean-committed"
setup_changed_fixture "$cleancommittedrepo"
res="$(run_runner --changed "$cleancommittedrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "2" "a clean, fully-committed tree must exit non-zero, not a false green"
assert_contains "$out" "nothing selected" "the message must say nothing was SELECTED"
assert_contains "$out" "nothing ran" "the message must say nothing RAN"
case "$out" in
  *"3/3 passed"*) fail "--changed on a clean, fully-committed tree must not widen and run the full fixture set" ;;
  *"RUNNING "*) fail "--changed on a clean, fully-committed tree must not run any test at all" ;;
  *"no changed test targets"*) fail "--changed on a clean, fully-committed tree must not silently report zero targets with exit 0" ;;
esac

# --- --changed: outside a git repo, falls back to the full set --------------

nogitdir="$TMP/fixture-changed-nogit"
mkdir -p "$nogitdir"
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$nogitdir/a.test.sh"
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$nogitdir/b.test.sh"
res="$(run_runner --changed "$nogitdir")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed outside a git repo must still be green"
assert_contains "$out" "2/2 passed" "outside a git repo, --changed must fall back to running the full set"

# --- --changed: a fresh repo with no HEAD falls back to the full set --------

noheaddir="$TMP/fixture-changed-nohead"
mkdir -p "$noheaddir/bin" "$noheaddir/tests/sh"
git -C "$noheaddir" init -q
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$noheaddir/tests/sh/a.test.sh"
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$noheaddir/tests/sh/b.test.sh"
res="$(run_runner --changed "$noheaddir/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed with no HEAD yet must still be green"
assert_contains "$out" "2/2 passed" "a repo with no HEAD yet must fall back to running the full set"

# --- regression: the runner must not alter a test's signal disposition ------
#
# Bash gives an async `&` command SIGINT/SIGQUIT=ignore when job control is
# off, and that ignore survives exec/fork into every descendant it spawns -
# exactly how ac-watch.test.sh false-reds under a naive `( ... ) &` loop: its
# own backgrounded watcher inherits the ignore and never sees the INT it is
# asserted to die from (landing-gate report, tests-need-a-canonical-run-suite,
# 2026-07-22; confirmed against the GNU Bash Reference Manual, "Signals").
# This fixture backgrounds a child and sends it SIGINT; delivery (the child
# dying) only holds if the runner's own backgrounding preserves normal
# job-control signal semantics - it fails outright under a runner missing the
# `set -m`/`set +m` fix.
#
# The fixture itself needs the SAME two safeguards, or it flakes even under a
# correct runner (held-constant repro, family run-suite-sigint-child-intermittent):
#   1. `set -m` here too. The runner's `set -m` does NOT propagate into this
#      `bash "$f"` - it starts as a fresh non-interactive shell with job control
#      OFF ($- lacks 'm', SHELLOPTS lacks 'monitor'), so its OWN `( sleep ) &`
#      re-triggers the very async SIGINT=ignore this fixture exists to catch,
#      one level down. Repro: JC-off => child gets SIG_IGN and survives the
#      kill deterministically (30/30) once the race below is removed; JC-on =>
#      killed deterministically (0/500). An inherited SIG_IGN from a broken
#      runner stays sticky through this `set -m`, so it does NOT mask the
#      regression: fixed fixture reds 40/40 through a set-m-stripped runner,
#      greens 0/40 through the correct one.
#   2. sync before the kill. `kill -INT` fired immediately after `( sleep ) &`
#      races the child's fork/exec and signal-disposition setup - the kill can
#      land before the child is running `sleep`, so the outcome is a coin flip
#      (JC-on + immediate kill still flaked 2/500). Wait until the child is
#      actually executing `sleep` (exec done => disposition final), then kill.
sigdir="$TMP/fixture-signal"
mkdir -p "$sigdir"
cat >"$sigdir/int-kills-child.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
# No `set -e` here on purpose: `wait` returning >=128 (killed-by-signal) is the
# EXPECTED outcome, not an error to abort on before rc is captured. `set -m`
# (job control ON) so this fixture's own async `( sleep ) &` is not forced to
# ignore SIGINT - mirrors run-suite.sh's own toggle, one level down.
set -m
( sleep 5 ) &
cpid=$!
# Race guard: send the signal only once the child is actually running `sleep`
# (exec complete, so its signal disposition is final). Killing immediately
# races the child's setup and makes the outcome nondeterministic. This is a
# readiness poll (no fixed deadline to lose, so it holds under load), not the
# fixed kill -0 death-poll a prior revision removed.
until ps -o comm= -p "$cpid" 2>/dev/null | grep -q sleep; do
  kill -0 "$cpid" 2>/dev/null || break
done
kill -INT "$cpid"
# wait BLOCKS until the child terminates. >=128 means the signal killed it
# (130 = 128+SIGINT); 0 means it ignored SIGINT and slept out its full 5s -
# the bug this fixture exists to catch.
wait "$cpid"; rc=$?
if [ "$rc" -lt 128 ]; then
  printf 'FAIL: child survived SIGINT - signal disposition was altered (wait rc=%s)\n' "$rc" >&2
  exit 1
fi
printf 'PASS: int-kills-child.test.sh\n'
FIXTURE
chmod +x "$sigdir/int-kills-child.test.sh"
res="$(run_runner "$sigdir")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "the runner must deliver SIGINT normally to a test's backgrounded child"
assert_contains "$out" "1/1 passed" "the signal fixture must pass under a job-control-safe runner"

# --- the split layout: shell tests and their helpers live in tests/sh -------
#
# The fixture tests each dot-source a helpers.sh, as the real ones do, so a
# helper changed under tests/sh is a shared library of all four.
printf '# touched\n' >>"$changedrepo/tests/sh/ac-foo.test.sh"
res="$(run_runner --changed "$changedrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_contains "$out" "RUNNING ac-foo.test.sh" "a changed tests/sh/*.test.sh must select itself"
assert_contains "$out" "1/1 passed" "a changed tests/sh/*.test.sh must select only itself"
git -C "$changedrepo" checkout -q -- tests/sh/ac-foo.test.sh

printf '# fixture helper\n' >"$changedrepo/tests/sh/helpers.sh"
res="$(run_runner --changed "$changedrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_contains "$out" "narrows tests/sh/helpers.sh (a shared library)" "a helper under tests/sh must narrow to the tests sourcing it"
assert_contains "$out" "4/4 passed" "a helper under tests/sh must select every test sourcing it"
rm -f "$changedrepo/tests/sh/helpers.sh"

# A bare run discovers <repo>/tests/sh from the runner's own location, never
# the tests/ it sits in.
layout="$TMP/fixture-layout"
mkdir -p "$layout/tests/sh"
cp "$RUNNER" "$layout/tests/run-suite.sh"
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$layout/tests/sh/a.test.sh"
set +e
out="$(bash "$layout/tests/run-suite.sh" 2>&1)"; rc=$?
set -e
assert_eq "$rc" "0" "a bare run over the split layout must be green"
assert_contains "$out" "1/1 passed" "a bare run must discover <repo>/tests/sh/*.test.sh"

pass
