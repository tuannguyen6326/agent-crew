#!/usr/bin/env bash
# helpers.test.sh - helpers.sh: the fleet-env isolation rung (case 8), the
# fail-closed sourcing rung (case 9), and the load harness - a hog is reaped on
# every EXIT path a test can actually take - a clean exit, a FAILING assert, SIGTERM,
# and a caller that installs its OWN EXIT trap over ours - and when nothing can
# run at all (SIGKILL), AC_HOG_TTL still bounds the orphan.
#
# The regression this pins: ad-hoc `while :; do :; done &` load orphaned 77
# busy loops (~760% CPU, ~48min) because cleanup never reached them.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# Case 6 SIGKILLs a child on purpose, so that child's own cleanup CANNOT run and
# its temp home would leak once per run of this file - a test about not leaking
# that leaks. macOS mktemp -d ignores $TMPDIR (verified), so the home cannot be
# nested inside ours; instead each child publishes its $TMP and we sweep them.
# The sweep chains cleanup rather than adding a second trap - the same shape the
# six tmux tests use, and the seam this file exists to pin.
child_tmps=""
sweep_children() {
  local d
  for d in $child_tmps; do [ -z "$d" ] || rm -rf "$d"; done
  cleanup
}
trap sweep_children EXIT

# A child that sources the real helpers, spawns 2 hogs, publishes their pids and
# its temp home, then leaves by <mode>. `override` reproduces the shape of the
# six test files that install their own EXIT trap after sourcing helpers.
cat >"$TMP/child.sh" <<CHILD
#!/usr/bin/env bash
. "$ROOT/tests/helpers.sh"
mode="\$1"; pidfile="\$2"
if [ "\${3:-}" = override ]; then
  kill_tmux() { cleanup; }
  trap kill_tmux EXIT
fi
load_hogs 2
printf '%s\n' "\$TMP" >"\$pidfile.tmpdir"
printf '%s\n' "\$_ac_hogs" >"\$pidfile"
printf '%s\n' "\$(hog_survivors)" >"\$pidfile.alive"
case "\$mode" in
  clean)   : ;;
  failing) fail "deliberate failure" ;;
  # 'wait' is a builtin: holding on it spawns no extra process, so a SIGKILLed
  # hold leaves ONLY the hogs to be judged - never a stray sleep of our own.
  hold)    : >"\$pidfile.ready"; wait ;;
esac
CHILD
chmod +x "$TMP/child.sh"

