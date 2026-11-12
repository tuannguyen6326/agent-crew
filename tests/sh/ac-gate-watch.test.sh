#!/usr/bin/env bash
# ac-gate-watch.test.sh - the ACTIVE-run second-chief observer (bin/ac-gate-watch.sh).
# It shows ONLY gates running RIGHT NOW (each run's .gate-running.<pid> marker +
# its observe descriptor); a SETTLED second-chief.md is an ordinary artifact and creates NO
# row. --once renders the active dashboard (newest-first, dot-dirs are not
# families) and never crashes on an empty home; --tail follows the newest active
# gate's REAL emitted bytes (the exact prompt once, then the harness's own
# output) - it never invents reasoning.
# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# ac-gate-watch needs jq unconditionally (it reads the observe descriptor); a
# jq-less host can run nothing here.
command -v jq >/dev/null || skip 'jq not available'

make_home
W="$BIN/ac-gate-watch.sh"

# mk_active <fam> <stage> <round> <engine> <mtime> <prompt> <out> [pid] - stamp
# ONE active gate:
# the run's .gate-running.<pid> marker (ac-gate's live fields) + the transient observe
# descriptor the pane-agent arm publishes + its real prompt/out/err stream files.
mk_active() {
  local fam=$1 stage=$2 round=$3 eng=$4 mt=$5 pc=$6 oc=$7 pid=${8:-$$} d
  d="$AC_HOME/data/$fam"; mkdir -p "$d/$stage"
  printf '%s\n' "$pc" >"$d/.gate-prompt-r$round"
  printf '%s\n' "$oc" >"$d/.gate-out-r$round"
  : >"$d/.gate-err-r$round"
  printf '{"pane":"pX","tab":"tX","harness":"%s","prompt":"%s","out":"%s","err":"%s"}\n' \
    "$eng" "$d/.gate-prompt-r$round" "$d/.gate-out-r$round" "$d/.gate-err-r$round" \
    >"$d/.gate-observe-r$round"
  printf 'family=%s\nstage=%s\nround=%s\nengine=%s\nmodel=\nat=%s\nobserve=%s\npid=%s\n' \
    "$fam" "$stage" "$round" "$eng" "2026-07-23T09:0${mt}:00Z" \
    "$d/.gate-observe-r$round" "$pid" >"$d/.gate-running.$pid"
  touch -t "$(printf '2026072309%02d' "$mt")" "$d/.gate-running.$pid"
}

# 1. empty home: clean exit, "no gate running", zero active
out="$("$W" --once 2>&1)" || fail "watch --once must exit 0 on an empty home"
case "$out" in *"no gate running"*) ;; *) fail "empty home should say 'no gate running': $out" ;; esac
case "$out" in *"0 active"*) ;; *) fail "empty home should report 0 active: $out" ;; esac

# 2. a SETTLED second-chief.md alone creates NO row (the contract inversion vs the
#    old gate.json board: settled reviews are browsed elsewhere, never here)
mkdir -p "$AC_HOME/data/settled/spec"
printf -- '---\ndecision: continue\n---\n# Second-Chief Decision\n' >"$AC_HOME/data/settled/spec/second-chief.md"
out="$("$W" --once 2>&1)" || fail "watch must not crash on a settled review"
case "$out" in *settled*) fail "a settled second-chief.md must NOT appear on the active board: $out" ;; esac
case "$out" in *"no gate running"*) ;; *) fail "a settled-only home still has no ACTIVE gate: $out" ;; esac

# 3. one active gate: family, stage, engine, and the REAL last activity line show.
# The activity column is truncated to the terminal width, so its probe token is
# kept short; --tail (below) proves the full untruncated bytes are followed.
mk_active widget spec 1 codex 6 "PROMPT-WIDGET-SPEC contract" "emit-live-widget"
out="$("$W" --once 2>&1)" || fail "watch --once must exit 0 with an active gate"
case "$out" in *"1 active"*) ;; *) fail "one active gate should report 1 active: $out" ;; esac
case "$out" in *widget*) ;; *) fail "the active family is not shown: $out" ;; esac
case "$out" in *spec*) ;; *) fail "the active stage is not shown: $out" ;; esac
case "$out" in *codex*) ;; *) fail "the active engine is not shown: $out" ;; esac
case "$out" in *r1*) ;; *) fail "the active gate round is not shown: $out" ;; esac
case "$out" in *emit-live-widget*) ;; *) fail "the REAL emitted activity is not shown: $out" ;; esac

# 4. two active gates float NEWEST-first (by marker mtime)
mk_active gizmo plan 2 claude 8 "PROMPT-GIZMO-PLAN" "gizmo-activity"
out="$("$W" --once 2>&1)"
gline="$(printf '%s\n' "$out" | grep -n gizmo | head -1 | cut -d: -f1)"
wline="$(printf '%s\n' "$out" | grep -n widget | head -1 | cut -d: -f1)"
{ [ -n "$gline" ] && [ -n "$wline" ] && [ "$gline" -lt "$wline" ]; } \
  || fail "the newer active gate must sort first (gizmo=$gline widget=$wline)"
out="$("$W" --round 2 --once 2>&1)"
case "$out" in *gizmo*) ;; *) fail "--round 2 must retain the R2 gate: $out" ;; esac
case "$out" in *widget*) fail "--round 2 must filter out the R1 gate: $out" ;; esac
assert_fails "$W" --round 3 --once

# 5. a dot-prefixed dir is never treated as a family
mkdir -p "$AC_HOME/data/.hidden/spec"
printf 'family=.hidden\nstage=spec\nround=1\nengine=codex\nmodel=\nat=x\nobserve=-\npid=%s\n' \
  "$$" >"$AC_HOME/data/.hidden/.gate-running.$$"
out="$("$W" --once 2>&1)" || fail "watch must not crash on a dot-prefixed dir"
case "$out" in *hidden*) fail "a dot-prefixed dir must not appear as a family: $out" ;; esac

