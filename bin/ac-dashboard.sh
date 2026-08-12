#!/usr/bin/env bash
# ac-dashboard.sh - launch the agent-crew local web dashboard.
#
# Usage: ac-dashboard.sh [--port <N>]     (default port 8787)
#        ac-dashboard.sh -h | --help
#
# Runs `bun run <bin>/dashboard.ts` in the FOREGROUND: on-demand, Ctrl-C to
# stop (D1 - no daemon, no launchd, no pid file, no host residue). Prints the
# URL, then serves until interrupted. Before launching it does one cheap check
# that the port is free, so a second launch on a busy port fails with a clear
# message instead of a stack trace (the hermes --status ergonomic, §6.2 - the
# ergonomic ONLY, never the daemon/stop/stale-PID machinery).
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

# Cheap busy-port guard (bash /dev/tcp, no external dependency): a successful
# connect in the subshell means something is already serving on that port.
if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
  printf 'ac-dashboard.sh: 127.0.0.1:%s is already in use - a dashboard may already be running.\n' "$port" >&2
  printf '  stop it (Ctrl-C in its window) or pick another port: ac-dashboard.sh --port <N>\n' >&2
  exit 3
fi

printf 'http://127.0.0.1:%s\n' "$port"
exec bun run "$bin_dir/dashboard.ts" --port "$port"
