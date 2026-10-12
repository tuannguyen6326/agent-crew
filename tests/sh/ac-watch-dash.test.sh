#!/usr/bin/env bash
# ac-watch-dash.test.sh - the shared body of the two live run boards
# (src/watch-dash.ts, which src/ship-watch.ts and src/qa-watch.ts import):
# run.meta reads (metaGet since audit-f4 retired the local meta_last copy), the
# step-table width parameter, the per-role active-step detection that must
# survive the merge (ship counts `awaiting_approval` as active, qa does not -
# repo-deep-review report F28, HARD CONSTRAINT 4), and the idle clock's use of
# the portable mtime helper instead of raw BSD `stat -f %m` (F47). The body is
# a module, so these run through the two boards' --once frames; the idle
# clock's newest-mtime values are held in tests/ts/watch-dash.test.ts.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# --- F47: the idle clock must use the mtime helper, not raw BSD stat -f %m ---

if grep -q "stat -f %m" "$ROOT/src/watch-dash.ts"; then
  fail "src/watch-dash.ts must use fileMtime (src/lib.ts), not raw BSD stat -f %m"
fi

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
if grep -q "meta_last()" "$ROOT/src/watch-dash.ts" "$ROOT/src/gate-watch.ts"; then
  fail "the local meta_last copies were retired (audit-f4); read metas through metaGet"
fi

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

# --- differential leg: src/watch-dash.ts, through both boards, against the frozen originals
# The frozen boards (tests/fixtures/ac-ship-watch.sh and ac-qa-watch.sh, each
# sourcing tests/fixtures/ac-watch-dash.sh - bin/ac-watch-dash.sh is retired,
# so the frozen body is copied into the one oracle bin beside the live scripts)
# and the shims answer each row in a world rebuilt from nothing before each
# side. Both sides spawn `sleep` from PATH once a tick, so every live row is
# driven by the leg's sleep stub: it logs each call, runs the row's hook for
# that call, and from call XKILL on signals its parent and waits for it to go -
# a row ends after an exact number of ticks, never on a wall clock. A
# divergence the port keeps on purpose is asserted on both sides, where it is.
# DISPUTED: the implementation (tests/fixtures/ac-{ship,qa}-watch.sh + ac-watch-dash.sh under bash vs src/{ship,qa}-watch.ts + src/watch-dash.ts through the shims)
# HELD-CONSTANT: one world path ($XW: a git repo at repo/ with sub/ and the row's .crew run dirs, home/config/, log/, hooks/) rebuilt by the row's world function before each side; argv; env (AC_HOME=$XW/home unless the row is homeless, TERM=xterm unless the row unsets it, LC_ALL=C unless the row names en_US.UTF-8, XW/XKILL/XSIG for the stubs; AC_HERDR_SESSION, AC_SHIP_WATCH_IDLE, AC_QA_WATCH_IDLE, EPOCHSECONDS, LANG, LC_CTYPE, COLUMNS, LINES and CDPATH unset unless the row sets one); PATH the leg's stubs (sleep, a logging herdr, a date answering 1767225600 for %s) before this suite's; cwd ($XW/repo unless the row names another); stdin (/dev/null); exit status, stdout and stderr compared whole, then the stub logs (sleep's argv per call, herdr's argv) and every path under the repo's .crew.
xobin="$(make_oracle_bin ac-ship-watch)"
cp "$ROOT/tests/fixtures/ac-qa-watch.sh" "$ROOT/tests/fixtures/ac-watch-dash.sh" "$xobin/"
for f in ac-ship-watch ac-qa-watch ac-watch-dash; do
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

# A run dir with no steps.tsv - SHELL-OWN, named: the original's redirection
# line opens its stderr, the rest (awk's own `can't open file`) is alike.
xnosteps() {  # xnosteps <label> - after an xpair
  assert_eq "$XO_RC:$XN_RC" "0:0" "$1: both exit 0"
  cmp -s "$TMP/xo.out" "$TMP/xn.out" || fail "$1: the frames agree: $(diff "$TMP/xo.out" "$TMP/xn.out" | head -n 4)"
  assert_contains "$(head -n 1 "$TMP/xo.err")" "steps.tsv: No such file or directory" "$1: the original's redirection line"
  assert_eq "$(xerr)" "$(tail -n +2 "$TMP/xo.err")" "$1: the port prints the rest alike"
}

