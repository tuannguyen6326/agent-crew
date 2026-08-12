#!/usr/bin/env bash
# ac-term-recorder.test.sh - the passive signal-sender recorder.
#
# Five defect classes, no more:
#   1. the PREMISE - a sender whose pid we know must land in the record as
#      si_pid EXACTLY, with its parent chain resolved. If this fails the tool
#      records nothing worth having.
#   2. a second arm must refuse (two recorders = unbounded host impact).
#   3. the documented one-command reap must actually reap, with no orphan and
#      without fabricating a catch record.
#   4. the lifetime cap must expire on its own.
#   5. a STALE pidfile must never be believed on liveness alone - a recycled
#      pid must neither refuse an arm nor be SIGKILLed by the reap.
#
# ISOLATION (lock-test-live-fleet-isolation, absolute): AC_HOME is the fixture
# home helpers.sh made; every process signalled here is one this file started
# itself and is signalled BY PID. Nothing is ever signalled by pattern.

# Fail-closed sourcing: unsourced, errexit is never armed and $AC_HOME is the
# operator's REAL fleet home - abort instead. This file moved out of tests/
# (repo-deep-review F37, the incident it existed for is closed) so
# helpers.sh is a sibling of its OLD location, not this one.
. "$(dirname "$0")/../../tests/helpers.sh" \
  || { printf 'run this from docs/examples/ (tests/helpers.sh not found)\n' >&2; exit 1; }

make_home

recorder="$ROOT/docs/examples/ac-term-recorder.sh"
rec="$AC_HOME/state/.term-recorder.log"
pidfile="$AC_HOME/state/.term-recorder.pid"

wait_for() {
  # wait_for <seconds> <cmd...> - poll until <cmd> succeeds or the bound passes.
  local lim="$1" n=0
  shift
  while [ "$n" -lt "$((lim * 20))" ]; do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.05
    n=$((n + 1))
  done
  return 1
}

# --- 1. the premise: si_pid is the sender's exact pid, chain resolved ---------

AC_RECORDER_TTL=60 "$recorder" >"$TMP/out1" 2>"$TMP/err1" &
armed=$!
# The `arm` line is written only AFTER the handlers are installed, so it is the
# readiness marker: signalling before it would hit the default disposition and
# leave no record at all.
wait_for 30 grep -q '^arm ' "$rec" || fail "recorder never armed (err: $(cat "$TMP/err1"))"
assert_file "$pidfile" "arming writes a pidfile"
rpid="$(cat "$pidfile")"
assert_eq "$rpid" "$armed" "the wrapper execs the binary - one pid, no wrapper left behind"

# A sender whose pid we KNOW, kept alive so the chain has something to walk.
bash -c 'printf "%s\n" "$$" >"$1/sender.pid"; kill -TERM "$2"; sleep 30' _ "$TMP" "$rpid" &
sender=$!
wait_for 20 test -s "$TMP/sender.pid" || fail "sender never published its pid"
spid="$(cat "$TMP/sender.pid")"
assert_eq "$spid" "$sender" "the sender pid the test knows is the sender pid that runs"

wait_for 30 grep -q '^resolve ' "$rec" || fail "recorder never resolved the sender"
wait "$armed" 2>/dev/null || true

sig="$(grep '^signal ' "$rec")"
assert_contains "$sig" "si_pid=$spid" "si_pid is the exact sender pid"
assert_contains "$sig" "signo=15" "the signal number is recorded"
assert_contains "$sig" "self_pid=$rpid" "the recorder records its own pid"
assert_contains "$sig" "si_uid=$(id -u)" "si_uid is recorded"
assert_contains "$sig" "si_code=" "si_code is recorded"

assert_contains "$(grep '^resolve ' "$rec")" "lag_ms=" "resolution latency is recorded"
assert_contains "$(grep '^chain depth=0 ' "$rec")" "$spid" "chain depth 0 is the sender itself"
assert_contains "$(grep '^chain depth=1 ' "$rec")" "$$" "the chain walks to the sender's parent"
assert_contains "$(cat "$rec")" "chain end pid=1" "the chain is walked all the way to init"
assert_contains "$(cat "$TMP/out1")" "caught SIGTERM" "the exit line carries the catch"
assert_contains "$(cat "$TMP/out1")" "si_pid=$spid" "the exit line names the sender"

