#!/usr/bin/env bash
# ac-lock.test.sh - per-home session lock: acquire/status/release, live
# foreign-holder refusal, stale recovery, AC_SCOPE skip, the fleet watcher
# owner gate, and the session-start READ-ONLY path under a foreign lock.
# AC_LOCK_PID pins the detected session pid so every case is deterministic.
#
# FIXTURE ISOLATION (mandatory - this test acquires/recovers/refuses a REAL
# session lock and arms the fleet watcher, so an un-isolated run would maul the
# operator's live fleet). Two guarantees keep every op inside a throwaway:
#  - HOME: every lock/watcher op runs under helpers.sh's throwaway AC_HOME
#    ($TMP/home, exported at SOURCE time - before line `state=` below - and
#    removed in the EXIT trap), so `state="$AC_HOME/state"` and every
#    ac-lock.sh/ac-watch.sh invocation touch the fixture home, NEVER the
#    operator's real $AC_HOME/state/.session-lock or its live watcher.
#  - PROCESSES: every live fixture the test spawns (the FOREIGN holder, the
#    race session holders) is a NON-EXPIRING fifo-blocked reader reaped by its
#    RECORDED pid in the EXIT trap. Never a `sleep N`: a holder that outlived
#    its interval would free its pid for reuse, and the EXIT-trap kill could
#    then SIGTERM a process OUTSIDE the fixture (plausibly a real watcher). No
#    pattern kills - only recorded pids.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
state="$AC_HOME/state"
lockf="$state/.session-lock"

# fifo_hold <fifo> <ttl-secs> - background a fifo-blocked holder that is BOTH
# bounded and stdout-detached, and print its pid.
#
# Two failure modes, and this file needed a shape that closes both. The one
# that wedges a CALLER: an orphaned holder inherits the runner's stdout, so it
# holds the caller's capture pipe open for as long as it lives - a red run then
# hangs its caller even though the runner has exited (measured by the sibling
# family at @b7c3dc4). The one that wedges the RUN: no bound at all, so a
# holder whose release path never fires blocks forever.
#
# tests/helpers.sh hold_open closes both, and this file CANNOT use it - that is
# measured, not assumed. hold_open bounds the wait by opening the fifo
# READ-WRITE (`exec 3<>fifo`), which is the only form that bounds, because
# `read -r -t N _ <fifo` bounds the READ and not the OPEN (a plain `<fifo`
# blocks in open() until a writer arrives; a holder was measured still alive 2s
# past a 1s TTL). But a read-write holder is also a WRITER, so the gate never
# reaches EOF when the release path closes it - and this file's release paths
# are built on exactly that EOF. Converting these sites to hold_open wedged the
# suite outright (no progress past the spare-gate cases against a 22s green).
#
# So the bound comes from OUTSIDE the holder instead: the holder keeps its
# plain read-only `<fifo` open, semantics untouched, and a detached watchdog
# kills it after <ttl>. The watchdog never touches the fifo, so nothing about
# EOF or reader-count changes; it only guarantees the holder cannot outlive the
# run. Both processes redirect their own output, so neither can hold a caller's
# pipe.
#
# TTLs are set from the measured green runtime of this file (22s), not copied
# from the sibling's 90: a gate held for one case takes 60s (~40x the longest
# real hold here), and the FOREIGN holder - which must survive the WHOLE file
# by design - takes 300s, an order of magnitude over the run so a loaded box
# cannot expire the live foreign pid every later case depends on.
fifo_hold() {
  local fifo="$1" ttl="$2" h
  ( read -r _ <"$fifo" ) >/dev/null 2>&1 &
  h=$!
  ( sleep "$ttl"; kill -9 "$h" 2>/dev/null || true ) >/dev/null 2>&1 &
  printf '%s\n' "$h"
}

# A live process that is not this test: the "other chief session". A
# fifo-blocked reader (blocks in open() for want of a writer), so it stays
# alive for the WHOLE test - never expiring like a `sleep N` whose freed pid
# could be reused, then TERMed out-of-fixture by the EXIT-trap kill. Reaped by
# its recorded pid below. Bounded well past the run (see fifo_hold): a holder
# that outlives a crashed runner is the leak this file is being hardened
# against, and "it dies with the trap" is only true when the trap runs.
FOREIGN_HOLD="$TMP/foreign.hold"
mkfifo "$FOREIGN_HOLD"
FOREIGN="$(fifo_hold "$FOREIGN_HOLD" 300)"
kill_foreign() { kill "$FOREIGN" 2>/dev/null || true; wait "$FOREIGN" 2>/dev/null || true; cleanup; }
trap kill_foreign EXIT

