#!/usr/bin/env bash
# ac-watch-dash.test.sh - the shared body of the two live run boards
# (src/watch-dash.ts, which src/ship-watch.ts and src/qa-watch.ts import):
# run.meta reads (metaGet since audit-f4 retired the local meta_last copy), the
# step-table width parameter, the per-role active-step detection that must
# survive the merge (ship counts `awaiting_approval` as active, qa does not -
# repo-deep-review report F28, HARD CONSTRAINT 4). The body is
# a module, so these run through the two boards' --once frames; the idle
# clock's newest-mtime values are held in tests/ts/watch-dash.test.ts.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# --- run.meta reads: last value wins on a repeated key ----------------------
# The dash body's own meta_last copy is gone (audit-f4): run.meta reads go
# through metaGet, whose last-write-wins rule this pins from the board, so a
# reintroduced local reader with different precedence reds here.

lw="$(make_repo lastwinsrepo)"
mkdir -p "$lw/.crew/qa/q1" "$lw/.crew/ship/s1"
printf 'outcome=running\noutcome=passed\n' >"$lw/.crew/qa/q1/run.meta"
: >"$lw/.crew/qa/q1/steps.tsv"
ln -sfn q1 "$lw/.crew/qa/current"
assert_contains "$("$BIN/ac-qa-watch.sh" --repo "$lw" --once)" "run finished: passed" "run.meta reads return the LAST value"

# --- the step table: the one real per-role step-table difference is width ---

printf 'pin\tcompleted\t0\n' >"$lw/.crew/qa/q1/steps.tsv"
printf 'outcome=running\n' >"$lw/.crew/ship/s1/run.meta"
printf 'pin\tcompleted\t0\n' >"$lw/.crew/ship/s1/steps.tsv"
ln -sfn s1 "$lw/.crew/ship/current"
out12="$("$BIN/ac-qa-watch.sh" --repo "$lw" --once)"
out18="$("$BIN/ac-ship-watch.sh" --repo "$lw" --once)"
assert_contains "$out12" "$(printf '%-12s' completed)" "qa's step table pads status to 12"
assert_contains "$out18" "$(printf '%-18s' completed)" "ship's step table pads status to 18"

# --- active-step detection: the one real per-role BEHAVIOR difference ------
# (ship counts awaiting_approval as active, qa does not.)

repo="$(make_repo watchdashrepo)"

mk_run() {
  # mk_run <base under repo> <run-id> <outcome> <steps.tsv line>
  local base="$1" id="$2" outcome="$3" line="$4" d
  d="$repo/$base/$id"
  mkdir -p "$d/logs" "$d/findings"
  : >"$d/logs/run.log"
  printf 'outcome=%s\n' "$outcome" >"$d/run.meta"
  printf '%s\n' "$line" >"$d/steps.tsv"
  ln -sfn "$id" "$repo/$base/current"
}

mk_run ".crew/ship" r1 "checks-passed" "$(printf 'review\tawaiting_approval\t0')"
frame="$("$BIN/ac-ship-watch.sh" --repo "$repo" --once)"
case "$frame" in
  *"run finished"*) fail "ship must treat awaiting_approval as ACTIVE, not finished: $frame" ;;
esac

mk_run ".crew/qa" q1 "unverifiable" "$(printf 'review\tawaiting_approval\t0')"
qframe="$("$BIN/ac-qa-watch.sh" --repo "$repo" --once)"
assert_contains "$qframe" "run finished: unverifiable" \
  "qa must NOT treat awaiting_approval as active"

