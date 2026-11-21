#!/usr/bin/env bash
# helpers.sh - shared test helpers, sourced by every tests/sh/*.test.sh.
# Provides: asserts, an isolated temp AC_HOME, disposable git repos, the load
# harness (load_hogs and friends - see their block below, which is the
# authoritative spec for how a stress run generates and reaps CPU load), and the
# hold gates (hold_open/hold_close - the block below them is likewise the
# authoritative spec for standing in for a live foreign pid).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
BIN="$ROOT/bin"
TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
# Hog reaping is folded IN here rather than given its own `trap ... EXIT`:
# bash keeps ONE handler per signal, and six test files install their own EXIT
# trap after sourcing this file, so a second trap here would be silently
# clobbered. Every one of those six chains cleanup, so this rides them all.
# See the load-harness block for the measurements behind that choice.
#
# The `type` guard is not defensive dressing: this trap is armed HERE, while
# reap_hogs is defined further down, so anything failing in between (set -e)
# would enter cleanup with reap_hogs still unbound - a `command not found`
# that aborts cleanup and leaks $TMP. Verified; the guard keeps the rm.
#
# A suite DECIDES its verdict through pass, skip or fail, and an exit that
# decided nothing is a failure: /bin/bash 3.2 exits with this trap's own status
# after a `set -u` death, and $? reads 0 in here, so a suite that died on an
# unbound variable mid-file used to exit 0 and read PASS to every runner.
AC_SUITE_DECIDED=""
cleanup() {
  local rc=$?
  type reap_hogs >/dev/null 2>&1 && reap_hogs
  rm -rf "$TMP"
  [ -z "$AC_SUITE_DECIDED" ] || return 0
  printf 'FAIL: %s ended before pass, skip or fail (bash 3.2 exits 0 from an unbound variable otherwise)\n' "$(basename "$0")" >&2
  [ "$rc" != 0 ] || rc=1
  exit "$rc"
}
trap cleanup EXIT

# Tests must NEVER see (or touch!) the operator's live fleet: the harness
# exports AC_HOME from .claude/settings.local.json, so an un-isolated test
# would read - or worse, write - the real home. Every test gets a throwaway
# home; call make_home when the test needs data/config seeded.
mkdir -p "$TMP/home/state" "$TMP/home/data" "$TMP/home/records" "$TMP/home/config" "$TMP/home/projects"
printf 'off\n' >"$TMP/home/config/wedge-alarm"
export AC_HOME="$TMP/home"
export AC_SHIP_WATCH=off
# Verified sends (ac-backend.sh) settle AC_SEND_SETTLE seconds around each
# Enter before probing; the fake orca is synchronous, so the suite skips them.
export AC_SEND_SETTLE=0
# The startup-dialog sequence polls an UNOBSERVABLE pane to its budget; a
# fake backend that models neither identity nor dialog must not cost 15s.
export AC_STARTUP_DIALOG_BUDGET=2
# Same hermetic rule for the claude-transcript ARRIVAL probe (ac-lib.sh
# ac_claude_transcript_root): unset, a claude-harness spawn under the fake
# backend would glob the OPERATOR's real ~/.claude/projects looking for a
# session id the fake backend never actually ran - never a match, but still a
# read of live data no test may depend on or leak into. An isolated, always-
# empty root makes every such spawn resolve UNOBSERVABLE deterministically
# (tests/sh/ac-arrival.test.sh and tests/sh/ac-spawn-kickoff-arrival.test.sh own
# that contract); a test proving CONFIRMED/REFUTED arrival seeds a transcript
# under this same root.
export AC_CLAUDE_TRANSCRIPT_ROOT="$TMP/claude-projects"
mkdir -p "$AC_CLAUDE_TRANSCRIPT_ROOT"
# The same for the brain's keyless local-ollama synthesize rung (src/brain.ts):
# it answers before the harness rung, so a daemon on the operator's default
# port would answer every synthesize leg instead of the command under test.
# Port 1 is never served; the connect is refused at once.
export AC_BRAIN_OLLAMA_URL="http://127.0.0.1:1/v1"
# Nor may a test run the host's REAL herdr or orca. A suite's fake prepended to
# PATH shields only a first-match lookup: once that fake reports a version,
# bin/ac-bootstrap.sh's shadow_check runs EVERY further copy on PATH, and
# bin/ac-pane-agent.sh appends /opt/homebrew/bin. So each inherited PATH dir
# holding either is swapped for a mirror of its other tools, and refusing
# stand-ins lead PATH - ahead of the host, behind every fake a suite prepends.
# docker and codegraph are mirrored out too, with no stand-in: the code reaches
# them only through `command -v`, so absent is the not-installed path every
# host shares, and a suite that exercises docker plants its own stub.
# gh goes the same way, and its token variables with it, so no suite reads the
# operator's GitHub login: every gh call in the code sits behind a presence
# check or is reached only by a suite that plants its own gh.
unset GH_TOKEN GITHUB_TOKEN
mkdir -p "$TMP/no-host-backend"
for _ac_tool in herdr orca; do
  printf '#!/bin/sh\necho "%s: refused - no test reaches the host binary (tests/sh/helpers.sh)" >&2\nexit 1\n' \
    "$_ac_tool" >"$TMP/no-host-backend/$_ac_tool"
  chmod +x "$TMP/no-host-backend/$_ac_tool"