# A provably dead pid for stale-recovery cases.
sh -c 'exit 0' &
DEAD=$!
wait "$DEAD" 2>/dev/null || true

# acquire + status.
out="$(AC_LOCK_PID=$$ "$BIN/ac-lock.sh" acquire)"
assert_contains "$out" "lock: acquired (pid $$)" "first acquire"
assert_file "$lockf" "lock file written"
assert_contains "$(AC_LOCK_PID=$$ "$BIN/ac-lock.sh" status)" "held pid=$$ since" "status shows live holder"

# Re-acquire by the holder is idempotent.
assert_contains "$(AC_LOCK_PID=$$ "$BIN/ac-lock.sh" acquire)" "already held" "holder re-acquire"

# RE-ENTRANCY: the same session re-entering through a child shell that detects a
# DIFFERENT pid than the recorded holder - live cause: a tool-call subshell whose
# argv carries a harness token (`... --harness claude ...`) matches the harness
# regex, so the ancestry walk answers with that transient shell instead of the
# harness that took the lock. AC_LOCK_HARNESS_RE pins that divergence here
# (nothing matches -> the nearest stable ancestor, never this test shell). The
# recorded holder is an ANCESTOR of the acquiring process, so it is this
# session's own lock and acquire must pass, not refuse it as foreign.
rc=0; out="$(AC_LOCK_HARNESS_RE='ac-no-such-harness' "$BIN/ac-lock.sh" acquire 2>/dev/null)" || rc=$?
assert_eq "$rc" "0" "ancestor holder acquire is not refused"
assert_contains "$out" "already held by this session (pid $$" "ancestor holder re-acquires"
# release asks the same identity question and must answer it the same way.
out="$(AC_LOCK_HARNESS_RE='ac-no-such-harness' "$BIN/ac-lock.sh" release 2>/dev/null)"
assert_contains "$out" "lock: released" "ancestor holder releases"
# The other side of that check, with the ancestry walk ENABLED (AC_LOCK_PID
# pins identity exactly, so the cases below it never reach the walk): a LIVE
# holder outside this process's ancestry is still foreign, still refused.
printf 'pid=%s\nsince=2026-01-01T00:00:00Z\n' "$FOREIGN" >"$lockf"
rc=0; out="$(AC_LOCK_HARNESS_RE='ac-no-such-harness' "$BIN/ac-lock.sh" acquire 2>&1)" || rc=$?
assert_eq "$rc" "2" "non-ancestor live holder still refused"
assert_contains "$out" "another chief session owns this home (pid $FOREIGN since" "refusal wording unchanged"
rm -f "$lockf"
AC_LOCK_PID=$$ "$BIN/ac-lock.sh" acquire >/dev/null

# A second session against a LIVE holder is refused with exit 2.
rc=0; out="$(AC_LOCK_PID=$FOREIGN "$BIN/ac-lock.sh" acquire 2>&1)" || rc=$?
assert_eq "$rc" "2" "foreign acquire exits 2"
assert_contains "$out" "another chief session owns this home (pid $$ since" "refusal names the holder"

# Only the holder releases.
rc=0; AC_LOCK_PID=$FOREIGN "$BIN/ac-lock.sh" release >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "foreign release refused"
assert_contains "$(AC_LOCK_PID=$$ "$BIN/ac-lock.sh" release)" "lock: released" "holder release"
assert_no_file "$lockf" "lock gone after release"
assert_contains "$(AC_LOCK_PID=$$ "$BIN/ac-lock.sh" status)" "unlocked" "status unlocked"

# Stale recovery: a dead holder is recovered with a printed notice.
printf 'pid=%s\nsince=2026-01-01T00:00:00Z\n' "$DEAD" >"$lockf"
assert_contains "$(AC_LOCK_PID=$$ "$BIN/ac-lock.sh" status)" "stale pid=$DEAD" "status flags dead holder"
out="$(AC_LOCK_PID=$$ "$BIN/ac-lock.sh" acquire)"
assert_contains "$out" "recovering stale lock (pid $DEAD dead" "stale notice"
assert_contains "$out" "lock: acquired (pid $$)" "stale lock recovered"
AC_LOCK_PID=$$ "$BIN/ac-lock.sh" release >/dev/null

