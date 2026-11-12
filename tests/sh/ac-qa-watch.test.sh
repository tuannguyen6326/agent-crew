#!/usr/bin/env bash
# ac-qa-watch.test.sh - RUN_BASE must resolve to .crew/qa, never accidentally
# to its sibling .crew/ship (bin/ac-qa-watch.sh's RUN_BASE) - ac-qa.test.sh and
# tests/sh/ac-watch-dash.test.sh only ever exercise a run that already exists at
# the RIGHT path, so a copy-paste RUN_BASE regression between the two
# near-identical watch scripts (ac-ship-watch.sh is the twin) would go
# uncaught.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

repo="$(make_repo qawatchrepo)"
# A ship run exists, but no qa run - the qa watch must still report "no
# active run", proving it looks at .crew/qa and not .crew/ship.
mkdir -p "$repo/.crew/ship/s1"
printf 'outcome=running\n' >"$repo/.crew/ship/s1/run.meta"
ln -sfn s1 "$repo/.crew/ship/current"

out="$("$BIN/ac-qa-watch.sh" --repo "$repo" --once)"
assert_eq "$out" "no active qa run in $repo" \
  "ac-qa-watch.sh must read .crew/qa, not a sibling ship run"

# --- the qa role's bytes, row by row ------------------------------------------
# Each row runs the shim in a world rebuilt from nothing ($XW: a git repo at
# repo/ with the row's .crew/qa run dir, home/config/, log/, hooks/), cwd
# $XW/repo, stdin /dev/null, under the leg's PATH stubs: a sleep that logs each
# call, runs the row's hook, and from call XKILL on signals its parent and
# waits for it to go; a logging herdr; a date answering 1767225600 for %s. The
# role's own bytes are here (the header, the step table at width 12, the case
# ledger, its idle files and knob), the shared body's in
# tests/sh/ac-watch-dash.test.sh.
XW="$TMP/xw"; XS="$TMP/xstubs"
mkdir -p "$XS"
cat >"$XS/sleep" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$XW/log/sleep.log"
n=$(wc -l <"$XW/log/sleep.log" | tr -d ' ')
[ ! -f "$XW/hooks/$n" ] || . "$XW/hooks/$n"
if [ "$n" -ge "${XKILL:-999}" ]; then
  kill -"${XSIG:-TERM}" "$PPID"
  i=0
  while kill -0 "$PPID" 2>/dev/null && [ "$i" -lt 40 ]; do /bin/sleep 0.05; i=$((i + 1)); done
fi
exit 0
STUB
cat >"$XS/herdr" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$XW/log/herdr.log"
exit 0
STUB
cat >"$XS/date" <<'STUB'
#!/bin/sh
case "$*" in *%s*) echo 1767225600 ;; *) exec /bin/date "$@" ;; esac
STUB
# A job a non-interactive shell starts may hold SIGINT ignored, which bash
# cannot trap; a SIGINT row runs the board with INT at its default first.
cat >"$XS/int-default" <<'STUB'
#!/usr/bin/env python3
import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])
STUB
chmod +x "$XS/sleep" "$XS/herdr" "$XS/date" "$XS/int-default"

