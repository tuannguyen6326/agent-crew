#!/usr/bin/env bash
# ac-dashboard.sh - launch the agent-crew local web dashboard.
#
# Usage: ac-dashboard.sh [--port <N>]     (default port 8787; FOREGROUND)
#        ac-dashboard.sh start|stop|restart|status [--port <N>]
#        ac-dashboard.sh -h | --help
#
# The bare invocation runs `bun run <bin>/dashboard.ts` in the FOREGROUND:
# on-demand, Ctrl-C to stop, prints the URL, serves until interrupted. Before
# launching it does one cheap check that the port is free, so a second launch
# on a busy port fails with a clear message instead of a stack trace.
#
# DAEMON verbs (captain-facing lifecycle; the dashboard is a standing service
# of a home, so the ceremony of keeping a terminal window open for it is
# gone - launchd stays out, this is one detached process + one pidfile):
#   start    launch detached; pid -> $AC_HOME/state/dashboard.pid, log ->
#            $AC_HOME/state/dashboard.log; waits until the port answers and
#            prints the url (a boot that never answers is reported with the
#            log tail, and the dead pid is cleaned). Idempotent: an already-
#            running daemon is reported, never doubled; a port held by a
#            FOREIGN process still refuses.
#   stop     kill the recorded pid (verified to be dashboard.ts before the
#            kill - a recycled pid is never shot), wait until gone, remove
#            the pidfile. Idempotent ("not running" is a clean no-op); a
#            stale pidfile (dead process) is repaired, not obeyed.
#   restart  stop (tolerant) then start - the reload after a dashboard/ edit.
#   status   one line: running (pid + url) exit 0, or not running exit 1.
# The verbs need AC_HOME (the pidfile's home); the foreground path does not.
#
# The server is stateless and read-only over fleet task/session state - it
# never locks or drives a backend - but has FOUR write surfaces:
# POST /api/config writes ONE
# allowlisted flat value-file under <home>/config/; POST /api/dispatch
# atomic-writes config/crew-dispatch.json, the table deciding which
# harness/model every crewmate spawns on; and POST /api/whiteboard
# normalize+atomic-writes (or RENAMEs - never onto an existing name - or
# DELETEs, two-step-confirmed in the UI) ONE
# Excalidraw scene under <home>/whiteboards/
# (the /whiteboard editor page's save - the dashboard.ts whiteboard block owns
# the contract, incl. its pinned-CDN editor runtime); and the review routes
# publish ONE fleet wake (kind=review, via ac_wake_publish - never a
# re-implemented grammar) when captain feedback lands on a session nobody is
# polling, or when the captain reopens an ended one - deduped until a poller
# returns, so a message can never fall silent yet never floods the spool. Otherwise it only shells out to
# ac-fleets.sh --json / ac-room.sh and reads flat config/state/records/slots
# files and discovered artifacts. Bun runs the TypeScript with no build step
# (zero-install; the host already has Bun).
#
# Exit: 0 on clean shutdown; 2 bad args; 3 port busy; 4 bun missing.

set -euo pipefail
bin_dir="$(cd "$(dirname "$0")" && pwd -P)"

verb=""
case "${1:-}" in start|stop|restart|status) verb="$1"; shift ;; esac

port=8787
while [ $# -gt 0 ]; do
  case "$1" in
    --port)
      [ $# -ge 2 ] || { printf 'ac-dashboard.sh: --port needs a value\n' >&2; exit 2; }
      port="$2"; shift 2 ;;
    -h|--help) awk 'NR>1{if(!/^#/)exit; print}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'ac-dashboard.sh: unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$port" in
  ''|*[!0-9]*) printf 'ac-dashboard.sh: --port must be a number\n' >&2; exit 2 ;;
esac

command -v bun >/dev/null 2>&1 \
  || { printf 'ac-dashboard.sh: bun not found (needed to run dashboard.ts)\n' >&2; exit 4; }

port_answers() { (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; }

# The recorded pid counts only while it is alive AND still the dashboard -
# a recycled pid must read as "not running", never as a kill target.
pid_running() {
  local pid="$1"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null \
    && ps -o command= -p "$pid" 2>/dev/null | grep -q "dashboard.ts"
}

if [ -n "$verb" ]; then
  [ -n "${AC_HOME:-}" ] \
    || { printf 'ac-dashboard.sh %s: AC_HOME must be set (the pidfile lives in its state/)\n' "$verb" >&2; exit 2; }
  state_dir="$AC_HOME/state"
  pidfile="$state_dir/dashboard.pid"
  logfile="$state_dir/dashboard.log"
  mkdir -p "$state_dir"
  pid=""
  [ -f "$pidfile" ] && pid="$(cat "$pidfile" 2>/dev/null || printf '')"

  do_stop() {
    if pid_running "$pid"; then
      kill "$pid" 2>/dev/null || true
      for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
      rm -f "$pidfile"
      printf 'stopped (pid %s)\n' "$pid"
    else
      rm -f "$pidfile"
      printf 'not running\n'
    fi
  }

  do_start() {
    if pid_running "$pid" && port_answers; then
      printf 'already running (pid %s) - http://127.0.0.1:%s\n' "$pid" "$port"
      return 0
    fi
    rm -f "$pidfile"
    if port_answers; then
      printf 'ac-dashboard.sh start: 127.0.0.1:%s is held by a FOREIGN process - pick another port\n' "$port" >&2
      exit 3
    fi
    nohup bun run "$bin_dir/dashboard.ts" --port "$port" >"$logfile" 2>&1 &
    pid=$!
    disown "$pid" 2>/dev/null || true
    printf '%s\n' "$pid" >"$pidfile"
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
      port_answers && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    if ! port_answers; then
      printf 'ac-dashboard.sh start: the daemon never answered on %s - log tail:\n' "$port" >&2
      tail -5 "$logfile" >&2 || true
      kill "$pid" 2>/dev/null || true
      rm -f "$pidfile"
      exit 1
    fi
    printf 'started (pid %s) - http://127.0.0.1:%s (log: %s)\n' "$pid" "$port" "$logfile"
  }

  case "$verb" in
    status)
      if pid_running "$pid" && port_answers; then
        printf 'running (pid %s) - http://127.0.0.1:%s\n' "$pid" "$port"
        exit 0
      fi
      printf 'not running\n'
      exit 1 ;;
    stop) do_stop ;;
    start) do_start ;;
    restart) do_stop; pid=""; do_start ;;
  esac
  exit 0
fi

# Cheap busy-port guard (bash /dev/tcp, no external dependency): a successful
# connect in the subshell means something is already serving on that port.
if port_answers; then
  printf 'ac-dashboard.sh: 127.0.0.1:%s is already in use - a dashboard may already be running.\n' "$port" >&2
  printf '  stop it (Ctrl-C in its window, or ac-dashboard.sh stop) or pick another port: ac-dashboard.sh --port <N>\n' >&2
  exit 3
fi

printf 'http://127.0.0.1:%s\n' "$port"
exec bun run "$bin_dir/dashboard.ts" --port "$port"