# --- the shared body's bytes, through both boards, row by row -----------------
# Each row runs a shim in a world rebuilt from nothing ($XW: a git repo at
# repo/ with sub/ and the row's .crew run dirs, home/config/, log/, hooks/),
# cwd $XW/repo unless the row names another, stdin /dev/null. The board spawns
# `sleep` from PATH once a tick, so every live row is driven by the leg's sleep
# stub: it logs each call, runs the row's hook for that call, and from call
# XKILL on signals its parent and waits for it to go - a row ends after an
# exact number of ticks, never on a wall clock. Beside it a logging herdr and a
# date answering 1767225600 for %s.
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
xrefuse() {  # xrefuse <stderr> <world fn> <entry> <args...> - exit 1, no stdout, exactly <stderr>
  local want="$1"; shift
  xrun "$@"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::$want" "board refusal for '$*'"
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
# 1. no run: each board's text with no `current` and with `current` a plain
#    directory; a dangling `current` and one with an ABSOLUTE target (joined as
#    `<base>//<target>`: nothing there) render an empty header and
#    `run finished: `.
w_none() { xseed; }
w_plaindir() { xseed; mkdir -p "$XW/repo/.crew/ship/current"; }
w_dangling() { xseed; mkdir -p "$XW/repo/.crew/ship"; ln -s gone "$XW/repo/.crew/ship/current"; }
w_abs() { xseed; xrd ship r1; printf 'outcome=passed\n' >"$XRD/run.meta"; ln -sfn "$XRD" "$XW/repo/.crew/ship/current"; }
xrun w_none ac-ship-watch.sh --once
assert_eq "$XN_RC:$(xout):$(xerr)" "0:no active crew-ship run in $XW/repo:" "row 1: the ship board's no-run text"
xrun w_none ac-qa-watch.sh --once
assert_eq "$XN_RC:$(xout):$(xerr)" "0:no active qa run in $XW/repo:" "row 1: the qa board's no-run text"
xrun w_plaindir ac-ship-watch.sh --once
assert_eq "$XN_RC:$(xout)" "0:no active crew-ship run in $XW/repo" "row 1: a plain directory is no run"
xrun w_dangling ac-ship-watch.sh --once
assert_eq "$XN_RC:$(xout)" $'0:ac-ship   run gone  []\nintent: \n\nrun finished: ' "row 1: a dangling current is an empty run"
xrun w_abs ac-ship-watch.sh --once
assert_eq "$XN_RC:$(tail -n 1 "$TMP/xn.out")" "0:run finished: " "row 1: an absolute target joins as <base>//<target>, an empty run"

# 2. a full ship run, --once: every step status and glyph, rounds 0/08/ 3/abc/1e2,
#    an over-wide step, an unterminated last line (never read); findings (fix x2
#    + ask-user, [], not JSON, an object, null/number actions, a .meta.json,
#    three byte-ordered names); a 7-line log (tail 6: a no-space line, a no-`T`
#    stamp, a line cut at 79 bytes + `…`, a TAB, an unterminated last line) -
#    TERM=xterm (80 columns), TERM unset and empty (200).
XE_LONG="$(printf 'x%.0s' $(seq 1 120))"
w_full() {
  xseed; xrd ship r1
  printf 'intent=old\nbranch=crew/x\noutcome=running\noutcome=checks-passed\nintent=%s\n' "$XE_ACCENTS" >"$XRD/run.meta"
  printf 'a\tcompleted\t0\nb\trunning\t08\nc\tfixing\t 3\nd\tawaiting_approval\tabc\ne\tfailed\t1e2\nf\tskipped\t2\ng\tbogus\t1\nlongerstepname\tcompleted\nunterm\tcompleted' >"$XRD/steps.tsv"
  printf '[{"action":"fix"},{"action":"fix"},{"action":"ask-user"}]' >"$XRD/findings/review.json"
  printf '[]' >"$XRD/findings/empty.json"; printf 'nope' >"$XRD/findings/bad.json"; printf '{}' >"$XRD/findings/obj.json"
  printf '[{"action":null},{"action":null},{"action":2},{"action":"fix"},{"action":"ask-user"}]' >"$XRD/findings/odd.json"
  printf '[{"action":"fix"}]' >"$XRD/findings/review.meta.json"
  for n in Zeta a-b a_b; do printf '[{"action":"prefix"}]' >"$XRD/findings/$n.json"; done
  { printf '2026-01-01T01:02:01Z one\n2026-01-01T01:02:02Z two\nnospaceline\nnots line here\n'
    printf '2026-01-01T01:02:05Z %s\n' "$XE_LONG"; printf '2026-01-01T01:02:06Z tab\there\n2026-01-01T01:02:07Z unterminated'; } >"$XRD/logs/run.log"
}
xrun w_full ac-ship-watch.sh --once
assert_eq "$XN_RC:$(xerr)" "0:" "row 2: a full run renders, silent on stderr"
for want in "$(printf ' %s %-10s %-18s %s' ✓ a completed '')" "$(printf ' %s %-10s %-18s %s' ▶ b running 'round 08')" \
  "$(printf ' %s %-10s %-18s %s' ▶ c fixing 'round  3')" "$(printf ' %s %-10s %-18s %s' ⏸ d awaiting_approval '')" \
  "$(printf ' %s %-10s %-18s %s' ✗ e failed '')" "$(printf ' %s %-10s %-18s %s' - f skipped 'round 2')" \
  "$(printf ' %s %-10s %-18s %s' ○ g bogus 'round 1')" "$(printf ' %s %-10s %-18s %s' ✓ longerstepname completed '')" \
  ' findings odd       null=2  2=1  ask-user=1  fix=1' ' findings review    ask-user=1  fix=2' \
  ' nospaceline  nospaceline' ' nots  line here' " 01:02:05  $(printf 'x%.0s' $(seq 1 68))…" ' 01:02:06  tab	here'; do
  assert_contains "$(xout)" "$want
" "row 2: the frame holds [$want]"
done
case "$(xout)" in *unterm*completed*|*empty*|*bad*|*obj*|*" 01:02:01 "*) fail "row 2: an unread step, a silent findings file or a 7th log line shows: $(xout)" ;; esac
assert_eq "$(tail -n 1 "$TMP/xn.out")" " 01:02:07  unterminated" "row 2: the log's unterminated last line ends the frame"
assert_eq "$(awk '$1 == "findings" { printf "%s ", $2 }' "$TMP/xn.out")" "Zeta a-b a_b odd review " "row 2: findings in byte order"
for t in unset ""; do
  XTERMV="$t" xrun w_full ac-ship-watch.sh --once
  assert_contains "$(xout)" " 01:02:05  $XE_LONG