# 1. no run: each board's text with no `current`, with only the other board's
#    run, with `current` a plain directory; a dangling `current` and one with an
#    ABSOLUTE target (joined as `<base>//<target>`: nothing there) render an
#    empty header and `run finished: ` (no steps.tsv: xnosteps).
w_none() { xseed; }
w_qaonly() { xseed; xrd qa q1; printf 'outcome=running\n' >"$XRD/run.meta"; }
w_plaindir() { xseed; mkdir -p "$XW/repo/.crew/ship/current"; }
w_dangling() { xseed; mkdir -p "$XW/repo/.crew/ship"; ln -s gone "$XW/repo/.crew/ship/current"; }
w_abs() { xseed; xrd ship r1; printf 'outcome=passed\n' >"$XRD/run.meta"; ln -sfn "$XRD" "$XW/repo/.crew/ship/current"; }
xsame w_none ac-ship-watch.sh --once
assert_eq "$XN_RC:$(xout)" "0:no active crew-ship run in $XW/repo" "row 1: the ship board's no-run text"
xsame w_none ac-qa-watch.sh --once
assert_eq "$(xout)" "no active qa run in $XW/repo" "row 1: the qa board's no-run text"
xsame w_qaonly ac-ship-watch.sh --once
xsame w_plaindir ac-ship-watch.sh --once
assert_eq "$(xout)" "no active crew-ship run in $XW/repo" "row 1: a plain directory is no run"
xpair w_dangling ac-ship-watch.sh --once
xnosteps "row 1 dangling"
assert_eq "$(xout)" $'ac-ship   run gone  []\nintent: \n\nrun finished: ' "row 1: a dangling current is an empty run"
xpair w_abs ac-ship-watch.sh --once
xnosteps "row 1 absolute"
assert_contains "$(xout)" "run finished: " "row 1: an absolute target joins as <base>//<target>, an empty run"

# 2. a full ship run, --once: every step status and glyph, rounds 0/08/ 3/abc/1e2,
#    a 4-field line, a TAB-run line, an over-wide step, an unterminated last
#    line (never read); findings (fix x2 + ask-user, [], not JSON, an object,
#    null/number actions, a .meta.json, three byte-ordered names); a 7-line log
#    (tail 6: a no-space line, a no-`T` stamp, a 120-byte line cut at 79 bytes +
#    `…`, a TAB, an unterminated last line) - TERM=xterm (80 columns), TERM
#    unset and empty (200).
w_full() {
  xseed; xrd ship r1
  printf 'intent=old\nbranch=crew/x\noutcome=running\noutcome=checks-passed\nintent=%s\n' "$XE_ACCENTS" >"$XRD/run.meta"
  printf 'a\tcompleted\t0\nb\trunning\t08\nc\tfixing\t 3\nd\tawaiting_approval\tabc\ne\tfailed\t1e2\nf\tskipped\t2\tx\ng\tbogus\t1\n\t\th\trunning\nlongerstepname\tcompleted\nunterm\tcompleted' >"$XRD/steps.tsv"
  printf '[{"action":"fix"},{"action":"fix"},{"action":"ask-user"}]' >"$XRD/findings/review.json"
  printf '[]' >"$XRD/findings/empty.json"; printf 'nope' >"$XRD/findings/bad.json"; printf '{}' >"$XRD/findings/obj.json"
  printf '[{"action":null},{"action":null},{"action":2},{"action":"fix"},{"action":"ask-user"}]' >"$XRD/findings/odd.json"
  printf '[{"action":"fix"}]' >"$XRD/findings/review.meta.json"
  for n in Zeta a-b a_b; do printf '[{"action":"prefix"}]' >"$XRD/findings/$n.json"; done
  { printf '2026-01-01T01:02:01Z one\n2026-01-01T01:02:02Z two\nnospaceline\nnots line here\n'
    printf '2026-01-01T01:02:05Z %s\n' "$XE_ACCENTS"; printf '2026-01-01T01:02:06Z tab\there\n2026-01-01T01:02:07Z unterminated'; } >"$XRD/logs/run.log"
}
xsame w_full ac-ship-watch.sh --once
for want in "$(printf ' %s %-10s %-18s %s' ✓ a completed '')" "$(printf ' %s %-10s %-18s %s' ▶ b running 'round 08')" \
  "$(printf ' %s %-10s %-18s %s' ▶ c fixing 'round  3')" "$(printf ' %s %-10s %-18s %s' ○ g bogus 'round 1')" \
  "$(printf ' %s %-10s %-18s %s' ▶ h running '')" "$(printf ' %s %-10s %-18s %s' ✓ longerstepname completed '')" \
  ' findings odd       null=2  2=1  ask-user=1  fix=1' ' findings review    ask-user=1  fix=2' \
  ' nospaceline  nospaceline' ' nots  line here'; do
  assert_contains "$(xout)" "$want