# F10 (repo-deep-review): a recorded pid that is ALIVE but whose CURRENT
# command no longer matches the IDENTITY FINGERPRINT recorded at acquire
# time (pid reuse after an unclean session end) must read STALE, not
# "another chief session owns this home" - bare ac_pid_alive used to wedge
# every acquire until a human deleted the lock, and silently inerted both
# Stop hooks (they classify the true chief session as read-only and exit 0
# SILENTLY on that refusal). FOREIGN is genuinely alive throughout this
# case; only the FINGERPRINT MISMATCH is what must flip the verdict.
printf 'pid=%s\nsince=2026-01-01T00:00:00Z\ncmd=a-process-that-is-no-longer-here\n' "$FOREIGN" >"$lockf"
kill -0 "$FOREIGN" 2>/dev/null || fail "FOREIGN must be genuinely alive for this case to mean anything"
assert_contains "$(AC_LOCK_PID=$$ "$BIN/ac-lock.sh" status)" "stale pid=$FOREIGN" \
  "a live pid whose command no longer matches its fingerprint reads stale, not held"
out="$(AC_LOCK_PID=$$ "$BIN/ac-lock.sh" acquire)"
assert_contains "$out" "recovering stale lock (pid $FOREIGN alive but a DIFFERENT process now" \
  "a reused pid is recovered, distinguished from a genuinely dead one"
assert_contains "$out" "lock: acquired (pid $$)" "acquire succeeds past the reused pid"
AC_LOCK_PID=$$ "$BIN/ac-lock.sh" release >/dev/null

# Reap gate exclusivity, deterministic (no load, no concurrency, one process).
# The gate's contract (ac-lock.sh:68-76) documents a RESIDUAL: a reap dir that
# already exists (e.g. leaked by a reaper SIGKILLed between its mkdir/rmdir)
# must make stale recovery REFUSE, never reap around it. Pre-create the reap
# dir so mkdir fails every attempt: with the gate this spins to max_attempts
# and refuses with the corpse untouched; drop the gate and the reap runs
# unconditionally, acquiring at once instead. A categorical difference the
# race section below can only sample - this one proves it every single run.
printf 'pid=%s\nsince=2026-01-01T00:00:00Z\n' "$DEAD" >"$lockf"
mkdir "$lockf.reap"
rc=0; out="$(AC_LOCK_PID=$$ "$BIN/ac-lock.sh" acquire 2>&1)" || rc=$?
assert_eq "$rc" "2" "leaked reap dir: acquire refuses instead of reaping around the gate"
assert_contains "$out" "did not settle after" "leaked reap dir: did-not-settle diagnostic"
assert_contains "$(cat "$lockf")" "pid=$DEAD" "leaked reap dir: corpse left untouched on disk"
rm -rf "$lockf.reap" "$lockf"

# AC_SCOPE set: skip notice, exit 0, no lock written.
out="$(AC_SCOPE=widget AC_LOCK_PID=$$ "$BIN/ac-lock.sh" acquire)"
assert_contains "$out" "skipped" "scoped-session skip notice"
assert_no_file "$lockf" "scoped session never locks"

# Fleet watcher owner gate: a live foreign holder refuses the arm.
AC_LOCK_PID=$FOREIGN "$BIN/ac-lock.sh" acquire >/dev/null
rc=0; out="$(AC_LOCK_PID=$$ AC_HEARTBEAT=0 AC_POLL=1 "$BIN/ac-watch.sh" 2>/dev/null)" || rc=$?
assert_eq "$rc" "2" "fleet watcher refused under a foreign lock"
assert_contains "$out" "refused: fleet watcher not armed" "refusal reason line"

# Scoped watcher (AC_WATCH_ONLY) is exempt from the owner gate.
out="$(AC_WATCH_ONLY=widget AC_LOCK_PID=$$ AC_HEARTBEAT=0 AC_POLL=1 "$BIN/ac-watch.sh")"
assert_contains "$out" "heartbeat" "scoped watcher arms under a foreign lock"