" "row 2: TERM ${t:-empty} is 200 columns, the log line whole"
done
XLC=en_US.UTF-8 xrun w_full ac-ship-watch.sh --once
assert_eq "$XN_RC:$(awk '$1 == "findings" { printf "%s ", $2 }' "$TMP/xn.out")" "0:Zeta a-b a_b odd review " "row 2: findings in byte order under a UTF-8 locale too"
XHOMELESS=1 xrun w_full ac-ship-watch.sh --once
assert_eq "$XN_RC:$(xerr)" "0:" "row 2: a homeless run renders"
assert_contains "$(xout)" ' findings review    ask-user=1  fix=2' "row 2: ...the same frame"
XTTY=1 xrun w_full ac-ship-watch.sh --once
assert_contains "$(xout)" $'\033[1mac-ship\033[0m \033[36mcrew/x\033[0m  \033[2mrun r1\033[0m  [\033[32mchecks-passed\033[0m]' "row 2: the header's colors on a tty"
assert_contains "$(xout)" $' \033[35m\xe2\x8f\xb8\033[0m d          \033[35mawaiting_approval ' "row 2: an awaiting step is magenta"
assert_contains "$(xout)" $' findings review    \033[35mask-user=1  fix=2\033[0m' "row 2: ask-user findings are magenta"
# A NUL ends its line where `read -r` cut it, the later fields with it.
w_nulsteps() { xseed; xrd ship r1; printf 'outcome=failed\n' >"$XRD/run.meta"; printf 'a\tcomp\0leted\t2\nb\tfailed\t0\n' >"$XRD/steps.tsv"; }
xrun w_nulsteps ac-ship-watch.sh --once
assert_eq "$XN_RC" "0" "row 2: a NUL in steps.tsv still renders"
assert_contains "$(xout)" "$(printf ' %s %-10s %-18s %s' ○ a comp '')
" "row 2: a NUL cuts its step line"