# 5b. a story's dir one level down, marked .family (src/brief.ts's header owns
#     the layout), is a family of its own: its gate shows under the story's name.
mkdir -p "$AC_HOME/data/ep/story"
: >"$AC_HOME/data/ep/story/.family"
mk_active ep/story plan 1 codex 9 "PROMPT-STORY-PLAN" "emit-live-story"
out="$("$W" --once 2>&1)" || fail "watch --once must exit 0 with a nested story's gate"
case "$out" in *"3 active"*) ;; *) fail "the story's gate should count as active: $out" ;; esac
case "$out" in *story*) ;; *) fail "the story's gate is not shown: $out" ;; esac
case "$out" in *"ep/story"*) fail "the story is named by itself, never by its path: $out" ;; esac
rm -rf "$AC_HOME/data/ep"

# 6. --tail follows the newest active gate's EXACT prompt (once) + real output.
#    --tail is an endless follow loop (no --once), so bound it: run it briefly in
#    the background, then stop it and inspect what it emitted. No timeout(1) on
#    this host, so background+kill is the bounded harness.
tout="$TMP/tail.out"
# The whole background+kill+wait runs in a subshell whose stderr is discarded, so
# the shell's "Terminated" job-control notice never leaks into the suite output.
(
  "$W" --tail --interval 1 >"$tout" 2>&1 &
  tpid=$!
  sleep 2
  kill "$tpid" 2>/dev/null
  wait "$tpid" 2>/dev/null
) 2>/dev/null || true
tcap="$(cat "$tout" 2>/dev/null)"
case "$tcap" in *"-- prompt --"*) ;; *) fail "--tail must print the prompt block: $tcap" ;; esac
case "$tcap" in *"PROMPT-GIZMO-PLAN"*) ;; *) fail "--tail must show the newest gate's EXACT prompt: $tcap" ;; esac
case "$tcap" in *"gizmo"*) ;; *) fail "--tail must banner the active family/stage: $tcap" ;; esac
case "$tcap" in *"gizmo-activity"*) ;; *) fail "--tail must follow the REAL emitted output bytes: $tcap" ;; esac
# 7. --tail NAMES ITS FLEET HOME, like the dashboard header already does. The
#    auto-opened board is a tail board, and a fleet runs several homes: an
#    operator who cannot tell WHICH home is being watched cannot use the surface
#    to diagnose (it blocked a diagnosis on 2026-07-26).
case "$tcap" in *"$(basename "$AC_HOME")"*) ;; *) fail "--tail header must name the fleet home: $tcap" ;; esac

# 8. once the followed gate SETTLES (its .gate-running goes away), --tail
#    announces where its prompt is retained - a settled gate has no live stream
#    left to follow, but the board the captain runs should still say where the
#    prompt landed (ac-gate.sh keeps it at gate-prompt-r<N>.md, never deleted).
rm -f "$AC_HOME"/data/*/.gate-running*
mk_active solo design 1 opencode 9 "PROMPT-SOLO-DESIGN" "solo-activity"
tout2="$TMP/tail2.out"
(
  "$W" --tail --interval 1 >"$tout2" 2>&1 &
  tpid=$!
  sleep 2
  rm -f "$AC_HOME/data/solo/.gate-running".*
  sleep 2
  kill "$tpid" 2>/dev/null
  wait "$tpid" 2>/dev/null
) 2>/dev/null || true
tcap2="$(cat "$tout2" 2>/dev/null)"
case "$tcap2" in *"settled"*) ;; *) fail "--tail must announce the settled gate: $tcap2" ;; esac
case "$tcap2" in *"$AC_HOME/data/solo/.gate-prompt-r1"*) ;; *) fail "--tail must name where the settled prompt is retained: $tcap2" ;; esac

# 9. The marker intentionally lands before pane-agent publishes its observation
# descriptor. If --tail observes that startup window, it must keep probing the
# descriptor rather than pinning empty stream paths for the whole round.
rm -f "$AC_HOME"/data/*/.gate-running*
lag="$AC_HOME/data/lag"; mkdir -p "$lag/spec"
: >"$lag/.gate-observe-r1"
printf 'family=lag\nstage=spec\nround=1\nengine=codex\nmodel=\nat=2026-07-23T09:10:00Z\nobserve=%s\npid=%s\n' \
  "$lag/.gate-observe-r1" "$$" >"$lag/.gate-running.$$"
tout3="$TMP/tail3.out"
(
  "$W" --tail --interval 1 >"$tout3" 2>&1 &
  tpid=$!
  sleep 2
  printf '%s\n' "PROMPT-LATE-DESCRIPTOR" >"$lag/.gate-prompt-r1"
  printf '%s\n' "late-descriptor-activity" >"$lag/.gate-out-r1"
  : >"$lag/.gate-err-r1"
  printf '{"pane":"pL","tab":"tL","harness":"codex","prompt":"%s","out":"%s","err":"%s"}\n' \
    "$lag/.gate-prompt-r1" "$lag/.gate-out-r1" "$lag/.gate-err-r1" \
    >"$lag/.gate-observe-r1"
  sleep 2
  kill "$tpid" 2>/dev/null
  wait "$tpid" 2>/dev/null
) 2>/dev/null || true
tcap3="$(cat "$tout3" 2>/dev/null)"
case "$tcap3" in *PROMPT-LATE-DESCRIPTOR*) ;; *) fail "--tail must recover a descriptor published after the marker: $tcap3" ;; esac
case "$tcap3" in *late-descriptor-activity*) ;; *) fail "--tail must follow streams from the late descriptor: $tcap3" ;; esac

# 10. R1 and R2 share family/stage. A watcher that misses the brief marker-free
# interval must still switch because round + observe identify the run.
rm -f "$AC_HOME"/data/*/.gate-running*
mk_active swap spec 1 codex 11 "PROMPT-SWAP-R1" "swap-r1-activity"
tout4="$TMP/tail4.out"
(
  "$W" --tail --interval 1 >"$tout4" 2>&1 &
  tpid=$!
  sleep 2
  mk_active swap spec 2 codex 12 "PROMPT-SWAP-R2" "swap-r2-activity"
  sleep 2
  kill "$tpid" 2>/dev/null
  wait "$tpid" 2>/dev/null
) 2>/dev/null || true
tcap4="$(cat "$tout4" 2>/dev/null)"
case "$tcap4" in *PROMPT-SWAP-R1*) ;; *) fail "--tail must show R1 before the switch: $tcap4" ;; esac
case "$tcap4" in *PROMPT-SWAP-R2*) ;; *) fail "--tail must switch to the R2 prompt: $tcap4" ;; esac
case "$tcap4" in *swap-r2-activity*) ;; *) fail "--tail must switch to the R2 stream: $tcap4" ;; esac
case "$tcap4" in *" / r1  "*"/ r2  "*) ;; *) fail "--tail must label both rounds: $tcap4" ;; esac

# 11. A SIGKILL cannot run ac-gate's EXIT trap. The watcher remains read-only
# but ignores a marker whose recorded owner pid is dead.
rm -f "$AC_HOME"/data/*/.gate-running*
mk_active dead spec 1 codex 13 "PROMPT-DEAD" "dead-activity" 99999999
out="$("$W" --once 2>&1)" || fail "watch must tolerate a stale marker"
case "$out" in *"0 active"*) ;; *) fail "a dead-owner marker must not count as active: $out" ;; esac
case "$out" in *dead*) fail "a dead-owner marker must not render as a live gate: $out" ;; esac