kill "$sender" 2>/dev/null || true
wait "$sender" 2>/dev/null || true

# --- 2. a second arm refuses, naming the live recorder -----------------------

: >"$rec"
AC_RECORDER_TTL=600 "$recorder" >"$TMP/out2" 2>&1 &
armed2=$!
wait_for 30 grep -q '^arm ' "$rec" || fail "second recorder never armed"

set +e
second="$("$recorder" 2>&1)"
rc=$?
set -e
assert_eq "$rc" "2" "a second arm refuses"
assert_contains "$second" "$armed2" "the refusal names the live recorder's pid"
assert_contains "$second" "stop" "the refusal names the reap command"

# --- 3. the documented reap: no orphan, no fabricated catch ------------------

# Bash announces a background job killed by a signal ("Killed: 9") on the
# shell's own stderr, which no redirection on the commands below can catch -
# it would read like a failure in the suite output. Muted for exactly the two
# lines that reap, then restored.
exec 3>&2 2>/dev/null
set +e
reap="$("$recorder" stop 2>&1)"
reap_rc=$?
# `wait` only on a reap that CLAIMS success: a broken reap leaves the recorder
# alive, and waiting on it would hang this file for the whole TTL instead of
# failing. On that path the test reaps its own child by pid, so a red run
# leaves nothing behind either.
if [ "$reap_rc" = 0 ]; then wait "$armed2" 2>/dev/null; else kill -9 "$armed2" 2>/dev/null; wait "$armed2" 2>/dev/null; fi
set -e
exec 2>&3 3>&-
# Reported only once stderr is back, so a broken reap fails LOUDLY instead of
# dying inside the muted window.
assert_eq "$reap_rc" "0" "the reap succeeds: $reap"
assert_contains "$reap" "$armed2" "the reap names the pid it reaped"
assert_fails kill -0 "$armed2"
assert_no_file "$pidfile" "the reap removes the pidfile"
assert_eq "$(grep -c '^signal ' "$rec" || true)" "0" \
  "the reap does not fabricate a catch record"
# Nothing of the recorder may outlive it: the wrapper exec'd, so the recorded
# pid IS the whole process, and it is gone.
assert_eq "$("$recorder" stop 2>&1 | grep -c 'not running')" "1" \
  "a second reap is a no-op, not an error"

# --- 4. the lifetime cap expires on its own ----------------------------------

: >"$rec"
AC_RECORDER_TTL=2 "$recorder" >"$TMP/out3" 2>&1 &
armed3=$!
wait_for 30 grep -q '^expired ' "$rec" || fail "recorder never expired on its own"
wait "$armed3" 2>/dev/null || true
assert_fails kill -0 "$armed3"
assert_contains "$(cat "$TMP/out3")" "expired" "the exit line reports the expiry"

# --- 5. a STALE pidfile must never be believed on liveness alone -------------
#
# The success path is catch-then-EXIT, so every catch leaves a pidfile behind.
# If that pid is later recycled by an unrelated process, `kill -0` alone would
# make the wrapper refuse a fresh arm against a stranger and SIGKILL it on
# stop. Both consequences are asserted against one innocent process.

sleep 30 &
innocent=$!
printf '%s\n' "$innocent" >"$pidfile"

stale_stop="$("$recorder" stop 2>&1)"
assert_contains "$stale_stop" "not running" "a foreign pid in the pidfile is not a live recorder"
kill -0 "$innocent" 2>/dev/null || fail "stop signalled an unrelated process"

: >"$rec"
printf '%s\n' "$innocent" >"$pidfile"
AC_RECORDER_TTL=2 "$recorder" >"$TMP/out4" 2>&1 &
armed4=$!
wait_for 30 grep -q '^arm ' "$rec" || fail "a foreign pid in the pidfile refused a fresh arm"
kill -0 "$innocent" 2>/dev/null || fail "arming signalled an unrelated process"
wait_for 30 grep -q '^expired ' "$rec" || fail "the recorder armed past a stale pidfile never expired"
wait "$armed4" 2>/dev/null || true

# Same job-control mute as case 3, for the same reason. `wait` on a job killed
# by a signal returns 143, which errexit would turn into a silent abort of this
# whole file - hence the `|| true` on both.
exec 3>&2 2>/dev/null
kill "$innocent" 2>/dev/null || true
wait "$innocent" 2>/dev/null || true
exec 2>&3 3>&-

pass
