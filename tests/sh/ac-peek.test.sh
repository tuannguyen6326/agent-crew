#!/usr/bin/env bash
# ac-peek.test.sh - peek output must NEUTRALIZE a reprinted captain marker
# (contract: src/peek.ts's "prefixed, never merely indented" comment - an
# indent alone still matches AC_CAPTAIN_RE at line start, the same F13
# class tests/sh/ac-crew-state.test.sh pins for ac-crew-state.sh).

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_orca
make_home

mk_crewmate() {
  # mk_crewmate <id> <handle> <tab> - a live crewmate: meta + handle + fake terminal.
  printf 'backend=orca\n' >"$AC_HOME/state/$1.meta"
  printf '%s %s\n' "$2" "$3" >"$AC_HOME/state/.pane-$1"
  : >"$FAKE_ORCA/terminals/$2.buf"
}

mk_crewmate c1 termC1 tabC1
printf 'needs-decision: which prefix should I use?\n' >"$FAKE_ORCA/terminals/termC1.buf"

out="$("$BIN/ac-peek.sh" c1)"
assert_contains "$out" "needs-decision: which prefix" "the marker text itself must survive the peek prefix"
. "$BIN/ac-lib.sh"
if grep -qE "$AC_CAPTAIN_RE" <<<"$out"; then
  fail "ac-peek.sh must not re-emit a line matching the LIVE AC_CAPTAIN_RE: $out"
fi

