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

# --- differential leg: src/dashboard.ts against the frozen bash original -----
# The frozen original (tests/fixtures/ac-dashboard.sh, run from an oracle bin
# beside the live scripts) and the shim each run a row's SCRIPT - one or more
# invocations against one home - in a world rebuilt from nothing, and the two
# transcripts are compared: per invocation its argv, exit status, stdout,
# stderr and the state/ files after it (pids spelled PID, the side's root
# ROOT). A daemon either side leaves behind is reaped between the sides, so
# each port is the oracle's first and the shim's next. `sleep` is the leg's
# stub: it logs its argument and returns at once, or really sleeps where the
# row runs a real dashboard (XSLEEP=real), whose waits are timing and are not
# compared. A divergence the port keeps on purpose is asserted on both sides.
# DISPUTED: the implementation (tests/fixtures/ac-dashboard.sh under bash vs src/dashboard.ts through bin/ac-dashboard.sh)
# HELD-CONSTANT: one world path ($XW: home/ with state/, cwd/, log/) rebuilt by the row's world function before each side; the row's script (argv per invocation); the leg's free ports (one per role, probed free at the start, the FOREIGN one held by the leg's own listener); env (AC_HOME=$XW/home unless the row is homeless or names another, LC_ALL=C, PATH the leg's stubs - sleep, and bun where the row fakes the daemon - before the suite's unless the row names one; CDPATH, LANG, LC_CTYPE, AC_FLEET_STATE and AC_SCOPE unset); cwd ($XW/cwd, deleted first where the row says); stdin (/dev/null); per invocation exit status, stdout, stderr and the state/ files compared whole after the normalisation above.
xobin="$(make_oracle_bin ac-dashboard)"
cmp -s "$xobin/ac-dashboard.sh" "$ROOT/tests/fixtures/ac-dashboard.sh" || fail "the oracle bin holds the frozen original"
xoroot="$(cd "$xobin/.." && pwd -P)"
xnroot="$(cd "$ROOT" && pwd -P)"
XW="$TMP/xw"; XS="$TMP/xstubs"
mkdir -p "$XS"
XREALBUN="$(command -v bun)"
cat >"$XS/sleep" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$XW/log/sleep.log"
[ "${XSLEEP:-}" != real ] || exec /bin/sleep "$@"
exit 0
STUB
# A daemon either side starts is `bun --no-env-file <root>/dashboard/app.ts
# ...` found on PATH; under XFAKE this bun answers that one call itself: it
# records its argv, cwd and the INT/QUIT dispositions it inherited, then dies
# at once (XFAKE=die) or lives without binding (XFAKE=mute).
cat >"$XS/bun" <<'STUB'
#!/bin/sh
case "${XFAKE:-}:$2" in
  ?*:*/dashboard/app.ts)
    { printf '%s\n' "$@"; pwd -P; python3 -c 'import signal; print(signal.getsignal(signal.SIGINT), signal.getsignal(signal.SIGQUIT))'; } >"$XW/log/daemon"
    echo boom
    [ "$XFAKE" = die ] && exit 3
    exec /bin/sleep 60 ;;
esac
exec "$XREALBUN" "$@"
STUB
chmod +x "$XS/sleep" "$XS/bun"
xpicked=""
xfree() {  # xfree - appends to xpicked a port no one answers on, distinct from the ones picked
  local p=$((23000 + RANDOM % 2000))
  while (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null || case " $xpicked " in *" $p "*) true ;; *) false ;; esac; do p=$((p + 1)); done
  xpicked="$xpicked $p"
}
# Called in this shell, never under `$(...)`, whose subshell would drop the pick.
xfree; xfree; xfree; xfree
read -r XP XP2 XPF XPG <<<"$xpicked"
"$XREALBUN" -e "Bun.listen({ hostname: '127.0.0.1', port: $XPF, socket: { data() {} } }); setTimeout(() => {}, 600000);" &
xforeign=$!
disown "$xforeign"
xstrays=""
xreap() {  # xreap - the side's daemon (by its cmdline) and the leg's helpers are killed
  local p
  p="$(cat "$XW/home/state/dashboard.pid" 2>/dev/null || true)"
  case "$p" in
    *[!0-9]* | "") ;;
    *) case "$(ps -o command= -p "$p" 2>/dev/null || true)" in */dashboard/app.ts* | */bin/sleep*) kill -9 "$p" 2>/dev/null || true ;; esac ;;
  esac
  for p in $xstrays; do kill -9 "$p" 2>/dev/null || true; done
  xstrays=""
}
trap 'xreap; kill "$xforeign" 2>/dev/null || true; cleanup' EXIT
xi=0
until (exec 3<>"/dev/tcp/127.0.0.1/$XPF") 2>/dev/null; do
  xi=$((xi + 1)); [ "$xi" -lt 100 ] || fail "the leg's FOREIGN listener never answered on $XPF"
  sleep 0.1
