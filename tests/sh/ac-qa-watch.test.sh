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

# --- differential leg: src/qa-watch.ts against the frozen original -----------
# The frozen board (tests/fixtures/ac-qa-watch.sh, sourcing the frozen
# tests/fixtures/ac-watch-dash.sh copied into its oracle bin - bin/ac-watch-dash.sh
# is retired) and the shim answer each row in a world rebuilt from nothing
# before each side; the qa role's own bytes here (the header, the step table at
# width 12 over a real 4-column steps.tsv, the case ledger, its idle files and
# knob), the shared body's in tests/sh/ac-watch-dash.test.sh. Live rows are
# driven tick by tick by the leg's sleep stub (it logs each call, runs the
# row's hook, and from call XKILL on signals its parent and waits for it to go).
# DISPUTED: the implementation (tests/fixtures/ac-qa-watch.sh + ac-watch-dash.sh under bash vs src/qa-watch.ts + src/watch-dash.ts through bin/ac-qa-watch.sh)
# HELD-CONSTANT: one world path ($XW: a git repo at repo/ with the row's .crew/qa run dir, home/config/, log/, hooks/) rebuilt by the row's world function before each side; argv; env (AC_HOME=$XW/home, TERM=xterm, LC_ALL=C, XW/XKILL/XSIG for the stubs; AC_HERDR_SESSION, AC_SHIP_WATCH_IDLE, AC_QA_WATCH_IDLE, EPOCHSECONDS, LANG, LC_CTYPE, COLUMNS, LINES and CDPATH unset unless the row sets one); PATH the leg's stubs (sleep, a logging herdr, a date answering 1767225600 for %s) before this suite's; cwd ($XW/repo); stdin (/dev/null); exit status, stdout and stderr compared whole, then the stub logs and every path under the repo's .crew.
xobin="$(make_oracle_bin ac-qa-watch)"
cp "$ROOT/tests/fixtures/ac-watch-dash.sh" "$xobin/"
for f in ac-qa-watch ac-watch-dash; do
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
w_qa() {  # w_qa <outcome> - a qa run: task dash, one completed step, a log line
  xseed; xrd qa q1
  printf 'task=dash\ntarget=the widget\noutcome=%s\n' "$1" >"$XRD/run.meta"
  printf 'pin\tcompleted\t0\t-\n' >"$XRD/steps.tsv"
  printf '2026-01-01T00:00:00Z go\n' >"$XRD/logs/run.log"
}

# 1. the step table as ac-qa.sh writes it (four columns): a fixing step's
#    rounds fold into `3\t-` and never show (QW2); a 3-column hand row shows
#    `round 2`; `awaiting_approval` overflows the 12-byte column; the header
#    with an absent task, a target whose byte 110 opens a character (QW7), and
#    the last outcome key.
w_steps() {
  w_qa running
  printf 'pin\tcompleted\t0\t-\nexec\tfixing\t3\t-\nhand\tfixing\t2\nwait\tawaiting_approval\t0\t-\n' >"$XRD/steps.tsv"
  printf 'target=%s%s\noutcome=running\noutcome=passed\n' "$(printf 'y%.0s' $(seq 1 109))" "é" >"$XRD/run.meta"
}
xsame w_steps ac-qa-watch.sh --once
for want in "$(printf ' %s %-10s %-12s %s' ▶ exec fixing '')" "$(printf ' %s %-10s %-12s %s' ▶ hand fixing 'round 2')" \
  "$(printf ' %s %-10s %-12s %s' ⏸ wait awaiting_approval '')"; do
  assert_contains "$(xout)" "$want
" "row 1: the step table holds [$want]"
done
assert_contains "$(xout)" "ac-qa   run q1  [passed]
target: $(printf 'y%.0s' $(seq 1 109))"$'\303\n' "row 1: no task, the last outcome, QW7's lone byte"
case "$(xout)" in *"run finished"*) fail "row 1: fixing steps keep the run open" ;; esac

# 2. the case ledger: absent and zero bytes (no section); a single LF (zero
#    counts and one empty `?` row ending `grade `); ten rows - pass/fail/
#    unverifiable/an unknown status (QW4: `?`, in no count), grade `-` and set,
#    a 3-field row (QW3: `grade `), a 30-byte and a multibyte id (QW8: byte pads),
#    an unterminated last row - of which the last 8 show.
w_nocases() { w_qa passed; }
w_zerocases() { w_qa passed; : >"$XRD/cases.tsv"; }
w_lfcases() { w_qa passed; printf '\n' >"$XRD/cases.tsv"; }
w_cases() {
  w_qa passed
  printf 'c1\tapi\tpass\tx\tx\tA\nc2\tdb\tfail\tx\tx\t-\nc3\tweb\tunverifiable\nc4\tapi\tbogus\tx\tx\tB\nthirtybytecaseidentifier123456\tui\tpass\tx\tx\tC\nc\303\251\tapi\tpass\tx\tx\t-\nc7\tapi\tpass\tx\tx\t-\nc8\tapi\tfail\tx\tx\t-\nc9\tapi\tpass\tx\tx\t-\nunterm\tx\tpass' >"$XRD/cases.tsv"
}
xsame w_nocases ac-qa-watch.sh --once
case "$(xout)" in *cases*) fail "row 2: no ledger, no section" ;; esac
xsame w_zerocases ac-qa-watch.sh --once
case "$(xout)" in *cases*) fail "row 2: an empty ledger, no section" ;; esac
xsame w_lfcases ac-qa-watch.sh --once
assert_contains "$(xout)" "0 pass  0 fail  0 unverifiable
$(printf '   ? %-22s %-4s %-13s %s' '' '' '' 'grade')" "row 2: a single LF is one empty row"
xsame w_cases ac-qa-watch.sh --once
assert_contains "$(xout)" " 6 pass  2 fail  1 unverifiable
" "row 2: the counts (bogus in none, the unterminated row counted)"
for want in "$(printf '   ? %-22s %-4s %-13s %s' c3 web unverifiable 'grade ')" "$(printf '   ? %-22s %-4s %-13s %s' c4 api bogus 'grade B')" \
  "$(printf '   ✓ %-22s %-4s %-13s %s' thirtybytecaseidentifier123456 ui pass 'grade C')" "$(printf '   ✓ %-22s %-4s %-13s %s' c7 api pass '')" \
  "$(printf '   ✓ %-22s %-4s %-13s %s' unterm x pass 'grade ')"; do
  assert_contains "$(xout)" "$want