XLC=C; XTERMV=xterm; XHOMELESS=0; XE=""; XPATH=""; XWRAP=""; XTTY=0; XKILL=999; XSIG=TERM; XCWD=repo; XRC=0
xside() {  # xside <bin> <entry> <prefix> <args...> - one run in the current world (XTTY=1: on a pty, stderr in stdout), SIGKILLed past 30 s
  local bin="$1" entry="$2" p="$3" path x dog rc=0
  shift 3
  path="$XS:$PATH"; [ -z "$XPATH" ] || path="$XPATH"
  local e=("PATH=$path" "XW=$XW" "XKILL=$XKILL" "XSIG=$XSIG" "LC_ALL=$XLC")
  [ "$XTERMV" = unset ] || e+=("TERM=$XTERMV")
  [ "$XHOMELESS" = 1 ] || e+=("AC_HOME=$XW/home")
  for x in $XE; do e+=("$x"); done
  local u=(-u AC_HOME -u TERM -u AC_HERDR_SESSION -u AC_SHIP_WATCH_IDLE -u AC_QA_WATCH_IDLE -u AC_FLEET_STATE -u AC_SCOPE
    -u LANG -u LC_CTYPE -u COLUMNS -u LINES -u CDPATH -u EPOCHSECONDS)
  rm -f "$TMP/$p.pid" "$TMP/$p.done"
  ( n=0 x="" id=""
    until [ -e "$TMP/$p.done" ] || [ "$n" -ge 300 ]; do
      [ -n "$id" ] || { x="$(cat "$TMP/$p.pid" 2>/dev/null || true)"; id="$(proc_identity "$x")"; }
      sleep 0.1; n=$((n + 1))
    done
    [ -e "$TMP/$p.done" ] || ! same_process "$x" "$id" || kill -9 "$x" 2>/dev/null || true ) &
  dog=$!
  if [ "$XTTY" = 1 ]; then
    (cd "$XW/$XCWD" && run_on_tty /bin/sh -c 'printf %s "$$" >"$0"; exec "$@"' "$TMP/$p.pid" \
      env "${u[@]}" "${e[@]}" "$bin/$entry" ${@+"$@"}) >"$TMP/$p.out" 2>&1 || rc=$?
    : >"$TMP/$p.err"
  else
    # The braces' stderr takes the shell's own job notice for a run a signal
    # ended; the status is kept.
    { (cd "$XW/$XCWD" && exec $XWRAP /bin/sh -c 'printf %s "$$" >"$0"; exec "$@"' "$TMP/$p.pid" \
      env "${u[@]}" "${e[@]}" "$bin/$entry" ${@+"$@"}) </dev/null >"$TMP/$p.out" 2>"$TMP/$p.err"; } 2>/dev/null || rc=$?
  fi
  : >"$TMP/$p.done"
  wait "$dog" 2>/dev/null || true
  cat "$XW/log/sleep.log" >"$TMP/$p.sleep" 2>/dev/null || : >"$TMP/$p.sleep"
  cat "$XW/log/herdr.log" >"$TMP/$p.herdr" 2>/dev/null || : >"$TMP/$p.herdr"
  (cd "$XW/repo" && find .crew -print 2>/dev/null | LC_ALL=C sort) >"$TMP/$p.world" || true
  XRC=$rc
}
XN_RC=0
xrun() {  # xrun <world fn> <entry> <args...> - the shim in a fresh world; sets XN_RC
  local wf="$1" entry="$2"; shift 2
  "$wf"; xside "$BIN" "$entry" xn ${@+"$@"}; XN_RC=$XRC
}
xout() { cat "$TMP/xn.out"; }
xerr() { cat "$TMP/xn.err"; }
xcount() {  # xcount <needle> <file> - how many times <needle> occurs in <file>
  local rest n=0
  rest="$(cat "$2")"
  while [ "${rest#*"$1"}" != "$rest" ]; do rest="${rest#*"$1"}"; n=$((n + 1)); done
  printf '%s' "$n"
}
xseed() {
  rm -rf "$XW"
  mkdir -p "$XW/home/config" "$XW/log" "$XW/hooks" "$XW/repo/sub"
  git init -q -b main "$XW/repo" >/dev/null 2>&1
}
xrd() {  # xrd <ship|qa> <id> - a run dir with logs/ and findings/, current pointing at it; sets XRD
  XRD="$XW/repo/.crew/$1/$2"
  mkdir -p "$XRD/logs" "$XRD/findings"
  ln -sfn "$2" "$XW/repo/.crew/$1/current"
}
xhook() { printf '%s\n' "$2" >"$XW/hooks/$1"; }   # xhook <call> <sh> - run by the sleep stub at that call, before its signal
xold() { TZ=UTC0 touch -t 202512300000 "$@"; }     # two days before the date stub's instant
xnow() { TZ=UTC0 touch -t 202601010000 "$@"; }     # the date stub's instant (1767225600)
XE_ACCENTS="$(printf 'é%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60)"
w_qa() {  # w_qa <outcome> - a qa run: task dash, one completed step, a log line
  xseed; xrd qa q1
  printf 'task=dash\ntarget=the widget\noutcome=%s\n' "$1" >"$XRD/run.meta"
  printf 'pin\tcompleted\t0\t-\n' >"$XRD/steps.tsv"
  printf '2026-01-01T00:00:00Z go\n' >"$XRD/logs/run.log"
}