" "row 2: the frame holds [$want]"
done
case "$(xout)" in *unterm*completed*|*empty*|*bad*|*obj*|*" 01:02:01 "*) fail "row 2: an unread step, a silent findings file or a 7th log line shows: $(xout)" ;; esac
assert_eq "$(tail -n 1 "$TMP/xn.out")" " 01:02:07  unterminated" "row 2: the log's unterminated last line ends the frame"
assert_eq "$(awk '$1 == "findings" { printf "%s ", $2 }' "$TMP/xn.out")" "Zeta a-b a_b odd review " "row 2: findings in byte order"
XTERMV=unset xsame w_full ac-ship-watch.sh --once
XTERMV= xsame w_full ac-ship-watch.sh --once
# FINDINGS ORDER, named: under UTF-8 the original's glob collated the files.
XLC=en_US.UTF-8 xpair w_full ac-ship-watch.sh --once
assert_eq "$XO_RC:$XN_RC" "0:0" "FINDINGS ORDER: both render"
assert_eq "$(awk '$1 == "findings" { printf "%s ", $2 }' "$TMP/xo.out")" "a_b a-b odd review Zeta " "FINDINGS ORDER: the original's glob collated under UTF-8"
assert_eq "$(awk '$1 == "findings" { printf "%s ", $2 }' "$TMP/xn.out")" "Zeta a-b a_b odd review " "FINDINGS ORDER: the port walks byte order under every locale"
XHOMELESS=1 xsame w_full ac-ship-watch.sh --once
XTTY=1 xsame w_full ac-ship-watch.sh --once
assert_contains "$(xout)" $'\033[1mac-ship\033[0m \033[36mcrew/x\033[0m  \033[2mrun r1\033[0m  [\033[32mchecks-passed\033[0m]' "row 2: the header's colors on a tty"
assert_contains "$(xout)" $' \033[35m\xe2\x8f\xb8\033[0m d          \033[35mawaiting_approval ' "row 2: an awaiting step is magenta"
assert_contains "$(xout)" $' findings review    \033[35mask-user=1  fix=2\033[0m' "row 2: ask-user findings are magenta"
# A NUL ends its line where `read -r` cut it, the later fields with it.
w_nulsteps() { xseed; xrd ship r1; printf 'outcome=failed\n' >"$XRD/run.meta"; printf 'a\tcomp\0leted\t2\nb\tfailed\t0\n' >"$XRD/steps.tsv"; }
xsame w_nulsteps ac-ship-watch.sh --once
assert_contains "$(xout)" "$(printf ' %s %-10s %-18s %s' ○ a comp '')
" "row 2: a NUL cuts its step line"

# 3. finished detection, --once: running with nothing active (no line); no
#    outcome (`run finished: `); no steps.tsv - SHELL-OWN, named: the original's
#    redirection line, then awk's own line on both sides; the frame alike.
w_running() { xseed; xrd ship r1; printf 'outcome=running\n' >"$XRD/run.meta"; printf 'a\tcompleted\t0\n' >"$XRD/steps.tsv"; }
w_nooutcome() { xseed; xrd qa q1; printf 'task=t\n' >"$XRD/run.meta"; printf 'a\tcompleted\t0\n' >"$XRD/steps.tsv"; }
w_nosteps() { xseed; xrd ship r1; printf 'outcome=failed\n' >"$XRD/run.meta"; }
xsame w_running ac-ship-watch.sh --once
case "$(xout)" in *"run finished"*) fail "row 3: a running run is not finished" ;; esac
xsame w_nooutcome ac-qa-watch.sh --once
assert_contains "$(xout)" "
run finished: " "row 3: an absent outcome finishes with an empty name"
xpair w_nosteps ac-ship-watch.sh --once
xnosteps "row 3 no steps.tsv"
assert_contains "$(xout)" "run finished: failed" "row 3: failed and nothing active"