# 3. finished detection, --once: running with nothing active (no line); no
#    outcome (`run finished: `); no steps.tsv (the frame, then the finish line).
w_running() { xseed; xrd ship r1; printf 'outcome=running\n' >"$XRD/run.meta"; printf 'a\tcompleted\t0\n' >"$XRD/steps.tsv"; }
w_nooutcome() { xseed; xrd qa q1; printf 'task=t\n' >"$XRD/run.meta"; printf 'a\tcompleted\t0\n' >"$XRD/steps.tsv"; }
w_nosteps() { xseed; xrd ship r1; printf 'outcome=failed\n' >"$XRD/run.meta"; }
xrun w_running ac-ship-watch.sh --once
assert_eq "$XN_RC:$(xerr)" "0:" "row 3: a running run renders"
case "$(xout)" in *"run finished"*) fail "row 3: a running run is not finished" ;; esac
xrun w_nooutcome ac-qa-watch.sh --once
assert_eq "$XN_RC:$(tail -n 1 "$TMP/xn.out")" "0:run finished: " "row 3: an absent outcome finishes with an empty name"
xrun w_nosteps ac-ship-watch.sh --once
assert_eq "$XN_RC:$(tail -n 1 "$TMP/xn.out")" "0:run finished: failed" "row 3: no steps.tsv - failed and nothing active"

# 4. arguments: refusals in scan order; a value flag with no value or an empty
#    one; --repo naming no repo and a path that cannot be entered; a subdir and
#    the cwd's subdir read the toplevel; --self-pane is never called by --once.
xrefuse "ERROR: unknown arg: --bogus" w_none ac-ship-watch.sh --bogus
xrefuse "ERROR: unknown arg: -h" w_none ac-qa-watch.sh -h
xrefuse "ERROR: unknown arg: x" w_none ac-ship-watch.sh --once x
for f in --repo --self-pane --interval; do
  xrefuse "ERROR: $f needs a value" w_none ac-ship-watch.sh --once "$f"
  xrefuse "ERROR: $f needs a value" w_none ac-ship-watch.sh "$f" '' --once
done
for d in home nope; do
  xrun w_none ac-qa-watch.sh --repo "$XW/$d" --once
  assert_eq "$XN_RC:$(xout)" "1:" "row 4: --repo $d refuses"
  assert_contains "$(xerr)" "ERROR: not a git repo:" "row 4: --repo $d is no git repo"
done
xrun w_none ac-ship-watch.sh --repo "$XW/repo/sub" --once
assert_eq "$XN_RC:$(xout)" "0:no active crew-ship run in $XW/repo" "row 4: a subdir reads its toplevel"
XCWD=repo/sub xrun w_none ac-qa-watch.sh --once
assert_eq "$XN_RC:$(xout)" "0:no active qa run in $XW/repo" "row 4: the cwd's subdir reads its toplevel"
xrun w_running ac-ship-watch.sh --interval 1 --interval 5 --once --self-pane p1
assert_eq "$XN_RC:$(cat "$TMP/xn.herdr"):$(cat "$TMP/xn.sleep")" "0::" "row 4: --once never sleeps or closes a pane"