" "row 2: the ledger holds [$want]"
done
assert_contains "$(xout)" "   ✓ cé$(printf '%19s' '') api  pass          " "row 2: QW8 - a multibyte id is padded by bytes"
case "$(xout)" in *" c1 "*|*" c2 "*) fail "row 2: only the last 8 rows show" ;; esac
# TOOL-OWN, named: a non-empty ledger that cannot be read - the original's
# three awks and its tail said so on stderr; both count 0 and list no row.
if [ "$(id -u)" != 0 ]; then
  w_lockedcases() { w_cases; chmod 000 "$XRD/cases.tsv"; }
  xpair w_lockedcases ac-qa-watch.sh --once
  assert_eq "$XO_RC:$XN_RC" "0:0" "TOOL-OWN ledger: both render"
  cmp -s "$TMP/xo.out" "$TMP/xn.out" || fail "TOOL-OWN ledger: the frames agree: $(diff "$TMP/xo.out" "$TMP/xn.out" | head -n 4)"
  assert_contains "$(xout)" "0 pass  0 fail  0 unverifiable" "TOOL-OWN ledger: zero counts"
  assert_contains "$(xoerr)" "cases.tsv" "TOOL-OWN ledger: the original's tools said so"
  assert_eq "$(xerr)" "" "TOOL-OWN ledger: nothing on the port's stderr"
fi

# 3. finished detection: an awaiting_approval step holds no qa run open
#    (`run finished: passed`); a running outcome does.
w_awaiting() { w_qa passed; printf 'review\tawaiting_approval\t0\t-\n' >"$XRD/steps.tsv"; }
xsame w_awaiting ac-qa-watch.sh --once
assert_contains "$(xout)" "run finished: passed" "row 3: awaiting_approval is not active for qa"
w_run() { w_qa running; }
xsame w_run ac-qa-watch.sh --once
case "$(xout)" in *"run finished"*) fail "row 3: a running outcome is not finished" ;; esac

# 4. the live finish: `run finished`, `sleep 5`, the self close only - no
#    finish hook, so a review.pane present is neither closed nor removed.
w_done() { w_qa passed; printf 'pR7\n' >"$XRD/review.pane"; }
XKILL=9 xsame w_done ac-qa-watch.sh --self-pane pq
assert_eq "$XN_RC:$(cat "$TMP/xn.herdr"):$(cat "$TMP/xn.sleep")" "0:--session default pane close pq:5" "row 4: the board's pane alone"
assert_contains "$(cat "$TMP/xn.world")" "review.pane" "row 4: review.pane untouched"

# 5. idle, from the date stub's instant: old steps/log with a fresh cases.tsv
#    stay open at AC_QA_WATCH_IDLE=1000; all old close; AC_SHIP_WATCH_IDLE is
#    not this board's (the default 1800 closes).
w_idlecases() { w_qa running; printf 'exec\trunning\t0\t-\n' >"$XRD/steps.tsv"; printf 'c1\tapi\tpass\n' >"$XRD/cases.tsv"; xold "$XRD/steps.tsv" "$XRD/logs/run.log"; xnow "$XRD/cases.tsv"; }
w_allold() { w_idlecases; xold "$XRD/cases.tsv"; }
XE=AC_QA_WATCH_IDLE=1000 XKILL=3 xsame w_idlecases ac-qa-watch.sh --interval 1
assert_eq "$XN_RC" "143" "row 5: a fresh cases.tsv keeps the board open"
XE=AC_QA_WATCH_IDLE=1000 XKILL=9 xsame w_allold ac-qa-watch.sh --interval 1 --self-pane pq
assert_eq "$XN_RC:$(cat "$TMP/xn.herdr")" "0:--session default pane close pq" "row 5: all old, the idle close"
XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=9 xsame w_allold ac-qa-watch.sh --interval 1 --self-pane pq
assert_eq "$XN_RC:$(cat "$TMP/xn.herdr")" "0:--session default pane close pq" "row 5: AC_SHIP_WATCH_IDLE is not read"

# 6. colors on a tty: the ledger's green/red/yellow glyphs and counts with dim
#    tier and grade; the outcome's color for running, passed, failed,
#    unverifiable and anything else.
XTTY=1 xsame w_cases ac-qa-watch.sh --once
assert_contains "$(xout)" $'\033[32m6 pass\033[0m  \033[31m2 fail\033[0m  \033[33m1 unverifiable\033[0m' "row 6: the counts' colors"
assert_contains "$(xout)" $'   \033[31m\xe2\x9c\x97\033[0m c8' "row 6: a fail row is red"
w_color() { w_qa "$XO_COLOR"; }
for o in running passed failed unverifiable other; do XO_COLOR="$o" XTTY=1 xsame w_color ac-qa-watch.sh --once; done
assert_contains "$(xout)" $'[\033[2mother\033[0m]' "row 6: an unknown outcome is dim"

pass