# 4. arguments: refusals in scan order; a value flag with no value or an empty
#    one (SHELL-OWN, named); --repo naming no repo (WD1, the name EMPTY) and a
#    path cd cannot enter (cd's own line, named); a subdir and the cwd's subdir
#    read the toplevel; the last --interval wins; --self-pane is never called
#    by --once.
xrefuse "ERROR: unknown arg: --bogus" w_none ac-ship-watch.sh --bogus
xrefuse "ERROR: unknown arg: -h" w_none ac-qa-watch.sh -h
xrefuse "ERROR: unknown arg: x" w_none ac-ship-watch.sh --once x
for f in --repo --self-pane --interval; do
  for v in none empty; do
    if [ "$v" = none ]; then xpair w_none ac-ship-watch.sh --once "$f"; else xpair w_none ac-ship-watch.sh "$f" '' --once; fi
    assert_eq "$XO_RC:$XN_RC:$(xoout)$(xout)" "1:1:" "SHELL-OWN $f ($v): exit 1, nothing on stdout, both"
    assert_contains "$(xoerr)" "2: parameter null or not set" "SHELL-OWN $f ($v): bash's own line on the original"
    assert_eq "$(xerr)" "ERROR: $f needs a value" "SHELL-OWN $f ($v): the port names the flag"
  done
done
xrefuse "ERROR: not a git repo: " w_none ac-ship-watch.sh --repo "$XW/home" --once
xpair w_none ac-qa-watch.sh --repo "$XW/nope" --once
assert_eq "$XO_RC:$XN_RC:$(xerr)" "1:1:ERROR: not a git repo: " "SHELL-OWN --repo nope: both refuse with the empty name"
assert_contains "$(xoerr)" "cd: $XW/nope: No such file or directory" "SHELL-OWN --repo nope: the original's cd line first"
xsame w_none ac-ship-watch.sh --repo "$XW/repo/sub" --once
assert_eq "$(xout)" "no active crew-ship run in $XW/repo" "row 4: a subdir reads its toplevel"
XCWD=repo/sub xsame w_none ac-qa-watch.sh --once
assert_eq "$(xout)" "no active qa run in $XW/repo" "row 4: the cwd's subdir reads its toplevel"
xsame w_running ac-ship-watch.sh --interval 1 --interval 5 --once --self-pane p1
assert_eq "$(cat "$TMP/xn.herdr")" "" "row 4: --once never closes a pane"

# 5. the live loop with a run (WD4: the interval only handed to sleep): the
#    prelude, one paint while the frame is unchanged, a second when steps.tsv
#    changes, TERM and HUP restoring the cursor (143, 129); an interval sleep
#    refuses (`abc`) is handed to it each tick on both sides.
w_live() { xseed; xrd ship r1; printf 'outcome=running\nbranch=b\n' >"$XRD/run.meta"; printf 'a\trunning\t0\n' >"$XRD/steps.tsv"; printf '2026-01-01T00:00:00Z go\n' >"$XRD/logs/run.log"; }
w_livechange() { w_live; printf 'a\tcompleted\t0\nb\trunning\t1\n' >"$XW/steps2"; xhook 2 "cp '$XW/steps2' '$XRD/steps.tsv'"; }
XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=3 xsame w_live ac-ship-watch.sh --interval 1
assert_eq "$XN_RC:$(xcount $'\033[H' "$TMP/xn.out")" "143:2" "row 5: the prelude and one paint over three ticks"
assert_eq "$(tail -c 6 "$TMP/xn.out" | od -An -c | tr -d ' \n')" "033[?25h" "row 5: TERM restores the cursor"
XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=3 xsame w_livechange ac-ship-watch.sh --interval 1
assert_eq "$(xcount $'\033[H' "$TMP/xn.out")" "3" "row 5: a changed steps.tsv is painted again"
XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=2 XSIG=HUP xsame w_live ac-qa-watch.sh
assert_eq "$XN_RC:$(tr '\n' ' ' <"$TMP/xn.sleep")" "129:2 2 " "row 5: HUP, the default interval"
XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=3 xsame w_live ac-ship-watch.sh --interval abc
assert_eq "$(tr '\n' ' ' <"$TMP/xn.sleep")" "abc abc abc " "row 5: WD4 - abc only handed to sleep while a run is shown"
XTTY=1 XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=1 xsame w_live ac-ship-watch.sh --interval 1

