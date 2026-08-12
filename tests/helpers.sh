#!/usr/bin/env bash
# helpers.sh - shared test helpers, sourced by every tests/*.test.sh.
# Provides: asserts, an isolated temp AC_HOME, disposable git repos, the load
# harness (load_hogs and friends - see their block below, which is the
# authoritative spec for how a stress run generates and reaps CPU load), and the
# hold gates (hold_open/hold_close - the block below them is likewise the
# authoritative spec for standing in for a live foreign pid).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
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
cleanup() { type reap_hogs >/dev/null 2>&1 && reap_hogs; rm -rf "$TMP"; }
trap cleanup EXIT

# Tests must NEVER see (or touch!) the operator's live fleet: the harness
# exports AC_HOME from .claude/settings.local.json, so an un-isolated test
# would read - or worse, write - the real home. Every test gets a throwaway
# home; call make_home when the test needs data/config seeded.
mkdir -p "$TMP/home/state" "$TMP/home/data" "$TMP/home/records" "$TMP/home/config" "$TMP/home/projects"
printf 'off\n' >"$TMP/home/config/wedge-alarm"
export AC_HOME="$TMP/home"
export AC_SHIP_WATCH=off
export AC_GATE_WATCH=off
# Verified sends (ac-backend.sh) settle AC_SEND_SETTLE seconds around each
# Enter before probing; the fake herdr is synchronous, so the suite skips them.
export AC_SEND_SETTLE=0
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
# ambiguity (tests/ac-ship.test.sh's "homeless crewmate" cases) silently pass
# or fail against the OPERATOR'S live fleet's project config instead of the
# case under test.
unset AC_SCOPE AC_WATCH_ONLY AC_WATCH_SKIP AC_FLEET_MODEL AC_FLEET_EFFORT \
      AC_FLEET_STATE AC_FLEET_SCOPE \
      AC_FLEET_NAME AC_FLEET_REVIEW AC_CREW_ID \
      AC_FLEET_HOME_CHECKED AC_FLEET_PROJECT_CONFIG
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

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "${3:-assert_eq}: want '$2' got '$1'"; }
assert_contains() { [ -n "$2" ] || fail "${3:-assert_contains}: empty needle"; case "$1" in *"$2"*) ;; *) fail "${3:-assert_contains}: '$2' not found in: $1" ;; esac; }
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
  # run_on_tty hangs FOREVER and tests/run-suite.sh cannot complete (helpers.sh:103,
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
# red for someone else's mess.

AC_HOG_TTL="${AC_HOG_TTL:-300}"
# Must stay ABOVE the functions below: cleanup's `type reap_hogs` guard only
# saves the rm when reap_hogs is merely undefined. Move this assignment below
# reap_hogs and an early failure enters cleanup with _ac_hogs unbound, which
# under set -u aborts inside the guard instead of skipping it.
_ac_hogs=""

load_hogs() {
  # load_hogs [n=4] - spawn n self-limiting CPU hogs, recording every pid.
  # Counted, not `seq`: BSD seq counts DOWN when the range is empty, so
  # `$(seq 1 0)` prints "1 0" and load_hogs 0 spawned two hogs on macOS -
  # silent load in the runs that asked for none.
  local n="${1:-4}" i=0
  while [ "$i" -lt "$n" ]; do
    ( SECONDS=0; while [ "$SECONDS" -lt "$AC_HOG_TTL" ]; do :; done ) &
    _ac_hogs="$_ac_hogs $!"
    # Lowest priority, so the box's real work outruns the load we manufacture.
    # A courtesy only: nice changes PRIORITY, not how many cores are occupied -
    # the cap on the hog COUNT is what bounds the blast (tests/stress.sh).
    renice 19 -p "$!" >/dev/null 2>&1 || true
    i=$((i + 1))
  done
}