done
_ac_path="$TMP/no-host-backend" _ac_n=0
IFS=: read -ra _ac_dirs <<<"$PATH"
for _ac_dir in "${_ac_dirs[@]}"; do
  # An empty entry is dropped and a relative one pinned to the dir it names
  # now: either is resolved against whatever dir the shell is in at each
  # lookup, so a host gh in a dir a suite cd's into would answer. CDPATH=
  # keeps an exported CDPATH from swapping in a namesake dir.
  [ -n "$_ac_dir" ] || continue
  case "$_ac_dir" in /*) ;; *) _ac_dir="$(CDPATH= cd -- "$_ac_dir" 2>/dev/null && pwd)" || continue ;; esac
  if [ -e "$_ac_dir/herdr" ] || [ -e "$_ac_dir/orca" ] || [ -e "$_ac_dir/docker" ] || [ -e "$_ac_dir/codegraph" ] || [ -e "$_ac_dir/gh" ]; then
    _ac_n=$((_ac_n + 1))
    mkdir -p "$TMP/host-path/$_ac_n"
    ln -s "$_ac_dir"/* "$TMP/host-path/$_ac_n/"
    rm -f "$TMP/host-path/$_ac_n/herdr" "$TMP/host-path/$_ac_n/orca" "$TMP/host-path/$_ac_n/docker" "$TMP/host-path/$_ac_n/codegraph" "$TMP/host-path/$_ac_n/gh"
    _ac_dir="$TMP/host-path/$_ac_n"
  fi
  _ac_path="$_ac_path:$_ac_dir"
done
export PATH="$_ac_path"
unset _ac_tool _ac_path _ac_n _ac_dirs _ac_dir
# Hermetic scope, too: every roomchief session runs with AC_SCOPE (and often
# AC_WATCH_ONLY) exported, and scope changes what the scripts under test route,
# watch and refuse - so an inherited scope reds the suite for exactly the
# operators most likely to run it. Tests that want a scope set it per command.
# AC_WATCH_SKIP is AC_WATCH_ONLY's twin on the crewchief side (the fleet
# watcher is armed with the promoted families) and refuses outright on a family
# absent from THIS home - an inherited one reds ac-watch/ac-roomchief.
#
# The fleet knobs ride the same rung for the same reason: ac-spawn.sh prefixes
# every CREWMATE launch line with AC_FLEET_MODEL/AC_FLEET_EFFORT, and
# ac-pane-agent.sh reads exactly that env as its model/effort fallback - so a
# suite run from a crewmate pane let the OPERATOR'S live fleet decide what the
# fixture asserts (found live 2026-07-20: ac-pane-agent.test.sh's "no model
# anywhere must pass no --model" case reds under a pinned fleet). Tests that
# want a fleet knob set it per command, like scope.
# AC_FLEET_STATE/AC_FLEET_SCOPE ride the same launch line and are the sharpest
# of the lot: they point bin/ac-done.sh at a fleet's REAL state dir, so a suite
# run from a crewmate pane would publish its fixtures' wakes - and stamp its
# dedup markers - into the OPERATOR'S live home.
# AC_FLEET_NAME rides that line too and shadows exactly one rung: ac_fleet_name's
# homeless answer. A fixture proving the fixed fallback runs with AC_HOME unset,
# so an inherited name would red it under a crewmate pane and pass elsewhere.
# AC_FLEET_HOME_CHECKED/AC_FLEET_PROJECT_CONFIG ride the same launch line and
# are what bin/ac-ship.sh reads to tell a verified-none config from the
# ambiguous no-AC_HOME case - an inherited pair makes a fixture asserting that
# ambiguity (tests/sh/ac-ship.test.sh's "homeless crewmate" cases) silently pass
# or fail against the OPERATOR'S live fleet's project config instead of the
# case under test.
# AC_SOLO/AC_CHIEF_SOLO mark a solo session, which the drain, the watcher and
# the session hooks answer differently - a suite run from one must not inherit it.
unset AC_SOLO AC_CHIEF_SOLO
unset AC_SCOPE AC_WATCH_ONLY AC_WATCH_SKIP AC_FLEET_MODEL AC_FLEET_EFFORT \
      AC_FLEET_STATE AC_FLEET_SCOPE \
      AC_FLEET_NAME AC_FLEET_REVIEW AC_CREW_ID \
      AC_FLEET_HOME_CHECKED AC_FLEET_PROJECT_CONFIG
# A value the code under test sets for its own children is pinned by reading it
# back in a stub, so an inherited copy passes that pin vacuously or reds a row
# asserting its absence: Claude Code exports GIT_TERMINAL_PROMPT=0, which
# ac-ship's push sets beside GIT_OPTIONAL_LOCKS=0; a chief running under its
# own CLAUDE_CONFIG_DIR passes it on in every launch line. HERDR_SESSION is a
# retired knob name kept here only as an isolation-hygiene example, read by
# nothing now.
unset GIT_TERMINAL_PROMPT GIT_OPTIONAL_LOCKS HERDR_SESSION CLAUDE_CONFIG_DIR
# The double key for the two arbitrary-exec test hooks (audit-f8): production
# code runs AC_CURATE_SNAPSHOT_HOOK / AC_QA_PROFILE_RECHECK_HOOK only when
# this is ALSO set, and only the suite sets it.
export AC_TEST_HOOKS=1
# The PER-ROLE families are the same leak one rung further, and they are
# FAMILIES, not fixed pairs: ac-spawn.sh derives each name from the role and
# the knob (AC_FLEET_PROFILE_<KIND>, AC_FLEET_{AGENT,MODEL,EFFORT}_<ROLE>), and
# in ac-pane-agent.sh they sit ABOVE the matching config/ rung - so an inherited
# one shadows the very rung a fixture is asserting. An ENUMERATED unset goes
# stale the day a new kind or knob is added, which is exactly how CODEREVIEW/QA
# once went unpaired with their newer PROFILE twin. Scrub by prefix so a future
# role or knob is covered without anyone touching this file.
for _ac_fleet_prefix in "${!AC_FLEET_PROFILE_@}" "${!AC_FLEET_AGENT_@}" \
                        "${!AC_FLEET_MODEL_@}" "${!AC_FLEET_EFFORT_@}"; do
  unset "$_ac_fleet_prefix"
done
unset _ac_fleet_prefix

fail() { AC_SUITE_DECIDED=1; printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "${3:-assert_eq}: want '$2' got '$1'"; }
assert_contains() { [ -n "$2" ] || fail "${3:-assert_contains}: empty needle"; [ "$2" != -- ] || fail "${3:-assert_contains}: takes no -- (the needle is the second argument)"; case "$1" in *"$2"*) ;; *) fail "${3:-assert_contains}: '$2' not found in: $1" ;; esac; }
assert_file() { [ -f "$1" ] || fail "${2:-assert_file}: missing $1"; }
assert_no_file() { [ ! -e "$1" ] || fail "${2:-assert_no_file}: exists $1"; }
assert_fails() { if "$@" >/dev/null 2>&1; then fail "expected failure: $*"; fi; }
assert_fails_with() {
  # assert_fails_with <substring> -- cmd... - like assert_fails, but also pins
  # the REASON: assert_fails alone cannot tell a fail-closed refusal from a
  # crash that never reached it (both exit non-zero) - this variant additionally
  # requires the captured output to name the refusal. Additive: assert_fails and
  # its existing call sites are untouched (repo-knowledge:97).
  local want="$1"
  [ -n "$want" ] || fail "assert_fails_with: empty expected substring"
  [ "${2:-}" = -- ] || fail "assert_fails_with: expected -- before the command"
  shift 2
  local out rc=0
  out="$("$@" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "expected failure: $*"
  assert_contains "$out" "$want" "assert_fails_with: '$want' not found in: $out"
}

run_on_tty() {
  # run_on_tty <cmd> [args...] - run a command with stdin connected to a REAL
  # pty (not a pipe or /dev/null), for tests proving a `[ -t 0 ]` refusal.
  #
  # Does NOT use pty.spawn: Xcode's python3.9 stdlib pty._copy is `while True`
  # (not the `while fds:` that bpo-26228 landed in 3.10), so once /dev/null stdin
  # AND the pty master both reach EOF, both drop out of its watch set and it
  # calls select([],[],[]) with no fds and no timeout - which never returns on
  # macOS. The child has already exited cleanly, but waitpid is never reached, so
  # run_on_tty hangs FOREVER and tests/run-suite.sh cannot complete (pty.spawn version,
  # repro'd 2026-08-02). We fork the pty ourselves and drain the master until it
  # EOFs (or errors), which terminates on child exit, then waitpid and decode the
  # raw wait status like a shell would (a signal death is 128+signum) rather than
  # `status >> 8`, which reads a signal-killed child (low byte set, high byte 0)
  # as exit 0. Relaying the master to fd 1 preserves the child's tty output for
  # the callers' `2>&1` capture (e.g. the "refusing a tty" assertions).
  python3 -c '
import os, pty, sys
pid, master_fd = pty.fork()
if pid == 0:
    os.execvp(sys.argv[1], sys.argv[1:])
while True:
    try:
        data = os.read(master_fd, 1024)
    except OSError:  # macOS raises EIO on the master once the slave is gone
        break
    if not data:     # clean EOF - the child has exited
        break
    os.write(1, data)
os.close(master_fd)
status = os.waitpid(pid, 0)[1]
if os.WIFSIGNALED(status):
    sys.exit(128 + os.WTERMSIG(status))
sys.exit(os.WEXITSTATUS(status))
' "$@" </dev/null
}

make_home() {
  # Kept for readability at call sites; the isolated home is already
  # created and exported at source time (see above).
  :
}

make_repo() {
  # make_repo [<name>] -> prints repo path with one commit on main.
  local r="$TMP/${1:-repo}"
  git init -q -b main "$r"
  git -C "$r" config user.email test@test
  git -C "$r" config user.name test
  printf 'hello\n' >"$r/file.txt"
  git -C "$r" add -A
  git -C "$r" commit -qm init
  printf '%s\n' "$r"
}

# --- delayed kills ------------------------------------------------------------
#
# AUTHORITATIVE for how a test bounds a process it started, and for signalling a
# pid it recorded earlier. A pid is a NUMBER this host hands out again: measured
# at 29k-58k new pids a minute against a 99999 ceiling, the whole space turns
# over every 1.7 to 3.5 minutes. A bare `( sleep 60; kill -9 "$pid" ) &` whose
# target ended early can therefore SIGKILL whatever process of this user holds
# the number by then - probably how a bun in another suite died rc 137 exactly
# 60s after tests/sh/ac-lock.test.sh had finished (no pid log proves it).
#
#   proc_identity <pid>          who <pid> is: its start time, empty once gone
#   same_process <pid> <ident>   true only while <pid> is still that process
#   kill_after <secs> <pid> [<signal>] [group]
#                                signal <pid> (KILL by default; `group`: its
#                                process group) once <secs> pass. The watchdog's
#                                pid is KILL_AFTER_PID; a `kill` on it stands it
#                                down, its sleep included.
#
# Identity is the start time `ps -o lstart=` reports: exec keeps it, and no
# reissued pid can carry it - a turnover takes minutes, lstart counts seconds.
# The command line is NOT part of it: an entry that execs changes `command=`
# (measured), so a bound on a shim would never fire. ps and sleep are called by
# path because suites lead PATH with stubs of both.
#
# The watchdog stands itself down within a second of its target ending, so none
# outlives what it guards - not one armed inside `$(...)`, not one orphaned by a
# SIGKILLed run, both out of any trap's reach. cleanup does NOT cancel it: a
# target still alive at EXIT is an orphan only its watchdog will ever end.
proc_identity() {
  case "$1" in '' | *[!0-9]*) return 0 ;; esac
  /bin/ps -o lstart= -p "$1" 2>/dev/null || true
}

same_process() { [ -n "$2" ] && [ "$(proc_identity "$1")" = "$2" ]; }

kill_after() {
  local secs="$1" pid="$2" sig="${3:-KILL}" group="${4:-}" id
  id="$(proc_identity "$pid")"
  ( set +e
    s=""
    trap '[ -z "$s" ] || kill "$s" 2>/dev/null; exit 0' TERM
    n=0
    while [ "$n" -lt "$secs" ] && kill -0 "$pid" 2>/dev/null; do
      /bin/sleep 1 & s=$!
      wait "$s"
      s=""
      n=$((n + 1))
    done
    [ "$n" -ge "$secs" ] && same_process "$pid" "$id" || exit 0
    if [ "$group" = group ]; then kill -"$sig" -- -"$pid"; else kill -"$sig" "$pid"; fi
  ) >/dev/null 2>&1 &
  KILL_AFTER_PID=$!
}

# --- load harness -------------------------------------------------------------
#
# AUTHORITATIVE for how a test generates CPU contention and gives it back.
# Timing-sensitive tests are only proved by running them on a CONTENDED box, so
# stress verification needs real hogs - and a hog that outlives its run is worse
# than no hog at all: one afternoon of ad-hoc `while :; do :; done &` reruns
# orphaned 77 busy loops (ppid=1, ~760% CPU, ~48min) because nothing reaped them.
#
# TWO layers, because neither covers the other's gap. Measured, not assumed:
#
#   1. reap_hogs, called from cleanup(). Runs on a clean exit, on a FAILING
#      assert (fail -> exit 1) and on SIGTERM - the paths that actually leaked.
#      It lives inside cleanup() instead of a second `trap ... EXIT` because
#      that trap would be clobbered by the six files that install their own
#      (ac-lock, ac-promote, ac-roomchief, ac-spawn-model-effort,
#      ac-spawn-teardown, ac-watch) - all of which chain cleanup, so this
#      reaches every EXIT path with no second handler.
#
#   2. AC_HOG_TTL, a hard lifetime each hog enforces on itself. SIGKILL cannot
#      be caught, so NO trap can reap a killed or timed-out run - layer 1 is
#      structurally unable to cover it, and that is the path that produced the
#      48-minute orphans. The TTL bounds a worst-case orphan to seconds.
#      The loop spins on the SECONDS builtin so it never forks (a `date`-per-
#      iteration hog would be a fork storm, not CPU load).
#
# Survivors are counted BY RECORDED PID, never by pgrep pattern: a pattern
# match would also count another agent's unrelated load and turn a green run
# red for someone else's mess. The pid alone is not enough either: a run that
# outlives AC_HOG_TTL reaps hogs whose pids may be reissued by then, so each is
# also recorded with its identity and only that process is counted or killed
# (see the delayed-kills block above).

AC_HOG_TTL="${AC_HOG_TTL:-300}"
# Must stay ABOVE the functions below: cleanup's `type reap_hogs` guard only
# saves the rm when reap_hogs is merely undefined. Move this assignment below
# reap_hogs and an early failure enters cleanup with _ac_hogs unbound, which
# under set -u aborts inside the guard instead of skipping it.
_ac_hogs=""
_ac_hog_id=()

load_hogs() {
  # load_hogs [n=4] - spawn n self-limiting CPU hogs, recording every pid.
  # Counted, not `seq`: BSD seq counts DOWN when the range is empty, so
  # `$(seq 1 0)` prints "1 0" and load_hogs 0 spawned two hogs on macOS -
  # silent load in the runs that asked for none.
  local n="${1:-4}" i=0
  while [ "$i" -lt "$n" ]; do
    ( SECONDS=0; while [ "$SECONDS" -lt "$AC_HOG_TTL" ]; do :; done ) &
    _ac_hogs="$_ac_hogs $!"
    _ac_hog_id[$!]="$(proc_identity "$!")"
    # Lowest priority, so the box's real work outruns the load we manufacture.
    # A courtesy only: nice changes PRIORITY, not how many cores are occupied -
    # the cap on the hog COUNT is what bounds the blast (tests/sh/stress.sh).
    renice 19 -p "$!" >/dev/null 2>&1 || true
    i=$((i + 1))
  done
}

hog_survivors() {
  # hog_survivors - how many spawned hogs are still alive, checked by pid and identity.
  local p n=0
  for p in $_ac_hogs; do
    same_process "$p" "${_ac_hog_id[$p]-}" && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

reap_hogs() {
  # reap_hogs - KILL every recorded hog and reap it. Idempotent, and safe to
  # call when none were spawned. Warns loudly rather than failing when a hog
  # outlives the kill: cleanup runs at EXIT, where the status is already decided
  # and a fail would be swallowed.
  #
  # This kills; it does not wait for AC_HOG_TTL. The TTL is the SIGKILL
  # backstop only - a reap that let hogs self-expire would leave minutes of
  # 100%-CPU load poisoning every concurrent run, which is waiting, not reaping.
  #
  # SIGKILL, not SIGTERM: a hog is a disposable busy loop with nothing to flush,
  # and a catchable signal can be ignored (or masked by a caller's disposition),
  # which would leave the wait below blocked for the hog's whole remaining TTL -
  # hanging the suite instead of failing it. The wait is still required: it
  # reaps the zombie, which keeps its identity and so would count as a survivor.
  local p left
  [ -n "$_ac_hogs" ] || return 0
  for p in $_ac_hogs; do same_process "$p" "${_ac_hog_id[$p]-}" && kill -9 "$p" 2>/dev/null || true; done
  for p in $_ac_hogs; do wait "$p" 2>/dev/null || true; done
  left="$(hog_survivors)"
  # Clear ONLY on a clean reap. hog_survivors reads _ac_hogs, so clearing it
  # unconditionally made every post-reap assert_no_hogs true by construction -
  # the gate passed against a reap that killed nothing. A survivor stays on the
  # record so the assertion can still see it.
  if [ "$left" = 0 ]; then
    _ac_hogs=""
    _ac_hog_id=()
  else
    printf 'WARNING: %s hog(s) survived reap_hogs: %s\n' "$left" "$_ac_hogs" >&2
  fi
  # Always 0: cleanup runs this as `type reap_hogs ... && reap_hogs; rm -rf`,
  # so a non-zero return would trip errexit and skip the rm for all ~39 files.
  # The survivor is reported, never signalled through the exit status.
  return 0
}

assert_no_hogs() {
  # assert_no_hogs [msg] - the zero-survivor assertion, by pid.
  assert_eq "$(hog_survivors)" "0" "${1:-no hog survived the run}"
}

# --- hold gates ----------------------------------------------------------------
#
# AUTHORITATIVE for how a test stands in for a LIVE FOREIGN PID - a lock owner,
# a session-lock holder - for the length of a block. A blocked reader, so the
# stand-in is a real live pid with no sleep and no polling.
#
#   hold_open <name>          publishes the holder's pid as HOLD_PID
#   hold_close <name> <pid>   releases it and reaps it
#
# The holder's LIFETIME is the whole contract, and the earlier idiom
# (`( read -r _ <fifo ) &`, released by `: >fifo`) got it wrong in both
# directions. Measured on this host, not reasoned:
#
#   1. `read -r _ <fifo` blocks in OPEN(2) until a writer appears, and `-t`
#      cannot bound that - the redirection happens before read runs (`read -t 1`
#      on a writerless fifo was still blocked 3s later). Unlinking the fifo does
#      not wake it either. So a run that died INSIDE the block - a FAIL, a set -e
#      abort, a kill - left a holder blocked forever. The orphan is a FORK of the
#      runner: `ps` renders it with the runner's own argv, and it inherits the
#      runner's stdout, so a captured or piped run of that file never saw the
#      FAIL line and never EOFed. Both halves were found in the wild: a red run
#      wedging its caller for its whole timeout, and a holder still alive 1 day
#      6 hours later, ppid=1, no children, holding only its cwd.
#   2. `: >fifo` is a write-only open, which blocks until a READER appears - so
#      releasing a gate whose holder had already gone would wedge the runner
#      itself, the same hang wearing the other sign.
#
# Both are opened `<>` here, which never blocks in either direction (the fd is
# its own counterpart), and the wait that remains is bounded by AC_HOLD_TTL.
# That single bound covers every exit path INCLUDING SIGKILL, which no trap can
# cover - the same gap AC_HOG_TTL exists for above. A hog needs the second layer
# (an explicit reap) because a self-expiring hog burns a core meanwhile; a holder
# blocked on a read burns nothing, so the bound is the whole answer here.
#
# An EXPIRED gate is a named failure, never a silent one: every assertion after
# the stand-in vanished was judging a dead pid, and a bound that died quietly
# would only move the lie.

# 90s against a longest MEASURED hold of 1s (all seven gates in
# tests/sh/ac-watch.test.sh, instrumented over a full green run), so the bound is
# ~90x the work it brackets - far enough that a loaded box cannot expire a
# healthy gate, short enough that a SIGKILLed run's orphan clears itself well
# inside the next run.
AC_HOLD_TTL="${AC_HOLD_TTL:-90}"

hold_open() {
  # hold_open <name> - a LIVE holder pid blocked on $TMP/<name>; sets HOLD_PID.
  mkfifo "$TMP/$1"
  # Redirected: an orphan that inherits the runner's stdout holds its caller's
  # capture pipe open for as long as it lives, which is what turned a red run
  # into a wedge. It now holds nothing, so the FAIL line reaches the caller at
  # once even in the window before the TTL reaps the orphan.
  ( exec 3<>"$TMP/$1"; read -r -t "$AC_HOLD_TTL" _ <&3 ) >/dev/null 2>&1 &
  HOLD_PID=$!
}

hold_close() {
  # hold_close <name> <pid> - release the gate and reap its holder.
  #
  # The reference is HELD across the whole handover. A token written into a fifo
  # whose last reference then closes is discarded with the pipe buffer (measured:
  # a holder that opened afterwards waited out its entire timeout for a newline
  # that no longer existed) - and hold_open returns as soon as the fork is
  # scheduled, so the holder may not have opened yet. Opened `<>`, so this cannot
  # block on a missing reader either. fd 9 is opened and closed with no fork in
  # between, so nothing can inherit it.
  local rc=0
  exec 9<>"$TMP/$1"
  printf '\n' >&9
  # Judged on `wait`, never on `kill -0`: an exited-but-unreaped child still
  # answers kill -0 (measured: 8 of 8 immediate polls), so a liveness probe would
  # pass exactly when the gate had JUST expired - the silent lie this refusal
  # exists to catch. The recorded status cannot lie: a released holder read the
  # token and exits 0, an expired one exits non-zero out of `read -t`.
  wait "$2" || rc=$?
  exec 9>&-
  [ "$rc" = 0 ] || fail "hold gate '$1' expired after ${AC_HOLD_TTL}s: its block outran the stand-in, so everything asserted after that judged a DEAD pid"
}

make_fake_orca() {
  # File-backed fake `orca` CLI - the orca driver's test double. Terminals
  # are files under $FAKE_ORCA/terminals:
  #   <h>.buf         transcript; `terminal read` serves its tail as lines
  #   <h>.in          composer - `send --text` appends, only `--enter` submits
  #   <h>.tab         the tabId minted with the terminal
  #   <h>.title       what `terminal show` reports (the real CLI's title
  #                   tracks the foreground process - a bare shell reports
  #                   its own name; default zsh, .default-title overrides)
  #   <h>.exited      present = connected:false; `read` still succeeds and
  #                   `send` fails terminal_not_writable (both measured on
  #                   orca CLI 1.4.188 - a closed terminal keeps serving its
  #                   retained scrollback)
  #   <h>.idle        present = `wait --for tui-idle` satisfied immediately;
  #                   absent = the wait times out with error code "timeout"
  #                   (the real CLI's envelope, measured on orca 1.4.215)
  #   <h>.screen-next moved over <h>.screen by a timed-out wait - the TUI
  #                   repainting inside the wait's window
  #   <h>.wait-error  content = an error code `wait` fails with instead of
  #                   timing out (a stale handle answers terminal_handle_stale)
  #   <h>.agentwait   present = show reports agentWait non-null
  #   <h>.agent       content = the agentIdentity `show` reports (Orca's own
  #                   harness detection: "claude"/"codex" once the TUI owns
  #                   the pane, null for a shell - measured on orca CLI
  #                   1.4.188); absent = null
  #   <h>.dialog      content = a STARTUP DIALOG's reason, reported as
  #                   agentWait {source:"prompt-text", reason} and as `wait
  #                   --for tui-idle`'s blockedReason (both measured: codex's
  #                   update prompt and hooks-review prompt); any `send`
  #                   (text or Enter) dismisses it, advancing to
  #                   <h>.dialog-next when present - a digit key dismisses
  #                   the real dialogs the same way
  #   <h>.drop-enters "<count>" - swallow N `--enter` submits (strand knob)
  #   <h>.receipt     content = the envelope a `--text --enter` prompt send
  #                   answers; absent = Orca's measured receipt (probe
  #                   2026-11-17): observation "supported" for a claude/codex
  #                   <h>.agent, "unsupported" for anything else
  #   <h>.prompt-blocked  present = a `--text --enter` send is refused with
  #                   error.code agent_prompt_blocked and types nothing (probe
  #                   2026-11-17: an agent parked on a trust prompt)
  #   <h>.agentrow    content = one `worktree ps` agent row (JSON object);
  #                   its paneKey defaults to the "pk-<h>" `show` reports as
  #                   recordedPaneKey (probe 2026-11-17); absent = no row
  #   <h>.popup-once  one-shot: the next `--enter` on a non-empty composer is
  #                   CONSUMED by a popup (render changes, composer keeps its
  #                   text) - the false-success class the pending check closes
  #   <h>.read-fails  `terminal read` of this terminal fails outright while
  #                   `terminal show` still answers: an unreadable composer,
  #                   never a gone terminal (ac-send.sh/ac-peek.sh's UNVERIFIED
  #                   case, distinct from "terminal_not_found")
  #   <h>.delay-ready-secs  "<n>" - id-scoped, like `.drop-enters`: before <n>
  #                   real seconds have passed since this terminal's FIRST
  #                   `terminal show` (the only "is it up yet" probe orca has -
  #                   never read, and send only DROPS, below), `show` reports
  #                   a SPINNER title (harnessUp: up via the spinner match;
  #                   agentIdle: not idle, same match) and `send --text`
  #                   drops silently (logs `dropped-before-ready`) - without
  #                   the drop, a send issued before the clock's read counterpart EVER checks
  #                   it would still land, so a ported readiness-gate test
  #                   could not tell "waited" from "typed blind and got
  #                   lucky". At or after <n> seconds `show` reports the idle
  #                   glyph title and sends stop dropping. While this knob is
  #                   armed it OVERRIDES <h>.title outright (`terminal list`
  #                   still reports the real file, untouched - nothing reads
  #                   a title from `list`). The delay signal itself is
  #                   narrower than the real readiness gate (title alone -
  #                   kickoffWaitInputReady in src/spawn.ts also reads
  #                   backendDialogAnswer and a stable render, neither of
  #                   which is timing-gated here).
  # Root knobs: .unreachable (every call fails with an error envelope),
  # .terminal-api-down - a PARTIAL outage: a window-collision guard must stay
  # blind-safe, never read "unobservable" as license to create a second
  # window; see the in-heredoc comment at its check for the exact call set,
  # .default-title (title newly created terminals report - writing the idle
  # glyph here before `make_fake_orca` creates/splits seeds every pane idle
  # the same way, with no separate knob needed - precedent:
  # tests/sh/ac-spawn-teardown.test.sh's orca block),
  # .require-repo-reg (worktree create and repo show resolve a path only when
  # $FAKE_ORCA/repos lists it; repo add registers - and fails runtime_error on
  # an already-registered path, measured on the real CLI).
  # .create-no-path (worktree create answers ok with an id but NO path - the
  # partial-create shape whose leak the lease must release by id).
  # worktree-list.json (the envelope `worktree list` serves; absent = no entries).
  # .ps-fails (`worktree ps` fails with an error envelope).
  # worktree-show-ambiguous (paths, one per line, whose `worktree show`
  # fails selector_ambiguous instead of resolving - and whose `terminal
  # create --worktree path:<p>` fails the SAME way, measured on the real
  # CLI: one resolver underlies both verbs).
  # worktree-show-fails (paths, one per line, whose `worktree show` fails
  # a plain selector_not_found instead of resolving - lets a resolve-group
  # walk pass OVER a path on its way to an ambiguous ancestor further up,
  # modeling an unregistered dir between it and a registered one).
  # Every call appends one line to $FAKE_ORCA/log.
  export FAKE_ORCA="$TMP/fake-orca"
  mkdir -p "$FAKE_ORCA/terminals" "$TMP/stubbin"
  cat >"$TMP/stubbin/orca" <<'FAKE'
#!/usr/bin/env bash
d="$FAKE_ORCA"
printf 'orca %s\n' "$*" >>"$d/log"
if [ -f "$d/.unreachable" ]; then
  printf '{"ok":false,"error":{"message":"runtime unreachable"}}\n'; exit 1
fi
if [ -f "$d/.terminal-api-down" ]; then
  # Partial outage: window liveness is blind while window CREATION stays
  # healthy - the shape that
  # makes an unguarded window-collision guard actually open a second window.
  # `status` MUST fail alongside `terminal show`/`list`, not just the two:
  # backend_window_alive_orca (bin/ac-backend-orca.sh) falls back to a plain
  # `orca status` the instant `terminal show` fails, and reads THAT success
  # as "really gone" (rc=1) - only a failing status earns the "unobservable"
  # verdict (rc=2) a window-collision guard must see to stay blind-safe
  # (measured: with status left healthy here, the production driver read
  # this outage as a dead pane and opened a second window).
  case "${1:-} ${2:-}" in
    "terminal show"|"terminal list"|"status "*)
      printf '{"ok":false,"error":{"message":"terminal api unavailable"}}\n'; exit 1 ;;
  esac
fi
term="" text="" has_text=0 enter=0 interrupt=0 limit=40 wt="" cond="" title_flag="" screen=0
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    --terminal) i=$((i+1)); term="${args[$i]}" ;;
    --text) i=$((i+1)); text="${args[$i]}"; has_text=1 ;;
    --enter) enter=1 ;;
    --interrupt) interrupt=1 ;;
    --limit) i=$((i+1)); limit="${args[$i]}" ;;
    --worktree) i=$((i+1)); wt="${args[$i]}" ;;
    --for) i=$((i+1)); cond="${args[$i]}" ;;
    --screen) screen=1 ;;
    --title) i=$((i+1)); title_flag="${args[$i]}" ;;
  esac
  i=$((i+1))
done
next() { local f="$d/.n" n; n="$(cat "$f" 2>/dev/null || printf 0)"; n=$((n + 1)); printf '%s\n' "$n" >"$f"; printf '%s\n' "$n"; }
tail_json() {
  # Composer render mirrors the measured claude TUI screen: the pending text
  # sits on a glyph row BETWEEN two horizontal rules (the transcript echoes a
  # submitted line with the SAME glyph, which is why the driver's pending
  # check reads the between-rules region, never text-anywhere).
  # jq -R -s, never awk: this host's awk truncates a record at an embedded
  # NUL (C-string semantics), silently dropping every byte after it. split
  # on a TRAILING "\n" always adds one extra empty element, which a byte
  # stream ending without one never has - stripped only when it is there, so
  # zero complete lines stays [] rather than becoming a false empty line.
  { tail -n "$2" "$d/terminals/$1.buf" 2>/dev/null || tail -n "$2" "$d/terminals/$1" 2>/dev/null
    if [ -s "$d/terminals/$1.in" ]; then
      printf '%s\n' "────────────────────────"
      printf '❯ %s\n' "$(cat "$d/terminals/$1.in")"
      printf '%s\n' "────────────────────────"
    fi
  } | jq -R -s -c 'if . == "" then [] else (split("\n") | if .[-1] == "" then .[:-1] else . end) end'
}
case "${1:-}" in
  status)
    printf '{"ok":true,"result":{"runtime":{"state":"ready","reachable":true}}}\n'; exit 0 ;;
  worktree)
    # `worktree show` is the driver's cheap selector probe (every path
    # resolves, unless worktree-show-ambiguous lists it - the real CLI's
    # selector_ambiguous when several entries share a path, measured);
    # `worktree create`/`rm` mint and remove REAL git worktrees so the
    # orca-fleet lease flow runs end to end in tests. create mirrors the
    # real CLI (measured): path under a workspaces dir, branch named
    # fakeuser/<name>, base ref honored.
    case "${2:-}" in
      show)
        wpath="${wt#path:}"
        if [ -n "$wpath" ] && [ -f "$d/worktree-show-ambiguous" ] && grep -qxF "$wpath" "$d/worktree-show-ambiguous" 2>/dev/null; then
          printf '{"ok":false,"error":{"code":"selector_ambiguous","message":"selector_ambiguous"}}\n'; exit 1
        fi
        if [ -n "$wpath" ] && [ -f "$d/worktree-show-fails" ] && grep -qxF "$wpath" "$d/worktree-show-fails" 2>/dev/null; then
          printf '{"ok":false,"error":{"message":"selector_not_found"}}\n'; exit 1
        fi
        printf '{"ok":true,"result":{"worktree":{}}}\n'; exit 0 ;;
      create)
        wrepo="" wname="" wbase=""
        j=0
        while [ $j -lt ${#args[@]} ]; do
          case "${args[$j]}" in
            --repo) j=$((j+1)); wrepo="${args[$j]#path:}" ;;
            --name) j=$((j+1)); wname="${args[$j]}" ;;
            --base-branch) j=$((j+1)); wbase="${args[$j]}" ;;
          esac
          j=$((j+1))
        done
        [ -d "$wrepo/.git" ] || { printf '{"ok":false,"error":{"message":"selector_not_found"}}\n'; exit 1; }
        if [ -f "$d/.require-repo-reg" ] && ! grep -qxF "$wrepo" "$d/repos" 2>/dev/null; then
          printf '{"ok":false,"error":{"message":"selector_not_found"}}\n'; exit 1
        fi
        if [ -f "$d/.create-no-path" ]; then
          printf '{"ok":true,"result":{"worktree":{"id":"wt-broken"}}}\n'; exit 0
        fi
        wpath="$d/orca-wt/$wname"
        mkdir -p "$d/orca-wt"
        git -C "$wrepo" worktree add -q -b "fakeuser/$wname" "$wpath" "${wbase:-HEAD}" 2>/dev/null           || { printf '{"ok":false,"error":{"message":"worktree_create_failed"}}\n'; exit 1; }
        # The real CLI creates the worktree AND its first terminal, and the
        # create JSON carries NO startup handle (measured 1.4.188 - the
        # terminal is discoverable only through `terminal list` by
        # worktreePath) - mirror both halves so the lease's discovery-based
        # close is testable.
        sn="$(next)"
        : >"$d/terminals/termS$sn.buf"; : >"$d/terminals/termS$sn.in"
        printf 'tabS%s\n' "$sn" >"$d/terminals/termS$sn.tab"
        printf 'zsh\n' >"$d/terminals/termS$sn.title"
        printf '%s\n' "$wpath" >"$d/terminals/termS$sn.wt"
        printf '{"ok":true,"result":{"worktree":{"path":"%s","branch":"refs/heads/fakeuser/%s"}}}\n' "$wpath" "$wname"
        exit 0 ;;
      rm)
        wpath=""
        j=0
        while [ $j -lt ${#args[@]} ]; do
          case "${args[$j]}" in --worktree) j=$((j+1)); wpath="${args[$j]#path:}" ;; esac
          j=$((j+1))
        done
        [ -d "$wpath" ] || { printf '{"ok":false,"error":{"message":"selector_not_found"}}\n'; exit 1; }
        wrepo="$(git -C "$wpath" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
        wrepo="${wrepo%/.git}"
        git -C "$wrepo" worktree remove --force "$wpath" 2>/dev/null || rm -rf "$wpath"
        printf '{"ok":true,"result":{}}\n'; exit 0 ;;
      list)
        if [ -f "$d/worktree-list.json" ]; then cat "$d/worktree-list.json"
        else printf '{"ok":true,"result":{"worktrees":[]}}\n'; fi
        exit 0 ;;
      ps)
        [ -f "$d/.ps-fails" ] && { printf '{"ok":false,"error":{"message":"runtime_error"}}\n'; exit 1; }
        for f in "$d"/terminals/*.agentrow; do
          [ -e "$f" ] || continue
          h="${f##*/}"; h="${h%.agentrow}"
          jq -c --arg k "pk-$h" '{paneKey: $k} + .' "$f"
        done | jq -s -c '{ok: true, result: {worktrees: [{agents: .}]}}'
        exit 0 ;;
      *)
        printf '{"ok":true,"result":{"worktree":{}}}\n'; exit 0 ;;
    esac ;;
  repo)
    rsel="" rpath=""
    j=0
    while [ $j -lt ${#args[@]} ]; do
      case "${args[$j]}" in
        --repo) j=$((j+1)); rsel="${args[$j]#path:}" ;;
        --path) j=$((j+1)); rpath="${args[$j]}" ;;
      esac
      j=$((j+1))
    done
    case "${2:-}" in
      show)
        if [ ! -f "$d/.require-repo-reg" ] || grep -qxF "$rsel" "$d/repos" 2>/dev/null; then
          printf '{"ok":true,"result":{"repo":{"id":"r1"}}}\n'
        else
          printf '{"ok":false,"error":{"message":"selector_not_found"}}\n'
        fi
        exit 0 ;;
      add)
        if grep -qxF "$rpath" "$d/repos" 2>/dev/null; then
          printf '{"ok":false,"error":{"message":"runtime_error"}}\n'
        else
          printf '%s\n' "$rpath" >>"$d/repos"
          printf '{"ok":true,"result":{"repo":{"id":"r1"}}}\n'
        fi
        exit 0 ;;
    esac
    printf '{"ok":true,"result":{}}\n'; exit 0 ;;
  terminal) ;;
  *) printf 'fake-orca: unmodeled verb %s\n' "$*" >&2; exit 2 ;;