# --- the peek's bytes, row by row -----------------------------------------------
# One side root ($H): a home at $H/home and the fake orca's state at $H/orca;
# cwd $H, stdin /dev/null unless a row feeds a file, LC_ALL=C. EPOCHSECONDS is
# pinned with a watcher beat at that instant, AC_GUARD_ROOT is a non-repo dir
# and the guard's stamp is removed before each run, so the guard rides quiet
# unless a row stales the beat. PATH puts make_fake_orca's orca first (or
# orca absent where a row says) - no row reaches a real orca. $H reads @H in
# what a run printed.
H="$TMP/pside-n"
PEPOCH=1767225600
mkdir -p "$TMP/pguard-root"
pseed() {
  rm -rf "$H"; mkdir -p "$H/home/state" "$H/home/config" "$H/orca/terminals"
  printf 'off\n' >"$H/home/config/wedge-alarm"
  printf '%s\n' "$PEPOCH" >"$H/home/state/.last-watcher-beat"
}
pmate() {  # pmate <id> <handle> - a live orca crewmate: its meta, handle, tab and an empty transcript
  printf 'backend=orca\n' >"$H/home/state/$1.meta"
  printf '%s tab%s\n' "$2" "$2" >"$H/home/state/.pane-$1"
  : >"$H/orca/terminals/$2.buf"
}
PENV=(); PHOMELESS=0; PPATH=""; PSTDIN=/dev/null; PN_BIN="$BIN"; PN_RC=0
peek() {  # peek <args...> - the shim from $H; sets PN_RC
  local x
  local e=("LC_ALL=C" "PATH=${PPATH:-$TMP/stubbin:$PATH}" "FAKE_ORCA=$H/orca" "STUB_DIR=$H"
    "EPOCHSECONDS=$PEPOCH" "AC_GUARD_ROOT=$TMP/pguard-root")
  [ "$PHOMELESS" = 1 ] || e+=("AC_HOME=$H/home")
  for x in ${PENV[@]+"${PENV[@]}"}; do e+=("$x"); done
  rm -f "$H"/home/state/.guard-stamp*
  PN_RC=0
  (cd "$H" && env -u AC_HOME -u AC_BACKEND -u AC_FLEET_STATE -u AC_GUARD_QUIET \
    -u AC_GUARD_GRACE -u LANG -u LC_CTYPE "${e[@]}" "$PN_BIN/ac-peek.sh" "$@") <"$PSTDIN" >"$TMP/n.raw" 2>"$TMP/n.err" || PN_RC=$?
  LC_ALL=C sed -e "s#$H#@H#g" "$TMP/n.raw" >"$TMP/n.out"
  LC_ALL=C sed -e "s#$H#@H#g" "$TMP/n.err" >"$TMP/n.err2"
}
pout() { cat "$TMP/n.out"; }
perr() { cat "$TMP/n.err2"; }
prefuse() {  # prefuse <stderr> <label> - exit 1, no stdout, exactly <stderr>
  assert_eq "$PN_RC:$(pout):$(perr)" "1::$1" "$2"
}
PUSAGE='ERROR: usage: ac-peek.sh <id> [<lines>]'
PNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
PBAD="ERROR: unsupported backend 'tmux' (valid backend: orca)"
PUNREAD="the BACKEND could not be read for c1 - the pane's liveness is UNKNOWN and no work is lost; check the backend itself, then peek again"
p0() { pseed; pmate c1 termC1; printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\n' >"$H/orca/terminals/termC1.buf"; }
p0

# 1. usage and the meta gate: none and '' are the usage line, homeless too
#    (usage precedes any home read); homeless with an id is refused naming
#    AC_HOME; a missing meta; the arguments past <lines> are never read.
peek; prefuse "$PUSAGE" "1: no id is the usage line"
peek ''; prefuse "$PUSAGE" "1: an empty id is the usage line"
PHOMELESS=1
peek; prefuse "$PUSAGE" "1: homeless with no id is the usage line"
peek c1; assert_eq "$PN_RC:$(pout)" "1:" "1: homeless with an id refuses"
assert_contains "$(perr)" "$PNOHOME" "1: ...naming AC_HOME"
PHOMELESS=0
peek nope; prefuse "ERROR: no crewmate meta for nope" "1: a missing meta"
(cd "$H/home" && find . | grep -v guard-stamp | LC_ALL=C sort) >"$TMP/home.before"
peek c1 2 extra; assert_eq "$PN_RC:$(pout):$(perr)" "0:peek| l6
peek| l7:" "1: the arguments past <lines> are never read"
assert_eq "$(cd "$H/home" && find . | grep -v guard-stamp | LC_ALL=C sort)" "$(cat "$TMP/home.before")" "1: a peek leaves the home as it was, the guard's stamp aside"

# 2. meta shapes: a directory named d1.meta and a dangling link are no meta;
#    backend=tmux is the route's refusal, a UTF-8 name too; an orca meta and a
#    kind-less meta with no handle, and kind=self, are a gone window.
mkdir "$H/home/state/d1.meta"
peek d1; assert_eq "$PN_RC:$(pout)" "1:" "2: a directory meta refuses"
assert_contains "$(perr)" "ERROR: no crewmate meta for d1" "2: ...as no meta"
rmdir "$H/home/state/d1.meta"
ln -s nowhere "$H/home/state/d2.meta"
peek d2; prefuse "ERROR: no crewmate meta for d2" "2: a dangling link is no meta"
rm -f "$H/home/state/d2.meta"
printf 'backend=tmux\n' >"$H/home/state/t1.meta"; printf 'pT tT\n' >"$H/home/state/.pane-t1"
printf 'backend=orca\n' >"$H/home/state/o0.meta"
: >"$H/home/state/k0.meta"
printf 'backend=orca\nkind=self\n' >"$H/home/state/s1.meta"
peek t1; prefuse "$PBAD" "2: backend=tmux is the route's refusal"
printf 'backend=tm\303\274x\n' >"$H/home/state/t1.meta"
peek t1; prefuse "ERROR: unsupported backend 'tm$(printf '\303\274')x' (valid backend: orca)" "2: a meta's UTF-8 backend name is refused as its bytes"
for pv in o0 k0 s1; do
  peek "$pv"; prefuse "ERROR: window gone for $pv" "2: '$pv' is a gone window"
done
rm -f "$H/home/state/t1.meta" "$H/home/state/.pane-t1" "$H/home/state/o0.meta" "$H/home/state/k0.meta" "$H/home/state/s1.meta"

# 3. the fleet backend name: AC_BACKEND=tmux and config/backend tmux are
#    refused, ahead of any meta read.
# GAP, not ported: a sibling case here used to prove a task meta's own
# backend= overrides an AC_BACKEND the fleet-level check already accepted
# (AC_BACKEND=orca, meta backend=herdr) - with one backend left, both name
# the same driver, so a successful peek can no longer tell "accepted the
# ambient value" from "the meta overrode it" apart.
PENV=(AC_BACKEND=tmux)
peek c1; prefuse "$PBAD" "3: AC_BACKEND=tmux is refused"
PENV=()
printf 'tmux\n' >"$H/home/config/backend"
peek c1; prefuse "$PBAD" "3: config/backend tmux is refused"
rm -f "$H/home/config/backend"

# 4. liveness: an unreachable orca and orca absent from PATH are the BACKEND
#    line; an exited terminal is gone.
# GAP, not ported: a wedged-at-a-ceiling sub-case used to prove a hung herdr
# costs no more than AC_HERDR_RPC_TIMEOUT, its children reaped. The orca
# driver carries no per-call RPC ceiling of its own (ac-backend.sh HUNG RPC);
# there is no ceiling here to bound or prove.
touch "$H/orca/.unreachable"
peek c1; prefuse "ERROR: $PUNREAD" "4: an unreachable orca"
rm -f "$H/orca/.unreachable"
touch "$H/orca/terminals/termC1.exited"
peek c1; prefuse "ERROR: window gone for c1" "4: an exited terminal is gone"
rm -f "$H/orca/terminals/termC1.exited"
mkdir -p "$TMP/pnoorca"
PPATH="$TMP/pnoorca:$(dirname "$(command -v bun)"):/usr/bin:/bin:/usr/sbin:/sbin"
if [ -z "$(PATH="$PPATH" command -v orca || true)" ]; then
  peek c1; prefuse "ERROR: $PUNREAD" "4: orca absent from PATH"
else
  printf 'SKIP: row 4 orca-absent - bun shares its directory with a real orca on this host\n'
fi
PPATH=""

# 5. <lines>: the default (absent or ''), 2, 0, -2 (BSD tail's last 2), a
#    non-number (exit 1, nothing printed), and a request fetches exactly what
#    it asked (orca clamps nothing, unlike the retired herdr fetch floor).
peek c1; assert_eq "$PN_RC:$(pout | wc -l | tr -d ' ')" "0:7" "5: the default prints every line"
peek c1 ''; assert_eq "$PN_RC:$(pout | wc -l | tr -d ' ')" "0:7" "5: '' is the default"
peek c1 2; assert_eq "$PN_RC:$(pout)" "0:peek| l6
peek| l7" "5: 2"
peek c1 0; assert_eq "$PN_RC:$(pout)" "0:" "5: 0 prints nothing, exit 0"
peek c1 -2; assert_eq "$PN_RC:$(pout)" "0:peek| l6
peek| l7" "5: -2"
peek c1 abc; assert_eq "$PN_RC:$(pout)" "1:" "5: a non-number on orca"
rm -f "$H/orca/log"
peek c1 250; assert_contains "$(cat "$H/orca/log")" "orca terminal read --terminal termC1 --limit 250 --screen --json" "5: 250 fetches 250"
rm -f "$H/orca/log"
peek c1 5; assert_contains "$(cat "$H/orca/log")" "orca terminal read --terminal termC1 --limit 5 --screen --json" "5: 5 fetches 5"

# 6. the capture's bytes: the default is the last 40 lines; CR, a CR-only and
#    a whitespace-only line, TAB and a last line with no LF kept (the shared
#    `sed '/^$/d'` filter drops only TRULY empty lines, not these); NUL
#    dropped; an empty pane; a read that fails is exit 1 with nothing printed.
for i in $(seq 1 150); do printf 'L%s\n' "$i"; done >"$H/orca/terminals/termC1.buf"
peek c1; assert_eq "$(pout | wc -l | tr -d ' '):$(pout | head -n 1):$(pout | tail -n 1)" "40:peek| L111:peek| L150" "6: the default is the last 40 lines"
printf 'a\r\n\r\n   \n\tb\nlast-no-lf' >"$H/orca/terminals/termC1.buf"
peek c1; assert_eq "$(pout)" $'peek| a\r\npeek| \r\npeek|    \npeek| \tb\npeek| last-no-lf' "6: bytes kept"
printf 'x\000y\n' >"$H/orca/terminals/termC1.buf"
peek c1; assert_eq "$(pout)" "peek| xy" "6: NUL dropped"
: >"$H/orca/terminals/termC1.buf"
peek c1; assert_eq "$PN_RC:$(pout)" "0:" "6: an empty pane prints nothing"
touch "$H/orca/terminals/termC1.read-fails"
peek c1; assert_eq "$PN_RC:$(pout)" "1:" "6: a failing read is exit 1, nothing printed"
rm -f "$H/orca/terminals/termC1.read-fails"
seq 1 20000 >"$H/orca/terminals/termC1.buf"
pclosed="$(cd "$H" && env -u AC_BACKEND LC_ALL=C PATH="$TMP/stubbin:$PATH" FAKE_ORCA="$H/orca" EPOCHSECONDS="$PEPOCH" \
  AC_GUARD_ROOT="$TMP/pguard-root" AC_HOME="$H/home" bash -c '"$0/ac-peek.sh" c1 20000 | head -n 1 >/dev/null; printf "%s" "${PIPESTATUS[0]}"' "$BIN" </dev/null)"
assert_eq "$pclosed" "141" "6: a reader that leaves early ends the run with SIGPIPE's 141"

# GAP, not ported: herdr's `pane read` served the pane's raw bytes directly
# (fake herdr's own `pane read` was a bare `cat`), so an invalid-UTF-8 byte
# passed through untouched - provable with that stub. orca's `terminal read`
# answers JSON, which cannot carry a raw invalid byte without the real CLI's
# own choice of escape (unverified here, no real binary to check against);
# this fake's own JSON step (jq) replaces it with U+FFFD, which may or may
# not match the real CLI - asserting either way without that CLI to check
# against would be a claim this suite cannot back.

# 8. orca: a live terminal is read at --limit <lines> --screen, its blank
#    lines dropped; an exited one is gone; an unreachable runtime is the
#    BACKEND line; a non-number is exit 1, nothing printed.
p8() {
  printf 'backend=orca\n' >"$H/home/state/o1.meta"; printf 'term9 tab9\n' >"$H/home/state/.pane-o1"
  printf 'o1\no2\n\no3\no4\n' >"$H/orca/terminals/term9.buf"
}
p8
peek o1 5; assert_eq "$PN_RC:$(pout)" "0:peek| o1
peek| o2
peek| o3
peek| o4" "8: orca alive"
assert_contains "$(cat "$H/orca/log")" "orca terminal read --terminal term9 --limit 5 --screen --json" "8: the orca read's argv"
peek o1 abc; assert_eq "$PN_RC:$(pout)" "1:" "8: a non-number on orca"
touch "$H/orca/terminals/term9.exited"
peek o1; prefuse "ERROR: window gone for o1" "8: an exited terminal is gone"
rm -f "$H/orca/terminals/term9.exited"
touch "$H/orca/.unreachable"
peek o1; prefuse "ERROR: the BACKEND could not be read for o1 - the pane's liveness is UNKNOWN and no work is lost; check the backend itself, then peek again" "8: an unreachable orca"
rm -f "$H/orca/.unreachable"

# 9. stdin by position: orca reads the caller's at both calls - the first
#    drains it unless it leaves it alone (a stdin-skip-<verb> sentinel).
mkdir -p "$TMP/pstdin"
pc=orca
cat >"$TMP/pstdin/$pc" <<STUB
#!/bin/sh
if [ -e "\$STUB_DIR/stdin-skip-\$2" ]; then i=-; else i="\$(cat)"; fi
printf '$pc %s %s stdin=[%s]\n' "\$1" "\$2" "\$i" >>"\$STUB_DIR/stdin.log"
exec "$TMP/stubbin/$pc" "\$@" </dev/null
STUB
chmod +x "$TMP/pstdin/$pc"
printf 'caller bytes\n' >"$TMP/pstdin.in"
PSTDIN="$TMP/pstdin.in"; PPATH="$TMP/pstdin:$TMP/stubbin:$PATH"
p8
peek o1 1; assert_eq "$(cat "$H/stdin.log")" "orca terminal show stdin=[caller bytes]
orca terminal read stdin=[]" "9: orca's first call drains the caller's stdin"
rm -f "$H/stdin.log"
touch "$H/stdin-skip-show"
peek o1 1; assert_eq "$(cat "$H/stdin.log")" "orca terminal show stdin=[-]
orca terminal read stdin=[caller bytes]" "9: orca's capture reads the caller's stdin"
PSTDIN=/dev/null; PPATH=""
rm -f "$H/stdin.log" "$H/stdin-skip-show"

# 10. the guard: a stale beat with crew in flight prints WATCHER-DOWN ahead of
#     the usage line; a guard that is not executable stays silent.
rm -f "$H/home/state/.last-watcher-beat"
peek; prefuse "WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh
$PUSAGE" "10: the guard's block precedes the usage line"
mkdir -p "$TMP/pshimlab"
cp -R "$BIN" "$TMP/pshimlab/bin"; ln -s "$ROOT/src" "$TMP/pshimlab/src"
chmod -x "$TMP/pshimlab/bin/ac-guard.sh"
PN_BIN="$TMP/pshimlab/bin"
peek; prefuse "$PUSAGE" "10: a non-executable guard is silent"
PN_BIN="$BIN"

# 11. bun absent from PATH: the shim refuses; an id with a byte that is not
#     UTF-8 names no meta; an AC_HOME that cannot be entered names the variable.
p0
PPATH="$TMP/stubbin:/usr/bin:/bin:/usr/sbin:/sbin"
if [ -z "$(PATH="$PPATH" command -v bun || true)" ]; then
  peek c1 1; prefuse "ERROR: required tool not found: bun" "11: bun absent - the shim refuses"
else
  printf 'SKIP: row 11 bun-absent - bun sits in /usr/bin or /bin on this host\n'
fi
PPATH=""
peek "$(printf '\351')"
assert_eq "$PN_RC:$(pout)" "1:" "11: a non-UTF-8 id refuses"
assert_contains "$(perr)" "ERROR: no crewmate meta for " "11: ...as a missing meta"
PENV=("AC_HOME=$H/missing")
peek c1
assert_eq "$PN_RC:$(pout)" "1:" "11: an unenterable AC_HOME refuses"
assert_contains "$(perr)" "ERROR: AC_HOME is not a readable directory: @H/missing" "11: ...naming the variable"
PENV=()

pass
