#!/usr/bin/env bash
# ac-dashboard-daemon.test.sh - the dashboard daemon verbs: start detaches a
# background server (pid + log under $AC_HOME/state/), status answers from
# the pid AND the live port, restart replaces the process, stop kills it and
# cleans the pidfile; every verb is idempotent with a one-line receipt. The
# bare foreground invocation is untouched.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
DB="$BIN/ac-dashboard.sh"

# a free ephemeral port for the whole cycle
port=$((18000 + RANDOM % 2000))
while (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; do port=$((port + 1)); done

# status before anything: not running, exit 1
if "$DB" status --port "$port" >/dev/null 2>&1; then
  fail "status must exit non-zero while nothing runs"
fi

out="$("$DB" start --port "$port")"
assert_contains "$out" "http://127.0.0.1:$port" "start prints the url"
[ -f "$AC_HOME/state/dashboard.pid" ] || fail "start writes the pidfile"
pid1="$(cat "$AC_HOME/state/dashboard.pid")"
kill -0 "$pid1" 2>/dev/null || fail "the daemon process is alive"
assert_contains "$(ps -o command= -p "$pid1")" "$(cd "$ROOT" && pwd -P)/dashboard/app.ts" "the daemon runs dashboard/app.ts itself, no bin/ shim"
(exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || fail "the port answers after start"

out="$("$DB" status --port "$port")"
assert_contains "$out" "running" "status reports running"

# the server stamps its own log lines at the source (an ISO instant first),
# so a log read a day later still says WHEN each line happened
first="$(head -1 "$AC_HOME/state/dashboard.log")"
case "$first" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) ;;
  *) fail "log lines carry an ISO timestamp prefix, got: $first" ;;
esac

# idempotent start: reports the live daemon, never a second process
out="$("$DB" start --port "$port")"
assert_contains "$out" "already running" "a second start reports, never doubles"
# ... on another port too: the pidfile holds one pid, so a second daemon
# would be orphaned where no verb could stop it. A verb with no --port acts
# on the port the daemon really serves.
port2=$((port + 1))
while (exec 3<>"/dev/tcp/127.0.0.1/$port2") 2>/dev/null; do port2=$((port2 + 1)); done
out="$("$DB" start --port "$port2")"
assert_contains "$out" "already running (pid $pid1) - http://127.0.0.1:$port" "a start on another port reports the running daemon at its real port"
(exec 3<>"/dev/tcp/127.0.0.1/$port2") 2>/dev/null && fail "no second daemon may start on the other port"
assert_contains "$("$DB" status)" "http://127.0.0.1:$port" "status with no --port names the daemon's own port"

out="$("$DB" restart --port "$port")"
pid2="$(cat "$AC_HOME/state/dashboard.pid")"
[ "$pid1" != "$pid2" ] || fail "restart must replace the process (same pid kept)"
kill -0 "$pid2" 2>/dev/null || fail "the restarted daemon is alive"
(exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || fail "the port answers after restart"

out="$("$DB" stop)"
assert_contains "$out" "stopped" "stop reports"
kill -0 "$pid2" 2>/dev/null && fail "stop must kill the daemon"
[ ! -f "$AC_HOME/state/dashboard.pid" ] || fail "stop removes the pidfile"
# a stopped daemon says WHY it went down - the log's last word is the reason
assert_contains "$(cat "$AC_HOME/state/dashboard.log")" "shutdown: SIGTERM" "the log records the shutdown reason"
out="$("$DB" stop)"
assert_contains "$out" "not running" "a second stop is an idempotent no-op"

# A daemon the OLD code started still runs <root>/bin/dashboard.ts: after an
# upgrade, stop must still recognise and end it, never orphan it.
bun -e 'setTimeout(() => {}, 60000)' "$(cd "$ROOT" && pwd -P)/bin/dashboard.ts" --port "$port" &
old=$!
printf '%s\n' "$old" >"$AC_HOME/state/dashboard.pid"
"$DB" stop >/dev/null
kill -0 "$old" 2>/dev/null && { kill "$old"; fail "stop must end a daemon the pre-upgrade code started"; }

# A relative AC_HOME from a cwd that has no name is refused, never read in the
# distro checkout.
gone="$TMP/gone"
mkdir -p "$gone"
rc=0
(cd "$gone" && rmdir "$gone" && AC_HOME=relhome "$DB" --port "$port") >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "a relative AC_HOME from a nameless cwd is refused"

# An exported CDPATH never redirects the entry's own bin/ lookup.
mkdir -p "$TMP/cdp/bin"
out="$(cd "$ROOT" && CDPATH="$TMP/cdp" bin/ac-dashboard.sh status --port "$port" 2>&1 || true)"
assert_eq "$out" "not running" "an exported CDPATH never redirects the dashboard entry"

# a stale pidfile (process gone) is repaired, not obeyed
printf '999999\n' >"$AC_HOME/state/dashboard.pid"
if "$DB" status --port "$port" >/dev/null 2>&1; then
  fail "status with a stale pidfile and a dead port must exit non-zero"
fi
"$DB" start --port "$port" >/dev/null
kill -0 "$(cat "$AC_HOME/state/dashboard.pid")" 2>/dev/null || fail "start past a stale pidfile launches"
"$DB" stop >/dev/null
