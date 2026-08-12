#!/usr/bin/env bash
# ac-term-recorder.sh - passive recorder that names WHO signals a fleet watcher.
#
# Usage: ac-term-recorder.sh [arm|stop]
#
# WHY. Something outside this distro SIGTERMs fleet watchers every ~45-90
# minutes, in bursts that reap several watchers across independent homes in the
# SAME second (watcher-external-term-x3). Every readable log has been read; the
# one datum left is si_pid, the pid of the sending process, and bash cannot
# reach it - it is delivered only through sigaction/SA_SIGINFO. So this arms a
# tiny C process (docs/examples/ac-term-recorder.c) BESIDE the real watchers, catches the
# next sweep's signal, and resolves the sender before it can exit. It changes
# nothing: no watcher, lock, beacon, arm log or config file is ever written.
#
# ARM IT AS THE HARNESS'S OWN BACKGROUND TASK - the same shape as ac-watch.sh,
# because that is what makes a harness reaping its own tracked task (the
# leading suspect) able to reach the recorder at all, and because the process
# EXIT is then the wake that hands the chief the catch:
#
#   AC_HOME=<fleet home> <repo>/docs/examples/ac-term-recorder.sh
#
# NEVER nohup/&/disown it inside a tool call: that orphans it exactly as it
# orphans a watcher, and the catch would wake no one.
#
# WHAT IT CAN CATCH.
#  - a harness reaping its OWN tracked background task (per-task kill or
#    kill(-pgid)): reachable because the recorder IS such a task;
#  - a kill aimed BY PATTERN at watchers: the exec'd command line carries
#    `--pattern-bait bin/ac-watch.sh`, so `-f` patterns from bare `watch`
#    through the full `bin/ac-watch.sh` path all match it. argv[0] still reads
#    `ac-term-recorder`, and `--note passive-recorder-not-a-watcher` sits in the
#    line, so nothing that reads `ps` is misled into thinking a watcher runs
#    here. Nothing in bin/ resolves processes by name or pattern (verified: the
#    only process lookups are `ps -o ... -p <pid>` by pid), so the distro's own
#    logic cannot mistake this for a watcher either;
#  - any out-of-band TERM/HUP/INT delivered to this process or its group.
# WHAT IT IS BLIND TO.
#  - SIGKILL, which is uncatchable by construction;
#  - a kill aimed at ONE real watcher BY PID (from a lock file, arm log or a
#    ps listing): this recorder appears in none of those, so nothing points at
#    its pid;
#  - a signal delivered to a process group this recorder is not in - if the
#    sweep is per-session, only the arming session's own reap is visible;
#  - pid recycling: si_pid is resolved within milliseconds, but a recycled pid
#    cannot be detected, and the record never claims otherwise.
#
# RECORD - append-only, one event per line, in the fleet home's state/ (already
# gitignored, already where volatile runtime signals live):
#   state/.term-recorder.log
#     arm     epoch=<s> iso=<...> self_pid=<n> ttl=<s> armed=<sigs> skipped=<sigs>
#     signal  epoch=<s>.<ms> signo=<n> si_pid=<n> si_uid=<n> si_code=<n> self_pid=<n>
#     resolve iso=<...> lag_ms=<n> signo=<n>(<NAME>) si_pid=<n> si_uid=<n> si_code=<n>
#     chain   depth=<n> <pid> <ppid> <uid> <command>     (walked to pid 1)
#     chain   depth=<n> pid=<n> GONE - exited before resolution
#     expired epoch=<s> self_pid=<n>
# The `signal` line is written and fsynced INSIDE the handler, so a follow-up
# KILL a millisecond later still leaves the evidence. The `arm` line is written
# only after the handlers are installed: it is the readiness marker.
# Signals: TERM (the one the sweep delivers), plus HUP (what a closing pane or
# session delivers - a different sweep mechanism worth telling apart) and INT
# (the foreground/Ctrl-C shape the watcher's own trap exists for). A signal
# already ignored on entry is LEFT ignored, so the recorder's exposure matches
# the watcher's; the `arm` line records which were armed and which were skipped.
#
# LIFETIME AND REAP (bounded host impact - standing captain law). One idle
# process blocked in sigsuspend, no polling. It records, resolves, and EXITS on
# the first catch. A hard self-expiring cap (AC_RECORDER_TTL, default 7200s)
# ends it even if no signal ever comes. The documented one-command reap is:
#
#   AC_HOME=<fleet home> <repo>/docs/examples/ac-term-recorder.sh stop
#
# which reads state/.term-recorder.pid and sends SIGKILL - deliberately, so the
# reap works regardless of what the recorder does with catchable signals and
# never fabricates a catch record. A second arm while one is live REFUSES,
# naming the running pid and this command (a remedy that names no target is what
# drove operators to improvise pattern kills - ac-watch.sh's NAMED RELEASE
# TARGET block).
# STALE PIDFILE. Catch-then-EXIT means a pidfile OUTLIVES every catch, so a
# recorded pid is believed only while it is still a recorder: `ps -p <pid> -o
# command=` must name `.term-recorder.bin`, never `kill -0` alone. Without that
# check a recycled pid makes the arm refuse against a stranger and the reap
# SIGKILL it - a kill that never verified its target, which is the exact defect
# class this whole investigation exists to close.
#
# BUILD. The C source is committed; the binary is a runtime artifact built on
# demand into the gitignored state/ dir and rebuilt when the source is newer.
# The compiler is spelled /usr/bin/cc on purpose: bare `cc` is shadowed by a
# shell function in this operator's profile.

