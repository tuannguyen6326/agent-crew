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

# --- --changed: the tree-scanning guard suites ride every non-empty changed set
#     A guard's subject is a whole class of files, so no colocated mapping
#     reaches it. Its own fixture repo, so the shared one's counts stay put;
#     grep-q-pipes.test.sh is a real guard_suites name.
guardrepo="$TMP/fixture-changed-guards"
setup_changed_fixture "$guardrepo"
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$guardrepo/tests/sh/grep-q-pipes.test.sh"
git -C "$guardrepo" add -A
git -C "$guardrepo" commit -q -m "a guard suite"

printf '#!/usr/bin/env bash\n# touched\n' >"$guardrepo/bin/ac-foo.sh"
res="$(run_runner --changed "$guardrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed with a mapped change plus the guards must be green"
assert_contains "$out" "RUNNING ac-foo.test.sh" "the mapped test still runs beside the guards"
assert_contains "$out" "RUNNING grep-q-pipes.test.sh" "a mapped change must also select the tree-scanning guard suites"
assert_contains "$out" "2/2 passed" "the guards add to the mapped selection, never widen it"
assert_contains "$out" "tree-scanning guard suites" "the runner must say it added the guard suites"
case "$out" in
  *"RUNNING ac-bar.test.sh"*) fail "the guard set must not pull in unrelated mapped tests" ;;
esac
git -C "$guardrepo" checkout -q -- bin/ac-foo.sh

mkdir -p "$guardrepo/docs"
printf 'prose\n' >"$guardrepo/docs/x.md"
res="$(run_runner --changed "$guardrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "a change outside the owned set must run the guards, not exit empty"
assert_contains "$out" "RUNNING grep-q-pipes.test.sh" "a docs-only change must select the tree-scanning guard suites"
assert_contains "$out" "1/1 passed" "a docs-only change selects the guards alone"
rm -rf "$guardrepo/docs"

res="$(run_runner --changed "$guardrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "2" "the guards never turn an empty changed set into a green"
case "$out" in
  *"RUNNING "*) fail "a clean committed tree must run nothing, the guards included" ;;
esac

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
# also run ac-other.test.sh). Its flag-values.test.sh and
# ac-config-surface.test.sh stand-ins are guard_suites names, so every count
# below also carries those two (once, where the arm already names one).
splitrepo="$TMP/fixture-split-map"
mkdir -p "$splitrepo/bin" "$splitrepo/tests/sh"
git -C "$splitrepo" init -q
git -C "$splitrepo" config user.email test@test
git -C "$splitrepo" config user.name test
printf '#!/usr/bin/env bash\n# fixture ac-spawn\n' >"$splitrepo/bin/ac-spawn.sh"
printf '#!/usr/bin/env bash\n# fixture ac-teardown\n' >"$splitrepo/bin/ac-teardown.sh"
printf '#!/usr/bin/env bash\n# fixture ac-brief\n' >"$splitrepo/bin/ac-brief.sh"
printf '#!/usr/bin/env bash\n# fixture ac-know\n' >"$splitrepo/bin/ac-know.sh"
printf '#!/usr/bin/env bash\n# fixture ac-gate\n' >"$splitrepo/bin/ac-gate.sh"
printf '#!/usr/bin/env bash\n# fixture ac-curate\n' >"$splitrepo/bin/ac-curate.sh"
printf '#!/usr/bin/env bash\n# fixture ac-gate-watch\n' >"$splitrepo/bin/ac-gate-watch.sh"
printf '#!/usr/bin/env bash\n# fixture ac-ship-watch\n' >"$splitrepo/bin/ac-ship-watch.sh"
printf '#!/usr/bin/env bash\n# fixture ac-qa-watch\n' >"$splitrepo/bin/ac-qa-watch.sh"
printf '#!/usr/bin/env bash\n# fixture ac-dashboard\n' >"$splitrepo/bin/ac-dashboard.sh"
printf '#!/usr/bin/env bash\n# fixture ac-ready\n' >"$splitrepo/bin/ac-ready.sh"
printf '#!/usr/bin/env bash\n# fixture ac-learn\n' >"$splitrepo/bin/ac-learn.sh"
printf '#!/usr/bin/env bash\n# fixture ac-pane-agent\n' >"$splitrepo/bin/ac-pane-agent.sh"
printf '#!/usr/bin/env bash\n# fixture ac-watch\n' >"$splitrepo/bin/ac-watch.sh"
printf '#!/usr/bin/env bash\n# fixture ac-watch-policy-hook\n' >"$splitrepo/bin/ac-watch-policy-hook.sh"
printf '#!/usr/bin/env bash\n# fixture ac-other, unrelated - proves the map NARROWS instead of widening\n' >"$splitrepo/bin/ac-other.sh"
printf '#!/usr/bin/env bash\n# fixture ac-maintenance-lib, pinned inside ac-maintenance-core.test.sh\n' >"$splitrepo/bin/ac-maintenance-lib.sh"
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$splitrepo/tests/sh/ac-other.test.sh"
for t in ac-spawn-branch-collision ac-spawn-dead-pane ac-spawn-model-effort ac-spawn-teardown ac-teardown ac-qa ac-maintenance-core ac-brief ac-contract ac-know flag-values ac-gate ac-learn-loop ac-curate ac-backlog-sections ac-learning-automation-e2e ac-config-surface ac-gate-watch ac-watch-dash ac-ship-watch ac-qa-watch ac-ship ac-roomchief ac-room-parallel-cap ac-learn ac-learn-autoroom ac-learn-quote ac-pane-agent ac-brain ac-lib ac-watch ac-watch-jev ac-brain-freshen ac-lock ac-remote-wire ac-self-task ac-guard ac-harness-hooks; do
  printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$splitrepo/tests/sh/$t.test.sh"