done

XPATH=""; XHOMELESS=0; XE=""; XGONE=0; XB=""; XT=""; XROOT=""
xdo() {  # xdo <args...> - one invocation on the current side, appended to its transcript
  local path="$XS:$PATH" rc=0 x
  [ -z "$XPATH" ] || path="$XPATH"
  local e=("PATH=$path" "LC_ALL=C" "XW=$XW" "XREALBUN=$XREALBUN" "XSLEEP=${XSLEEP:-}" "XFAKE=${XFAKE:-}")
  [ "$XHOMELESS" = 1 ] || e+=("AC_HOME=$XW/home")
  for x in $XE; do e+=("$x"); done
  ( cd "$XW/cwd" || exit 97
    [ "$XGONE" = 0 ] || rm -rf "$XW/cwd"
    exec env -u AC_HOME -u CDPATH -u LANG -u LC_CTYPE -u AC_FLEET_STATE -u AC_SCOPE "${e[@]}" "$XB/ac-dashboard.sh" ${@+"$@"}
  ) </dev/null >"$TMP/$XT.out" 2>"$TMP/$XT.err" || rc=$?
  # From a deleted cwd every bash prints its own getcwd lines, the original
  # one per cd it ran and the shim fewer (SHELL-OWN): both sides drop them.
  if [ "$XGONE" = 1 ]; then
    grep -av -e '^shell-init: error retrieving current directory' -e '^chdir: error retrieving current directory' "$TMP/$XT.err" >"$TMP/$XT.err.kept" || true
    mv "$TMP/$XT.err.kept" "$TMP/$XT.err"
  fi
  {
    printf '== %s\nrc=%s\n-- stdout\n' "$*" "$rc"
    cat "$TMP/$XT.out"
    printf -- '-- stderr\n'
    cat "$TMP/$XT.err"
    printf -- '-- state/\n'
    ls -A "$XW/home/state" 2>/dev/null || true
    [ ! -f "$XW/home/state/dashboard.pid" ] || printf 'dashboard.pid: %s\n' "$(sed 's/^[0-9][0-9]*$/PID/' "$XW/home/state/dashboard.pid")"
    [ ! -f "$XW/home/state/dashboard.port" ] || printf 'dashboard.port: %s\n' "$(cat "$XW/home/state/dashboard.port")"
  } >>"$TMP/$XT.raw"
  XRC=$rc
}
xnorm() { sed -e 's/(pid [0-9][0-9]*)/(pid PID)/g' -e "s#$2#ROOT#g" "$1"; }
xrow() {  # xrow <world fn> <script fn> - the script on each side in its own fresh world, transcripts alike
  local wf="$1" sf="$2" at
  at="${BASH_LINENO[0]}"
  rm -f "$TMP/xo.raw" "$TMP/xn.raw"
  XB="$xobin"; XT=xo; XROOT="$xoroot"; "$wf"; "$sf"; cp "$XW/log/sleep.log" "$TMP/xo.sleep" 2>/dev/null || : >"$TMP/xo.sleep"; cp "$XW/log/daemon" "$TMP/xo.daemon" 2>/dev/null || : >"$TMP/xo.daemon"; xreap
  XB="$BIN"; XT=xn; XROOT="$xnroot"; "$wf"; "$sf"; cp "$XW/log/sleep.log" "$TMP/xn.sleep" 2>/dev/null || : >"$TMP/xn.sleep"; cp "$XW/log/daemon" "$TMP/xn.daemon" 2>/dev/null || : >"$TMP/xn.daemon"; xreap
  xnorm "$TMP/xo.raw" "$xoroot" >"$TMP/xo.t"
  xnorm "$TMP/xn.raw" "$xnroot" >"$TMP/xn.t"
  cmp -s "$TMP/xo.t" "$TMP/xn.t" || fail "dashboard differential transcript differs for $sf at line $at: $(diff "$TMP/xo.t" "$TMP/xn.t" | head -n 12)"
  [ "${XSLEEP:-}" = real ] || cmp -s "$TMP/xo.sleep" "$TMP/xn.sleep" || fail "dashboard differential sleep calls differ for $sf at line $at: $(diff "$TMP/xo.sleep" "$TMP/xn.sleep" | head -n 4)"
  cmp -s <(xnorm "$TMP/xo.daemon" "$xoroot") <(xnorm "$TMP/xn.daemon" "$xnroot") || fail "dashboard differential daemon launch differs for $sf at line $at: $(diff "$TMP/xo.daemon" "$TMP/xn.daemon" | head -n 6)"
}
xt() { xnorm "$TMP/xn.raw" "$xnroot"; }   # the shim's normalised transcript of the last row
xseed() { rm -rf "$XW"; mkdir -p "$XW/home" "$XW/cwd" "$XW/log"; }
xhead() { awk 'NR>1{if(!/^#/)exit; print}' "$ROOT/tests/fixtures/ac-dashboard.sh" | sed 's/^# \{0,1\}//'; }
xmodhead() { awk '!/^\/\//{exit} {sub(/^\/\/ ?/, ""); print}' "$ROOT/src/dashboard.ts"; }