set -euo pipefail
. "$(cd "$(dirname "$0")/../../bin" && pwd -P)/ac-lib.sh"

state_dir="$(ac_state_dir)"
src="$(cd "$(dirname "$0")" && pwd -P)/ac-term-recorder.c"
bin="$state_dir/.term-recorder.bin"
rec="$state_dir/.term-recorder.log"
pidfile="$state_dir/.term-recorder.pid"
ttl="${AC_RECORDER_TTL:-7200}"

live_pid() {
  # live_pid - prints the pid of the running recorder, if there is one.
  #
  # OWNERSHIP, not merely liveness. The success path is catch-then-EXIT, so
  # every catch leaves a stale pidfile behind; believing `kill -0` alone would
  # make a RECYCLED pid refuse a fresh arm against a stranger and SIGKILL it on
  # stop - a kill that never verified its target, the very defect the sibling
  # investigation just hardened ac-watch.sh against. One check closes both: the
  # pid is only a recorder if its own command line still says so.
  local p cmd
  p="$(cat "$pidfile" 2>/dev/null || true)"
  [ -n "$p" ] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  cmd="$(ps -p "$p" -o command= 2>/dev/null || true)"
  case "$cmd" in *.term-recorder.bin*) ;; *) return 1 ;; esac
  printf '%s\n' "$p"
}

do_stop() {
  local p n=0
  if ! p="$(live_pid)"; then
    rm -f "$pidfile"
    printf 'term-recorder: not running\n'
    return 0
  fi
  kill -KILL "$p" 2>/dev/null || true
  while [ "$n" -lt 100 ] && kill -0 "$p" 2>/dev/null; do
    sleep 0.05
    n=$((n + 1))
  done
  if kill -0 "$p" 2>/dev/null; then
    ac_die "term-recorder: pid $p survived the reap"
  fi
  rm -f "$pidfile"
  printf 'term-recorder: reaped pid %s\n' "$p"
}

do_arm() {
  local p
  if p="$(live_pid)"; then
    printf 'refused: a recorder is already running (pid %s); reap it with: %s stop\n' \
      "$p" "$0" >&2
    exit 2
  fi
  if [ ! -x "$bin" ] || [ "$src" -nt "$bin" ]; then
    /usr/bin/cc -O2 -Wall -Wextra -o "$bin.tmp.$$" "$src"
    mv "$bin.tmp.$$" "$bin"
  fi
  printf '%s\n' "$$" >"$pidfile"
  # exec: the pid in the pidfile stays the recorder's own pid, and no wrapper
  # shell is left behind for the reap to miss.
  exec "$bin" --record "$rec" --ttl "$ttl" \
    --note passive-recorder-not-a-watcher \
    --pattern-bait bin/ac-watch.sh
}

case "${1:-arm}" in
  arm) do_arm ;;
  stop) do_stop ;;
  *) ac_die "usage: $(basename "$0") [arm|stop]" ;;
esac