esac
case "${2:-}" in
  create)
    # terminal create --worktree path:<p> fails the same selector_ambiguous
    # as worktree show on an ambiguous <p> - one resolver underlies both
    # verbs on the real CLI (measured: this is the actual failure a
    # placement hits, not just the probe).
    wpath="${wt#path:}"
    if [ "$wt" != "$wpath" ] && [ -n "$wpath" ] && [ -f "$d/worktree-show-ambiguous" ] && grep -qxF "$wpath" "$d/worktree-show-ambiguous" 2>/dev/null; then
      printf '{"ok":false,"error":{"code":"selector_ambiguous","message":"selector_ambiguous"}}\n'; exit 1
    fi
    n="$(next)"
    : >"$d/terminals/term$n.buf"; : >"$d/terminals/term$n.in"
    printf 'tab%s\n' "$n" >"$d/terminals/term$n.tab"
    cat "$d/.default-title" 2>/dev/null >"$d/terminals/term$n.title" \
      || printf 'zsh\n' >"$d/terminals/term$n.title"
    printf '{"ok":true,"result":{"terminal":{"handle":"term%s","tabId":"tab%s"}}}\n' "$n" "$n"; exit 0 ;;
  show)
    [ -f "$d/terminals/$term.buf" ] || { printf '{"ok":false,"error":{"message":"terminal_not_found"}}\n'; exit 1; }
    conn=true; [ -e "$d/terminals/$term.exited" ] && conn=false
    aw='null'; [ -e "$d/terminals/$term.agentwait" ] && aw='{"evidence":"prompt-text"}'
    [ -s "$d/terminals/$term.dialog" ] && aw="{\"source\":\"prompt-text\",\"reason\":\"$(head -1 "$d/terminals/$term.dialog")\"}"
    ag='null'; [ -s "$d/terminals/$term.agent" ] && ag="\"$(head -1 "$d/terminals/$term.agent")\""
    shown_title="$(head -1 "$d/terminals/$term.title" 2>/dev/null)"
    if [ -f "$d/terminals/$term.delay-ready-secs" ]; then
      # kickoffWaitInputReady (src/spawn.ts) proves UP and IDLE off the title
      # alone (harnessUp's spinner/✳ checks, agentIdle's same two) - so the
      # delay lives in the TITLE this `show` reports, clocked from THIS
      # terminal's FIRST show (the only "up" probe orca has).
      # ONE `date +%s` read for both the write and the compare below - two
      # separate reads straddling a second boundary let elapsed read >= n on
      # the very first show (measured: ~3 in 400 runs at n=1), reporting idle
      # before any delay was actually observed. The write is tmp-then-mv so a
      # second `show` racing the first can never read a truncated start file.
      dr_now="$(date +%s)"
      if [ ! -f "$d/terminals/$term.ready-start" ]; then
        printf '%s\n' "$dr_now" >"$d/terminals/$term.ready-start.tmp"
        mv "$d/terminals/$term.ready-start.tmp" "$d/terminals/$term.ready-start"
      fi
      dr_n="$(cat "$d/terminals/$term.delay-ready-secs")"
      dr_start="$(cat "$d/terminals/$term.ready-start")"
      if [ $(( dr_now - dr_start )) -ge "$dr_n" ]; then shown_title='✳ fake'
      else shown_title='◐ fake'
      fi
    fi
    printf '{"ok":true,"result":{"terminal":{"handle":"%s","connected":%s,"writable":%s,"title":"%s","agentIdentity":%s,"agentWait":%s,"recordedPaneKey":"pk-%s"}}}\n' \
      "$term" "$conn" "$conn" "$shown_title" "$ag" "$aw" "$term"; exit 0 ;;
  read)
    [ -f "$d/terminals/$term.buf" ] || { printf '{"ok":false,"error":{"message":"terminal_not_found"}}\n'; exit 1; }
    [ -f "$d/terminals/$term.read-fails" ] && { printf '{"ok":false,"error":{"message":"read_failed"}}\n'; exit 1; }
    st=running; [ -e "$d/terminals/$term.exited" ] && st=exited
    src="$term"
    # --screen reads what the terminal RENDERS; the default reads accumulated
    # output, which a full-screen TUI sitting still leaves empty (measured on
    # orca CLI 1.4.188 - its own help calls the default unsuitable for
    # verifying rendered output). <h>.screen models the rendered surface.
    if [ "$screen" = 1 ] && [ -f "$d/terminals/$term.screen" ]; then src="$term.screen"; fi
    if [ "$screen" != 1 ] && [ -f "$d/terminals/$term.screen" ] && [ ! -s "$d/terminals/$term.buf" ]; then
      printf '{"ok":true,"result":{"terminal":{"status":"%s","tail":[]}}}\n' "$st"; exit 0
    fi
    printf '{"ok":true,"result":{"terminal":{"status":"%s","tail":%s}}}\n' "$st" "$(tail_json "$src" "$limit")"; exit 0 ;;
  send)
    [ -f "$d/terminals/$term.buf" ] || { printf '{"ok":false,"error":{"message":"terminal_not_found"}}\n'; exit 1; }
    [ -e "$d/terminals/$term.exited" ] && { printf '{"ok":false,"error":{"message":"terminal_not_writable"}}\n'; exit 1; }
    [ "$interrupt" = 1 ] && { printf '{"ok":true,"result":{}}\n'; exit 0; }
    if [ -s "$d/terminals/$term.dialog" ]; then
      if [ -s "$d/terminals/$term.dialog-next" ]; then
        mv "$d/terminals/$term.dialog-next" "$d/terminals/$term.dialog"
      else
        rm -f "$d/terminals/$term.dialog"
      fi
      printf '{"ok":true,"result":{}}\n'; exit 0
    fi
    if [ "$has_text" = 1 ] && [ "$enter" = 1 ] && [ -e "$d/terminals/$term.prompt-blocked" ]; then
      printf '{"ok":false,"error":{"code":"agent_prompt_blocked","message":"The agent is showing a permission or trust prompt"}}\n'; exit 1
    fi
    if [ "$has_text" = 1 ]; then
      dropped=0
      if [ -f "$d/terminals/$term.delay-ready-secs" ] && [ -f "$d/terminals/$term.ready-start" ]; then
        dr_n="$(cat "$d/terminals/$term.delay-ready-secs")"
        dr_start="$(cat "$d/terminals/$term.ready-start")"
        [ $(( $(date +%s) - dr_start )) -lt "$dr_n" ] && dropped=1
      fi
      if [ "$dropped" = 1 ]; then
        printf 'dropped-before-ready\n' >>"$d/log"
      else
        printf '%s' "$text" >>"$d/terminals/$term.in"
      fi
    fi
    if [ "$enter" = 1 ]; then
      cnt="$(cat "$d/terminals/$term.drop-enters" 2>/dev/null)"
      if [ -e "$d/terminals/$term.popup-once" ] && [ -s "$d/terminals/$term.in" ]; then
        rm -f "$d/terminals/$term.popup-once"
        printf 'argument hint filled\n' >>"$d/terminals/$term.buf"
      elif [ "${cnt:-0}" -gt 0 ] 2>/dev/null; then
        printf '%s\n' "$((cnt - 1))" >"$d/terminals/$term.drop-enters"
      elif [ -s "$d/terminals/$term.in" ]; then
        cat "$d/terminals/$term.in" >>"$d/terminals/$term.buf"
        printf '\n' >>"$d/terminals/$term.buf"
        : >"$d/terminals/$term.in"
      else
        printf '\n' >>"$d/terminals/$term.buf"
      fi
    fi
    if [ "$has_text" = 1 ] && [ "$enter" = 1 ]; then
      if [ -s "$d/terminals/$term.receipt" ]; then cat "$d/terminals/$term.receipt"; exit 0; fi
      case "$(head -1 "$d/terminals/$term.agent" 2>/dev/null)" in
        claude|codex)
          printf '{"ok":true,"result":{"send":{"prompt":{"stages":["input_accepted","turn_started"],"provider":"%s","observation":"supported"}}}}\n' \
            "$(head -1 "$d/terminals/$term.agent")" ;;
        *) printf '{"ok":true,"result":{"send":{"prompt":{"stages":["input_accepted"],"provider":"unsupported","observation":"unsupported"}}}}\n' ;;
      esac
      exit 0
    fi
    printf '{"ok":true,"result":{}}\n'; exit 0 ;;
  wait)
    [ -f "$d/terminals/$term.buf" ] || { printf '{"ok":false,"error":{"message":"terminal_not_found"}}\n'; exit 1; }
    if [ "$cond" = tui-idle ] && [ -s "$d/terminals/$term.dialog" ]; then
      printf '{"ok":true,"result":{"wait":{"satisfied":false,"status":"running","blockedReason":"%s"}}}\n' \
        "$(head -1 "$d/terminals/$term.dialog")"; exit 0
    fi
    if [ "$cond" = tui-idle ] && [ -e "$d/terminals/$term.idle" ]; then
      printf '{"ok":true,"result":{"wait":{"satisfied":true,"status":"running"}}}\n'; exit 0
    fi
    if [ -s "$d/terminals/$term.wait-error" ]; then
      printf '{"ok":false,"error":{"code":"%s","message":"%s"}}\n' \
        "$(head -1 "$d/terminals/$term.wait-error")" "$(head -1 "$d/terminals/$term.wait-error")"; exit 1
    fi
    [ -f "$d/terminals/$term.screen-next" ] && mv "$d/terminals/$term.screen-next" "$d/terminals/$term.screen"
    printf '{"ok":false,"error":{"code":"timeout","message":"timeout"}}\n'; exit 1 ;;
  list)
    sep=""; printf '{"ok":true,"result":{"terminals":['
    for f in "$d"/terminals/*.tab; do
      [ -e "$f" ] || continue
      h="${f##*/}"; h="${h%.tab}"
      [ -f "$d/terminals/$h.buf" ] || continue
      printf '%s{"handle":"%s","tabId":"%s","title":"%s","worktreePath":"%s"}' \
        "$sep" "$h" "$(cat "$f")" "$(head -1 "$d/terminals/$h.title" 2>/dev/null)" \
        "$(head -1 "$d/terminals/$h.wt" 2>/dev/null)"
      sep=","
    done
    printf ']}}\n'; exit 0 ;;
  split)
    # Mirrors the real CLI (measured): inherits the base terminal's tab,
    # takes --command, and returns NO handle - callers discover by diffing
    # `terminal list`.
    [ -f "$d/terminals/$term.buf" ] || { printf '{"ok":false,"error":{"message":"terminal_not_found"}}\n'; exit 1; }
    n="$(next)"
    : >"$d/terminals/term$n.buf"; : >"$d/terminals/term$n.in"
    cp "$d/terminals/$term.tab" "$d/terminals/term$n.tab"
    cat "$d/.default-title" 2>/dev/null >"$d/terminals/term$n.title" \
      || printf 'zsh\n' >"$d/terminals/term$n.title"
    printf '{"ok":true,"result":{}}\n'; exit 0 ;;
  switch|focus)
    printf '%s\n' "$term" >"$d/focused"
    printf '{"ok":true,"result":{}}\n'; exit 0 ;;
  close)
    [ -f "$d/terminals/$term.buf" ] || { printf '{"ok":false,"error":{"message":"terminal_not_found"}}\n'; exit 1; }
    rm -f "$d/terminals/$term".*
    printf '{"ok":true,"result":{}}\n'; exit 0 ;;
  *) printf 'fake-orca: unmodeled verb %s\n' "$*" >&2; exit 2 ;;
esac
FAKE
  chmod +x "$TMP/stubbin/orca"
  case ":$PATH:" in *":$TMP/stubbin:"*) ;; *) export PATH="$TMP/stubbin:$PATH" ;; esac
}

fake_pane() {
  # fake_pane <task-id> - the fake pane id behind a spawned task.
  awk '{print $1; exit}' "$AC_HOME/state/.pane-$1"
}

fake_orca_buf() {
  # fake_orca_buf <task-id> - path of that task's fake-orca terminal buffer.
  # backend_window_new_orca records "<handle> <tab>" into the same 2-field
  # state/.pane-<id> grammar fake_pane already reads, so only the directory
  # layout below it differs (terminals/, not panes/).
  printf '%s/terminals/%s.buf\n' "$FAKE_ORCA" "$(fake_pane "$1")"
}

pass() { AC_SUITE_DECIDED=1; printf 'PASS: %s\n' "$(basename "$0")"; }
skip() { AC_SUITE_DECIDED=1; printf 'SKIP: %s\n' "$*"; exit 0; }
