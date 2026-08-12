#!/usr/bin/env bash
# ac-done.test.sh - the agent-side completion PUSH (bin/ac-done.sh): a durable
# record in the spool of the scope whose watcher supervises the task, the
# marker dedup stamp that keeps one completion to ONE wake, and the
# wrong-kill guard on the watcher nudge (a dead, reused or non-sleeping
# target is never signalled).
#
# Every case runs ac-done.sh the way a CREWMATE does: with no AC_HOME at all,
# reaching the fleet only through the narrow scalars ac-spawn.sh threads.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
state="$AC_HOME/state"

push() {
  # push <id> <marker> [<scope>] - ac-done.sh as a homeless crewmate runs it.
  env -u AC_HOME -u AC_SCOPE \
    AC_FLEET_STATE="$state" AC_FLEET_SCOPE="${3:-}" \
    "$BIN/ac-done.sh" "$1" "$2"
}

spool_records() { cat "$state/.wake-spool"/* 2>/dev/null || true; }

# --- usage -------------------------------------------------------------------
assert_fails push "" ""
assert_fails env -u AC_HOME AC_FLEET_STATE="$state" "$BIN/ac-done.sh" onlyid

# --- the record: same format, same kind, same drain as the watcher's own -----
out="$(push c1 'done: shipped the widget')"
assert_contains "$out" "c1" "the push names the task it announced"
assert_contains "$(spool_records)" "done: shipped the widget" "the marker is in the record"
drained="$(env -u AC_SCOPE "$BIN/ac-wake-drain.sh")"
assert_contains "$drained" "report c1 done: shipped the widget" \
  "an ordinary drain emits the pushed record like any other wake"

# --- scope: a promoted family's push lands in ITS spool, not the fleet's -----
push f1-t1 'done: family work' f1 >/dev/null
assert_contains "$(cat "$state/.wake-spool.f1"/* 2>/dev/null || true)" "done: family work" \
  "a family-scoped push files for the roomchief that drains it"
assert_eq "$(spool_records)" "" "and never in the fleet spool"
rm -rf "$state"/.wake-spool*

# --- dedup: the push stamps the watcher's OWN marker dedup ------------------
# .seen-<id> is what keeps the poll that later reads the same completion off
# the pane from publishing a SECOND record; the stale .seen-hash-<id> of an
# earlier wake must go with it, or the watcher's re-wake branch would fire on
# the new marker's first poll.
printf 'old-hash\n' >"$state/.seen-hash-c2"
push c2 'blocked: waiting on the captain' >/dev/null
assert_eq "$(cat "$state/.seen-c2")" "blocked: waiting on the captain" \
  "the pushed marker is stamped as seen"
assert_no_file "$state/.seen-hash-c2" "the previous wake's pane-hash discriminator is dropped"

# --- no watcher armed: quiet success, the record still waits in the spool ----
rm -rf "$state"/.wake-spool* "$state"/.watch*.lock.d
out="$(push c3 'done: nobody is watching')"
assert_contains "$out" "no armed watcher" "an unwatched push says so instead of failing"
assert_contains "$(spool_records)" "done: nobody is watching" "the record is durable either way"

# --- the nudge: the watcher's poll sleep ends early --------------------------
# A stand-in whose command line is a watcher's and whose child is the poll
# `sleep` - exactly what poll_wait runs. Killing that child alone ends the
# wait; the stand-in records that it returned.
mkdir -p "$TMP/fakewatch"
flag="$TMP/fakewatch/woke"
cat >"$TMP/fakewatch/ac-watch.sh" <<EOF
#!/usr/bin/env bash
sleep 30 &
wait \$! 2>/dev/null || true
printf 'wait ended\n' >"$flag"
EOF
chmod +x "$TMP/fakewatch/ac-watch.sh"

arm_fake() {
  # arm_fake <lockdir> - run the stand-in and record its pid where ac-watch.sh
  # publishes it, then wait for its sleep child to exist. Every background job
  # here is detached from the suite's stdout: an inherited pipe outlives a
  # failing assert and hangs whatever reads the suite's output.
  bash "$TMP/fakewatch/ac-watch.sh" >/dev/null 2>&1 &
  fake_pid=$!
  mkdir -p "$1"
  printf '%s\n' "$fake_pid" >"$1/pid"
  local i=0
  while [ "$i" -lt 50 ]; do
    [ -n "$(pgrep -P "$fake_pid" 2>/dev/null || true)" ] && return 0
    sleep 0.1; i=$((i + 1))
  done
  fail "the stand-in watcher never started its sleep child"
}

arm_fake "$state/.watch.lock.d"
out="$(push c4 'done: nudge me')"
assert_contains "$out" "nudged" "a live watcher is nudged"
i=0; while [ ! -f "$flag" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
assert_file "$flag" "the nudge ended the watcher's poll wait"
wait "$fake_pid" 2>/dev/null || true
rm -f "$flag"
rm -rf "$state/.watch.lock.d"

# The scoped watcher takes its own lock, so a family push nudges THAT one.
arm_fake "$state/.watch-only-f2.lock.d"
push f2-t1 'done: scoped nudge' f2 >/dev/null
i=0; while [ ! -f "$flag" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
assert_file "$flag" "a family push nudges the family's own scoped watcher"
wait "$fake_pid" 2>/dev/null || true
rm -f "$flag"
rm -rf "$state/.watch-only-f2.lock.d"

# --- wrong-kill guard: a REUSED pid is never signalled -----------------------
# The recorded pid is alive but runs something else entirely (the shape pid
# reuse leaves behind). Killing it would be the sharp edge of this whole
# story, so the command line is confirmed to be a watcher's first.
sleep 30 >/dev/null 2>&1 & victim=$!
mkdir -p "$state/.watch.lock.d"
printf '%s\n' "$victim" >"$state/.watch.lock.d/pid"
out="$(push c5 'done: reused pid')"
assert_contains "$out" "no armed watcher" "a reused pid is treated as no watcher at all"
sleep 0.3
kill -0 "$victim" 2>/dev/null || fail "a reused pid must NEVER be signalled"
kill "$victim" 2>/dev/null || true
wait "$victim" 2>/dev/null || true

# A DEAD recorded pid is the same quiet no-op, and never a failure.
printf '%s\n' "$victim" >"$state/.watch.lock.d/pid"
out="$(push c6 'done: dead pid')"
assert_contains "$out" "no armed watcher" "a dead watcher pid nudges nothing"
assert_contains "$(spool_records)" "done: dead pid" "and the record is still durable"

# --- wrong-kill guard: only the poll SLEEP is a legal target -----------------
# A real watcher busy inside a poll pass has no sleep child; whatever child it
# does have is none of the push's business.
cat >"$TMP/fakewatch/ac-watch.sh" <<'EOF'
#!/usr/bin/env bash
tail -f /dev/null &
wait $! 2>/dev/null || true
EOF
chmod +x "$TMP/fakewatch/ac-watch.sh"
bash "$TMP/fakewatch/ac-watch.sh" >/dev/null 2>&1 & busy_pid=$!
i=0; child=""
while [ "$i" -lt 50 ]; do
  child="$(pgrep -P "$busy_pid" 2>/dev/null || true)"
  [ -n "$child" ] && break
  sleep 0.1; i=$((i + 1))
done
[ -n "$child" ] || fail "the busy stand-in never started its child"
printf '%s\n' "$busy_pid" >"$state/.watch.lock.d/pid"
out="$(push c7 'done: watcher is mid-poll')"
assert_contains "$out" "nothing to nudge" "a watcher with no poll sleep is left alone"
sleep 0.3
kill -0 "$child" 2>/dev/null || fail "a non-sleep child must NEVER be signalled"
kill "$busy_pid" "$child" 2>/dev/null || true
wait "$busy_pid" 2>/dev/null || true
assert_contains "$(spool_records)" "done: watcher is mid-poll" \
  "an un-nudgeable watcher still leaves the record for the next drain"

pass