# 5. the live loop with a run: the prelude, one paint while the frame is
#    unchanged, a second when steps.tsv changes, TERM and HUP restoring the
#    cursor (143, 129); the interval handed to sleep each tick, the last
#    --interval winning.
w_live() { xseed; xrd ship r1; printf 'outcome=running\nbranch=b\n' >"$XRD/run.meta"; printf 'a\trunning\t0\n' >"$XRD/steps.tsv"; printf '2026-01-01T00:00:00Z go\n' >"$XRD/logs/run.log"; }
w_livechange() { w_live; printf 'a\tcompleted\t0\nb\trunning\t1\n' >"$XW/steps2"; xhook 2 "cp '$XW/steps2' '$XRD/steps.tsv'"; }
XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=3 xrun w_live ac-ship-watch.sh --interval 1 --interval 7
assert_eq "$XN_RC:$(xcount $'\033[H' "$TMP/xn.out"):$(tr '\n' ' ' <"$TMP/xn.sleep")" "143:2:7 7 7 " "row 5: the prelude and one paint over three ticks"
assert_eq "$(head -c 13 "$TMP/xn.out" | od -An -c | tr -d ' \n')" "033[2J033[H033[?25l" "row 5: the prelude clears and hides the cursor"
assert_eq "$(tail -c 6 "$TMP/xn.out" | od -An -c | tr -d ' \n')" "033[?25h" "row 5: TERM restores the cursor"
XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=3 xrun w_livechange ac-ship-watch.sh --interval 1
assert_eq "$XN_RC:$(xcount $'\033[H' "$TMP/xn.out")" "143:3" "row 5: a changed steps.tsv is painted again"
XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=2 XSIG=HUP xrun w_live ac-qa-watch.sh
assert_eq "$XN_RC:$(tr '\n' ' ' <"$TMP/xn.sleep")" "129:2 2 " "row 5: HUP, the default interval"
XTTY=1 XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=1 xrun w_live ac-ship-watch.sh --interval 1
assert_eq "$XN_RC" "143" "row 5: a painted tty frame ends on TERM"
assert_contains "$(xout)" $' \033[36m\xe2\x96\xb6\033[0m a          \033[36mrunning ' "row 5: ...and is painted in color"

# 6. the live finish and the self-close: `run finished: <outcome>`, `sleep 5`,
#    the raw herdr close of --self-pane through the session ladder
#    (AC_HERDR_SESSION > config/herdr-session > default; homeless: default),
#    and none without --self-pane.
w_done() { xseed; xrd qa q1; printf 'outcome=passed\n' >"$XRD/run.meta"; printf 'a\tcompleted\t0\n' >"$XRD/steps.tsv"; }
w_donecfg() { w_done; printf ' s2 \n' >"$XW/home/config/herdr-session"; }
XKILL=9 xrun w_done ac-qa-watch.sh --self-pane p9
assert_eq "$XN_RC:$(tr '\n' ' ' <"$TMP/xn.sleep"):$(cat "$TMP/xn.herdr")" "0:5 :--session default pane close p9" "row 6: finish, sleep 5, the close"
assert_contains "$(xout)" $'run finished: passed\n\033[?25h' "row 6: the finish line, then the restore"
XKILL=9 xrun w_done ac-qa-watch.sh
assert_eq "$XN_RC:$(cat "$TMP/xn.herdr")" "0:" "row 6: no --self-pane, no herdr call"
XE=AC_HERDR_SESSION=s1 XKILL=9 xrun w_donecfg ac-qa-watch.sh --self-pane p9
assert_eq "$(cat "$TMP/xn.herdr")" "--session s1 pane close p9" "row 6: AC_HERDR_SESSION first"
XKILL=9 xrun w_donecfg ac-qa-watch.sh --self-pane p9
assert_eq "$(cat "$TMP/xn.herdr")" "--session s2 pane close p9" "row 6: config/herdr-session, trimmed"
XHOMELESS=1 XKILL=9 xrun w_donecfg ac-qa-watch.sh --self-pane p9
assert_eq "$(cat "$TMP/xn.herdr")" "--session default pane close p9" "row 6: homeless reads the default"