done
for t in ac-dashboard-daemon ac-review ac-review-reply; do
  printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$splitrepo/tests/sh/$t.test.sh"
done
for t in ac-ready ac-backlog ac-task ac-watch ac-watch-autoarm ac-turnend-guard ac-session-start; do
  printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$splitrepo/tests/sh/$t.test.sh"
done
chmod +x "$splitrepo"/bin/*.sh "$splitrepo"/tests/sh/*.test.sh
git -C "$splitrepo" add -A
git -C "$splitrepo" commit -q -m baseline

# 1) touching bin/ac-spawn.sh alone selects its FOUR split-name tests and the
#    two roomchief suites, excludes the unrelated colocated ac-other.test.sh,
#    and does not widen.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-spawn.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-spawn.sh's split tests must still be green"
assert_contains "$out" "RUNNING ac-spawn-branch-collision.test.sh" "ac-spawn.sh's split map must select ac-spawn-branch-collision.test.sh"
assert_contains "$out" "RUNNING ac-spawn-dead-pane.test.sh" "ac-spawn.sh's split map must select ac-spawn-dead-pane.test.sh"
assert_contains "$out" "RUNNING ac-spawn-model-effort.test.sh" "ac-spawn.sh's split map must select ac-spawn-model-effort.test.sh"
assert_contains "$out" "RUNNING ac-spawn-teardown.test.sh" "ac-spawn.sh's split map must select ac-spawn-teardown.test.sh"
assert_contains "$out" "RUNNING ac-roomchief.test.sh" "ac-spawn.sh's split map must select ac-roomchief.test.sh"
assert_contains "$out" "RUNNING ac-room-parallel-cap.test.sh" "ac-spawn.sh's split map must select ac-room-parallel-cap.test.sh"
assert_contains "$out" "8/8 passed" "must select exactly the six mapped tests plus the guards, not widen to the full fixture set"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-spawn.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
  *"has no colocated test"*) fail "ac-spawn.sh must not print the false widen reason once its split-name map exists" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-spawn.sh

# ac-maintenance-lib.sh keeps its pins inside ac-maintenance-core.test.sh:
# touching it selects that test, never a widen for want of an
# ac-maintenance-lib.test.sh.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-maintenance-lib.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-maintenance-lib.sh's test must still be green"
assert_contains "$out" "RUNNING ac-maintenance-core.test.sh" "ac-maintenance-lib.sh maps to ac-maintenance-core.test.sh"
assert_contains "$out" "3/3 passed" "ac-maintenance-lib.sh selects exactly ac-maintenance-core.test.sh plus the guards"
git -C "$splitrepo" checkout -q -- bin/ac-maintenance-lib.sh

# 2) touching bin/ac-teardown.sh alone selects its colocated leg AND its
#    split-name black-box test - the colocated name must not shadow the split.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-teardown.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-teardown.sh's split test must still be green"
assert_contains "$out" "RUNNING ac-teardown.test.sh" "ac-teardown.sh's split map must select its own ac-teardown.test.sh"
assert_contains "$out" "RUNNING ac-spawn-teardown.test.sh" "ac-teardown.sh's split map must select ac-spawn-teardown.test.sh"
assert_contains "$out" "4/4 passed" "must select exactly the two mapped tests plus the guards, not widen"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-teardown.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
  *"has no colocated test"*) fail "ac-teardown.sh must not print the false widen reason once its split-name map exists" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-teardown.sh

# touching bin/ac-brief.sh alone selects its colocated leg AND
# ac-contract.test.sh, which holds the escalation gate's black box.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-brief.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-brief.sh's split tests must still be green"
assert_contains "$out" "RUNNING ac-brief.test.sh" "ac-brief.sh's split map must select its own ac-brief.test.sh"
assert_contains "$out" "RUNNING ac-contract.test.sh" "ac-brief.sh's split map must select ac-contract.test.sh"
assert_contains "$out" "4/4 passed" "must select exactly the two mapped tests plus the guards, not widen"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-brief.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
  *"has no colocated test"*) fail "ac-brief.sh must not print the false widen reason once its split-name map exists" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-brief.sh

# touching bin/ac-know.sh alone selects its colocated leg AND
# flag-values.test.sh, which executes the entry's value-flag refusal.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-know.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-know.sh's split tests must still be green"
assert_contains "$out" "RUNNING ac-know.test.sh" "ac-know.sh's split map must select its own ac-know.test.sh"
assert_contains "$out" "RUNNING flag-values.test.sh" "ac-know.sh's split map must select flag-values.test.sh"
assert_contains "$out" "3/3 passed" "must select exactly the two mapped tests plus the guards, not widen"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-know.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
  *"has no colocated test"*) fail "ac-know.sh must not print the false widen reason once its split-name map exists" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-know.sh

# touching bin/ac-gate.sh alone selects its colocated leg AND
# ac-learn-loop.test.sh, which runs the real gate through `ac-learn.sh run`.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-gate.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-gate.sh's split tests must still be green"
assert_contains "$out" "RUNNING ac-gate.test.sh" "ac-gate.sh's split map must select its own ac-gate.test.sh"
assert_contains "$out" "RUNNING ac-learn-loop.test.sh" "ac-gate.sh's split map must select ac-learn-loop.test.sh"
assert_contains "$out" "4/4 passed" "must select exactly the two mapped tests plus the guards, not widen"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-gate.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
  *"has no colocated test"*) fail "ac-gate.sh must not print the false widen reason once its split-name map exists" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-gate.sh

# touching bin/ac-curate.sh alone selects its colocated leg AND the three
# suites that execute the entry, AND ac-config-surface.test.sh, which greps
# src/curate.ts for the double-keyed snapshot hook.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-curate.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-curate.sh's split tests must still be green"
for t in ac-curate ac-backlog-sections ac-learning-automation-e2e ac-learn-loop ac-config-surface; do
  assert_contains "$out" "RUNNING $t.test.sh" "ac-curate.sh's split map must select $t.test.sh"
done
assert_contains "$out" "6/6 passed" "must select exactly the five mapped tests plus the guards, not widen"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-curate.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
  *"has no colocated test"*) fail "ac-curate.sh must not print the false widen reason once its split-name map exists" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-curate.sh

# touching bin/ac-gate-watch.sh alone selects its colocated leg AND
# ac-gate.test.sh, whose board rows run it, AND ac-watch-dash.test.sh, which
# greps src/gate-watch.ts.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-gate-watch.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-gate-watch.sh's split tests must still be green"
for t in ac-gate-watch ac-gate ac-watch-dash; do
  assert_contains "$out" "RUNNING $t.test.sh" "ac-gate-watch.sh's split map must select $t.test.sh"
done
assert_contains "$out" "5/5 passed" "must select exactly the three mapped tests plus the guards, not widen"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-gate-watch.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
  *"has no colocated test"*) fail "ac-gate-watch.sh must not print the false widen reason once its split-name map exists" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-gate-watch.sh

# touching bin/ac-ship-watch.sh (or bin/ac-qa-watch.sh) alone selects its
# colocated leg, ac-watch-dash.test.sh (the shared body's leg) and its
# opener's suite, which runs it `--once`.
for w in ship qa; do
  printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-$w-watch.sh"
  res="$(run_runner --changed "$splitrepo/tests/sh")"
  rc="${res%%|*}"; out="${res#*|}"
  assert_eq "$rc" "0" "--changed narrowed to ac-$w-watch.sh's split tests must still be green"
  for t in "ac-$w-watch" ac-watch-dash "ac-$w"; do
    assert_contains "$out" "RUNNING $t.test.sh" "ac-$w-watch.sh's split map must select $t.test.sh"
  done
  assert_contains "$out" "5/5 passed" "must select exactly the three mapped tests plus the guards, not widen"
  case "$out" in
    *"RUNNING ac-other.test.sh"*) fail "ac-$w-watch.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
    *"has no colocated test"*) fail "ac-$w-watch.sh must not print the false widen reason once its split-name map exists" ;;
  esac
  git -C "$splitrepo" checkout -q -- "bin/ac-$w-watch.sh"
done

# touching bin/ac-dashboard.sh alone selects the daemon suite, which holds its
# leg, and the two review suites that start and stop real dashboards through
# it - no suite carries the entry's own name.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-dashboard.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-dashboard.sh's split tests must still be green"
for t in ac-dashboard-daemon ac-review ac-review-reply; do
  assert_contains "$out" "RUNNING $t.test.sh" "ac-dashboard.sh's split map must select $t.test.sh"
done
assert_contains "$out" "5/5 passed" "must select exactly the three mapped tests plus the guards, not widen"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-dashboard.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
  *"has no colocated test"*) fail "ac-dashboard.sh must not print the false widen reason once its split-name map exists" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-dashboard.sh

# touching bin/ac-ready.sh alone selects its colocated leg AND the eight
# suites that run the report, queued or watch-set.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-ready.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-ready.sh's split tests must still be green"
for t in ac-ready ac-backlog ac-backlog-sections ac-contract ac-task ac-watch ac-watch-autoarm ac-turnend-guard ac-session-start; do
  assert_contains "$out" "RUNNING $t.test.sh" "ac-ready.sh's split map must select $t.test.sh"
done
assert_contains "$out" "11/11 passed" "must select exactly the nine mapped tests plus the guards, not widen"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-ready.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-ready.sh

# touching bin/ac-learn.sh alone selects its colocated leg, the eight suites
# that execute the entry, AND ac-config-surface.test.sh, which greps
# src/learn.ts for the knobs it reads.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-learn.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-learn.sh's split tests must still be green"
for t in ac-learn ac-learn-loop ac-learn-autoroom ac-learn-quote ac-learning-automation-e2e ac-maintenance-core ac-curate ac-self-task ac-teardown ac-config-surface; do
  assert_contains "$out" "RUNNING $t.test.sh" "ac-learn.sh's split map must select $t.test.sh"
done
assert_contains "$out" "11/11 passed" "must select exactly the ten mapped tests plus the guards, not widen"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-learn.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
  *"has no colocated test"*) fail "ac-learn.sh must not print the false widen reason once its split-name map exists" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-learn.sh

# touching bin/ac-pane-agent.sh alone selects its colocated leg AND the four
# suites that execute the pane agent or import its one-shot table.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-pane-agent.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-pane-agent.sh's split tests must still be green"
for t in ac-pane-agent ac-teardown ac-spawn-teardown ac-brain ac-lib; do
  assert_contains "$out" "RUNNING $t.test.sh" "ac-pane-agent.sh's split map must select $t.test.sh"
done
assert_contains "$out" "7/7 passed" "must select exactly the five mapped tests plus the guards, not widen"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-pane-agent.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
  *"has no colocated test"*) fail "ac-pane-agent.sh must not print the false widen reason once its split-name map exists" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-pane-agent.sh

# touching bin/ac-watch.sh alone selects its colocated leg AND the six suites
# that execute the watcher.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-watch.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-watch.sh's split tests must still be green"
for t in ac-watch ac-watch-jev ac-brain-freshen ac-lock ac-remote-wire ac-roomchief ac-self-task; do
  assert_contains "$out" "RUNNING $t.test.sh" "ac-watch.sh's split map must select $t.test.sh"
done
assert_contains "$out" "9/9 passed" "must select exactly the seven mapped tests plus the guards, not widen"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-watch.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
  *"has no colocated test"*) fail "ac-watch.sh must not print the false widen reason once its split-name map exists" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-watch.sh

# touching bin/ac-watch-policy-hook.sh alone selects the two suites that hold
# and run it - it has no colocated test of its own.
printf '#!/usr/bin/env bash\n# touched\n' >"$splitrepo/bin/ac-watch-policy-hook.sh"
res="$(run_runner --changed "$splitrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed narrowed to ac-watch-policy-hook.sh's split tests must still be green"
for t in ac-guard ac-harness-hooks; do
  assert_contains "$out" "RUNNING $t.test.sh" "ac-watch-policy-hook.sh's split map must select $t.test.sh"
done
assert_contains "$out" "4/4 passed" "must select exactly the two mapped tests plus the guards, not widen"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "ac-watch-policy-hook.sh's split map must not widen to the unrelated ac-other.test.sh" ;;
  *"has no colocated test"*) fail "ac-watch-policy-hook.sh must not print the false widen reason once its split-name map exists" ;;
esac
git -C "$splitrepo" checkout -q -- bin/ac-watch-policy-hook.sh

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
assert_contains "$out" "9/9 passed" "must select the six original mapped tests PLUS the new one and the guards, not silently miss it"
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
# src/pth.ts has no entry of its own: two scripts run modes of it.
printf 'export const p = 1;\n' >"$tsrepo/src/pth.ts"
# The long tail after the starting line is the bash ac-qa.sh's shape: a pipe that
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

# --- --changed: dashboard/*.ts selects the suites that run the dashboard -----
#
# The dashboard's Bun tests run through tests/sh/dashboard.test.sh, the real
# app.ts boots under the ac-dashboard.sh split-map suites, and
# ac-contract.test.sh runs lib.ts's backlog-contract twin. A changed Bun test
# beside the modules selects its wrapper alone, as tests/ts/*.test.ts does.
dashrepo="$TMP/fixture-changed-dashboard"
mkdir -p "$dashrepo/dashboard" "$dashrepo/tests/sh"
git -C "$dashrepo" init -q
git -C "$dashrepo" config user.email test@test
git -C "$dashrepo" config user.name test
printf 'export const a = 1;\n' >"$dashrepo/dashboard/app.ts"
printf 'import { a } from "./app.ts";\n' >"$dashrepo/dashboard/app.test.ts"
for t in dashboard ac-contract ac-dashboard-daemon ac-review ac-review-reply ac-other; do
  printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\npass\n' "$ROOT" >"$dashrepo/tests/sh/$t.test.sh"
done
chmod +x "$dashrepo"/tests/sh/*.test.sh
git -C "$dashrepo" add -A
git -C "$dashrepo" commit -q -m baseline

printf 'export const b = 2;\n' >>"$dashrepo/dashboard/app.ts"
res="$(run_runner --changed "$dashrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed on a dashboard/*.ts change must still be green"
for t in dashboard ac-contract ac-dashboard-daemon ac-review ac-review-reply; do
  assert_contains "$out" "RUNNING $t.test.sh" "a dashboard module change must select $t.test.sh"
done
assert_contains "$out" "5/5 passed" "a dashboard module change must select exactly the dashboard's suites"
case "$out" in
  *"RUNNING ac-other.test.sh"*) fail "a dashboard module change must not select the unrelated ac-other.test.sh" ;;
esac
git -C "$dashrepo" checkout -q -- dashboard/app.ts

printf '// touched\n' >>"$dashrepo/dashboard/app.test.ts"
res="$(run_runner --changed "$dashrepo/tests/sh")"
rc="${res%%|*}"; out="${res#*|}"
assert_eq "$rc" "0" "--changed on a dashboard/*.test.ts change must still be green"
assert_contains "$out" "RUNNING dashboard.test.sh" "a changed dashboard Bun test must select its wrapper"
assert_contains "$out" "1/1 passed" "a changed dashboard Bun test must select only its wrapper"
git -C "$dashrepo" checkout -q -- dashboard/app.test.ts

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
until grep -q sleep < <(ps -o comm= -p "$cpid" 2>/dev/null); do
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

# The repair path: a runner started as an async command (job control off)
# inherits INT/QUIT ignored and re-execs through python3, which starts with
# PIPE/XFSZ ignored itself. A trap on a signal ignored at entry is silently
# refused, so each trap probe exits 42 only when its signal is at default.
reexecdir="$TMP/fixture-reexec"
mkdir -p "$reexecdir"
cp "$sigdir/int-kills-child.test.sh" "$reexecdir/"
cat >"$reexecdir/dispositions.test.sh" <<'FIXTURE'
#!/usr/bin/env bash
yes | head -1 >/dev/null; st="${PIPESTATUS[0]}"
[ "$st" = 141 ] || { printf 'FAIL: yes exited %s on a closed pipe - SIGPIPE is ignored\n' "$st" >&2; exit 1; }
( trap 'exit 42' QUIT; sh -c 'kill -QUIT $PPID'; : ); st=$?
[ "$st" = 42 ] || { printf 'FAIL: QUIT trap probe exited %s - SIGQUIT is ignored\n' "$st" >&2; exit 1; }
big="$(mktemp)"
( trap 'exit 42' XFSZ; ulimit -f 1; printf '%65536s' x >"$big" ) 2>/dev/null; st=$?
rm -f "$big"
[ "$st" = 42 ] || { printf 'FAIL: XFSZ trap probe exited %s - SIGXFSZ is ignored\n' "$st" >&2; exit 1; }
printf 'PASS: dispositions.test.sh\n'
FIXTURE
set +e
out="$(env -u AC_SUITE_INT_REPAIRED bash -c 'bash "$1" "$2" & wait "$!"' _ "$RUNNER" "$reexecdir" 2>&1)"; rc=$?
set -e
if command -v python3 >/dev/null 2>&1; then
  assert_contains "$out" "re-execing with the disposition reset" "an async runner must take the python3 repair path"
  assert_eq "$rc" "0" "a re-execed runner must hand every suite default INT/QUIT/PIPE/XFSZ: $out"
  assert_contains "$out" "2/2 passed" "both disposition fixtures must pass under the re-execed runner"
else
  assert_eq "$rc" "3" "an async runner with no python3 must refuse"
fi

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

# --- a suite never reads the runner's terminal ------------------------------
#
# Each suite runs as its own job (set -m); one that reads stdin from a
# terminal is stopped by SIGTTIN and the runner waits on it for ever - the
# Learning gate runs the suite in a pane, so a pty stands in for it here.
# script(1) takes the command as trailing argv on BSD/macOS but only as -c on
# util-linux, and each form is refused by the other.
ttydir="$TMP/fixture-tty"
mkdir -p "$ttydir"
printf '#!/usr/bin/env bash\n. "%s/tests/sh/helpers.sh"\nread -r _ || true\npass\n' "$ROOT" >"$ttydir/reads.test.sh"
if script -q /dev/null true </dev/null >/dev/null 2>&1; then
  script -q "$TMP/tty.typescript" bash "$RUNNER" "$ttydir" </dev/null >/dev/null 2>&1 &
else
  script -q -c "bash $(printf '%q ' "$RUNNER" "$ttydir")" "$TMP/tty.typescript" </dev/null >/dev/null 2>&1 &
fi
ttyjob=$!
for _ in $(seq 1 100); do kill -0 "$ttyjob" 2>/dev/null || break; sleep 0.2; done
if kill -0 "$ttyjob" 2>/dev/null; then
  pkill -KILL -f "$ttydir" 2>/dev/null || true
  kill -KILL "$ttyjob" 2>/dev/null || true
  fail "a suite reading stdin under a terminal must not stop the runner (SIGTTIN)"
fi
wait "$ttyjob" 2>/dev/null || true
assert_contains "$(cat "$TMP/tty.typescript")" "1/1 passed" "the suite that read stdin ran to its verdict"

pass
