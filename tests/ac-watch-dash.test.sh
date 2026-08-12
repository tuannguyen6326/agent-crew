#!/usr/bin/env bash
# ac-watch-dash.test.sh - the shared body ac-ship-watch.sh and ac-qa-watch.sh
# both source: run.meta reads (ac_meta_get since audit-f4 retired the local
# meta_last copy), the step-table width parameter, the per-role
# active-step detection that must survive the merge (ship counts
# `awaiting_approval` as active, qa does not - repo-deep-review report F28,
# HARD CONSTRAINT 4), and idle_since's use of the portable mtime helper
# instead of raw BSD `stat -f %m` (F47).
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

dash() {
  # dash <body> - run a body with ac-lib.sh + ac-watch-dash.sh sourced,
  # nothing else (mirrors ac-lib.test.sh's `lib` helper).
  bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; . '$BIN/ac-watch-dash.sh'; $1"
}

# --- F47: idle_since must use ac_file_mtime, not raw BSD stat -f %m --------

if grep -q "stat -f %m" "$BIN/ac-watch-dash.sh"; then
  fail "ac-watch-dash.sh must use ac_file_mtime (bin/ac-lib.sh), not raw BSD stat -f %m"
fi

idle_rd="$TMP/idlerd"; mkdir -p "$idle_rd/logs"
printf 'a\n' >"$idle_rd/steps.tsv"
printf 'b\n' >"$idle_rd/logs/run.log"
touch -t 202601010000 "$idle_rd/steps.tsv"
touch -t 202601020000 "$idle_rd/logs/run.log"
got="$(dash "IDLE_EXTRA_FILES=''; idle_since '$idle_rd'")"
want="$(dash "ac_file_mtime '$idle_rd/logs/run.log'")"
assert_eq "$got" "$want" "idle_since picks the newest of steps.tsv/run.log"

# A missing extra file (qa's cases.tsv before the first case lands) must not
# break the max-mtime arithmetic - the old `|| echo 0` fallback, now carried
# by ac_file_mtime's own exit-1-on-unstattable contract.
got="$(dash "IDLE_EXTRA_FILES='cases.tsv'; idle_since '$idle_rd'")"
assert_eq "$got" "$want" "idle_since tolerates a not-yet-existing extra file"

touch -t 202601030000 "$idle_rd/cases.tsv"
got="$(dash "IDLE_EXTRA_FILES='cases.tsv'; idle_since '$idle_rd'")"
want="$(dash "ac_file_mtime '$idle_rd/cases.tsv'")"
assert_eq "$got" "$want" "idle_since picks up a newer extra file (qa's cases.tsv)"

# --- run.meta reads: last value wins on a repeated key ----------------------
# The dash body's own meta_last copy is gone (audit-f4): run.meta reads go
# through ac_meta_get, whose last-write-wins rule this pins from the dash
# context so a reintroduced local reader with different precedence reds here.

mf="$TMP/run.meta"
printf 'outcome=running\noutcome=passed\n' >"$mf"
assert_eq "$(dash "ac_meta_get '$mf' outcome")" "passed" "run.meta reads return the LAST value"
if grep -q "meta_last()" "$BIN/ac-watch-dash.sh" "$BIN/ac-gate-watch.sh"; then
  fail "the local meta_last copies were retired (audit-f4); read metas through ac_meta_get"
fi

# --- render_steps: the one real per-role step-table difference is width ----

steps="$TMP/rd2"; mkdir -p "$steps"
printf 'pin\tcompleted\t0\n' >"$steps/steps.tsv"
out12="$(dash "STEP_WIDTH=12; render_steps '$steps'")"
out18="$(dash "STEP_WIDTH=18; render_steps '$steps'")"
assert_contains "$out12" "$(printf '%-12s' completed)" "qa's step table pads status to 12"
assert_contains "$out18" "$(printf '%-18s' completed)" "ship's step table pads status to 18"

# --- active-step detection: the one real per-role BEHAVIOR difference ------
# (ship counts awaiting_approval as active, qa does not.)

repo="$(make_repo watchdashrepo)"

mk_run() {
  # mk_run <base under repo> <run-id> <outcome> <steps.tsv line>
  local base="$1" id="$2" outcome="$3" line="$4" d
  d="$repo/$base/$id"
  mkdir -p "$d/logs" "$d/findings"
  : >"$d/logs/run.log"
  printf 'outcome=%s\n' "$outcome" >"$d/run.meta"
  printf '%s\n' "$line" >"$d/steps.tsv"
  ln -sfn "$id" "$repo/$base/current"
}

mk_run ".crew/ship" r1 "checks-passed" "$(printf 'review\tawaiting_approval\t0')"
frame="$("$BIN/ac-ship-watch.sh" --repo "$repo" --once)"
case "$frame" in
  *"run finished"*) fail "ship must treat awaiting_approval as ACTIVE, not finished: $frame" ;;
esac

mk_run ".crew/qa" q1 "unverifiable" "$(printf 'review\tawaiting_approval\t0')"
qframe="$("$BIN/ac-qa-watch.sh" --repo "$repo" --once)"
assert_contains "$qframe" "run finished: unverifiable" \
  "qa must NOT treat awaiting_approval as active"

printf 'ok\n'