# 7. idle, from the date stub's instant: old steps/log close after the default
#    1800 (`sleep 2`, the close); fresh ones never idle.
w_old() { w_live; xold "$XRD/steps.tsv" "$XRD/logs/run.log"; }
w_fresh() { w_live; xnow "$XRD/steps.tsv" "$XRD/logs/run.log"; }
XKILL=9 xrun w_old ac-ship-watch.sh --self-pane p9
assert_eq "$XN_RC:$(tr '\n' ' ' <"$TMP/xn.sleep"):$(cat "$TMP/xn.herdr")" "0:2 :--session default pane close p9" "row 7: idle past 1800"
assert_contains "$(xout)" $'\nrun idle too long - closing watch\n' "row 7: the idle line"
XKILL=3 xrun w_fresh ac-ship-watch.sh --interval 1
assert_eq "$XN_RC" "143" "row 7: a fresh run never idles"

# 8. no run, live: the waiting text painted once; `waited` past 300 closes
#    before that tick's sleep (`301`: no sleep; `100`: three; `010` adds 8:
#    thirty-seven); `-1` shrinks it.
xrun w_none ac-ship-watch.sh --interval 301 --self-pane p1
assert_eq "$XN_RC:$(cat "$TMP/xn.sleep"):$(cat "$TMP/xn.herdr")" "0::--session default pane close p1" "row 8: 301 closes before any sleep"
assert_contains "$(xout)" "waiting for a crew-ship run in $XW/repo ..." "row 8: the waiting text"
XKILL=9 xrun w_none ac-qa-watch.sh --interval 100 --self-pane p2
assert_eq "$(tr '\n' ' ' <"$TMP/xn.sleep"):$(cat "$TMP/xn.herdr")" "100 100 100 :--session default pane close p2" "row 8: 100 closes after three sleeps"
XKILL=99 xrun w_none ac-qa-watch.sh --interval 010 --self-pane p2
assert_eq "$XN_RC:$(wc -l <"$TMP/xn.sleep" | tr -d ' '):$(cat "$TMP/xn.herdr")" "0:37:--session default pane close p2" "row 8: 010 adds 8 a tick"
for iv in 2 -1; do
  XKILL=3 xrun w_none ac-ship-watch.sh --interval "$iv"
  assert_eq "$XN_RC:$(xcount $'\033[H' "$TMP/xn.out"):$(tr '\n' ' ' <"$TMP/xn.sleep")" "143:2:$iv $iv $iv " "row 8: interval $iv - one paint, no close within three ticks"
done

# 9. SIGINT to the board alone restores the cursor and ends 130 at once.
w_int() { w_live; xhook 2 'kill -INT "$PPID"; i=0; while kill -0 "$PPID" 2>/dev/null && [ "$i" -lt 40 ]; do /bin/sleep 0.05; i=$((i + 1)); done'; }
XWRAP="$XS/int-default" XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=4 xrun w_int ac-ship-watch.sh --interval 1
assert_eq "$XN_RC:$(tr '\n' ' ' <"$TMP/xn.sleep")" "130:1 1 " "row 9: SIGINT alone ends 130"
assert_eq "$(tail -c 6 "$TMP/xn.out" | od -An -c | tr -d ' \n')" "033[?25h" "row 9: ...the cursor restored"

# 10. a frame line holding a byte that is no UTF-8 is painted whole under a
#     UTF-8 locale.
w_badbyte() { w_live; printf '2026-01-01T01:02:05Z x\351y\n' >"$XRD/logs/run.log"; }
XLC=en_US.UTF-8 XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=1 xrun w_badbyte ac-ship-watch.sh --interval 1
assert_eq "$XN_RC:$(xerr)" "143:" "row 10: one frame painted, silent on stderr"
assert_contains "$(xout)" $' 01:02:05  x\351y\033[K' "row 10: the line is painted with its byte"

pass
