#!/usr/bin/env bash
# ac-ship-watch.test.sh - RUN_BASE must resolve to .crew/ship, never
# accidentally to its sibling .crew/qa (bin/ac-ship-watch.sh's RUN_BASE) - the
# mirror image of tests/sh/ac-qa-watch.test.sh, and the same gap: ac-ship.test.sh
# and tests/sh/ac-watch-dash.test.sh only ever exercise a run that already
# exists at the RIGHT path.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

repo="$(make_repo shipwatchrepo)"
# A qa run exists, but no ship run - the ship watch must still report "no
# active run", proving it looks at .crew/ship and not .crew/qa.
mkdir -p "$repo/.crew/qa/q1"
printf 'outcome=running\n' >"$repo/.crew/qa/q1/run.meta"
ln -sfn q1 "$repo/.crew/qa/current"

out="$("$BIN/ac-ship-watch.sh" --repo "$repo" --once)"
assert_eq "$out" "no active crew-ship run in $repo" \
  "ac-ship-watch.sh must read .crew/ship, not a sibling qa run"

# --- differential leg: src/ship-watch.ts against the frozen original ---------
# The frozen board (tests/fixtures/ac-ship-watch.sh, sourcing the frozen
# tests/fixtures/ac-watch-dash.sh copied into its oracle bin - bin/ac-watch-dash.sh
# is retired) and the shim answer each row in a world rebuilt from nothing
# before each side; the crew-ship role's own bytes here (the header, the
# override list, the reviewer-pane close, its idle knob), the shared body's in
# tests/sh/ac-watch-dash.test.sh. Live rows are driven tick by tick by the
# leg's sleep stub (it logs each call, runs the row's hook, and from call XKILL
# on signals its parent and waits for it to go).
# DISPUTED: the implementation (tests/fixtures/ac-ship-watch.sh + ac-watch-dash.sh under bash vs src/ship-watch.ts + src/watch-dash.ts through bin/ac-ship-watch.sh)
# HELD-CONSTANT: one world path ($XW: a git repo at repo/ with the row's .crew/ship run dir, home/config/, log/, hooks/) rebuilt by the row's world function before each side; argv; env (AC_HOME=$XW/home unless the row is homeless, TERM=xterm, LC_ALL=C unless the row names en_US.UTF-8, XW/XKILL/XSIG for the stubs; AC_HERDR_SESSION, AC_SHIP_WATCH_IDLE, AC_QA_WATCH_IDLE, EPOCHSECONDS, LANG, LC_CTYPE, COLUMNS, LINES and CDPATH unset unless the row sets one); PATH the leg's stubs (sleep, a logging herdr, a date answering 1767225600 for %s) before this suite's, or the same without herdr where a row says so; cwd ($XW/repo); stdin (/dev/null); exit status, stdout and stderr compared whole, then the stub logs and every path under the repo's .crew.
xobin="$(make_oracle_bin ac-ship-watch)"
cp "$ROOT/tests/fixtures/ac-watch-dash.sh" "$xobin/"
for f in ac-ship-watch ac-watch-dash; do
  cmp -s "$xobin/$f.sh" "$ROOT/tests/fixtures/$f.sh" || fail "the oracle bin holds the frozen $f.sh"
done
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
# cannot trap; a SIGINT row runs each side with INT at its default first.
cat >"$XS/int-default" <<'STUB'
#!/usr/bin/env python3
import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])
STUB
chmod +x "$XS/sleep" "$XS/herdr" "$XS/date" "$XS/int-default"

