#!/usr/bin/env bash
# stress.sh - prove a timing-sensitive test deterministic by running it N times
# on a deliberately contended box. A green single run on an idle machine is not
# evidence: ac-roomchief.test.sh passed 15/24 on pristine main and 24/24 once
# fixed, and only the loaded reruns could tell those apart.
#
# NOT part of the suite - the suite globs tests/*.test.sh, and this is opt-in
# verification. It is also the ONLY sanctioned way to generate load in this
# repo: it borrows helpers.sh's load harness, so every hog it starts is reaped
# on EXIT (including a failing run and SIGTERM) and self-limits via AC_HOG_TTL
# if the run is killed outright. Hand-rolled `while :; do :; done &` is what
# orphaned 77 busy loops (~760% CPU, ~48min); do not reintroduce it.
#
# Usage: tests/stress.sh <test-file> [runs=20] [parallel=4] [hogs=6]
#   AC_HOG_TTL=<secs>    hog lifetime (default 300) - raise it for long runs.
#   AC_STRESS_LOAD1=<n>  override the measured 1-min load (tests inject it).
#
# HOST BUDGET (captain.md 2026-07-16). Reaping bounds the aftermath; it never
# bounded the BLAST. This box carries other families, so the harness:
#   - REFUSES to start when the 1-min load already exceeds cores/2;
#   - never runs more than cores/2 hogs, whatever the caller asked for;
#   - runs them at the lowest priority (a courtesy - the CAP is the count);
#   - cannot run past a hard 600s deadline, watchdog included in the reap.
#
# Exits 0 only when every run passed AND no hog survived. Exits 2 on refusal.

. "$(dirname "$0")/helpers.sh"

t="${1:-}"
if [ -z "$t" ] || [ ! -f "$t" ]; then
  printf 'usage: tests/stress.sh <test-file> [runs=20] [parallel=4] [hogs=6]\n' >&2
  exit 2
fi
runs="${2:-20}"
par="${3:-4}"
hogs="${4:-6}"

# --- host budget (see header) --------------------------------------------------
cores="$(sysctl -n hw.ncpu 2>/dev/null || printf 2)"
half=$(( cores / 2 )); [ "$half" -ge 1 ] || half=1
load1="${AC_STRESS_LOAD1:-$(sysctl -n vm.loadavg 2>/dev/null | awk '{print $2}')}"
case "${load1%%.*}" in
  ''|*[!0-9]*)
    printf 'refusing: 1-min load unreadable (%s) - cannot verify the host is not already carrying other work\n' \
      "$load1" >&2
    exit 2 ;;
esac
if [ "${load1%%.*}" -gt "$half" ]; then
  printf 'refusing: 1-min load %s already over %s (cores/2 of %s) - the host is carrying other work\n' \
    "$load1" "$half" "$cores" >&2
  exit 2
fi
[ "$hogs" -le "$half" ] || {
  printf 'capping hogs %s -> %s: never more than half of %s cores\n' "$hogs" "$half" "$cores" >&2
  hogs="$half"
}

out="$TMP/runs"
mkdir -p "$out"

# The fan-out runs need reaping too: without this a SIGTERM here orphans every
# in-flight `bash <test>` to ppid=1 - the same class as the hog incident, and
# with no TTL to bound it. Chains cleanup (which reaps the hogs) rather than
# adding a second EXIT trap, since bash keeps one handler per signal.
#
# Killing the recorded pid is NOT enough and was measured leaving 4 orphans:
# the pid is the SUBSHELL, and `bash <test>` is its child, which survives it.
# `set -m` at spawn puts each job in its OWN process group, so `kill -- -PID`
# takes the whole run down with it.
#
# KNOWING GAP, decided not overlooked: this path has no test. Pinning it means
# signalling a live fan-out mid-flight and racing the reap, which makes a new
# flake source inside a flake-FIXING harness - it would cost more than it
# defends. Verified by hand instead: 4 orphans before, 0 after.
runpids=""
kill_runs() {
  local p
  for p in $runpids; do kill -9 -- -"$p" 2>/dev/null || true; done
  cleanup
}
trap kill_runs EXIT

# Hard deadline. macOS has no timeout(1), so this is the watchdog: it TERMs us,
# which runs the EXIT trap above and reaps everything - a self-kill would not.
# It is a spawn like any other, so it goes on runpids and dies with the rest.
set -m
( sleep 600; kill -TERM "$$" 2>/dev/null || true ) &
set +m
runpids="$runpids $!"

load_hogs "$hogs"
printf 'stress: %s x%s, parallel %s, under %s hogs (AC_HOG_TTL=%ss)\n' \
  "$(basename "$t")" "$runs" "$par" "$hogs" "$AC_HOG_TTL"

i=0
while [ "$i" -lt "$runs" ]; do
  batch=0
  pids=""
  while [ "$batch" -lt "$par" ] && [ "$i" -lt "$runs" ]; do
    i=$((i + 1))
    # `set +e` is what makes a red run COUNTABLE: helpers.sh sets errexit, the
    # subshell inherits it, and a failing test would abort the subshell BEFORE
    # the printf - no .rc file, so the tally silently counted only the runs
    # that passed. A stress harness that cannot report failure is decoration.
    set -m   # own process group per job, so kill_runs can take the whole run
    ( set +e; bash "$t" >"$out/$i.log" 2>&1; printf '%s\n' "$?" >"$out/$i.rc" ) &
    set +m
    pids="$pids $!"
    runpids="$runpids $!"
    batch=$((batch + 1))
  done
  for p in $pids; do wait "$p" 2>/dev/null || true; done
done

ok=0
bad=0
for f in "$out"/*.rc; do
  [ -f "$f" ] || continue
  if [ "$(cat "$f")" = 0 ]; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
done

# Every run must have landed in exactly one column. This is the invariant that
# would have caught the errexit bug above on sight: a lost .rc showed up as
# neither a pass nor a fail, and the tally still read green.
[ "$(( ok + bad ))" = "$runs" ] || fail "stress accounting lost runs: $ok pass + $bad fail != $runs"

printf '=== %s pass, %s fail (of %s) ===\n' "$ok" "$bad" "$runs"
# `|| true` is load-bearing: with runs red but no log carrying ^FAIL - a crash,
# an OOM kill, an unbound var, exactly what stress exists to surface - grep
# exits 1, pipefail promotes it past the trailing sort, and errexit aborted the
# script HERE, skipping the reap and the survivor gate below.
[ "$bad" = 0 ] || grep -h '^FAIL' "$out"/*.log 2>/dev/null | sort | uniq -c | sort -rn || true

# Zero survivors is part of the harness, not a habit the caller must remember -
# and the count is MEASURED after the reap, never a literal.
reap_hogs
left="$(hog_survivors)"
printf 'hogs: %s survivors\n' "$left"
assert_no_hogs "stress run must leave no hog behind"

[ "$bad" = 0 ]