# READ-ONLY session start under the foreign lock: banner printed, wake-drain
# skipped, queued wakes left untouched, still exits 0.
mkdir -p "$state/.wake-spool"
printf '9\treport\tt1\tdone: x\n' >"$state/.wake-spool/9.1.000000"
rc=0; out="$(AC_LOCK_PID=$$ "$BIN/ac-session-start.sh" 2>&1)" || rc=$?
assert_eq "$rc" "0" "read-only session start exits 0"
assert_contains "$out" "READ-ONLY: another chief session owns this fleet" "read-only banner"
assert_contains "$out" "wake-drain skipped" "drain skipped in read-only"
assert_file "$state/.wake-spool/9.1.000000" "queued wakes untouched in read-only"
rm -f "$state/.wake-spool"/*

# Holder session start: acquires the lock and drains wakes normally.
AC_LOCK_PID=$FOREIGN "$BIN/ac-lock.sh" release >/dev/null
out="$(AC_LOCK_PID=$$ "$BIN/ac-session-start.sh" 2>&1)"
assert_contains "$out" "lock: acquired (pid $$)" "session start takes the lock"
assert_contains "$out" "no queued wakes" "wake-drain ran"

# Fleet watcher arms for the holder and records the owner pid.
out="$(AC_LOCK_PID=$$ AC_HEARTBEAT=0 "$BIN/ac-watch.sh" 2>/dev/null)"
assert_contains "$out" "heartbeat" "holder fleet watcher arms"
assert_eq "$(cat "$state/.watcher-owner")" "$$" "owner beacon records the holder pid"

# ... and RE-ENTRANTLY for the same session reached through a child shell whose
# detected pid differs from the recorded holder (the arm-after-spawn refusal,
# 2026-07-20): an ANCESTOR-held home is this session's own, never another's.
rc=0
out="$(AC_LOCK_HARNESS_RE='ac-no-such-harness' AC_HEARTBEAT=0 "$BIN/ac-watch.sh" 2>/dev/null)" || rc=$?
assert_eq "$rc" "0" "re-entrant fleet arm exits 0"
assert_contains "$out" "heartbeat" "ancestor-held home arms the fleet watcher"
case "$out" in
  *"another session owns this home"*) fail "re-entrant fleet arm refused as foreign" ;;
esac

# --- SPARE WORKER: self_pid() must not resolve identity to a rotating daemon
# spare worker (session-lock-claims-daemon-spare-worker brief, recorded
# 2026-07-22 evidence: a bg-spare's argv literally starts with a harness
# token - `claude bg-spare --bg-spare /tmp/cc-daemon-<uid>/<id>/spare/<x>.cl` -
# so the ancestry walk answers with that TRANSIENT worker instead of the
# long-lived ancestor above it). Spares ROTATE, so the fix must resolve the
# SAME stable ancestor across two DIFFERENT spare pids, not merely dodge one.
#
# A real bg-spare process cannot be reproduced live on this host (verified:
# no /tmp/cc-daemon-* dir and no bg-spare process exist here, matching the
# brief's own 2026-07-27 check). An exec-a-renamed real process turned out to
# be a genuine but NON-DETERMINISTIC repro instead (a transient fork/exec race
# in nested command substitution intermittently shifts which pid the walk
# matches - verified live, repeated runs, on this host). A deterministic
# PATH-stubbed `ps` is used instead, SO DECLARED: it fakes only the ancestry
# ABOVE the real acquiring process; the acquiring process itself is 100% real
# (a live, fifo-gated fork that execs into ac-lock.sh, so self_pid()'s own
# `$$` and its own command line are genuine, never faked).
# DISPUTED: whether self_pid() treats a bg-spare-shaped ancestor as the
# harness match. HELD-CONSTANT: a real acquiring process (real $$, real own
# command line), the default AC_LOCK_HARNESS_RE, no AC_LOCK_PID, a real
# unlocked lock file.
rm -f "$lockf"
sparebin="$TMP/sparebin"
mkdir -p "$sparebin"
cat >"$sparebin/wrapper.sh" <<EOF
#!/usr/bin/env bash
# Blocks on its gate (real, live, fifo-blocked - never a sleep) so the test
# can finish configuring the ps stub for this EXACT real pid before release,
# then execs into ac-lock.sh acquire AS THIS SAME PID (exec never changes
# \$\$) - self_pid()'s own identity stays 100% real.
#
# This one cannot use fifo_hold: it must EXEC as this same pid, so the holder
# and the thing under test are one process. The bound is therefore a watchdog
# this process kills ITSELF before exec'ing - fired only while we are still the
# wrapper, so it can never reach the ac-lock.sh run (or, after it exits, a
# recycled pid).
( sleep 60; kill -9 \$\$ 2>/dev/null ) >/dev/null 2>&1 &
_wd=\$!
# The read's STATUS is deliberately ignored: the release path closes the gate
# with no newline, so EOF must still acquire (a bare `|| exit 0` here breaks
# the spare-A case - measured).
read -r _ <"\$1"
kill "\$_wd" 2>/dev/null || true
exec "$BIN/ac-lock.sh" acquire
EOF
chmod +x "$sparebin/wrapper.sh"

psbin="$TMP/psbin"
mkdir -p "$psbin"
oldpath="$PATH"
PATH="$psbin:$PATH"

gateA="$TMP/spare-gate-a"; gateB="$TMP/spare-gate-b"
mkfifo "$gateA" "$gateB"
outA="$TMP/spare-out-a"; outB="$TMP/spare-out-b"
"$sparebin/wrapper.sh" "$gateA" >"$outA" 2>&1 & realA=$!
"$sparebin/wrapper.sh" "$gateB" >"$outB" 2>&1 & realB=$!
spare_cleanup() {
  kill "$realA" "$realB" 2>/dev/null || true
  wait "$realA" "$realB" 2>/dev/null || true
  kill_foreign
}
trap spare_cleanup EXIT

spareA=$(( $$ + 600001 ))
spareB=$(( $$ + 600002 ))
stable=$(( $$ + 600099 ))
cat >"$psbin/ps" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "-o ppid= -p $realA") printf ' %s\n' "$spareA" ;;
  "-o command= -p $spareA") printf 'claude bg-spare --bg-spare /tmp/cc-daemon-501/a/spare/x.cl\n' ;;
  "-o ppid= -p $spareA") printf ' %s\n' "$stable" ;;
  "-o ppid= -p $realB") printf ' %s\n' "$spareB" ;;
  "-o command= -p $spareB") printf 'claude bg-spare --bg-spare /tmp/cc-daemon-501/b/spare/x.cl\n' ;;
  "-o ppid= -p $spareB") printf ' %s\n' "$stable" ;;
  "-o command= -p $stable") printf 'faketrueharness --stable\n' ;;
  "-o ppid= -p $stable") printf ' 1\n' ;;
  *) exec /bin/ps "\$@" ;;
esac
EOF
chmod +x "$psbin/ps"

printf x >"$gateA"
wait "$realA" 2>/dev/null || true
res1="$(cat "$outA")"
printf x >"$gateB"
wait "$realB" 2>/dev/null || true
res2="$(cat "$outB")"
PATH="$oldpath"
rm -f "$gateA" "$gateB"

assert_contains "$res1" "lock: acquired (pid $stable)" "spare A: self_pid() resolves through (skips) the bg-spare ancestor to the stable one above it"
assert_contains "$res2" "already held by this session (pid $stable" "spare B (rotated to a DIFFERENT spare pid): self_pid() resolves to the SAME stable ancestor as spare A"
rm -f "$lockf"

# --- FALSE-SKIP GUARD: the spare exclusion above must be ANCHORED to the
# spare token appearing directly after the harness token - a bare substring
# match would also skip a REAL harness whose argv merely CONTAINS "bg-spare"
# elsewhere (e.g. a path segment), falling through past it (chief-verify
# finding, repro'd live: an unanchored match fell through a fake harness
# ancestor `claude --permission-mode auto /Users/x/Work/bg-spare-notes/repo`
# to a shared `herdr server` ancestor above it - every pane's ancestry
# contains that shared pid, so two different chief sessions would both
# detect it and both believe they own the home: a SILENT double-driver, the
# exact failure this whole fix must never trade a visible refusal for).
# DISPUTED: whether self_pid() still matches a harness whose argv merely
# contains "bg-spare" as an unrelated substring. HELD-CONSTANT: a real
# acquiring process, the default AC_LOCK_HARNESS_RE, no AC_LOCK_PID, a real
# unlocked lock file.
rm -f "$lockf"
oldpath="$PATH"
PATH="$psbin:$PATH"
gateC="$TMP/spare-gate-c"
mkfifo "$gateC"
outC="$TMP/spare-out-c"
"$sparebin/wrapper.sh" "$gateC" >"$outC" 2>&1 & realC=$!
fh_cleanup() {
  kill "$realC" 2>/dev/null || true
  wait "$realC" 2>/dev/null || true
  kill_foreign
}
trap fh_cleanup EXIT

fakeharness=$(( $$ + 600201 ))
cat >"$psbin/ps" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "-o ppid= -p $realC") printf ' %s\n' "$fakeharness" ;;
  "-o command= -p $fakeharness") printf 'claude --permission-mode auto /Users/x/Work/bg-spare-notes/repo\n' ;;
  *) exec /bin/ps "\$@" ;;
esac
EOF
chmod +x "$psbin/ps"

printf x >"$gateC"
wait "$realC" 2>/dev/null || true
res3="$(cat "$outC")"
PATH="$oldpath"
rm -f "$gateC"

assert_contains "$res3" "lock: acquired (pid $fakeharness)" "false-skip guard: a harness whose argv merely contains 'bg-spare' (e.g. in a path) is still matched, not skipped as a spare"
rm -f "$lockf"

# --- OUTERMOST MATCH: a Claude Stop hook fires several
# levels below the session's lock-owning process - hook shell -> claude
# bg-spare -> claude bg-pty-host -> claude -> claude(lock) - so the NEAREST
# harness ancestor is a same-session worker, and first-match handed ownership
# checks the wrong pid. self_pid() must skip every anchored bg-* worker token
# (bg-pty-host was not bg-spare) and answer with the OUTERMOST harness match.
# DISPUTED: which harness ancestor self_pid() answers with when the chain
# holds more than one. HELD-CONSTANT: a real acquiring process (real $$, real
# own command line), the default AC_LOCK_HARNESS_RE, no AC_LOCK_PID, a real
# unlocked lock file, the same ps-stub technique the two legs above declare.
rm -f "$lockf"
oldpath="$PATH"
PATH="$psbin:$PATH"
gateD="$TMP/spare-gate-d"
mkfifo "$gateD"
outD="$TMP/spare-out-d"
"$sparebin/wrapper.sh" "$gateD" >"$outD" 2>&1 & realD=$!
om_cleanup() {
  kill "$realD" 2>/dev/null || true
  wait "$realD" 2>/dev/null || true
  kill_foreign
}
trap om_cleanup EXIT

ptyhost=$(( $$ + 600301 ))
innercl=$(( $$ + 600302 ))
outercl=$(( $$ + 600303 ))
cat >"$psbin/ps" <<EOF
#!/usr/bin/env bash
case "\$*" in
  "-o ppid= -p $realD") printf ' %s\n' "$ptyhost" ;;
  "-o command= -p $ptyhost") printf 'claude bg-pty-host serve\n' ;;
  "-o ppid= -p $ptyhost") printf ' %s\n' "$innercl" ;;
  "-o command= -p $innercl") printf 'claude\n' ;;
  "-o ppid= -p $innercl") printf ' %s\n' "$outercl" ;;
  "-o command= -p $outercl") printf 'claude --permission-mode auto\n' ;;
  "-o ppid= -p $outercl") printf ' 1\n' ;;
  *) exec /bin/ps "\$@" ;;
esac
EOF
chmod +x "$psbin/ps"

printf x >"$gateD"
wait "$realD" 2>/dev/null || true
res4="$(cat "$outD")"
PATH="$oldpath"
rm -f "$gateD"

assert_contains "$res4" "lock: acquired (pid $outercl)" \
  "self_pid() skips the bg-pty-host worker and answers the OUTERMOST harness ancestor, not the inner same-session claude"
rm -f "$lockf"

# --- Concurrent races -------------------------------------------------------
# The atomic claim (link(2), fail-for-loser) and the reap serializer must admit
# EXACTLY ONE winner, deterministically - the outcome rides on kernel atomicity,
# not on timing. Sessions are fifo-blocked readers: LIVE, idle, no sleep, so a
# winner is always observed alive by the losers (which must REFUSE, never steal).
# Bounded and reaped per the host-impact rules; never `jobs -p`.
rm -f "$state/.watcher-owner" "$lockf" "$lockf.reap"
SESS_HOLD="$TMP/sess.hold"
mkfifo "$SESS_HOLD"
# RACE_PIDS records EVERY worker this section spawns (session holders), so every
# exit path can reap them by their OWN pids - never a pattern. reap_race is the
# EXIT backstop; the test also reaps explicitly and asserts zero survivors below.
RACE_PIDS=""
reap_race() {
  local p
  for p in $RACE_PIDS; do kill "$p" 2>/dev/null || true; done
  for p in $RACE_PIDS; do wait "$p" 2>/dev/null || true; done
}
race_survivors() {
  # How many recorded workers are still alive, by pid.
  local p n=0
  for p in $RACE_PIDS; do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done
  printf '%s\n' "$n"
}
race_cleanup() {
  # Supersedes kill_foreign as the EXIT handler: also reaps every worker pid.
  kill "$FOREIGN" 2>/dev/null || true
  wait "$FOREIGN" 2>/dev/null || true
  reap_race
  cleanup
}
trap race_cleanup EXIT

spawn_sessions() {
  # spawn_sessions <n> - start n LIVE session holders and set SESSIONS to their
  # pids. Each is a fifo-blocked reader: alive, idle, no sleep, no busy-loop.
  # MUST run in the caller's shell (never `$(...)`) so the RACE_PIDS append
  # persists AND each holder is a direct child this shell can `wait` on - a
  # command substitution would drop the append and reparent the holders to init.
  local n="$1" i=0 sh_pid
  SESSIONS=""
  while [ "$i" -lt "$n" ]; do
    sh_pid="$(fifo_hold "$SESS_HOLD" 60)"
    SESSIONS="$SESSIONS $sh_pid"
    RACE_PIDS="$RACE_PIDS $sh_pid"
    i=$((i + 1))
  done
}

race_gate_read() {
  # race_gate_read <gate> <fd> <timeout-secs> - read one start token already
  # available on <fd> (the caller already opened it <>$gate); 1 with a loud
  # stderr diagnostic naming <gate> if <timeout-secs> passes with no token.
  # Bounded on purpose: this used to be a bare `read -r _ <&3 || true` with no
  # deadline, so a parent that died - or one that never wrote at all, e.g. an
  # empty $SESSIONS (n=0) below - left a racer waiting for ever, and the
  # parent's own `wait` waited for ever with it. tests/run-suite.sh has no
  # per-test timeout on this host (the same fact b0f0eb1 records), so one dead
  # gate hangs the WHOLE suite. A timeout here is a loud diagnostic, never a
  # silent proceed.
  local gate="$1" fd="$2" timeout="$3"
  read -r -t "$timeout" _ <&"$fd" && return 0
  printf 'race_acquire: gate %s timed out after %ss - no start signal\n' "$gate" "$timeout" >&2
  return 1
}

race_acquire() {
  # race_acquire <resdir> <sess...> - every given LIVE session pid races
  # `ac-lock.sh acquire` on $lockf behind a shared fifo start gate; each writes
  # "<rc>\n<output>" to <resdir>/<sess>. The gate is opened r+w by each racer
  # (never blocks on open) and released by one bulk write (2n tokens so no
  # reader starves) - synchronized and deadlock-free, no sleep.
  #
  # BOTH gate waits are bounded (2026-07-25). The racer's read is bounded by
  # race_gate_read above. The parent's own release write used to be
  # `>"$gate"` - a write-only open that BLOCKS in open() until a reader
  # appears, for ever if every racer died before reaching its own
  # `exec 3<>"$gate"`, and unconditionally for an EMPTY $@ (n=0): the while's
  # redirection still runs that open even when the loop body never executes,
  # with no racer alive to ever become a reader. Fixed the same way the
  # racers already dodge the problem: open the gate r+w (`exec 4<>"$gate"`)
  # instead of write-only, so the open can never block waiting for a reader -
  # a construction that cannot block at all, not a timeout guess.
  local resdir="$1"; shift
  local gate="$resdir/gate.fifo" sess n=0 pids="" i=0
  mkdir -p "$resdir"
  mkfifo "$gate"
  for sess in "$@"; do
    (
      exec 3<>"$gate"
      race_gate_read "$gate" 3 15 || true
      set +e
      out="$(AC_LOCK_PID="$sess" "$BIN/ac-lock.sh" acquire 2>&1)"; rc=$?
      set -e
      printf '%s\n%s\n' "$rc" "$out" >"$resdir/$sess"
    ) &
    pids="$pids $!"
    n=$((n + 1))
  done
  exec 4<>"$gate"
  while [ "$i" -lt $((2 * n)) ]; do printf 'go\n'; i=$((i + 1)); done >&4
  exec 4>&-
  for sess in $pids; do wait "$sess" 2>/dev/null || true; done
  rm -f "$gate"
}

count_results() {
  # count_results <resdir> <pattern> - result files whose body contains <pattern>.
  local resdir="$1" pat="$2" f n=0
  for f in "$resdir"/*; do
    [ -f "$f" ] || continue
    grep -q "$pat" "$f" && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# --- The start gate is BOUNDED: a token that never arrives fails fast, not
# for ever, instead of hanging the whole suite -----------------------------
# race_gate_read used to be a bare `read -r _ <&3 || true` with no deadline:
# if the parent died, or never wrote at all (an empty $SESSIONS races zero
# tokens - see race_acquire's own header), a racer waited for ever and the
# parent's `wait` waited for ever with it. tests/run-suite.sh has no per-test
# timeout here (no timeout/gtimeout - run-suite.sh:153-159), so one dead
# gate hangs the WHOLE suite. This pins the bound so a future edit cannot
# quietly drop it back to an unbounded read.
never_gate="$TMP/never-open.fifo"
mkfifo "$never_gate"
gate_start="$(date +%s)"
rc=0
out="$(exec 3<>"$never_gate"; race_gate_read "$never_gate" 3 1 2>&1)" || rc=$?
assert_eq "$rc" "1" "race_gate_read gives up on a start token that never arrives"
assert_contains "$out" "gate $never_gate timed out" "timeout is a loud diagnostic naming the gate"
# 10s of slack on a 1s deadline - the claim is BOUNDED-not-infinite, so the
# margin is deliberately far wider than any scheduling delay (the same margin
# helpers.test.sh case 7b uses for wait_ready).
[ "$(( $(date +%s) - gate_start ))" -le 10 ] \
  || fail "race_gate_read must give up on its own deadline, not spin for the life of the suite"
rm -f "$never_gate"

# Fresh lock, six racers: exactly one wins, the rest refuse a live holder.
spawn_sessions 6
# shellcheck disable=SC2086 # $SESSIONS is a pid list, word-split on purpose
race_acquire "$TMP/race-fresh" $SESSIONS
assert_eq "$(count_results "$TMP/race-fresh" 'lock: acquired')" "1" "fresh race: exactly one acquired"
assert_eq "$(count_results "$TMP/race-fresh" 'another chief session owns this home')" "5" "fresh race: the other five refused a live holder"
assert_file "$lockf" "fresh race: the winner's lock is on disk"

# Stale lock, two recoverers: the reap serializer lets exactly one recover and
# claim; the other refuses the (now live) winner. No unguarded rm clobbers it.
rm -f "$lockf" "$lockf.reap"
printf 'pid=%s\nsince=2026-01-01T00:00:00Z\n' "$DEAD" >"$lockf"
spawn_sessions 2
# shellcheck disable=SC2086 # $SESSIONS is a pid list, word-split on purpose
race_acquire "$TMP/race-stale" $SESSIONS
assert_eq "$(count_results "$TMP/race-stale" 'lock: acquired')" "1" "stale race: exactly one recoverer won"
assert_eq "$(count_results "$TMP/race-stale" 'another chief session owns this home')" "1" "stale race: the loser refused the live winner"
recov="$(count_results "$TMP/race-stale" 'recovering stale lock')"
# Exactly 1, not merely >=1: the reap gate serializes so only the sole reaper
# ever runs the recover branch (ac-lock.sh:68-76) - a mut-nogate leak lets both
# recoverers reap, tightening this to catch that instead of tolerating it.
assert_eq "$recov" "1" "stale race: exactly one recoverer runs the reap (gate serializes concurrent reaps)"
assert_file "$lockf" "stale race: the winner's lock is on disk"

# Host-impact reap law: reap every spawned worker by its OWN recorded pid and
# prove zero survivors before exit (race_cleanup is only the failure backstop).
reap_race
assert_eq "$(race_survivors)" "0" "every race worker reaped - no orphaned session holders"

pass