hog_survivors() {
  # hog_survivors - how many spawned hogs are still alive, checked by pid.
  local p n=0
  for p in $_ac_hogs; do
    kill -0 "$p" 2>/dev/null && n=$((n + 1))
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
  # reaps the zombie, which kill -0 would otherwise count as a live survivor.
  local p left
  [ -n "$_ac_hogs" ] || return 0
  for p in $_ac_hogs; do kill -9 "$p" 2>/dev/null || true; done
  for p in $_ac_hogs; do wait "$p" 2>/dev/null || true; done
  left="$(hog_survivors)"
  # Clear ONLY on a clean reap. hog_survivors reads _ac_hogs, so clearing it
  # unconditionally made every post-reap assert_no_hogs true by construction -
  # the gate passed against a reap that killed nothing. A survivor stays on the
  # record so the assertion can still see it.
  if [ "$left" = 0 ]; then
    _ac_hogs=""
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
# tests/ac-watch.test.sh, instrumented over a full green run), so the bound is
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

# --- fake herdr backend --------------------------------------------------------
#
# AUTHORITATIVE for how tests drive the herdr backend (the fleet's only one).
# A file-backed fake CLI - panes are files, no processes, nothing to orphan:
#   $FAKE_HERDR/tabs/<tab>        holds the tab's pane id (presence = alive)
#   $FAKE_HERDR/panes/<p>.buf     the pane transcript: enter submits the
#                                 composer into it (newline-terminated)
#   $FAKE_HERDR/panes/<p>.tab     the pane's own tab id, as `pane get` reports
#                                 it - what a RAW-pane caller focuses through
#                                 when it holds no state/.pane-<id> handle
#   $FAKE_HERDR/panes/<p>.label   the pane label (`pane rename` writes it);
#                                 `pane get` and `pane list` report it back,
#                                 which is how a pane agent's stable handle
#                                 resolves and proves itself
#   $FAKE_HERDR/panes/<p>.in      the composer: send-text appends here and
#                                 never auto-submits; `pane read` prints the
#                                 transcript, then a non-empty composer
#                                 rendered as "> <input>" (a TUI input box)
#   $FAKE_HERDR/panes/<p>.drop-enters  strand knob: "<count> [<pattern>]" -
#                                 the next <count> enters whose composer
#                                 matches <pattern> (default: any) are
#                                 dropped SILENTLY, exit 0 - herdr's
#                                 unfocused send-keys no-op
#   $FAKE_HERDR/panes/<p>.dead    the harness EXITED and the pane fell back to
#                                 its shell: `pane process-info` then reports a
#                                 bare `-zsh` in the foreground instead of the
#                                 harness (the dead-pane signature ac-spawn.sh
#                                 refuses on). $FAKE_HERDR/.spawn-dead marks
#                                 EVERY pane created from then on, which is how
#                                 a test kills a harness at launch time - before
#                                 the spawn it is racing has a handle to write
#   $FAKE_HERDR/.die-on-text      "<pattern>" - the harness EXITS when text
#                                 matching <pattern> is typed into it, marking
#                                 that pane `.dead`. This is the pane that is
#                                 ALIVE at the came-up gate and DEAD after the
#                                 kickoff, which no `.dead` written up front can
#                                 express: codex's startup trust dialog reads an
#                                 `n` or a `2` in the prompt as "2. No, quit"
#   $FAKE_HERDR/.die-on-bare-enter  the harness EXITS on an Enter typed into an
#                                 EMPTY composer, marking that pane `.dead` -
#                                 the keystroke that ANSWERS a startup dialog
#                                 ending the process instead. Only a BARE Enter,
#                                 so a launch line's own submit is untouched and
#                                 the death lands exactly where the dialog
#                                 answer is typed
#   $FAKE_HERDR/.probe-unreadable makes `pane process-info` fail outright, the
#                                 third (unobservable) verdict of that probe
#   $FAKE_HERDR/.unreachable      the BACKEND itself cannot answer: EVERY call
#                                 exits 1 with herdr's own error envelope on
#                                 stderr, the shape a client/server protocol
#                                 mismatch produced live (2026-07-25: brew
#                                 upgraded the CLI to protocol 17 against a
#                                 running protocol-16 server and every socket
#                                 call returned protocol_mismatch exit 1). This
#                                 is what tells an unreadable backend apart from
#                                 a pane that is really gone - a pane whose
#                                 files are simply removed
#   $FAKE_HERDR/.pane-api-down  a PARTIAL outage: `pane get` and `pane list`
#                                 both fail with herdr's error envelope while
#                                 every other verb answers normally. That is the
#                                 shape WINDOW LIVENESS cannot see through (both
#                                 of its calls are gone, so the verdict is
#                                 UNOBSERVABLE) on a backend that can still
#                                 CREATE a tab - i.e. the one where proceeding
#                                 past a window-collision guard really does open
#                                 a second window
#   $FAKE_HERDR/panes/<p>.status  agent_status served by `pane get`
#                                 (tests write `blocked` to simulate an ask)
#   $FAKE_HERDR/.pane-idle-by-default  seeds EVERY new pane's `.status` with
#                                 `idle` at `tab create` time - opt-in, for a
#                                 suite whose panes must clear the
#                                 composer-ready observation (bin/ac-spawn.sh
#                                 kickoff_wait_input_ready: agent_status=idle
#                                 AND a stable render) without hand-writing
#                                 `.status` per predicted pane id
#   $FAKE_HERDR/panes/<p>.delay-ready-secs  "<n>" - a PER-PANE knob (write it
#                                 before the pane exists, at the predicted
#                                 p$((n+1)), the same convention `.drop-enters`
#                                 uses): the clock starts on this pane's FIRST
#                                 `pane process-info` read (never on its
#                                 launch-line send-text, which always precedes
#                                 it) and reports `agent_status=working` and
#                                 DROPS any `pane send-text` until <n> real
#                                 seconds have elapsed, then flips to `idle`
#                                 and stops dropping. A dropped send-text still
#                                 lets a bare Enter append a newline to the
#                                 render - the "unrelated redraw" that fools a
#                                 naive render-diff submit verifier into
#                                 reporting ACCEPTED even though the text never
#                                 landed (the fault bin/ac-spawn.sh's composer-
#                                 ready observation exists to close). Logs
#                                 `dropped-before-ready` per drop.
#   $FAKE_HERDR/panes/<p>.reported  externally reported state (`pane
#                                 report-agent` writes it, `release-agent`
#                                 removes it); MASKS .status in `pane get`,
#                                 mirroring real herdr (verified 2026-07-17)
#   $FAKE_HERDR/focused           tab id of the last `tab focus`
#   $FAKE_HERDR/log               one line per CLI call, for call-shape asserts
#   $FAKE_HERDR/.n                the TAB/PANE counter, and nothing else's: the
#                                 nth `tab create` mints tab t<n> and pane p<n>,
#                                 so a test that must arm a knob on a pane BEFORE
#                                 it exists (`.drop-enters`, which has to be in
#                                 place before the spawn opens the tab) predicts
#                                 it as p$((n + 1)) (or t$((n + 1))). Seven call
#                                 sites in four test files do. Any verb that
#                                 draws from THIS counter silently shifts
#                                 that prediction and reds them somewhere else
#                                 entirely - one workspace-per-family create did
#                                 exactly that (d74b7d6), and by a CONDITIONAL
#                                 offset (2 when the family workspace is created,
#                                 1 when an existing one is adopted), so no
#                                 constant fixes it. A new id-minting verb gets
#                                 its own counter file, like `workspace create`
#                                 below.
#   $FAKE_HERDR/.wn               the workspace counter, deliberately separate
# A spawned launch line therefore sits VERBATIM in the buffer (nothing
# executes it) - assert launch-line content against the buffer, and inject
# crewmate output (done:/blocked: markers) by appending lines to the buffer.

make_fake_herdr() {
  export FAKE_HERDR="$TMP/fake-herdr"
  mkdir -p "$FAKE_HERDR/panes" "$FAKE_HERDR/tabs" "$TMP/stubbin"
  cat >"$TMP/stubbin/herdr" <<'FAKE'
#!/usr/bin/env bash
d="$FAKE_HERDR"
printf 'herdr %s\n' "$*" >>"$d/log"
# Real herdr takes --session either before the subcommand or after it;
# ac-backend.sh appends it, ac-pane-agent.sh puts it first. Strip the leading
# form so both callers reach the same fake.
[ "${1:-}" = --session ] && shift 2
if [ -f "$d/.unreachable" ]; then
  printf '{"error":{"code":"protocol_mismatch","message":"client protocol 17 server protocol 16"},"id":"cli:%s"}\n' \
    "${1:-}:${2:-}" >&2
  exit 1
fi
if [ -f "$d/.pane-api-down" ]; then
  case "${1:-} ${2:-}" in
    "pane get"|"pane list")
      printf '{"error":{"code":"internal_error","message":"pane api unavailable"},"id":"cli:%s"}\n' \
        "${1:-}:${2:-}" >&2
      exit 1 ;;
  esac
fi
next() { local f="$d/.${1:-n}" n; n="$(cat "$f" 2>/dev/null || printf 0)"; n=$((n + 1)); printf '%s\n' "$n" >"$f"; printf '%s\n' "$n"; }
case "${1:-} ${2:-}" in
  "workspace get")
    # ws.<id> holds the workspace's LABEL (empty file = unlabelled) - real herdr
    # reports it under result.workspace.label, which ac_herdr_agents_workspace
    # now checks so a knob can only place a fleet's panes in ITS OWN group.
    [ -e "$d/ws.$3" ] || exit 1
    printf '{"result":{"workspace":{"workspace_id":"%s","label":"%s"}}}\n' \
      "$3" "$(cat "$d/ws.$3" 2>/dev/null || true)"; exit 0 ;;
  "workspace create")
    n="$(next wn)"; lbl=""; shift 2
    while [ $# -gt 0 ]; do case "$1" in --label) lbl="${2:-}"; shift ;; esac; shift; done
    printf '%s' "$lbl" >"$d/ws.w$n"
    printf '{"result":{"workspace":{"workspace_id":"w%s"}}}\n' "$n"; exit 0 ;;
  "workspace list")
    sep=""; printf '{"result":{"workspaces":['
    for f in "$d"/ws.*; do
      [ -e "$f" ] || continue
      printf '%s{"workspace_id":"%s","label":"%s","tab_count":0}' \
        "$sep" "${f##*/ws.}" "$(cat "$f" 2>/dev/null || true)"; sep=","
    done
    printf ']}}\n'; exit 0 ;;
  "workspace close") rm -f "$d/ws.$3"; exit 0 ;;
  "tab create")
    # tabs/<tab> holds "<pane_id> [<label>]" - the label is what tab get
    # reports back, so an ownership check can prove a tab is still its task's.
    n="$(next)"; lbl=""; shift 2
    while [ $# -gt 0 ]; do case "$1" in --label) lbl="${2:-}"; shift ;; esac; shift; done
    printf 'p%s %s\n' "$n" "$lbl" >"$d/tabs/t$n"
    : >"$d/panes/p$n.buf"
    [ -f "$d/.spawn-dead" ] && : >"$d/panes/p$n.dead"
    [ -f "$d/.pane-idle-by-default" ] && printf 'idle\n' >"$d/panes/p$n.status"
    printf 't%s\n' "$n" >"$d/panes/p$n.tab"
    printf '{"result":{"tab":{"tab_id":"t%s"},"root_pane":{"pane_id":"p%s"}}}\n' "$n" "$n"; exit 0 ;;
  "tab get")
    [ -f "$d/tabs/$3" ] || exit 1
    read -r _ lbl <"$d/tabs/$3"
    printf '{"result":{"tab":{"tab_id":"%s","label":"%s"}}}\n' "$3" "$lbl"; exit 0 ;;
  "tab close")
    # Fault injection: `.kill-caller-on-tab-close` makes this close END its
    # caller, the way the real pane-kill step has ended ac-teardown.sh on
    # record (exit 144, no output). SIGKILL because the killer behind those
    # incidents is undiagnosed - a test may not assume it is catchable.
    [ -f "$d/.kill-caller-on-tab-close" ] && kill -s KILL "$PPID"
    p=""; [ -f "$d/tabs/$3" ] && read -r p _ <"$d/tabs/$3"
    [ -n "$p" ] && rm -f "$d/panes/$p".*
    rm -f "$d/tabs/$3"; exit 0 ;;
  "tab focus") printf '%s\n' "$3" >"$d/focused"; exit 0 ;;
  "tab list") exit 0 ;;
  "pane get")
    [ -f "$d/panes/$3.buf" ] || exit 1
    if [ -f "$d/panes/$3.reported" ]; then st="$(cat "$d/panes/$3.reported")"
    elif [ -f "$d/panes/$3.delay-ready-secs" ] && [ -f "$d/panes/$3.ready-start" ]; then
      n="$(cat "$d/panes/$3.delay-ready-secs")"; start="$(cat "$d/panes/$3.ready-start")"
      if [ $(( $(date +%s) - start )) -ge "$n" ]; then st=idle; else st=working; fi
    else st="$(cat "$d/panes/$3.status" 2>/dev/null || printf 'unknown')"; fi
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"%s","label":"%s","agent_status":"%s"}}}\n' \
      "$3" "$(cat "$d/panes/$3.tab" 2>/dev/null || true)" \
      "$(cat "$d/panes/$3.label" 2>/dev/null || true)" "$st"; exit 0 ;;
  "pane process-info")
    # Addressed as `--pane <id>` (the real CLI's form - it takes no positional
    # pane). A `.dead` pane reports its shell in the foreground, a live one the
    # harness; `.probe-unreadable` fails the read, the unobservable verdict.
    # `name` != `argv0` on a live pane - verified against real herdr 2026-07-21
    # (`herdr pane process-info`): argv0 is the launched command ("claude"),
    # name is the harness's OWN version string ("2.1.216"), never its argv0.
    # backend_harness_up (ac-backend.sh) reads argv0 first for exactly this
    # reason; a fixture that echoed argv0 into name too would stay green
    # under a future `.name`-trusting simplification while going blind in
    # production, where `.name` is never a process/harness name.
    p=""; shift 2
    while [ $# -gt 0 ]; do case "$1" in --pane) p="${2:-}"; shift 2 ;; *) shift ;; esac; done
    [ -f "$d/panes/$p.buf" ] || exit 1
    [ -f "$d/.probe-unreadable" ] && exit 1
    if [ -f "$d/panes/$p.delay-ready-secs" ] && [ ! -f "$d/panes/$p.ready-start" ]; then
      date +%s >"$d/panes/$p.ready-start"
    fi
    fg=claude; nm=9.9.9-fixture
    [ -f "$d/panes/$p.dead" ] && { fg=-zsh; nm=-zsh; }
    printf '{"result":{"process_info":{"pane_id":"%s","shell_pid":100,"foreground_processes":[{"argv0":"%s","name":"%s","pid":101}]}}}\n' \
      "$p" "$fg" "$nm"; exit 0 ;;
  "pane list")
    # Every live pane, with the label `pane rename` gave it - real herdr omits
    # the field on an unnamed pane, so an empty one is reported as "".
    sep=""
    printf '{"result":{"panes":['
    for f in "$d"/panes/*.buf; do
      [ -e "$f" ] || continue
      p="$(basename "$f" .buf)"
      printf '%s{"pane_id":"%s","tab_id":"%s","label":"%s"}' "$sep" "$p" \
        "$(cat "$d/panes/$p.tab" 2>/dev/null || true)" \
        "$(cat "$d/panes/$p.label" 2>/dev/null || true)"
      sep=","
    done
    printf ']}}\n'; exit 0 ;;
  "pane rename")
    [ -f "$d/panes/$3.buf" ] || exit 1
    printf '%s\n' "${4:-}" >"$d/panes/$3.label"; exit 0 ;;
  "pane report-agent")
    p="$3"; [ -f "$d/panes/$p.buf" ] || exit 1
    # Fault injection: an executable `.hook-report-agent` runs ONCE here (it is
    # renamed before it runs, so a second call is inert). This CLI call is what
    # ac-watch.sh's marker branch makes BETWEEN stamping .seen-<id> and
    # publishing its wake, so a hook is how a test lands a concurrent write
    # inside that window deterministically - no sleeps, no racing processes.
    if [ -x "$d/.hook-report-agent" ]; then
      mv "$d/.hook-report-agent" "$d/.hook-report-agent.used"
      "$d/.hook-report-agent.used" || true
    fi
    shift 3; state=unknown
    while [ $# -gt 0 ]; do
      case "$1" in --state) state="${2:-unknown}"; shift 2 ;; *) shift ;; esac
    done
    printf '%s\n' "$state" >"$d/panes/$p.reported"; exit 0 ;;
  "pane release-agent")
    rm -f "$d/panes/$3.reported"; exit 0 ;;
  "pane read")
    [ -f "$d/panes/$3.buf" ] || exit 1
    cat "$d/panes/$3.buf"
    if [ -s "$d/panes/$3.in" ]; then printf '> '; cat "$d/panes/$3.in"; printf '\n'; fi
    exit 0 ;;
  "pane send-text")
    p="$3"; shift 3
    [ -f "$d/panes/$p.buf" ] || exit 1
    if [ -f "$d/panes/$p.delay-ready-secs" ] && [ -f "$d/panes/$p.ready-start" ]; then
      n="$(cat "$d/panes/$p.delay-ready-secs")"; start="$(cat "$d/panes/$p.ready-start")"
      if [ $(( $(date +%s) - start )) -lt "$n" ]; then
        printf 'dropped-before-ready\n' >>"$d/log"
        exit 0
      fi
    fi
    printf '%s' "$*" >>"$d/panes/$p.in"
    if [ -f "$d/.die-on-text" ]; then
      pat="$(cat "$d/.die-on-text")"
      case "$*" in *"$pat"*) : >"$d/panes/$p.dead" ;; esac
    fi
    exit 0 ;;
  "pane send-keys")
    p="$3"
    if [ "${4:-}" = enter ] && [ -f "$d/panes/$p.buf" ]; then
      if [ -f "$d/panes/$p.drop-enters" ]; then
        read -r cnt pat <"$d/panes/$p.drop-enters" || true
        if [ "${cnt:-0}" -gt 0 ] 2>/dev/null \
           && { [ -z "${pat:-}" ] || grep -q -- "$pat" "$d/panes/$p.in" 2>/dev/null; }; then
          printf '%s %s\n' "$((cnt - 1))" "${pat:-}" >"$d/panes/$p.drop-enters"
          exit 0
        fi
      fi
      if [ -s "$d/panes/$p.in" ]; then
        cat "$d/panes/$p.in" >>"$d/panes/$p.buf"
        printf '\n' >>"$d/panes/$p.buf"
        : >"$d/panes/$p.in"
      else
        printf '\n' >>"$d/panes/$p.buf"
        [ -f "$d/.die-on-bare-enter" ] && : >"$d/panes/$p.dead"
      fi
    fi
    exit 0 ;;
esac
printf 'fake-herdr: unmodeled verb %s\n' "$*" >&2
exit 2
FAKE
  chmod +x "$TMP/stubbin/herdr"
  case ":$PATH:" in *":$TMP/stubbin:"*) ;; *) export PATH="$TMP/stubbin:$PATH" ;; esac
}

fake_pane() {
  # fake_pane <task-id> - the fake pane id behind a spawned task.
  awk '{print $1; exit}' "$AC_HOME/state/.pane-$1"
}

fake_pane_buf() {
  # fake_pane_buf <task-id> - path of that task's pane buffer.
  printf '%s/panes/%s.buf\n' "$FAKE_HERDR" "$(fake_pane "$1")"
}

pass() { printf 'PASS: %s\n' "$(basename "$0")"; }