# 1. arguments: every refusal is exit 2 with one line, before AC_HOME or a
#    port is looked at; a verb is only the first word; the last --port wins.
s_args() {
  xdo --port; xdo --port ''; xdo --port x1; xdo --port -5; xdo --port 1.5; xdo --bogus; xdo ''
  xdo --port 1 start; xdo start --bogus; xdo stop --port; xdo status --port abc; xdo --bogus -h
  xdo status --port 1 --port x
}
xrow xseed s_args
assert_contains "$(xt)" "== --port 1 start
rc=2
-- stdout
-- stderr
ac-dashboard.sh: unknown arg: start" "row 1: a verb is only the first word"
assert_contains "$(xt)" "== --port x1
rc=2
-- stdout
-- stderr
ac-dashboard.sh: --port must be a number" "row 1: a port is digits"
# USAGE HEADER, named: each side prints its own header, exit 0.
for xa in -h --help; do
  XB="$xobin"; XT=xo; xseed; rm -f "$TMP/xo.raw"; xdo start "$xa"
  assert_eq "$XRC:$(cat "$TMP/xo.out")" "0:$(xhead)" "USAGE HEADER: the original printed its own header for $xa"
  XB="$BIN"; XT=xn; xseed; rm -f "$TMP/xn.raw"; xdo start "$xa"
  assert_eq "$XRC:$(cat "$TMP/xn.out")" "0:$(xmodhead)" "USAGE HEADER: the port prints src/dashboard.ts's header for $xa"
done

# 2. homeless verbs refuse with exit 2 and create nothing; an empty home and a
#    home with nothing recorded answer `not running`.
s_homeless() { for v in status start stop restart; do xdo "$v"; done; }
XHOMELESS=1 xrow xseed s_homeless
XE="AC_HOME=" xrow xseed s_homeless
assert_contains "$(xt)" "ac-dashboard.sh restart: AC_HOME must be set (the pidfile lives in its state/)" "row 2: the verb names itself"
s_empty() { xdo status; xdo status --port "$XP"; xdo stop; xdo stop; }
xrow xseed s_empty
assert_contains "$(xt)" "== status
rc=1
-- stdout
not running" "row 2: status with nothing recorded"