# 6. the live finish and the self-close: `run finished: <outcome>`, `sleep 5`,
#    the raw herdr close of --self-pane through the session ladder
#    (AC_HERDR_SESSION > config/herdr-session > default; homeless: default),
#    and none without --self-pane.
w_done() { xseed; xrd qa q1; printf 'outcome=passed\n' >"$XRD/run.meta"; printf 'a\tcompleted\t0\n' >"$XRD/steps.tsv"; }
w_donecfg() { w_done; printf ' s2 \n' >"$XW/home/config/herdr-session"; }
XKILL=9 xsame w_done ac-qa-watch.sh --self-pane p9
assert_eq "$XN_RC:$(tr '\n' ' ' <"$TMP/xn.sleep"):$(cat "$TMP/xn.herdr")" "0:5 :--session default pane close p9" "row 6: finish, sleep 5, the close"
assert_contains "$(xout)" $'run finished: passed\n\033[?25h' "row 6: the finish line, then the restore"
XKILL=9 xsame w_done ac-qa-watch.sh
assert_eq "$XN_RC:$(cat "$TMP/xn.herdr")" "0:" "row 6: no --self-pane, no herdr call"
XE=AC_HERDR_SESSION=s1 XKILL=9 xsame w_donecfg ac-qa-watch.sh --self-pane p9
assert_eq "$(cat "$TMP/xn.herdr")" "--session s1 pane close p9" "row 6: AC_HERDR_SESSION first"
XKILL=9 xsame w_donecfg ac-qa-watch.sh --self-pane p9
assert_eq "$(cat "$TMP/xn.herdr")" "--session s2 pane close p9" "row 6: config/herdr-session, trimmed"
XHOMELESS=1 XKILL=9 xsame w_donecfg ac-qa-watch.sh --self-pane p9
assert_eq "$(cat "$TMP/xn.herdr")" "--session default pane close p9" "row 6: homeless reads the default"

# 7. idle, from the date stub's instant: old steps/log close after the default
#    1800 (`sleep 2`, the close); fresh ones never idle; a non-integer limit
#    never idles - SHELL-OWN, named: `[`'s line each tick on the original only.
w_old() { w_live; xold "$XRD/steps.tsv" "$XRD/logs/run.log"; }
w_fresh() { w_live; xnow "$XRD/steps.tsv" "$XRD/logs/run.log"; }
XKILL=9 xsame w_old ac-ship-watch.sh --self-pane p9
assert_eq "$XN_RC:$(tr '\n' ' ' <"$TMP/xn.sleep"):$(cat "$TMP/xn.herdr")" "0:2 :--session default pane close p9" "row 7: idle past 1800"
assert_contains "$(xout)" $'\nrun idle too long - closing watch\n' "row 7: the idle line"
XKILL=3 xsame w_fresh ac-ship-watch.sh --interval 1
assert_eq "$XN_RC" "143" "row 7: a fresh run never idles"
XE=AC_SHIP_WATCH_IDLE=abc XKILL=3 xpair w_old ac-ship-watch.sh --interval 1
assert_eq "$XO_RC:$XN_RC" "143:143" "SHELL-OWN idle abc: never closes, both"
cmp -s "$TMP/xo.out" "$TMP/xn.out" || fail "SHELL-OWN idle abc: the same frames"
assert_contains "$(xoerr)" "integer expression expected" "SHELL-OWN idle abc: the original's test line"
assert_eq "$(xerr)" "" "SHELL-OWN idle abc: nothing on the port's stderr"

# 8. no run, live: the waiting text painted once; `waited` past 300 closes
#    before that tick's sleep (`301`: no sleep; `100`: three); `010` adds 8,
#    `0` nothing, `-1` shrinks it; a non-operand ends the board - exit 1
#    (`5abc`, `0.5`, `08`), exit 0 for a name (`abc`), the cursor restored -
#    SHELL-OWN, named; a whole expression (`1+1`) - INTERVAL ARITHMETIC, named.
xsame w_none ac-ship-watch.sh --interval 301 --self-pane p1
assert_eq "$XN_RC:$(cat "$TMP/xn.sleep"):$(cat "$TMP/xn.herdr")" "0::--session default pane close p1" "row 8: 301 closes before any sleep"
assert_contains "$(xout)" "waiting for a crew-ship run in $XW/repo ..." "row 8: the waiting text"
XKILL=9 xsame w_none ac-qa-watch.sh --interval 100 --self-pane p2
assert_eq "$(tr '\n' ' ' <"$TMP/xn.sleep"):$(cat "$TMP/xn.herdr")" "100 100 100 :--session default pane close p2" "row 8: 100 closes after three sleeps"
for iv in 2 010 0 -1; do
  XKILL=3 xsame w_none ac-ship-watch.sh --interval "$iv"
  assert_eq "$XN_RC:$(xcount $'\033[H' "$TMP/xn.out")" "143:2" "row 8: interval $iv - one paint, no close within three ticks"