# 1. the step table: a 3-column row shows `round 2`; `awaiting_approval`
#    overflows the 12-byte column; the header with an absent task, a target of
#    60 x `é` cut at 110 BYTES (55 of them), and the last outcome key.
w_steps() {
  w_qa running
  printf 'pin\tcompleted\t0\t-\nhand\tfixing\t2\nwait\tawaiting_approval\t0\t-\n' >"$XRD/steps.tsv"
  printf 'target=%s\noutcome=running\noutcome=passed\n' "$XE_ACCENTS" >"$XRD/run.meta"
}
xrun w_steps ac-qa-watch.sh --once
assert_eq "$XN_RC:$(xerr)" "0:" "row 1: --once renders and exits 0"
for want in "$(printf ' %s %-10s %-12s %s' ▶ hand fixing 'round 2')" \
  "$(printf ' %s %-10s %-12s %s' ⏸ wait awaiting_approval '')"; do
  assert_contains "$(xout)" "$want
" "row 1: the step table holds [$want]"
done
assert_contains "$(xout)" "ac-qa   run q1  [passed]
target: $(printf 'é%.0s' $(seq 1 55))
" "row 1: no task, the last outcome, 110 bytes of target"
case "$(xout)" in *"run finished"*) fail "row 1: fixing steps keep the run open" ;; esac

# 2. the case ledger: absent and zero bytes (no section); ten rows - pass,
#    fail and unverifiable, grade `-` and set, a 30-byte id, an unterminated
#    last row - of which the last 8 show.
w_nocases() { w_qa passed; }
w_zerocases() { w_qa passed; : >"$XRD/cases.tsv"; }
w_cases() {
  w_qa passed
  printf 'c1\tapi\tpass\tx\tx\tA\nc2\tdb\tfail\tx\tx\t-\nc3\tweb\tunverifiable\tx\tx\tD\nc4\tapi\tpass\tx\tx\tB\nthirtybytecaseidentifier123456\tui\tpass\tx\tx\tC\nc6\tapi\tpass\tx\tx\t-\nc7\tapi\tpass\tx\tx\t-\nc8\tapi\tfail\tx\tx\t-\nc9\tapi\tpass\tx\tx\t-\nunterm\tx\tpass\tx\tx\t-' >"$XRD/cases.tsv"
}
xrun w_nocases ac-qa-watch.sh --once
assert_eq "$XN_RC" "0" "row 2: no ledger renders"
case "$(xout)" in *cases*) fail "row 2: no ledger, no section" ;; esac
xrun w_zerocases ac-qa-watch.sh --once
assert_eq "$XN_RC" "0" "row 2: an empty ledger renders"
case "$(xout)" in *cases*) fail "row 2: an empty ledger, no section" ;; esac
xrun w_cases ac-qa-watch.sh --once
assert_contains "$(xout)" " 7 pass  2 fail  1 unverifiable
" "row 2: the counts (the unterminated row counted)"
for want in "$(printf '   ? %-22s %-4s %-13s %s' c3 web unverifiable 'grade D')" "$(printf '   ✓ %-22s %-4s %-13s %s' c4 api pass 'grade B')" \
  "$(printf '   ✓ %-22s %-4s %-13s %s' thirtybytecaseidentifier123456 ui pass 'grade C')" "$(printf '   ✓ %-22s %-4s %-13s %s' c7 api pass '')" \
  "$(printf '   ✗ %-22s %-4s %-13s %s' c8 api fail '')" "$(printf '   ✓ %-22s %-4s %-13s %s' unterm x pass '')"; do
  assert_contains "$(xout)" "$want
" "row 2: the ledger holds [$want]"
done
case "$(xout)" in *" c1 "*|*" c2 "*) fail "row 2: only the last 8 rows show" ;; esac
# A NUL ends its row, the later fields with it: the status before it counts.
w_nulcases() { w_qa passed; printf 'c1\tapi\tpass\0x\tx\tA\nc2\tdb\tfail\tx\tx\t-\n' >"$XRD/cases.tsv"; }
xrun w_nulcases ac-qa-watch.sh --once
assert_contains "$(xout)" " 1 pass  1 fail  0 unverifiable
" "row 2: a NUL cuts its case row"
case "$(xout)" in *"grade A"*) fail "row 2: a field after a NUL is not read" ;; esac
if [ "$(id -u)" != 0 ]; then
  w_lockedcases() { w_cases; chmod 000 "$XRD/cases.tsv"; }
  xrun w_lockedcases ac-qa-watch.sh --once
  assert_eq "$XN_RC:$(xerr)" "0:" "row 2: an unreadable ledger renders, silent on stderr"
  assert_contains "$(xout)" "0 pass  0 fail  0 unverifiable" "row 2: an unreadable ledger counts 0"
  case "$(xout)" in *" c9 "*) fail "row 2: an unreadable ledger lists no row" ;; esac