# 3. stale and foreign pidfiles: status never repairs, stop does; a pid that
#    is alive but no dashboard of THIS root (a recycled pid) is never shot,
#    nor one this user may not signal; one whose cmdline names <root>/bin/
#    dashboard.ts (a pre-upgrade daemon) is stopped. The port file's text is
#    the port a verb with no --port acts on.
w_stale() { xseed; mkdir -p "$XW/home/state"; printf '999999\n' >"$XW/home/state/dashboard.pid"; printf 'http\n' >"$XW/home/state/dashboard.port"; }
s_stale() { xdo status; xdo status --port "$XP"; xdo stop; xdo status; }
xrow w_stale s_stale
xsleeper() {  # xsleeper <cmdline word> - a live process the pidfile names
  "$XREALBUN" -e 'setTimeout(() => {}, 60000)' "$1" &
  xstrays="$xstrays $!"
  printf '%s\n' "$!" >"$XW/home/state/dashboard.pid"
  disown "$!"
}
w_state() { xseed; mkdir -p "$XW/home/state"; }
s_recycled() {
  xsleeper "$XW/not-a-dashboard.ts"
  local p; p="$(cat "$XW/home/state/dashboard.pid")"
  xdo status; xdo stop
  kill -0 "$p" 2>/dev/null || fail "a recycled pid was shot ($XT)"
}
xrow w_state s_recycled
s_preupgrade() {
  xsleeper "$XROOT/bin/dashboard.ts"
  local p; p="$(cat "$XW/home/state/dashboard.pid")"
  printf '%s\n' "$XP" >"$XW/home/state/dashboard.port"
  xdo status; xdo stop
  local i=0
  while kill -0 "$p" 2>/dev/null && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i + 1)); done
  kill -0 "$p" 2>/dev/null && fail "a pre-upgrade daemon was not stopped ($XT)"
  return 0
}
XSLEEP=real xrow w_state s_preupgrade
assert_contains "$(xt)" "stopped (pid PID)" "row 3: the pre-upgrade daemon is stopped"
if [ "$(id -u)" != 0 ]; then
  s_pid1() { printf '1\n' >"$XW/home/state/dashboard.pid"; xdo status; xdo stop; }
  xrow w_state s_pid1
fi

# 4. the lifecycle against a real dashboard: start, status, a second start, a
#    start on another port, status with no --port, restart, a SIGQUIT the
#    daemon ignores, stop, stop again. The daemon's cmdline is the original's
#    (bun from PATH on <root>/dashboard/app.ts, the caller's cwd, the port).
s_life() {
  local p
  xdo start --port "$XP"
  p="$(cat "$XW/home/state/dashboard.pid")"
  printf 'cmdline: %s\n' "$(ps -o command= -p "$p")" >>"$TMP/$XT.raw"
  xdo status
  xdo start --port "$XP"
  xdo start --port "$XP2"
  xdo status
  xdo restart
  p="$(cat "$XW/home/state/dashboard.pid")"
  kill -QUIT "$p" 2>/dev/null || true
  sleep 0.3
  kill -0 "$p" 2>/dev/null && printf 'SIGQUIT: ignored\n' >>"$TMP/$XT.raw"
  xdo status --port "$XP"
  printf '0%s\n' "$XP" >"$XW/home/state/dashboard.port"
  xdo status
  xdo stop
  printf 'log: %s\n' "$(tail -n 1 "$XW/home/state/dashboard.log" | sed 's/^[0-9T:.Z-]* //')" >>"$TMP/$XT.raw"
  xdo stop
  xdo status
}
XSLEEP=real xrow xseed s_life
assert_contains "$(xt)" "started (pid PID) - http://127.0.0.1:$XP (log: $XW/home/state/dashboard.log)" "row 4: start"
assert_contains "$(xt)" "cmdline: $XREALBUN --no-env-file ROOT/dashboard/app.ts $XW/cwd --port $XP" "row 4: the daemon runs dashboard/app.ts itself (PATH's bun, here the leg's pass-through)"
assert_contains "$(xt)" "running (pid PID) - http://127.0.0.1:0$XP" "row 4: the port file's text is the port, read by getaddrinfo"
assert_contains "$(xt)" "already running (pid PID) - http://127.0.0.1:$XP (restart --port $XP2 moves it)" "row 4: a start on another port reports the real one"
assert_contains "$(xt)" "SIGQUIT: ignored" "row 4: the daemon ignores QUIT as a shell's background job did"
assert_contains "$(xt)" "log: shutdown: SIGTERM" "row 4: stop TERMs the daemon"