done
for iv in 5abc 0.5 08 abc; do
  XKILL=3 xpair w_none ac-qa-watch.sh --interval "$iv" --self-pane p3
  want=1; [ "$iv" != abc ] || want=0
  assert_eq "$XO_RC:$XN_RC:$(cat "$TMP/xo.herdr" "$TMP/xn.herdr" "$TMP/xo.sleep" "$TMP/xn.sleep")" "$want:$want:" "SHELL-OWN interval $iv: the board ends at its first no-run tick, nothing closed or slept"
  cmp -s "$TMP/xo.out" "$TMP/xn.out" || fail "SHELL-OWN interval $iv: the same paint and restore"
  assert_contains "$(xoerr)" "$iv" "SHELL-OWN interval $iv: the original's own line"
  assert_eq "$(xerr)" "" "SHELL-OWN interval $iv: nothing on the port's stderr"
done
XKILL=3 xpair w_none ac-ship-watch.sh --interval 1+1
assert_eq "$XO_RC:$(tr '\n' ' ' <"$TMP/xo.sleep")" "143:1+1 1+1 1+1 " "INTERVAL ARITHMETIC: the original evaluated 1+1 and waited on"
assert_eq "$XN_RC:$(cat "$TMP/xn.sleep")" "1:" "INTERVAL ARITHMETIC: the port ends 1 at the first no-run tick"

# 9. SIGNALS, named: SIGINT to the board alone - bash swallowed it while its
#    sleep ran and went on to the TERM; the port restores the cursor and ends
#    130 at once.
w_int() { w_live; xhook 2 'kill -INT "$PPID"; i=0; while kill -0 "$PPID" 2>/dev/null && [ "$i" -lt 40 ]; do /bin/sleep 0.05; i=$((i + 1)); done'; }
XWRAP="$XS/int-default" XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=4 xpair w_int ac-ship-watch.sh --interval 1
assert_eq "$XO_RC:$(tr '\n' ' ' <"$TMP/xo.sleep")" "143:1 1 1 1 " "SIGINT alone: the original swallowed it"
assert_eq "$XN_RC:$(tr '\n' ' ' <"$TMP/xn.sleep")" "130:1 1 " "SIGINT alone: the port ends 130"
cmp -s "$TMP/xo.out" "$TMP/xn.out" || fail "SIGINT alone: the same paint and restore: $(diff "$TMP/xo.out" "$TMP/xn.out" | head -n 4)"

# 10. WD2 and WD6: a log line cut at 79 bytes splits a character. --once prints
#     the byte under either locale (at parity); painted under C both sides
#     paint it whole; painted under UTF-8 - FAIL-PATH, named - the original's
#     sed stopped at that line (`sed: RE error: illegal byte sequence`), the
#     port paints the whole frame.
w_split() { w_live; printf '2026-01-01T01:02:05Z x%s\n' "$XE_ACCENTS" >"$XRD/logs/run.log"; }
XLC=en_US.UTF-8 xsame w_split ac-ship-watch.sh --once
assert_contains "$(xout)" "x$(printf 'é%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33)"$'\303'"…" "WD2: the cut splits the 34th é"
XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=1 xsame w_split ac-ship-watch.sh --interval 1
XLC=en_US.UTF-8 XE=AC_SHIP_WATCH_IDLE=99999999999 XKILL=1 xpair w_split ac-ship-watch.sh --interval 1
assert_eq "$XO_RC:$XN_RC" "143:143" "WD6: both painted one frame"
case "$(xoout)" in *"01:02:05"*) fail "WD6: the original's sed stopped before the log line" ;; esac
assert_eq "$(xoerr)" "sed: RE error: illegal byte sequence" "WD6: and sed said so"
assert_contains "$(xout)" $'\303'"…"$'\033[K' "WD6: the port paints the whole frame"
assert_eq "$(xerr)" "" "WD6: nothing on the port's stderr"

pass