alive_count() {
  # alive_count <pidfile> - how many of the child's hogs are still running.
  local p n=0 pids
  pids="$(cat "$1")"
  # shellcheck disable=SC2086 # deliberate split: the file holds a pid list
  for p in $pids; do
    kill -0 "$p" 2>/dev/null && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

wait_all_dead() {
  # wait_all_dead <pidfile> <deadline-secs> - poll until every hog is gone.
  local deadline=$(( $(date +%s) + $2 ))
  while [ "$(alive_count "$1")" != 0 ]; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.1
  done
}

wait_ready() {
  # wait_ready <pidfile> <deadline-secs> - poll until the child publishes its
  # `.ready` marker; 1 when the deadline passes first. Bounded on purpose, the
  # same shape as wait_all_dead above: the child runs under helpers.sh's errexit
  # and its spawn discards stderr, so anything that kills it before the publish
  # is SILENT - and an unbounded poll then spins for as long as the suite lives,
  # because tests/run-suite.sh has no per-test timeout on this host to cut it off.
  local deadline=$(( $(date +%s) + $2 ))
  while [ ! -f "$1.ready" ]; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 0.05
  done
}

note_child_tmp() {
  # note_child_tmp <pidfile> - remember a child's home so the sweep gets it even
  # when the child was killed before its own cleanup could run.
  child_tmps="$child_tmps $(cat "$1.tmpdir" 2>/dev/null)"
}

assert_child_spawned() {
  # assert_child_spawned <pidfile> - the POSITIVE CONTROL. Every case below is
  # "no hog is alive afterwards", which a child that spawned NOTHING satisfies
  # perfectly: without this they cannot tell a working reap from an empty run.
  # .alive is measured inside the child, before anything could reap it.
  assert_eq "$(wc -w <"$1" | tr -d ' ')" "2" "child published 2 hog pids (${1##*/})"
  assert_eq "$(cat "$1.alive" 2>/dev/null)" "2" "child's hogs were ALIVE pre-reap (${1##*/})"
}

# --- 1. the hogs are real ------------------------------------------------------

# A hog that does not load the box is not a hog; one that forks per iteration is
# a fork storm, not CPU load.
load_hogs 2
# shellcheck disable=SC2086 # deliberate split: _ac_hogs is a space-joined pid list
set -- $_ac_hogs
assert_eq "$#" "2" "load_hogs records one pid per hog"
assert_eq "$(hog_survivors)" "2" "hog_survivors counts the live hogs"
[ -z "$(pgrep -P "$1" 2>/dev/null)" ] || fail "a hog must not fork children (SECONDS, not a date fork)"
reap_hogs
assert_no_hogs "reap_hogs kills what load_hogs spawned"
assert_eq "$_ac_hogs" "" "reap_hogs clears the record"

# reap_hogs is idempotent and safe with nothing spawned - cleanup calls it on
# every EXIT, including tests that never generate load.
reap_hogs
assert_no_hogs "reap_hogs on an empty record is a no-op"

# Zero means zero. BSD seq counts DOWN over an empty range - `$(seq 1 0)` is
# "1 0" - so the seq form spawned TWO hogs for load_hogs 0, loading a box that
# asked for no load at all.
load_hogs 0
assert_eq "$(hog_survivors)" "0" "load_hogs 0 spawns nothing"

# The reap KILLS; it does not wait for the TTL. 60s is comfortably past every
# deadline in this file (the longest is 15s), so a helper that had quietly
# become "spawn and let them expire" cannot pass this - while still bounding
# what a SIGKILL landing in this window could orphan. A 3000s probe would prove
# the same thing and hand the backstop a 50-minute orphan to prove it.
AC_HOG_TTL=60 load_hogs 2
reap_hogs
assert_no_hogs "reap_hogs kills immediately, independent of AC_HOG_TTL"

# --- 2. a CLEAN exit reaps -----------------------------------------------------

bash "$TMP/child.sh" clean "$TMP/p1"
note_child_tmp "$TMP/p1"
assert_child_spawned "$TMP/p1"
wait_all_dead "$TMP/p1" 5 || fail "clean exit left $(alive_count "$TMP/p1") hog(s) alive"

# --- 3. a FAILING assert reaps -------------------------------------------------

# The path that leaked in practice: `fail` exits 1, and a reap that only ran on
# success would strand every hog of every red run.
if bash "$TMP/child.sh" failing "$TMP/p2" 2>/dev/null; then
  fail "the failing child must exit non-zero"
fi
note_child_tmp "$TMP/p2"
assert_child_spawned "$TMP/p2"
wait_all_dead "$TMP/p2" 5 || fail "failing assert left $(alive_count "$TMP/p2") hog(s) alive"

# --- 4. a caller's OWN EXIT trap still reaps -----------------------------------

# bash keeps ONE handler per signal, so the six tmux tests' `trap kill_tmux EXIT`
# REPLACES helpers' trap. They all chain cleanup, which is exactly why the reap
# lives there and not in a second trap of its own.
bash "$TMP/child.sh" clean "$TMP/p3" override
note_child_tmp "$TMP/p3"
assert_child_spawned "$TMP/p3"
wait_all_dead "$TMP/p3" 5 || fail "a caller's EXIT trap override left $(alive_count "$TMP/p3") hog(s) alive"

# --- 5. SIGTERM reaps ----------------------------------------------------------

bash "$TMP/child.sh" hold "$TMP/p4" >/dev/null 2>&1 &
child_pid=$!
wait_ready "$TMP/p4" 15 || fail "the held child never published readiness (it died before it could)"
note_child_tmp "$TMP/p4"
assert_child_spawned "$TMP/p4"
kill -TERM "$child_pid" 2>/dev/null || true
wait "$child_pid" 2>/dev/null || true
wait_all_dead "$TMP/p4" 5 || fail "SIGTERM left $(alive_count "$TMP/p4") hog(s) alive"

# --- 6. SIGKILL cannot reap - the TTL does -------------------------------------

# No trap can catch SIGKILL, so layer 1 is structurally unable to cover a killed
# or timed-out run. The hog's own AC_HOG_TTL is what bounds the orphan, and this
# is the assertion that keeps a future `while :; do :; done` from creeping back.
AC_HOG_TTL=2 bash "$TMP/child.sh" hold "$TMP/p5" >/dev/null 2>&1 &
child_pid=$!
wait_ready "$TMP/p5" 15 || fail "the TTL child never published readiness (it died before it could)"
note_child_tmp "$TMP/p5"
assert_child_spawned "$TMP/p5"
kill -KILL "$child_pid" 2>/dev/null || true
wait "$child_pid" 2>/dev/null || true
# Orphaned by construction: the parent died without running anything.
wait_all_dead "$TMP/p5" 15 || fail "AC_HOG_TTL did not reap a SIGKILLed run's hogs: $(alive_count "$TMP/p5") alive"

# --- 7. a reap that cannot kill must not lie -----------------------------------

# Fault injection for the vacuous-gate bug: reap_hogs used to clear _ac_hogs
# unconditionally, and hog_survivors reads _ac_hogs - so a reap that killed
# nothing still left every assert_no_hogs true. `wait` is stubbed too:
# un-neutered it blocks on the live hogs for the whole AC_HOG_TTL.
AC_HOG_TTL=5 load_hogs 2
# shellcheck disable=SC2329 # invoked indirectly: these shadow the builtins reap_hogs calls
kill() { :; }
# shellcheck disable=SC2329
wait() { :; }
set +e
reap_hogs 2>/dev/null
rc=$?
set -e
unset -f kill wait
assert_eq "$rc" "0" "reap_hogs returns 0 even when its kill does nothing"
assert_eq "$(printf '%s' "$_ac_hogs" | wc -w | tr -d ' ')" "2" \
  "a survivor STAYS on the record for the gate to see"
reap_hogs
assert_no_hogs "the real reap clears them"

# --- 7b. the readiness wait cases 5 and 6 depend on is BOUNDED -----------------

# Cases 5 and 6 background a child and wait for it to publish `.ready`. That
# wait used to be a bare `until [ -f ... ]; do sleep 0.05; done` with no
# deadline and no liveness check - and the child runs under helpers.sh's
# `set -e` with its stderr discarded by the spawn, so ANY failure before it
# reaches the publish (a fork the host cannot serve under contention, a failing
# mktemp) killed it silently and left this file spinning for ever. Nothing above
# it bounds that: tests/run-suite.sh has no per-test timeout here
# (no timeout/gtimeout - run-suite.sh:153-159), so one dead child hangs the WHOLE
# suite. Measured 2026-07-25 on the real shape: the child was already reaped
# (kill -0 said no) while the poll was still spinning 600 iterations later.
# The bound is the same shape wait_all_dead above already uses.
readiness_start="$(date +%s)"
set +e
wait_ready "$TMP/never-published" 1
readiness_rc=$?
set -e
# rc is asserted EXACTLY, never merely "non-zero": an `if wait_ready ...` reads
# a missing function's 127 as a clean refusal and the case passes vacuously.
assert_eq "$readiness_rc" "1" "wait_ready gives up on a marker that is never written"
# 10s of slack on a 1s deadline: the claim is BOUNDED-not-infinite, so the
# margin is deliberately far wider than any scheduling delay - a tight bound
# here would be the load-flaky assertion this file exists to keep out.
[ "$(( $(date +%s) - readiness_start ))" -le 10 ] \
  || fail "wait_ready must give up on its own deadline, not spin for the life of the suite"

# --- 8. the fleet env of the pane running the suite never reaches a test -------

# The suite is most often run from a crewmate/roomchief/crewchief pane, whose
# launch line ac-spawn.sh prefixes with AC_FLEET_MODEL/AC_FLEET_EFFORT (a
# roomchief carries AC_SCOPE, and the watchers a chief arms carry
# AC_WATCH_ONLY/AC_WATCH_SKIP). Every one of those is a FALLBACK or a refusal
# some script under test reads - ac-pane-agent.sh takes its model/effort from
# the fleet knobs, ac-watch.sh refuses a skip naming a foreign family - so an
# inherited value silently decides what the fixture asserts, or reds it
# outright. Sourced in a child, because our own copy was scrubbed at line 1.
iso="$(AC_SCOPE=fam AC_WATCH_ONLY=fam AC_WATCH_SKIP=fam \
  AC_FLEET_MODEL=opus AC_FLEET_EFFORT=xhigh \
  AC_FLEET_MODEL_CODEREVIEW=haiku AC_FLEET_MODEL_QA=haiku \
  AC_FLEET_PROFILE_CODEREVIEW=x AC_FLEET_PROFILE_QA=x AC_FLEET_PROFILE_SOMETHINGELSE=x \
  AC_FLEET_HOME_CHECKED=1 AC_FLEET_PROJECT_CONFIG=/tmp/some-project.yaml \
  bash -c '. "$1/tests/helpers.sh"
    printf "%s %s %s %s %s %s %s %s %s %s %s %s\n" "${AC_SCOPE-unset}" "${AC_WATCH_ONLY-unset}" \
      "${AC_WATCH_SKIP-unset}" "${AC_FLEET_MODEL-unset}" "${AC_FLEET_EFFORT-unset}" \
      "${AC_FLEET_MODEL_CODEREVIEW-unset}" "${AC_FLEET_MODEL_QA-unset}" \
      "${AC_FLEET_PROFILE_CODEREVIEW-unset}" "${AC_FLEET_PROFILE_QA-unset}" \
      "${AC_FLEET_PROFILE_SOMETHINGELSE-unset}" "${AC_FLEET_HOME_CHECKED-unset}" \
      "${AC_FLEET_PROJECT_CONFIG-unset}"' \
    _ "$ROOT")"
assert_eq "$iso" "unset unset unset unset unset unset unset unset unset unset unset unset" \
  "sourcing helpers.sh scrubs the pane's fleet env (scope, watch scope, fleet knobs, PROFILE_* by prefix - including an unlisted pane kind - plus HOME_CHECKED/PROJECT_CONFIG)"

# --- 9. fail-closed sourcing: a suite run outside tests/ aborts, never pushes --

# `. "$(dirname "$0")/helpers.sh"` no-ops when the file is not next to $0, so a
# suite copied elsewhere ran with errexit unarmed and every helper var EMPTY -
# and its `git -C "" push origin main` fixture then hit the REAL repo (incident
# 2026-07-20). Every suite that pushes now aborts instead. Proven from a
# throwaway cwd repo, so a REGRESSION here damages the sandbox, never the fleet.
sandbox="$TMP/outside"
mkdir -p "$sandbox"
git init -q -b main "$sandbox/live"
git -C "$sandbox/live" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
for suite in ac-spawn-teardown ac-ship ac-sync; do
  cp "$ROOT/tests/$suite.test.sh" "$sandbox/$suite.copy.sh"
  out="$(cd "$sandbox/live" && bash "$sandbox/$suite.copy.sh" 2>&1)" \
    && fail "$suite must refuse to run outside tests/"
  assert_contains "$out" "run this suite from tests/" "$suite says why it refused"
done
assert_eq "$(git -C "$sandbox/live" rev-list --count HEAD)" "1" \
  "the refused runs committed nothing into the cwd repo"

# Completeness, cheaply: the behavioral proof above covers three suites; this
# grep is what keeps the OTHER 57 from regressing - a suite that sources
# helpers.sh unguarded fails HERE instead of in the operator's fleet home.
# shellcheck disable=SC2016 # the pattern is literal: it must NOT expand here
unguarded="$(grep -l '^\. "\$(dirname "\$0")/helpers\.sh"$' "$ROOT"/tests/*.test.sh || true)"
[ -z "$unguarded" ] || fail "unguarded helpers.sh sourcing in: $unguarded"

# --- 10. assert_fails_with distinguishes a refusal from a crash (F52) ---------

# A CRASH input: dies on an unbound variable under `set -u`, before it ever
# reaches a guard - it never prints a refusal reason. This is the shape
# repo-knowledge:97 audited (a broken PATH finds no bash and the script never
# runs); an unbound-variable death is the same "crashed before the guard"
# class without needing a second stub binary to build it.
crash_script="$TMP/f52-crash.sh"
cat >"$crash_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "$AC_F52_UNSET_VAR_NEVER_DECLARED"
EOF
chmod +x "$crash_script"

# A REAL refusal: exits non-zero AND names the reason.
refuse_script="$TMP/f52-refuse.sh"
cat >"$refuse_script" <<'EOF'
#!/usr/bin/env bash
printf 'refusing: bad input\n' >&2
exit 1
EOF
chmod +x "$refuse_script"

# assert_fails cannot tell them apart - both a crash and a real refusal pass
# it identically. Documented status quo (repo-knowledge:97); still true here
# because assert_fails itself is untouched by this change.
assert_fails "$crash_script"
assert_fails "$refuse_script"

# assert_fails_with pins the REASON, so the SAME crash input it just accepted
# as "assert_fails" is REJECTED here for naming no reason at all - run in a
# subshell because a rejection calls fail(), which exits.
crash_rc=0
( assert_fails_with "refusing: bad input" -- "$crash_script" ) >/dev/null 2>&1 || crash_rc=$?
assert_eq "$crash_rc" "1" \
  "assert_fails_with rejects the crash: same input assert_fails just accepted, opposite verdict"

# ...while ACCEPTING the real refusal that prints the expected reason.
assert_fails_with "refusing: bad input" -- "$refuse_script"

# The `--` separator is required, not optional punctuation.
sep_rc=0
( assert_fails_with "refusing: bad input" "$refuse_script" ) >/dev/null 2>&1 || sep_rc=$?
assert_eq "$sep_rc" "1" "assert_fails_with requires the -- separator before the command"

# An empty expected substring must be REFUSED, not silently vacuous: assert_contains
# matches ANY output on an empty needle, which would let a caller whose reason
# variable came up empty degrade assert_fails_with back into plain assert_fails
# and accept the very crash F52 exists to reject.
empty_rc=0
( assert_fails_with "" -- "$crash_script" ) >/dev/null 2>&1 || empty_rc=$?
assert_eq "$empty_rc" "1" "assert_fails_with refuses an empty expected substring"

# --- 11a. run_on_tty RETURNS instead of hanging (suite-pty-hang) --------------

# Xcode python3.9's stdlib pty.spawn wedges FOREVER after the child exits: its
# pty._copy is `while True` (not the `while fds:` of bpo-26228, fixed in 3.10),
# so once /dev/null stdin AND the pty master both EOF, both are dropped from the
# watch set and it calls select([],[],[]) with no fds and no timeout, which
# never returns on macOS - the child has already exited but waitpid is never
# reached, so tests/run-suite.sh hung indefinitely on ac-qa/ac-ship/helpers.
# run_on_tty now forks the pty itself and terminates on master EOF. This case is
# BOUNDED (background + polled deadline, the wait_ready shape - NOT an external
# `timeout` this host may lack) so the pre-fix hang surfaces as a timeout
# FAILURE here rather than an infinite spin of the whole suite. It runs BEFORE
# case 11's unbounded calls on purpose: pre-fix, the first run_on_tty to run is
# the one that must fail cleanly, not hang the file.
tty_rc_file="$TMP/tty-return-rc"
# `|| rc=$?` so the child's non-zero exit records its status instead of tripping
# helpers.sh's errexit and killing this subshell before the rc is written (which
# would make the poll below time out on a fix that actually returns).
( rc=0; run_on_tty bash -c 'exit 7' || rc=$?; printf '%s\n' "$rc" >"$tty_rc_file.tmp"; mv "$tty_rc_file.tmp" "$tty_rc_file" ) &
tty_pid=$!
tty_deadline=$(( $(date +%s) + 10 ))
while [ ! -f "$tty_rc_file" ]; do
  if [ "$(date +%s)" -ge "$tty_deadline" ]; then
    # Pre-fix, the child is already a zombie and only the python parent is live;
    # kill it (and the backgrounding subshell) so the failing run leaks nothing.
    pkill -KILL -P "$tty_pid" 2>/dev/null || true
    kill -KILL "$tty_pid" 2>/dev/null || true
    fail "run_on_tty hung past its 10s bound instead of returning (the suite-pty-hang regression)"
  fi
  sleep 0.1
done
wait "$tty_pid" 2>/dev/null || true
assert_eq "$(cat "$tty_rc_file")" "7" "run_on_tty returns the child's exit status without hanging"

# --- 11. run_on_tty distinguishes a signal death from success (F55) ----------

# A child that kills ITSELF with SIGTERM under the real pty. `status >> 8`
# reads this as exit 0 (the low byte carries the signal number, the high byte
# stays 0), so a test subject killed by a signal read as a pass.
rc=0
run_on_tty bash -c 'kill -TERM $$' >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "143" \
  "run_on_tty reports a signal death as 128+signum (SIGTERM=15), never exit 0"

# A clean exit, and an ordinary non-zero exit, still report their own status
# untouched - the three call sites (ac-ship.test.sh x2, ac-qa.test.sh) depend
# on an ordinary `exit 1` still reading as rc 1, not on the decode changing it.
rc=0
run_on_tty bash -c 'exit 0' >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "run_on_tty still reports a clean exit 0 untouched"

rc=0
run_on_tty bash -c 'exit 1' >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "run_on_tty still reports an ordinary exit 1 untouched"

# --- 12. the fake herdr refuses an unmodeled verb and names it (F53) ----------

make_fake_herdr

# Control FIRST: a modeled verb still dispatches exactly as before. Without it,
# a guard that swallowed the whole `case` would pass the refusal check below
# while breaking every other test in the suite.
rc=0
herdr --session s1 tab list >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "a modeled verb still dispatches"

# An unmodeled verb must be REFUSED, not "succeed" with empty output. `pane run`
# is the real instance, not a hypothetical: bin/ac-pane-agent.sh:1085 issues it
# against the backend, and this fake models no arm for it.
rc=0
out="$(herdr --session s1 pane run p1 somecmd 2>&1)" || rc=$?
assert_eq "$rc" "2" "an unmodeled verb is refused, never a silent success"

# ...and the refusal NAMES the verb. A bare non-zero would leave a test author
# hunting which of the composed call's parts the fake could not answer.
assert_contains "$out" "pane run p1 somecmd" "the refusal names the verb it could not model"

# --- 13. assert_contains refuses an empty needle (F56) ------------------------

# `case "$1" in *""*)` matches ANY haystack, so an assert whose needle is a
# computed variable that came up empty passed vacuously - proving nothing while
# reading green. Subshell because a refusal calls fail(), which exits.
empty_needle_rc=0
( assert_contains "some haystack" "" ) >/dev/null 2>&1 || empty_needle_rc=$?
assert_eq "$empty_needle_rc" "1" "assert_contains refuses an empty needle"

# Both directions of the ordinary path are untouched: a needle that IS present
# still passes, and one that is genuinely absent still fails. Without the second
# of these, a guard that refused everything would satisfy the check above.
assert_contains "some haystack" "hay"
absent_rc=0
( assert_contains "some haystack" "no-such-needle" ) >/dev/null 2>&1 || absent_rc=$?
assert_eq "$absent_rc" "1" "assert_contains still fails on a needle that is genuinely absent"

# --- 14. hold gates: a holder never outlives its run --------------------------
# (watch-test-wedges-and-orphans-its-runner)

# The regression, measured rather than reasoned: tests/ac-watch.test.sh stood in
# for a live lock owner with `( read -r _ <fifo ) & ... : >fifo`, and a run that
# died INSIDE that block - a FAIL, a set -e abort, a kill - left the holder
# blocked in open(2) FOREVER, because unlinking the fifo does not wake a blocked
# open. The orphan is a FORK of the runner, so `ps` renders it with the runner's
# own argv and it inherits the runner's stdout: a captured or piped run then
# never saw the FAIL line and never EOFed. One such holder was found alive
# 1 day 6 hours after its run, ppid=1, no children, holding only its cwd.

# Positive control FIRST: every case below is "the holder is gone", which a
# hold_open that spawned NOTHING satisfies perfectly.
hold_open g1; g1pid=$HOLD_PID
kill -0 "$g1pid" 2>/dev/null || fail "hold_open must publish a LIVE holder pid"
[ -z "$(pgrep -P "$g1pid" 2>/dev/null)" ] || fail "a holder blocks; it must not fork (no sleep, no polling)"
hold_close g1 "$g1pid"
printf '%s\n' "$g1pid" >"$TMP/h0"
wait_all_dead "$TMP/h0" 5 || fail "hold_close left its holder alive"

# THE DEFECT ITSELF: a run that dies inside the block must not leave a holder
# behind. The child publishes the pid from inside, before anything could reap it.
cat >"$TMP/holdchild.sh" <<CHILD
#!/usr/bin/env bash
. "$ROOT/tests/helpers.sh"
hold_open gate
printf '%s\n' "\$HOLD_PID" >"\$1"
printf '%s\n' "\$TMP" >"\$1.tmpdir"
fail "injected: the run dies inside the hold-gate block"
CHILD
if AC_HOLD_TTL=1 bash "$TMP/holdchild.sh" "$TMP/h1" >"$TMP/h1.out" 2>&1; then
  fail "the child must exit non-zero - it fails inside the block"
fi
note_child_tmp "$TMP/h1"
assert_contains "$(cat "$TMP/h1.out")" "injected:" "the child died for the injected reason, not another"
wait_all_dead "$TMP/h1" 10 \
  || fail "a run that died inside the block left its holder alive - the orphan that wedged a captured run"

# A gate whose stand-in is already GONE must be a named failure, never a silent
# pass: every assertion after it was judging a dead pid. Released with NO poll in
# between, which is what the seven real call sites do - and the trap in it: an
# exited-but-unreaped child still answers `kill -0` (8 of 8 immediate polls
# measured), so a liveness probe passes exactly here, while the recorded exit
# status cannot lie. In a child because the refusal calls fail(), which exits.
cat >"$TMP/holdgone.sh" <<CHILD
#!/usr/bin/env bash
. "$ROOT/tests/helpers.sh"
hold_open gate
printf '%s\n' "\$TMP" >"\$1.tmpdir"
kill -9 "\$HOLD_PID"
hold_close gate "\$HOLD_PID"
printf 'NOT REACHED\n'
CHILD
if bash "$TMP/holdgone.sh" "$TMP/h2" >"$TMP/h2.out" 2>&1; then
  fail "hold_close must refuse a gate whose stand-in is already gone"
fi
note_child_tmp "$TMP/h2"
assert_contains "$(cat "$TMP/h2.out")" "hold gate 'gate' expired" "the refusal NAMES the gate"
case "$(cat "$TMP/h2.out")" in
  *'NOT REACHED'*) fail "hold_close returned instead of refusing" ;;
esac

pass