# 5. a FOREIGN process on the port: start refuses 3 having removed the
#    pidfile but not the port file; the foreground refuses 3 with two lines.
w_foreign() { w_state; printf '999999\n' >"$XW/home/state/dashboard.pid"; printf '%s\n' "$XPF" >"$XW/home/state/dashboard.port"; }
s_foreign() { xdo start; xdo status; xdo --port "$XPF"; }
xrow w_foreign s_foreign
assert_contains "$(xt)" "ac-dashboard.sh start: 127.0.0.1:$XPF is held by a FOREIGN process - pick another port
-- state/
dashboard.port
dashboard.port: $XPF" "row 5: the pidfile goes, the port file stays"

# 6. a daemon that never answers: one that dies at once (the log tail shows
#    it), and one that lives without binding (20 waits, then TERMed); both
#    exit 1 with the files removed. The fake records the launch: argv, cwd,
#    and INT and QUIT ignored as a non-interactive shell's job had them.
s_never() { xdo start --port "$XP"; }
XFAKE=mute xrow xseed s_never
assert_contains "$(xt)" "ac-dashboard.sh start: the daemon never answered on $XP - log tail:
boom" "row 6: a mute daemon"
assert_eq "$(grep -c . "$TMP/xn.sleep")" "20" "row 6: twenty waits"
assert_eq "$(xnorm "$TMP/xn.daemon" "$xnroot")" "--no-env-file
ROOT/dashboard/app.ts
$XW/cwd
--port
$XP
ROOT
1 1" "row 6: the launch"
XSLEEP=real XFAKE=die xrow xseed s_never
w_badlog() { w_state; mkdir "$XW/home/state/dashboard.log"; }
# SHELL-OWN, named: a log that cannot be opened was the original's own
# redirection line in its forked daemon; here nothing starts. Both exit 1 with
# the never-answered line and tail's own refusal, and remove the files.
XB="$xobin"; XT=xo
w_badlog; rm -f "$TMP/xo.raw"; xdo start --port "$XP"; xo_rc=$XRC; grep -v ': line [0-9]*: ' "$TMP/xo.err" >"$TMP/xo.err2" || true; xreap
XB="$BIN"; XT=xn
w_badlog; rm -f "$TMP/xn.raw"; xdo start --port "$XP"; xreap
assert_eq "$xo_rc:$XRC" "1:1" "SHELL-OWN: an unopenable log fails both sides"
assert_contains "$(cat "$TMP/xo.err")" "dashboard.log: Is a directory" "SHELL-OWN: the original's fork printed the shell's line"
assert_eq "$(cat "$TMP/xn.err")" "$(cat "$TMP/xo.err2")" "SHELL-OWN: the rest of stderr is alike"
assert_no_file "$XW/home/state/dashboard.pid" "SHELL-OWN: the pidfile is removed"