fi

# 3. finished detection: an awaiting_approval step holds no qa run open
#    (`run finished: passed`); a running outcome does.
w_awaiting() { w_qa passed; printf 'review\tawaiting_approval\t0\t-\n' >"$XRD/steps.tsv"; }
xrun w_awaiting ac-qa-watch.sh --once
assert_contains "$(xout)" "run finished: passed" "row 3: awaiting_approval is not active for qa"
w_run() { w_qa running; }
xrun w_run ac-qa-watch.sh --once
assert_eq "$XN_RC" "0" "row 3: a running outcome renders"
case "$(xout)" in *"run finished"*) fail "row 3: a running outcome is not finished" ;; esac

# 4. the live finish: `run finished`, `sleep 5`, the self close only - no
#    finish hook, so a review.pane present is neither closed nor removed.
w_done() { w_qa passed; printf 'pR7\n' >"$XRD/review.pane"; }
XKILL=9 xrun w_done ac-qa-watch.sh --self-pane pq
assert_eq "$XN_RC:$(cat "$TMP/xn.herdr"):$(cat "$TMP/xn.sleep")" "0:--session default pane close pq:5" "row 4: the board's pane alone"
assert_contains "$(cat "$TMP/xn.world")" "review.pane" "row 4: review.pane untouched"

# 5. idle, from the date stub's instant: old steps/log with a fresh cases.tsv
#    stay open at AC_QA_WATCH_IDLE=1000; all old close; AC_SHIP_WATCH_IDLE is
#    not this board's (the default 1800 closes).
w_idlecases() { w_qa running; printf 'exec\trunning\t0\t-\n' >"$XRD/steps.tsv"; printf 'c1\tapi\tpass\n' >"$XRD/cases.tsv"; xold "$XRD/steps.tsv" "$XRD/logs/run.log"; xnow "$XRD/cases.tsv"; }
w_allold() { w_idlecases; xold "$XRD/cases.tsv"; }
XE=AC_QA_WATCH_IDLE=1000 XKILL=3 xrun w_idlecases ac-qa-watch.sh --interval 1
assert_eq "$XN_RC" "143" "row 5: a fresh cases.tsv keeps the board open"
XE=AC_QA_WATCH_IDLE=1000 XKILL=9 xrun w_allold ac-qa-watch.sh --interval 1 --self-pane pq
assert_eq "$XN_RC:$(cat "$TMP/xn.herdr")" "0:--session default pane close pq" "row 5: all old, the idle close"
XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=9 xrun w_allold ac-qa-watch.sh --interval 1 --self-pane pq
assert_eq "$XN_RC:$(cat "$TMP/xn.herdr")" "0:--session default pane close pq" "row 5: AC_SHIP_WATCH_IDLE is not read"

# 6. colors on a tty: the ledger's green/red/yellow glyphs and counts; the
#    outcome's color for running, passed, failed, unverifiable and anything
#    else.
XTTY=1 xrun w_cases ac-qa-watch.sh --once
assert_contains "$(xout)" $'\033[32m7 pass\033[0m  \033[31m2 fail\033[0m  \033[33m1 unverifiable\033[0m' "row 6: the counts' colors"
assert_contains "$(xout)" $'   \033[31m\xe2\x9c\x97\033[0m c8' "row 6: a fail row is red"
w_color() { w_qa "$XO_COLOR"; }
for oc in running:36 passed:32 failed:31 unverifiable:33 other:2; do
  XO_COLOR="${oc%:*}" XTTY=1 xrun w_color ac-qa-watch.sh --once
  assert_contains "$(xout)" "[$(printf '\033[%sm%s\033[0m' "${oc#*:}" "${oc%:*}")]" "row 6: ${oc%:*} is SGR ${oc#*:}"
done

pass