# 12. Two runs of ONE family at once are two rows: each run owns its marker.
rm -f "$AC_HOME"/data/*/.gate-running*
hold_open duo-holder
mk_active duo spec 1 codex 14 "PROMPT-DUO-SPEC" "duo-spec-activity"
mk_active duo plan 2 claude 15 "PROMPT-DUO-PLAN" "duo-plan-activity" "$HOLD_PID"
out="$("$W" --family duo --once 2>&1)" || fail "watch --once must exit 0 with two runs of one family"
hold_close duo-holder "$HOLD_PID"
case "$out" in *"2 active"*) ;; *) fail "two live runs of one family must both count: $out" ;; esac
case "$out" in *spec*plan*|*plan*spec*) ;; *) fail "both runs of the family must render: $out" ;; esac

# 13. The dashboard closes itself on IDLE, never on age: AC_GATE_WATCH_IDLE
#     seconds with no active gate close it, and a live gate keeps it open
#     however old its marker is (mk_active's are months old).
board_state() { # board_state <seconds> - "open" or "closed" after that long
  local p
  AC_GATE_WATCH_IDLE=1 "$W" --interval 1 >/dev/null 2>&1 &
  p=$!
  sleep "$1"
  if kill -0 "$p" 2>/dev/null; then kill "$p"; wait "$p" 2>/dev/null; echo open; else echo closed; fi
}
rm -f "$AC_HOME"/data/*/.gate-running*
mk_active aged spec 1 codex 16 "PROMPT-AGED" "aged-activity"
assert_eq "$(board_state 3 2>/dev/null)" "open" "a live gate keeps the board open however old its marker"
rm -f "$AC_HOME"/data/*/.gate-running*
assert_eq "$(board_state 5 2>/dev/null)" "closed" "with no active gate the board closes after AC_GATE_WATCH_IDLE"

# --- the board, row by row -----------------------------------------------------
# Each row runs the shim in a world rebuilt from nothing ($XW: home/ with data/
# and config/, cwd/, log/, hooks/), markers touch -t stamped and owned by this
# suite's own live pid, under TERM=xterm and LC_ALL=C unless the row says
# otherwise. The board spawns `sleep` from PATH once a tick, so every loop row
# is driven by the leg's sleep stub: it logs each call, runs the row's hook for
# that call, and from call XKILL on signals its parent and waits for it to go -
# a row ends after an exact number of ticks, never on a wall clock.
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
# A job a non-interactive shell starts may hold SIGINT ignored, which bash
# cannot trap; a SIGINT row runs the board with INT at its default first.
cat >"$XS/int-default" <<'STUB'
#!/usr/bin/env python3
import os, signal, sys
signal.signal(signal.SIGINT, signal.SIG_DFL)
os.execvp(sys.argv[1], sys.argv[1:])
STUB
chmod +x "$XS/sleep" "$XS/herdr" "$XS/int-default"

XLC=C; XTERMV=xterm; XHOMELESS=0; XE=""; XPATH=""; XWRAP=""; XTTY=0; XKILL=999; XSIG=TERM; XRC=0
xrun() {  # xrun <world fn> <args...> - the shim in a fresh world (XTTY=1: on a pty, stderr in stdout), SIGKILLed past 30 s; sets XRC
  local p=xn path x dog rc=0
  "$1"; shift
  path="$XS:$PATH"; [ -z "$XPATH" ] || path="$XPATH"
  local e=("PATH=$path" "XW=$XW" "XKILL=$XKILL" "XSIG=$XSIG" "LC_ALL=$XLC")
  [ "$XTERMV" = unset ] || e+=("TERM=$XTERMV")
  [ "$XHOMELESS" = 1 ] || e+=("AC_HOME=$XW/home")
  for x in $XE; do e+=("$x"); done
  local u=(-u AC_HOME -u TERM -u AC_HERDR_SESSION -u AC_GATE_WATCH_IDLE -u AC_FLEET_NAME -u AC_FLEET_STATE -u AC_SCOPE
    -u LANG -u LC_CTYPE -u COLUMNS -u LINES -u CDPATH)
  rm -f "$TMP/$p.pid" "$TMP/$p.done"
  ( n=0 x="" id=""
    until [ -e "$TMP/$p.done" ] || [ "$n" -ge 300 ]; do
      [ -n "$id" ] || { x="$(cat "$TMP/$p.pid" 2>/dev/null || true)"; id="$(proc_identity "$x")"; }
      sleep 0.1; n=$((n + 1))
    done
    [ -e "$TMP/$p.done" ] || ! same_process "$x" "$id" || kill -9 "$x" 2>/dev/null || true ) &
  dog=$!
  if [ "$XTTY" = 1 ]; then
    (cd "$XW/cwd" && run_on_tty /bin/sh -c 'printf %s "$$" >"$0"; exec "$@"' "$TMP/$p.pid" \
      env "${u[@]}" "${e[@]}" "$BIN/ac-gate-watch.sh" ${@+"$@"}) >"$TMP/$p.out" 2>&1 || rc=$?
    : >"$TMP/$p.err"
  else
    # The braces' stderr takes the shell's own job notice for a board a signal
    # ended; the status is kept.
    { (cd "$XW/cwd" && exec $XWRAP /bin/sh -c 'printf %s "$$" >"$0"; exec "$@"' "$TMP/$p.pid" \
      env "${u[@]}" "${e[@]}" "$BIN/ac-gate-watch.sh" ${@+"$@"}) </dev/null >"$TMP/$p.out" 2>"$TMP/$p.err"; } 2>/dev/null || rc=$?
  fi
  : >"$TMP/$p.done"
  wait "$dog" 2>/dev/null || true
  cat "$XW/log/sleep.log" >"$TMP/$p.sleep" 2>/dev/null || : >"$TMP/$p.sleep"
  cat "$XW/log/herdr.log" >"$TMP/$p.herdr" 2>/dev/null || : >"$TMP/$p.herdr"
  XRC=$rc
}
xok() { xrun "$@"; assert_eq "$XRC" "0" "gate-watch exit for '$*'"; }
xkilled() { xrun "$@"; assert_eq "$XRC" "143" "gate-watch runs to the stub's TERM for '$*'"; }
xrefuse() {  # xrefuse <stderr> <world fn> <args...> - exit 1, no stdout, exactly <stderr>
  local want="$1"; shift
  xrun "$@"
  assert_eq "$XRC:$(xout):$(xerr)" "1::$want" "gate-watch refusal for '$*'"
}
xout() { cat "$TMP/xn.out"; }
xerr() { cat "$TMP/xn.err"; }
xrows() { awk '$1 == ">" { printf "%s ", $2 }' "$TMP/xn.out"; }   # the row families, in order
xcount() {  # xcount <needle> <file> - how many times <needle> occurs in <file>
  local rest n=0
  rest="$(cat "$2")"
  while [ "${rest#*"$1"}" != "$rest" ]; do rest="${rest#*"$1"}"; n=$((n + 1)); done
  printf '%s' "$n"
}
xwithout() {  # xwithout <tool> - the leg's PATH with every dir holding <tool> mirrored without it
  local dirs d f key mirror out=""
  IFS=: read -r -a dirs <<<"$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ -x "$d/$1" ]; then
      key="$(cd "$d" && pwd -P)"; mirror="$TMP/no$1$(printf '%s' "$key" | tr -c 'A-Za-z0-9' '_')"
      if [ ! -d "$mirror" ]; then
        mkdir -p "$mirror"
        for f in "$key"/*; do [ "$(basename "$f")" = "$1" ] || ln -sf "$f" "$mirror/$(basename "$f")" 2>/dev/null || true; done
      fi
      d="$mirror"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s\n' "$XS:$out"
}

xseed() { rm -rf "$XW"; mkdir -p "$XW/home/data" "$XW/home/config" "$XW/cwd" "$XW/log" "$XW/hooks"; }
xmark() {  # xmark <family> <suffix> <minute> <meta lines, printf %b> - one marker, stamped 2026-07-23 09:<minute>
  mkdir -p "$XW/home/data/$1"
  printf '%b' "$4" >"$XW/home/data/$1/.gate-running.$2"
  touch -t "$(printf '2026072309%02d' "$3")" "$XW/home/data/$1/.gate-running.$2"
}
xgate() {  # xgate <family> <suffix> <minute> <stage> <round> <engine> <model> <prompt> <out> <err> - a live marker, its descriptor and its streams (printf %b bytes)
  local d="$XW/home/data/$1"
  mkdir -p "$d"
  printf '%b' "$8" >"$d/p$2"; printf '%b' "$9" >"$d/o$2"; printf '%b' "${10}" >"$d/e$2"
  printf '{"pane":"pX","tab":"tX","prompt":"%s","out":"%s","err":"%s"}\n' "$d/p$2" "$d/o$2" "$d/e$2" >"$d/obs$2"
  xmark "$1" "$2" "$3" "family=$1\nstage=$4\nround=$5\nengine=$6\nmodel=$7\nat=2026-07-23T09:$(printf %02d "$3"):00Z\nobserve=$d/obs$2\npid=$$\n"
}
xdesc() {  # xdesc <family> <minute> <descriptor text, @D = the family dir> - a live marker whose observe names it
  local d="$XW/home/data/$1"
  mkdir -p "$d"
  printf '%s\n' "${3//@D/$d}" >"$d/obs"
  xmark "$1" 1 "$2" "stage=spec\nround=1\nengine=codex\nobserve=$d/obs\npid=$$\n"
}
xhook() { printf '%s\n' "$2" >"$XW/hooks/$1"; }   # xhook <call> <sh> - run by the sleep stub at that call, before its signal
XNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
XTRAILER='--tail to follow the exact prompt + live emitted output of the active gate'
XHEAD="$(printf '  %-22s %-8s %-5s %-20s %s' family stage round engine/model 'since | activity')"
XLONG="last activity héllo"
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28; do XLONG="$XLONG word$i"; done

# 1. --once on an empty home, and on one holding only a SETTLED review.
w_empty() { xseed; }
w_settled() { xseed; mkdir -p "$XW/home/data/settled/spec"; printf -- '---\ndecision: continue\n---\n# Second-Chief Decision\n' >"$XW/home/data/settled/spec/second-chief.md"; }
xok w_empty --once
assert_eq "$(xout)" "ac-gate home  0 active

(no gate running)" "row 1: the empty board, byte for byte"
xok w_settled --once
assert_eq "$(xout)" "ac-gate home  0 active

(no gate running)" "row 1: a settled review is no row"

# 2. one marker (codex, r1, no model): the exact frame under C (a 20-BYTE cut
#    of the activity, TERM=xterm answering 80 columns), the 20-CHARACTER cut
#    under UTF-8, and the 123-byte cut with TERM unset or empty (tput fails:
#    200).
w_one() { xseed; xgate fam1 1 6 spec 1 codex '' 'PROMPT ONE\n' "line one\n$XLONG\n" ''; }
xok w_one --once
assert_eq "$(xout)" "ac-gate home  1 active

$XHEAD
$(printf ' > %-22s %-8s %-5s %-20s %s %s' fam1 spec r1 codex 09:06:00 'last activity héllo')

$XTRAILER" "row 2: one gate, byte for byte"
XLC=en_US.UTF-8 xok w_one --once
assert_contains "$(xout)" "$(printf ' > %-22s %-8s %-5s %-20s %s %s' fam1 spec r1 codex 09:06:00 'last activity héllo ')
" "row 2: under UTF-8 the cut counts characters"
for xt in unset ''; do
  XTERMV="$xt" xok w_one --once
  xact="$(awk '$1 == ">" { sub(/^.*09:06:00 /, ""); print }' "$TMP/xn.out")"
  assert_eq "$(printf '%s' "$xact" | LC_ALL=C wc -c | tr -d ' ')" "123" "row 2: TERM '$xt' leaves 200 columns, a 123-byte cut"
done

# 3. order and pins: newest first by marker mtime; a tie by the whole line in
#    reverse BYTE order under every locale; --round, --stage and --family pins; --round 3.
w_two() { xseed; xgate widget 1 6 spec 1 codex '' 'P1\n' 'widget-act\n' ''; xgate gizmo 2 8 plan 2 claude '' 'P2\n' 'gizmo-act\n' ''; }
xok w_two --once
assert_eq "$(xrows)" "gizmo widget " "row 3: the newer marker first"
w_tie() { xseed; for f in Zz ab a-b a_b; do xgate "$f" 1 5 spec 1 codex '' '' '' ''; done; }
xok w_tie --once
assert_eq "$(xrows)" "ab a_b a-b Zz " "row 3: a tie in reverse byte order"
xok w_two --round 2 --once
assert_eq "$(xrows)" "gizmo " "row 3: --round 2"
xok w_two --stage spec --once
assert_eq "$(xrows)" "widget " "row 3: --stage spec"
xok w_two --family widget --once
assert_eq "$(xrows)" "widget " "row 3: --family widget"
xok w_two --family nosuch --once
assert_contains "$(xout)" "0 active" "row 3: a pin nothing matches"
xrefuse "ERROR: --round must be 1 or 2" w_two --round 3 --once
XLC=en_US.UTF-8 xok w_tie --once
assert_eq "$(xrows)" "ab a_b a-b Zz " "row 3: the tie keeps byte order under UTF-8"

# 4. marker fields and shapes: a model, at=now, an empty observe, no
#    stage/round/at, a leading-zero pid, pid abc, a dead pid, a pid past
#    pid_t, the empty suffix with no engine, a directory marker, a dot-dir, a
#    plain file in data/, a repeated key with an empty last value, CRLF values, a linked marker (its own mtime)
#    and a linked family dir; pid 1 (EPERM: dead) when not root.
w_fields() {
  xseed
  xgate full 1 1 spec 1 claude opus 'P\n' 'full-act\n' ''
  xmark nowat 2 2 "stage=spec\nround=1\nengine=codex\nat=now\npid=$$\n"
  xmark noobs 3 3 "stage=plan\nround=2\nengine=codex\nat=2026-07-23T09:03:00Z\nobserve=\npid=$$\n"
  xmark bare 4 4 "engine=pi\npid=$$\n"
  xmark lead 6 6 "stage=spec\nround=1\nengine=codex\npid=0$$\n"
  xmark abc 7 7 "stage=spec\nround=1\nengine=codex\npid=abc\n"
  xmark gone 8 8 "stage=spec\nround=1\nengine=codex\npid=99999999\n"
  xmark huge 9 9 "stage=spec\nround=1\nengine=codex\npid=4294967295\n"
  xmark nosuffix '' 10 "stage=design\nround=1\nat=2026-07-23T09:10:00\nmodel=m\npid=$$\n"
  mkdir -p "$XW/home/data/dirmark/.gate-running.1"
  mkdir -p "$XW/home/data/.dot"; printf 'stage=spec\npid=%s\n' "$$" >"$XW/home/data/.dot/.gate-running.1"
  : >"$XW/home/data/plainfile"
  xmark lastwins 12 12 "stage=old\nstage=new\nround=1\nround=\nengine=e\npid=$$\n"
  xmark crlf 13 13 "stage=spec\r\nround=1\nengine=codex\npid=$$\r\n"
  xmark crlf2 14 14 "stage=spec\r\nround=1\r\nengine=codex\r\nat=2026-07-23T09:14:00Z\r\npid=$$\n"
  xgate real 15 15 spec 1 codex '' '' 'real-act\n' ''
  mkdir -p "$XW/home/data/linked"
  ln -s "$XW/home/data/real/.gate-running.15" "$XW/home/data/linked/.gate-running.1"
  touch -h -t 202607230916 "$XW/home/data/linked/.gate-running.1"
  ln -s "$XW/home/data/real" "$XW/home/data/alias"
  if [ "$(id -u)" != 0 ]; then xmark init 17 17 "stage=spec\nround=1\nengine=codex\npid=1\n"; fi
}
xok w_fields --once
for f in full nowat noobs bare lead nosuffix lastwins crlf2 real linked alias; do
  case " $(xrows)" in *" $f "*) ;; *) fail "row 4: $f is a live row: $(xrows)" ;; esac
done
for f in abc gone huge dirmark .dot plainfile crlf init; do
  case " $(xrows)" in *" $f "*) fail "row 4: $f is no live row: $(xrows)" ;; esac
done
assert_contains "$(xout)" "$(printf ' > %-22s %-8s %-5s %-20s %s ' full spec r1 claude/opus 09:01:00)full-act" "row 4: engine/model and the activity"
assert_contains "$(xout)" "$(printf ' > %-22s %-8s %-5s %-20s %s ' bare - - pi -)" "row 4: no stage, round or at"
assert_contains "$(xout)" "$(printf ' > %-22s %-8s %-5s %-20s %s ' nosuffix design r1 -/m 09:10:00)" "row 4: the empty suffix, no engine, an at with no Z"
assert_contains "$(xout)" "$(printf ' > %-22s %-8s %-5s %-20s %s ' lastwins new - e -)" "row 4: the last key wins, an empty last value is absent"
# Unreadable markers (not as root): metaGet's WARN, no row; two of them warn
# in byte order of their paths under every locale.
if [ "$(id -u)" != 0 ]; then
  w_locked() {
    xseed
    xgate live 1 5 spec 1 codex '' '' 'live-act\n' ''
    for f in a B; do xmark "$f" 1 1 "pid=$$\n"; chmod 000 "$XW/home/data/$f/.gate-running.1"; done
  }
  for xl in C en_US.UTF-8; do
    XLC="$xl" xok w_locked --once
    assert_eq "$(xerr)" "WARN: cannot read meta file $XW/home/data/B/.gate-running.1
WARN: cannot read meta file $XW/home/data/a/.gate-running.1" "row 4: one WARN per unreadable marker, in byte order under $xl"
    assert_eq "$(xrows)" "live " "row 4: an unreadable marker is no row"
  done
fi

# 5. descriptor forms: a partial last line, not JSON, a null out, an empty
#    last line, an empty out, an absent out (each falls to err), a number (a
#    cwd file of that name), two JSON values, an array, a directory, TAB and
#    CR kept, a NUL dropped, a relative path (the cwd's).
w_desc() {
  local d="$XW/home/data"
  xseed
  xdesc valid 1 '{"out":"@D/o","err":"@D/e"}'; printf 'a\nlast-line' >"$d/valid/o"; printf 'err-line\n' >"$d/valid/e"
  xdesc notjson 2 'not json'
  xdesc nullout 3 '{"out":null,"err":"@D/e"}'; printf 'err-wins\n' >"$d/nullout/e"
  xdesc emptylast 4 '{"out":"@D/o","err":"@D/e"}'; printf 'a\n\n' >"$d/emptylast/o"; printf 'err-after-empty-line\n' >"$d/emptylast/e"
  xdesc emptyfile 5 '{"out":"@D/o","err":"@D/e"}'; : >"$d/emptyfile/o"; printf 'err-after-empty-file\n' >"$d/emptyfile/e"
  xdesc absent 6 '{"out":"@D/none","err":"@D/e"}'; printf 'err-after-absent\n' >"$d/absent/e"
  xdesc number 7 '{"out":5}'; printf 'cwd-file-five\n' >"$XW/cwd/5"
  xdesc twovals 8 '{"out":"@D/o"}{"out":"@D/o"}'; printf 'never\n' >"$d/twovals/o"
  xdesc array 9 '[1,2]'
  mkdir -p "$d/dirdesc/obsdir"; xmark dirdesc 1 10 "stage=spec\nround=1\nengine=codex\nobserve=$d/dirdesc/obsdir\npid=$$\n"
  xdesc ctrl 11 '{"out":"@D/o"}'; printf 'tab\there\r\n' >"$d/ctrl/o"
  xdesc nul 12 '{"out":"@D/o"}'; printf 'a\000b\n' >"$d/nul/o"
  xdesc relative 13 '{"out":"rel-out"}'; printf 'relative-to-cwd\n' >"$XW/cwd/rel-out"
}
xok w_desc --once
for want in 'valid last-line' 'nullout err-wins' 'emptylast err-after-empty-line' 'emptyfile err-after-empty-file' \
  'absent err-after-absent' 'number cwd-file-five' 'nul ab' 'relative relative-to-cwd'; do
  assert_contains "$(xout)" "$(printf ' > %-22s %-8s %-5s %-20s %s ' "${want%% *}" spec r1 codex -)${want#* }
" "row 5: ${want%% *}"
done
for f in notjson twovals array dirdesc; do
  assert_contains "$(xout)" "$(printf ' > %-22s %-8s %-5s %-20s %s ' "$f" spec r1 codex -)
" "row 5: $f has no activity"
done
assert_contains "$(xout)" "$(printf ' > %-22s %-8s %-5s %-20s %s ' ctrl spec r1 codex -)tab"$'\there\r' "row 5: TAB and CR are activity bytes"
# An invalid UTF-8 byte in the last line: the cut counts bytes under C, and
# the byte as one character under UTF-8.
w_badact() { xseed; xgate w6 1 6 spec 1 codex '' '' "last activity h"$'\351'"llo world and more\n" ''; }
xok w_badact --once
assert_contains "$(xout)" "09:06:00 last activity h"$'\351'"llo "$'\n' "row 5: a 20-byte cut under C"
XLC=en_US.UTF-8 xok w_badact --once
assert_contains "$(xout)" "09:06:00 last activity h"$'\351'"llo "$'\n' "row 5: 20 characters under UTF-8, the byte one of them"
assert_eq "$(xerr)" "" "row 5: nothing on stderr for the byte"
# A marker value holding such a byte: the rows are ordered by bytes and both
# shown, and the board stays open while the gate runs.
w_badval() { xseed; xmark f 1 5 "stage=spec\nround=1\nengine=c"$'\351'"x\npid=$$\n"; xgate other 2 6 spec 1 codex '' '' 'other-act\n' ''; }
XLC=en_US.UTF-8 xok w_badval --once
assert_contains "$(xout)" "2 active" "row 5: a byte that is no UTF-8 in a marker value drops no row"
assert_eq "$(xrows)" "other f " "row 5: ... and the rows keep their order"
assert_contains "$(xout)" "$(printf ' > %-22s %-8s %-5s ' f spec r1)c"$'\351'"x" "row 5: the byte reaches the frame"
assert_eq "$(xerr)" "" "row 5: nothing on stderr for it"
XLC=en_US.UTF-8 XE=AC_GATE_WATCH_IDLE=1 XKILL=3 xkilled w_badval --interval 1 --self-pane pZ
assert_eq "$(tr '\n' ' ' <"$TMP/xn.sleep"):$(cat "$TMP/xn.herdr")" "1 1 1 :" "row 5: the board stays open while that gate runs, closing nothing"

# 6. arguments: a positional interval, the refusals in scan order, a value
#    flag with no value or an empty one, and --once --tail (tail wins).
for iv in 5abc 00; do
  xok w_one "$iv" --once
  assert_contains "$(xout)" "1 active" "row 6: '$iv' is taken as the interval"
done
xrefuse "ERROR: unknown arg: --bogus" w_one --bogus
xrefuse "ERROR: unknown arg: -h" w_one -h
xrefuse "ERROR: unknown arg: " w_one ''
xrefuse "ERROR: unknown arg: --bogus" w_one --round 3 --bogus
xrefuse "ERROR: unknown arg: x" w_one --family f --once x
for f in --family --stage --round --self-pane --interval; do
  xrefuse "ERROR: $f needs a value" w_one --once "$f"
  xrefuse "ERROR: $f needs a value" w_one "$f" '' --once
done
XKILL=2 xkilled w_two --once --tail
assert_contains "$(xout)" "following the active second-chief run" "row 6: --tail wins over --once"

# 7. a PATH without jq, an unreadable herdr-session (the board goes on) and a
#    PATH without bun.
XPATH="$(xwithout jq)" xrefuse "ERROR: ac-gate-watch needs jq" w_one --once
if [ "$(id -u)" != 0 ]; then
  w_lockedcfg() { w_one; printf 's9\n' >"$XW/home/config/herdr-session"; chmod 000 "$XW/home/config/herdr-session"; }
  xok w_lockedcfg --once
  assert_contains "$(xout)" "1 active" "row 7: an unreadable session knob does not stop the board"
fi
XPATH="$(xwithout bun)" xrefuse "ERROR: required tool not found: bun" w_one --once

# 8. --tail, driven tick by tick: the newest gate followed (prompt with no
#    trailing LF, err before out); a --family pin on the OLDER family, with
#    both streams growing between ticks (default interval 2); no gate at all;
#    the gate settling (the prompt's retained path); a descriptor published
#    late, its prompt path then changed; a round switch within one family; a
#    stream that shrinks and regrows (the offset kept).
w_tail() {
  xseed
  xgate old 1 5 spec 1 codex '' 'PROMPT OLD\nline two' 'out-a\nout-b\n' 'err-x\n'
  xgate new 2 7 plan 2 claude opus 'PROMPT NEW\n' 'new-out\n' ''
}
XKILL=3 xkilled w_tail --tail --interval 1
assert_eq "$XRC:$(xout)" "143:ac-gate home - following the active second-chief run (Ctrl-C to quit)

== new / plan / r2  [claude/opus] ==
-- prompt --
PROMPT NEW

-- activity/output (live emitted bytes) --
new-out" "row 8: the newest gate, byte for byte"
assert_eq "$(cat "$TMP/xn.sleep")" "1
1
1" "row 8: three ticks"
w_tailgrow() {
  local d="$XW/home/data/old"
  w_tail
  printf 'more-out\n' >"$d/more-out"; printf 'more-err' >"$d/more-err"
  xhook 1 "cat '$d/more-err' >>'$d/e1'; cat '$d/more-out' >>'$d/o1'"
}
XKILL=3 xkilled w_tailgrow --tail --family old
assert_eq "$(xout)" "ac-gate home - following the active second-chief run (Ctrl-C to quit)

== old / spec / r1  [codex] ==
-- prompt --
PROMPT OLD
line two
-- activity/output (live emitted bytes) --
err-x
out-a
out-b
more-errmore-out" "row 8: the pinned older family, its new bytes err first"
assert_eq "$(cat "$TMP/xn.sleep")" "2
2
2" "row 8: the default interval"
XKILL=3 xkilled w_empty --tail --interval 1
assert_eq "$(xout)" "ac-gate home - following the active second-chief run (Ctrl-C to quit)
  ... waiting for an active gate ..." "row 8: no gate, the waiting line once"
w_settle() { w_tail; xhook 1 "rm -f '$XW/home/data/old/.gate-running.1' '$XW/home/data/new/.gate-running.2'"; }
XKILL=3 xkilled w_settle --tail --family old --interval 1
assert_contains "$(xout)" "out-b
  (settled - prompt retained at $XW/home/data/old/p1)
  ... waiting for an active gate ..." "row 8: a settled gate names its retained prompt"
w_late() {
  local d="$XW/home/data/lag"
  xseed
  mkdir -p "$d"; : >"$d/obs"
  xmark lag 1 10 "family=lag\nstage=spec\nround=1\nengine=codex\nmodel=\nat=2026-07-23T09:10:00Z\nobserve=$d/obs\npid=$$\n"
  printf 'PROMPT-LATE\n' >"$d/p"; printf 'late-out\n' >"$d/o"; printf 'late-err\n' >"$d/e"; printf 'PROMPT-TWO\n' >"$d/p2"
  printf '{"prompt":"%s","out":"%s","err":"%s"}\n' "$d/p" "$d/o" "$d/e" >"$d/obs.ready"
  printf '{"prompt":"%s","out":"%s","err":"%s"}\n' "$d/p2" "$d/o" "$d/e" >"$d/obs.two"
  xhook 2 "cp '$d/obs.ready' '$d/obs'"
  xhook 3 "cp '$d/obs.two' '$d/obs'"
}
XKILL=4 xkilled w_late --tail --interval 1
assert_eq "$(xout)" "ac-gate home - following the active second-chief run (Ctrl-C to quit)

== lag / spec / r1  [codex] ==
-- prompt --
PROMPT-LATE

-- activity/output (live emitted bytes) --
late-err
late-out
-- prompt --
PROMPT-TWO" "row 8: a late descriptor adopted, a changed prompt path shown again"
w_switch() {
  local d="$XW/home/data/old"
  w_tail
  rm -f "$XW/home/data/new/.gate-running.2"
  printf 'PROMPT R2\n' >"$d/p9"; printf 'r2-out\n' >"$d/o9"; : >"$d/e9"
  printf '{"prompt":"%s","out":"%s","err":"%s"}\n' "$d/p9" "$d/o9" "$d/e9" >"$d/obs9"
  printf 'family=old\nstage=spec\nround=2\nengine=codex\nmodel=\nat=2026-07-23T09:09:00Z\nobserve=%s\npid=%s\n' "$d/obs9" "$$" >"$d/r2.marker"
  xhook 1 "cp '$d/r2.marker' '$d/.gate-running.9'; touch -t 202607230909 '$d/.gate-running.9'"
}
XKILL=3 xkilled w_switch --tail --interval 1
assert_contains "$(xout)" "== old / spec / r1  [codex] ==" "row 8: R1 first"
assert_contains "$(xout)" "
== old / spec / r2  [codex] ==
-- prompt --
PROMPT R2

-- activity/output (live emitted bytes) --
r2-out" "row 8: the newer R2 run of the family takes over"
w_shrink() {
  local d="$XW/home/data/s"
  xseed
  xgate s 1 5 spec 1 codex '' '' '0123456789\n' ''
  printf 'ab\n' >"$d/short"; printf 'abcdefghijklmnop\n' >"$d/long"
  xhook 1 "cp '$d/short' '$d/o1'"
  xhook 2 "cp '$d/long' '$d/o1'"
}
XKILL=4 xkilled w_shrink --tail --interval 1
assert_contains "$(xout)" "0123456789
lmnop" "row 8: a shrunk stream prints nothing, then resumes from its old offset"
# Colors on a tty: a --once frame and the tail board through run_on_tty
# (stdout and stderr share the pty).
XTTY=1 xok w_one --once
assert_contains "$(xout)" $'\033[1mac-gate\033[0m \033[36mhome\033[0m  \033[2m1 active\033[0m' "row 8: the header's colors on a tty"
XTTY=1 XKILL=2 xkilled w_tail --tail --interval 1
assert_contains "$(xout)" $'\033[32mnew-out' "row 8: out is green on a tty"
# A stream that cannot be read prints nothing, on stdout or stderr.
if [ "$(id -u)" != 0 ]; then
  w_lockedout() { w_tail; chmod 000 "$XW/home/data/new/o2"; }
  XKILL=2 xkilled w_lockedout --tail --interval 1
  assert_eq "$(xout):$(xerr)" "ac-gate home - following the active second-chief run (Ctrl-C to quit)

== new / plan / r2  [claude/opus] ==
-- prompt --
PROMPT NEW

-- activity/output (live emitted bytes) --:" "row 8: an unreadable stream prints nothing"
fi
# SIGINT to the --tail board alone ends it 130 at once.
w_tailint() { w_empty; xhook 2 'kill -INT "$PPID"; i=0; while kill -0 "$PPID" 2>/dev/null && [ "$i" -lt 40 ]; do /bin/sleep 0.05; i=$((i + 1)); done'; }
XWRAP="$XS/int-default" XKILL=4 xrun w_tailint --tail --interval 1
assert_eq "$XRC:$(tr '\n' ' ' <"$TMP/xn.sleep")" "130:1 1 " "row 8: SIGINT alone ends the --tail board 130 at its second tick"

# 9. the dashboard loop: the prelude, one paint, the idle close through the
#    raw herdr stub (the default session, AC_HERDR_SESSION, a padded
#    config/herdr-session), no --self-pane; a paint only when the frame
#    changes; the interval's arithmetic (010 is 8); an AC_GATE_WATCH_IDLE that
#    is no integer (never closes); TERM, HUP and INT restoring the cursor.
XE=AC_GATE_WATCH_IDLE=1 xok w_empty --interval 1 --self-pane pX
assert_eq "$XRC:$(xout)" "0:"$'\033[2J\033[H\033[?25l\033[Hac-gate home  0 active\033[K\n\033[K\n(no gate running)\033[K\033[J\n\nno active gate - closing watch\n\033[?25h' "row 9: the idle close, byte for byte"
assert_eq "$(cat "$TMP/xn.sleep"):$(cat "$TMP/xn.herdr")" "1
2:--session default pane close pX" "row 9: one tick, the close's sleep 2, the raw herdr close"
XE="AC_GATE_WATCH_IDLE=1 AC_HERDR_SESSION=s1" xok w_empty --interval 1 --self-pane pX
assert_eq "$(cat "$TMP/xn.herdr")" "--session s1 pane close pX" "row 9: AC_HERDR_SESSION names the session"
w_cfgses() { xseed; printf ' s2 \n' >"$XW/home/config/herdr-session"; }
XE=AC_GATE_WATCH_IDLE=1 xok w_cfgses --interval 1 --self-pane pX
assert_eq "$(cat "$TMP/xn.herdr")" "--session s2 pane close pX" "row 9: config/herdr-session, trimmed"
XE=AC_GATE_WATCH_IDLE=1 xok w_empty --interval 1
assert_eq "$XRC:$(cat "$TMP/xn.herdr")" "0:" "row 9: no --self-pane, no herdr call"
XE=AC_GATE_WATCH_IDLE=3 xok w_empty
assert_eq "$XRC:$(tr '\n' ' ' <"$TMP/xn.sleep")" "0:2 2 " "row 9: the default interval 2, past 3 at the second tick, then the close's sleep 2"
w_live() { local d="$XW/home/data/fam1"; w_one; printf 'second\n' >"$d/more"; xhook 2 "cat '$d/more' >>'$d/o1'"; }
XKILL=4 xkilled w_live --interval 1
assert_eq "$XRC" "143" "row 9: a live gate keeps the board open"
assert_eq "$(xcount $'\033[H' "$TMP/xn.out")" "3" "row 9: the prelude, then a paint only when the frame changed"
assert_contains "$(xout)" $'09:06:00 second\033[K' "row 9: the repaint shows the new activity"
assert_eq "$XRC:$(tail -c 6 "$TMP/xn.out" | od -An -c | tr -d ' \n')" "143:033[?25h" "row 9: TERM restores the cursor"
XE=AC_GATE_WATCH_IDLE=7 xok w_empty --interval 010
assert_eq "$XRC:$(cat "$TMP/xn.sleep")" "0:2" "row 9: 010 is 8 to the shell's arithmetic, past 7 at once"
XE=AC_GATE_WATCH_IDLE=100 XKILL=2 XSIG=HUP xrun w_empty --interval 1
assert_eq "$XRC:$(tail -c 6 "$TMP/xn.out" | od -An -c | tr -d ' \n')" "129:033[?25h" "row 9: HUP restores the cursor"
XE=AC_GATE_WATCH_IDLE=abc XKILL=3 xkilled w_empty --interval 1
assert_eq "$(tr '\n' ' ' <"$TMP/xn.sleep"):$(cat "$TMP/xn.herdr"):$(xerr)" "1 1 1 ::" "row 9: an AC_GATE_WATCH_IDLE that is no integer never closes, silently"
XWRAP="$XS/int-default" XE=AC_GATE_WATCH_IDLE=100 XKILL=4 xrun w_tailint --interval 1
assert_eq "$XRC:$(tr '\n' ' ' <"$TMP/xn.sleep"):$(tail -c 6 "$TMP/xn.out" | od -An -c | tr -d ' \n')" "130:1 1 :033[?25h" "row 9: SIGINT alone restores the cursor and ends the dashboard 130"
XTTY=1 XE=AC_GATE_WATCH_IDLE=1 xok w_empty --interval 1 --self-pane pT
assert_contains "$(xout)" $'\033[2J\033[H\033[?25l\033[H\033[1mac-gate\033[0m' "row 9: the dashboard's colors on a tty"
# A closed stdout (>&-): the writes land in the /dev/null bun opens over the
# closed fd (bin/ac-bun.sh leaves this module's closed channels to bun),
# silently.
printf '#!/bin/sh\nexec "$@" >&-\n' >"$XS/stdout-closed"; chmod +x "$XS/stdout-closed"
XWRAP="$XS/stdout-closed" xok w_one --once
assert_eq "$(xerr)" "" "closed stdout: nothing on stderr"

pass