# 7. the foreground serves until TERMed: the URL, the server's own lines (its
#    instants spelled T), the last --port winning, a leading zero read by
#    getaddrinfo and by app.ts alike; a relative AC_HOME from a cwd that has
#    no name prints the URL and is refused, exit 1, on both sides.
xfg() {  # xfg <args...> - the foreground on the current side, TERMed once its port answers
  local pid rc=0 i=0
  ( cd "$XW/cwd" && exec env -u AC_HOME -u CDPATH -u LANG -u LC_CTYPE PATH="$XS:$PATH" LC_ALL=C XW="$XW" XREALBUN="$XREALBUN" AC_HOME="$XW/home" "$XB/ac-dashboard.sh" "$@" ) </dev/null >"$TMP/$XT.out" 2>"$TMP/$XT.err" &
  pid=$!
  until (exec 3<>"/dev/tcp/127.0.0.1/$XPG") 2>/dev/null; do
    i=$((i + 1)); [ "$i" -lt 100 ] && kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
  done
  sleep 0.3
  kill -TERM "$pid" 2>/dev/null || true
  { wait "$pid"; } 2>/dev/null || rc=$?
  { printf '== %s\nrc=%s\n' "$*" "$rc"; sed 's/^[0-9][0-9T:.Z-]* /T /' "$TMP/$XT.out"; cat "$TMP/$XT.err"; } >>"$TMP/$XT.raw"
}
# A home the server's watchers find whole, so no ENOENT line races the TERM.
w_fg() { xseed; mkdir -p "$XW/home/state" "$XW/home/data" "$XW/home/records" "$XW/home/config" "$XW/home/projects"; }
s_fg() { xfg --port "$XPG"; xfg --port 1 --port "$XPG"; xfg --port "0$XPG"; }
xrow w_fg s_fg
assert_contains "$(xt)" "== --port 1 --port $XPG
rc=143
http://127.0.0.1:$XPG
T agent-crew dashboard serving on http://127.0.0.1:$XPG  (Ctrl-C to stop)" "row 7: the last --port is the one served"
assert_contains "$(xt)" "T shutdown: SIGTERM" "row 7: TERM ends the foreground through the server's handler"
assert_contains "$(xt)" "http://127.0.0.1:0$XPG
T agent-crew dashboard serving on http://127.0.0.1:$XPG " "row 7: a leading zero"
s_relhome() { xdo --port "$XPG"; }
XGONE=1 XE="AC_HOME=rel" xrow w_state s_relhome
assert_contains "$(xt)" "rc=1
-- stdout
http://127.0.0.1:$XPG
-- stderr
ERROR: the current directory cannot be resolved, so a relative AC_HOME cannot be either" "row 7: a relative home from a nameless cwd"
# HOME RESOLUTION, named: the verbs refuse that home with the same line, where
# the original's mkdir -p failed in the deleted directory.
XGONE=1; XE="AC_HOME=rel"; XB="$xobin"; XT=xo
w_state; rm -f "$TMP/xo.raw"; xdo status; xo_rc=$XRC
XB="$BIN"; XT=xn
w_state; rm -f "$TMP/xn.raw"; xdo status
XGONE=0; XE=""
assert_eq "$xo_rc:$XRC" "1:1" "HOME RESOLUTION: a relative home from a nameless cwd fails both verbs"
assert_contains "$(cat "$TMP/xo.err")" "mkdir: rel" "HOME RESOLUTION: the original's mkdir failed"
assert_eq "$(cat "$TMP/xn.err")" "ERROR: the current directory cannot be resolved, so a relative AC_HOME cannot be either" "HOME RESOLUTION: the port refuses it"

# 8. BUN, named: without bun the shim refuses first (exit 1); the original
#    refused a bad argument (2), then exited 4 with its own line.
xnobun="$TMP/xnobun"
mkdir -p "$xnobun"
for x in bash env dirname mkdir cat rm awk sed ps; do ln -sf "$(command -v "$x")" "$xnobun/$x"; done
s_nobun() { xdo --port x; xdo status; }
XPATH="$xnobun"; XB="$xobin"; XT=xo
xseed; rm -f "$TMP/xo.raw"; s_nobun
XB="$BIN"; XT=xn
xseed; rm -f "$TMP/xn.raw"; s_nobun
XPATH=""
assert_contains "$(cat "$TMP/xo.raw")" "== status
rc=4
-- stdout
-- stderr
ac-dashboard.sh: bun not found (needed to run dashboard/app.ts)" "BUN: the original's own line, exit 4"
assert_contains "$(cat "$TMP/xo.raw")" "== --port x
rc=2" "BUN: the original refused the argument first"
assert_contains "$(cat "$TMP/xn.raw")" "== --port x
rc=1
-- stdout
-- stderr
ERROR: required tool not found: bun" "BUN: the shim refuses first"

pass