XLC=C; XTERMV=xterm; XHOMELESS=0; XE=""; XPATH=""; XWRAP=""; XTTY=0; XKILL=999; XSIG=TERM; XCWD=repo; XRC=0
xside() {  # xside <bin> <entry> <prefix> <args...> - one side in the current world (XTTY=1: on a pty, stderr in stdout), SIGKILLed past 30 s
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
    # The braces' stderr takes the shell's own job notice for a side a signal
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
XO_RC=0; XN_RC=0
xpair() {  # xpair <world fn> <entry> <args...> - each side in its own fresh world, nothing compared yet
  local wf="$1" entry="$2"; shift 2
  "$wf"; xside "$xobin" "$entry" xo ${@+"$@"}; XO_RC=$XRC
  "$wf"; xside "$BIN" "$entry" xn ${@+"$@"}; XN_RC=$XRC
}
xline() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
xsame() {  # xsame <world fn> <entry> <args...> - exit, stdout, stderr, the stub logs and the run dirs alike
  xpair "$@"
  local at x; at="$(xline)"
  assert_eq "$XN_RC" "$XO_RC" "board differential exit for '$*' at line $at"
  for x in out err sleep herdr world; do
    cmp -s "$TMP/xo.$x" "$TMP/xn.$x" || fail "board differential $x differs for '$*' at line $at: $(diff "$TMP/xo.$x" "$TMP/xn.$x" | head -n 8)"
  done
}
xrefuse() {  # xrefuse <stderr> <world fn> <entry> <args...> - both sides refuse alike: exit 1, no stdout, exactly <stderr>
  local want="$1"; shift
  xsame "$@"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::$want" "board refusal for '$*' at line $(xline)"
}
xout() { cat "$TMP/xn.out"; }
xoout() { cat "$TMP/xo.out"; }
xerr() { cat "$TMP/xn.err"; }
xoerr() { cat "$TMP/xo.err"; }
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
w_ship() {  # w_ship <outcome> - a ship run: branch crew/x, one completed step, a log line
  xseed; xrd ship r1
  printf 'branch=crew/x\noutcome=%s\n' "$1" >"$XRD/run.meta"
  printf 'build\tcompleted\t0\n' >"$XRD/steps.tsv"
  printf '2026-01-01T00:00:00Z go\n' >"$XRD/logs/run.log"
}

# 1. the header: an intent of 60 x `é` cut at 110 BYTES (55 of them), one
#    whose byte 110 opens a character (SW6: the cut keeps that lone byte),
#    branch, id and the last outcome key (a repeated `outcome=`).
w_intent() { w_ship running; printf 'intent=old\noutcome=running\noutcome=checks-passed\nintent=%s\n' "$XE_ACCENTS" >>"$XRD/run.meta"; }
w_straddle() { w_ship running; printf 'intent=%s%s\n' "$(printf 'x%.0s' $(seq 1 109))" "é" >>"$XRD/run.meta"; }
xsame w_intent ac-ship-watch.sh --once
assert_contains "$(xout)" "ac-ship crew/x  run r1  [checks-passed]
intent: $(printf 'é%.0s' $(seq 1 55))
" "row 1: the last outcome; 110 bytes of intent"
assert_contains "$(xout)" "run finished: checks-passed" "row 1: finished, nothing active"
xsame w_straddle ac-ship-watch.sh --once
assert_contains "$(xout)" "intent: $(printf 'x%.0s' $(seq 1 109))"$'\303\n' "row 1: SW6 - the byte cut keeps the lone first byte"

# 2. the override list (SW2 at parity): absent; an empty file (nothing listed);
#    two rows (their first TAB fields); a blank row and a last row with no LF
#    (an empty slot, the last row counted); the finish line names the bare
#    outcome. An override that cannot be read - TOOL-OWN, named: the original's
#    cut said so on stderr; both list nothing.
w_ov() { w_ship checks-passed; printf "$1" >"$XRD/override"; }
w_ovempty() { w_ov ''; }
w_ovtwo() { w_ov 'test\tflaky\nlint\twhy\n'; }
w_ovblank() { w_ov 'test\n\nlint'; }
xsame w_ovempty ac-ship-watch.sh --once
assert_contains "$(xout)" "[checks-passed passed-with-override:]" "row 2: an empty override lists nothing"
xsame w_ovtwo ac-ship-watch.sh --once
assert_contains "$(xout)" "[checks-passed passed-with-override:test,lint]" "row 2: the first field of each row"
assert_contains "$(xout)" $'\nrun finished: checks-passed' "row 2: the finish line names the bare outcome"
xsame w_ovblank ac-ship-watch.sh --once
assert_contains "$(xout)" "[checks-passed passed-with-override:test,,lint]" "row 2: a blank row is an empty slot, a last row with no LF counts"
if [ "$(id -u)" != 0 ]; then
  w_ovlocked() { w_ovtwo; chmod 000 "$XRD/override"; }
  xpair w_ovlocked ac-ship-watch.sh --once
  assert_eq "$XO_RC:$XN_RC" "0:0" "TOOL-OWN override: both render"
  cmp -s "$TMP/xo.out" "$TMP/xn.out" || fail "TOOL-OWN override: the frames agree: $(diff "$TMP/xo.out" "$TMP/xn.out" | head -n 4)"
  assert_contains "$(xout)" "[checks-passed passed-with-override:]" "TOOL-OWN override: nothing listed"
  assert_contains "$(xoerr)" "override: Permission denied" "TOOL-OWN override: the original's cut said so"
  assert_eq "$(xerr)" "" "TOOL-OWN override: nothing on the port's stderr"
fi
# FAIL-PATH, named: under UTF-8 the original's cut stopped at a byte that is no
# UTF-8 and listed nothing; the port lists every row.
w_ovbad() { w_ov 'te\351st\tx\nlint\ty\n'; }
XLC=en_US.UTF-8 xpair w_ovbad ac-ship-watch.sh --once
assert_eq "$XO_RC:$XN_RC" "0:0" "FAIL-PATH override: both render"
assert_contains "$(xoout)" "[checks-passed passed-with-override:]" "FAIL-PATH override: the original's cut stopped"
assert_contains "$(xoerr)" "Illegal byte sequence" "FAIL-PATH override: and cut said so"
assert_contains "$(xout)" "[checks-passed passed-with-override:te"$'\351'"st,lint]" "FAIL-PATH override: the port lists both rows"
assert_eq "$(xerr)" "" "FAIL-PATH override: nothing on the port's stderr"

# 3. the live finish: a reviewer pane left in review.pane is closed through raw
#    herdr and the file removed, with --self-pane (then `sleep 5` and the self
#    close) and without it (SW3), on the session ladder; herdr absent from PATH
#    keeps the file and closes nothing.
w_review() { w_ship passed; printf 'pR7\n' >"$XRD/review.pane"; printf 'cfgses\n' >"$XW/home/config/herdr-session"; }
XKILL=9 xsame w_review ac-ship-watch.sh --self-pane p9
assert_eq "$XN_RC:$(tr '\n' '|' <"$TMP/xn.herdr"):$(cat "$TMP/xn.sleep")" "0:--session cfgses pane close pR7|--session cfgses pane close p9|:5" "row 3: the reviewer pane, sleep 5, the board's pane"
case "$(cat "$TMP/xn.world")" in *review.pane*) fail "row 3: review.pane is removed" ;; esac
XE=AC_HERDR_SESSION=envses XKILL=9 xsame w_review ac-ship-watch.sh
assert_eq "$XN_RC:$(cat "$TMP/xn.herdr")" "0:--session envses pane close pR7" "row 3: SW3 - a foreground board closes the reviewer pane too"
XSN="$TMP/xstubs-noherdr"; mkdir -p "$XSN"; ln -sf "$XS/sleep" "$XS/date" "$XSN/"
nh="$XSN"; IFS=: read -r -a xdirs <<<"$PATH"
for d in "${xdirs[@]}"; do
  [ -n "$d" ] || continue
  if [ -x "$d/herdr" ]; then
    m="$TMP/nh$(printf '%s' "$d" | tr -c 'A-Za-z0-9' '_')"; mkdir -p "$m"
    for f in "$d"/*; do [ "$(basename "$f")" = herdr ] || ln -sf "$f" "$m/$(basename "$f")" 2>/dev/null || true; done
    d="$m"
  fi
  nh="$nh:$d"
done
XPATH="$nh" XKILL=9 xsame w_review ac-ship-watch.sh --self-pane p9
assert_eq "$XN_RC:$(cat "$TMP/xn.herdr")" "0:" "row 3: no herdr, nothing closed"
assert_contains "$(cat "$TMP/xn.world")" "review.pane" "row 3: no herdr, review.pane kept"

# 4. the role's idle knob: AC_QA_WATCH_IDLE is not this board's (a fresh run at
#    the stub's instant stays open), AC_SHIP_WATCH_IDLE is (0 closes it).
w_live() { w_ship running; printf 'build\trunning\t0\n' >"$XRD/steps.tsv"; xnow "$XRD/steps.tsv" "$XRD/logs/run.log"; }
XE=AC_QA_WATCH_IDLE=0 XKILL=3 xsame w_live ac-ship-watch.sh --interval 1
assert_eq "$XN_RC" "143" "row 4: AC_QA_WATCH_IDLE is not read"
XE=AC_SHIP_WATCH_IDLE=-1 XKILL=9 xsame w_live ac-ship-watch.sh --interval 1 --self-pane p4
assert_eq "$XN_RC:$(cat "$TMP/xn.herdr")" "0:--session default pane close p4" "row 4: AC_SHIP_WATCH_IDLE is"

# 5. colors on a tty: the outcome's color - running cyan, an override yellow,
#    checks-passed green, failed red, anything else dim.
w_color() { w_ship "$XO_COLOR"; }
for o in running checks-passed cancelled; do XO_COLOR="$o" XTTY=1 xsame w_color ac-ship-watch.sh --once; done
XO_COLOR=failed XTTY=1 xsame w_color ac-ship-watch.sh --once
assert_contains "$(xout)" $'[\033[31mfailed\033[0m]' "row 5: failed is red"
XTTY=1 xsame w_ovtwo ac-ship-watch.sh --once
assert_contains "$(xout)" $'[\033[33mchecks-passed passed-with-override:test,lint\033[0m]' "row 5: an override is yellow"

pass
