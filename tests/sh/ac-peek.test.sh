#!/usr/bin/env bash
# ac-peek.test.sh - peek output must NEUTRALIZE a reprinted captain marker
# (contract: src/peek.ts's "prefixed, never merely indented" comment - an
# indent alone still matches AC_CAPTAIN_RE at line start, the same F13
# class tests/sh/ac-crew-state.test.sh pins for ac-crew-state.sh).

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_home

mk_crewmate() {
  # mk_crewmate <id> <pane> <tab> - a live crewmate: meta + handle + fake pane.
  printf 'backend=herdr\n' >"$AC_HOME/state/$1.meta"
  printf '%s %s\n' "$2" "$3" >"$AC_HOME/state/.pane-$1"
  printf '%s\n' "$2" >"$FAKE_HERDR/tabs/$3"
  : >"$FAKE_HERDR/panes/$2.buf"
}

mk_crewmate c1 pC1 tC1
printf 'needs-decision: which prefix should I use?\n' >"$FAKE_HERDR/panes/pC1.buf"

out="$("$BIN/ac-peek.sh" c1)"
assert_contains "$out" "needs-decision: which prefix" "the marker text itself must survive the peek prefix"
. "$BIN/ac-lib.sh"
if grep -qE "$AC_CAPTAIN_RE" <<<"$out"; then
  fail "ac-peek.sh must not re-emit a line matching the LIVE AC_CAPTAIN_RE: $out"
fi

# --- differential: src/peek.ts against the frozen bash original --------------
# DISPUTED: the implementation (tests/fixtures/ac-peek.sh under bash vs src/peek.ts through bin/ac-peek.sh)
# HELD-CONSTANT: two side roots seeded alike ($POH for the oracle, $PNH for the shim) - a home at <side>/home, the fake herdr's state at <side>/herdr and the fake orca's at <side>/orca; argv and env (the side root spelled @H, substituted in values only); cwd (the side root); stdin (/dev/null unless a row feeds a file); LC_ALL=C unless a row names a locale; EPOCHSECONDS pinned and a watcher beat at that instant in each home, AC_GUARD_ROOT at a non-repo dir, and the guard's stamp removed before each side, so the guard rides quiet unless a row stales the beat; PATH = make_fake_herdr's herdr and make_fake_orca's orca first (or herdr absent where a row says) - no row reaches a real herdr or orca; the live bin/ beside each entry (the oracle bin's copies, $BIN's own); exit status, stdout and stderr compared whole (the side root spelled @H, either bin root ROOT), then the world a row may touch: every path under the home, the guard stamp and both stub logs.
make_fake_orca
pobin="$(make_oracle_bin ac-peek)"
POH="$TMP/pside-o"; PNH="$TMP/pside-n"
PEPOCH=1767225600
mkdir -p "$TMP/pguard-root"
pboth() {  # pboth <cmd> <args...> - a seeding step at each side root: H names it, and so does a literal @H in an argument
  local h x a; for h in "$POH" "$PNH"; do H="$h"; a=(); for x in "$@"; do a+=("${x//@H/$h}"); done; "${a[@]}"; done
}
pseed() {
  rm -rf "$H"; mkdir -p "$H/home/state" "$H/home/config" "$H/herdr/panes" "$H/herdr/tabs" "$H/orca/terminals"
  printf 'off\n' >"$H/home/config/wedge-alarm"
  printf '%s\n' "$PEPOCH" >"$H/home/state/.last-watcher-beat"
}
pmate() {  # pmate <id> <pane> - a live herdr crewmate: its meta, handle, tab and an empty transcript
  printf 'backend=herdr\n' >"$H/home/state/$1.meta"
  printf '%s t%s\n' "$2" "$2" >"$H/home/state/.pane-$1"
  printf '%s\n' "$2" >"$H/herdr/tabs/t$2"; : >"$H/herdr/panes/$2.buf"
}
pput() { mkdir -p "$(dirname "$H/$1")"; printf '%s' "$2" >"$H/$1"; }   # pput <path under the side> <bytes>
PLC=C; PENV=(); PHOMELESS=0; PPATH=""; PSTDIN=/dev/null
prun_side() {  # prun_side <bin> <side root> <prefix> <args...>
  local bin="$1" h="$2" p="$3" x v; shift 3
  local a=() e=("LC_ALL=$PLC" "PATH=${PPATH:-$TMP/stubbin:$PATH}" "FAKE_HERDR=$h/herdr" "FAKE_ORCA=$h/orca" "STUB_DIR=$h"
    "EPOCHSECONDS=$PEPOCH" "AC_GUARD_ROOT=$TMP/pguard-root")
  [ "$PHOMELESS" = 1 ] || e+=("AC_HOME=$h/home")
  for x in ${PENV[@]+"${PENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$h}"); done
  for x in "$@"; do a+=("${x//@H/$h}"); done
  rm -f "$h"/home/state/.guard-stamp*
  (cd "$h" && env -u AC_HOME -u AC_BACKEND -u AC_FLEET_STATE -u AC_HERDR_SESSION -u AC_HERDR_RPC_TIMEOUT -u AC_GUARD_QUIET \
    -u AC_GUARD_GRACE -u LANG -u LC_CTYPE "${e[@]}" "$bin/ac-peek.sh" ${a[@]+"${a[@]}"}) <"$PSTDIN" >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
pnorm() { LC_ALL=C sed -E -e "s#$2#@H#g" -e "s#$TMP/oracle-ac-peek#ROOT#g" -e "s#$TMP/(poraclelab|pshimlab|ploadfail)#ROOT#g" -e "s#$ROOT#ROOT#g" "$1"; }
PO_RC=0; PN_RC=0; PO_BIN="$pobin"; PN_BIN="$BIN"
ppair() {  # ppair <args...> - both sides run, outputs normalised, nothing compared yet
  PO_RC=0; PN_RC=0
  prun_side "$PO_BIN" "$POH" o "$@" || PO_RC=$?
  prun_side "$PN_BIN" "$PNH" n "$@" || PN_RC=$?
  pnorm "$TMP/o.raw" "$POH" >"$TMP/o.out"; pnorm "$TMP/o.err" "$POH" >"$TMP/o.err2"
  pnorm "$TMP/n.raw" "$PNH" >"$TMP/n.out"; pnorm "$TMP/n.err" "$PNH" >"$TMP/n.err2"
}
prow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
psame_rc_out() {
  assert_eq "$PN_RC" "$PO_RC" "peek differential exit for '$*' at line $(prow)"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "peek differential stdout differs for '$*' at line $(prow): $(diff "$TMP/o.out" "$TMP/n.out" | head -n 8)"
}
psame_io() {
  psame_rc_out "$@"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "peek differential stderr differs for '$*' at line $(prow): $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 8)"
}
pworld() {  # pworld <side root> - what a row may change
  local h="$1" f
  (cd "$h/home" && find . 2>/dev/null | LC_ALL=C sort)
  for f in "$h"/home/state/.guard-stamp* "$h"/herdr/log "$h"/orca/log "$h"/stdin.log; do
    [ -f "$f" ] || continue
    printf '== %s\n' "$f"; cat "$f"; printf '\n'
  done
}
psame_world() {
  pworld "$POH" >"$TMP/o.world"; pworld "$PNH" >"$TMP/n.world"
  pnorm "$TMP/o.world" "$POH" >"$TMP/o.world2"; pnorm "$TMP/n.world" "$PNH" >"$TMP/n.world2"
  cmp -s "$TMP/o.world2" "$TMP/n.world2" || fail "peek differential world differs after '$*' at line $(prow): $(diff "$TMP/o.world2" "$TMP/n.world2" | head -n 10)"
}
psame() { ppair "$@"; psame_io "$@"; psame_world "$@"; }
pout() { cat "$TMP/n.out"; }
perr() { cat "$TMP/n.err2"; }
poerr() { cat "$TMP/o.err2"; }
PUSAGE='ERROR: usage: ac-peek.sh <id> [<lines>]'
PNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
PBAD="ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)"
PUNREAD="the BACKEND could not be read for c1 - the pane's liveness is UNKNOWN and no work is lost; check the backend itself (herdr status server), then peek again"
p0() { pseed; pmate c1 pC1; printf 'l1\nl2\nl3\nl4\nl5\nl6\nl7\n' >"$H/herdr/panes/pC1.buf"; }
pboth p0

# 1. usage and the meta gate: none and '' are the usage line, homeless too
#    (usage precedes any home read); homeless with an id prints the refusal
#    and the gate's own line (W7); -h is an id (W8); a missing meta; the
#    arguments past <lines> are never read (W10).
for pv in "" "''"; do
  # shellcheck disable=SC2086
  eval psame $pv
  assert_eq "$PN_RC:$(pout):$(perr)" "1::$PUSAGE" "1: '$pv' is the usage line, exit 1"
done
PHOMELESS=1
psame; assert_eq "$PN_RC:$(perr)" "1:$PUSAGE" "1: homeless with no id is the usage line"
psame c1; assert_eq "$PN_RC:$(perr)" "1:$PNOHOME
ERROR: no crewmate meta for c1" "1 (W7): homeless with an id prints the refusal, then the gate's line"
PHOMELESS=0
psame -h; assert_eq "$PN_RC:$(perr)" "1:ERROR: no crewmate meta for -h" "1 (W8): -h is an id"
psame nope; assert_eq "$PN_RC:$(perr)" "1:ERROR: no crewmate meta for nope" "1: a missing meta"
psame c1 2 extra; assert_eq "$PN_RC:$(pout)" "0:peek| l6
peek| l7" "1 (W10): the arguments past <lines> are never read"

# 2. meta shapes: a directory named d1.meta (W11) and a dangling link are no
#    meta; an unreadable meta WARNs and peeks as herdr, exit 0 (W1);
#    backend=tmux is the route's refusal, a UTF-8 name too; an orca meta and a
#    kind-less meta with no handle, and kind=self, are a gone window; the id
#    is a raw path component (W9).
pboth mkdir @H/home/state/d1.meta
psame d1; assert_eq "$PN_RC" 1 "2 (W11): a directory meta"
assert_contains "$(perr)" "ERROR: no crewmate meta for d1" "2 (W11): ... is no meta"
pboth rmdir @H/home/state/d1.meta
pboth ln -s nowhere @H/home/state/d2.meta
psame d2; assert_eq "$PN_RC:$(perr)" "1:ERROR: no crewmate meta for d2" "2: a dangling link is no meta"
pboth rm -f @H/home/state/d2.meta
pboth chmod 000 @H/home/state/c1.meta
psame c1 3; assert_eq "$PN_RC:$(pout)" "0:peek| l5
peek| l6
peek| l7" "2 (W1): an unreadable meta peeks as herdr"
assert_contains "$(perr)" "WARN: cannot read meta file @H/home/state/c1.meta" "2 (W1): ... after the WARN"
pboth chmod 644 @H/home/state/c1.meta
p2() {
  printf 'backend=tmux\n' >"$H/home/state/t1.meta"; printf 'pT tT\n' >"$H/home/state/.pane-t1"
  printf 'backend=orca\n' >"$H/home/state/o0.meta"
  : >"$H/home/state/k0.meta"
  printf 'backend=herdr\nkind=self\n' >"$H/home/state/s1.meta"
  pput home/x/y.meta $'backend=herdr\n'
}
pboth p2
psame t1; assert_eq "$PN_RC:$(perr)" "1:$PBAD" "2: backend=tmux is the route's refusal"
pboth pput home/state/t1.meta $'backend=tm\303\274x\n'
psame t1; assert_eq "$PN_RC:$(perr)" "1:ERROR: unsupported backend 'tm$(printf '\303\274')x' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "2: a meta's UTF-8 backend name is refused as its bytes"
for pv in o0 k0 s1 ../x/y; do
  psame "$pv"; assert_eq "$PN_RC:$(perr)" "1:ERROR: window gone for $pv" "2: '$pv' is a gone window"
done
pboth rm -f @H/home/state/t1.meta @H/home/state/.pane-t1 @H/home/state/o0.meta @H/home/state/k0.meta @H/home/state/s1.meta

# 3. the backend name is checked BEFORE usage (W14): AC_BACKEND=tmux with no
#    arguments and with an id, config/backend tmux; AC_BACKEND=orca is
#    overwritten by a herdr meta.
PENV=(AC_BACKEND=tmux)
psame; assert_eq "$PN_RC:$(perr)" "1:$PBAD" "3 (W14): AC_BACKEND=tmux refuses before usage"
psame c1; assert_eq "$PN_RC:$(perr)" "1:$PBAD" "3 (W14): ... and before the meta gate"
PENV=()
pboth pput home/config/backend $'tmux\n'
psame c1; assert_eq "$PN_RC:$(perr)" "1:$PBAD" "3 (W14): config/backend tmux"
pboth rm -f @H/home/config/backend
PENV=(AC_BACKEND=orca)
psame c1 1; assert_eq "$PN_RC:$(pout)" "0:peek| l7" "3: a herdr meta wins over AC_BACKEND=orca"
PENV=()

# 4. liveness: an unreachable herdr and herdr absent from PATH are the
#    BACKEND line; a stopped server is gone; a wedged one at a 1 s ceiling is
#    the BACKEND line, its children reaped.
pboth touch @H/herdr/.unreachable
psame c1; assert_eq "$PN_RC:$(perr)" "1:ERROR: $PUNREAD" "4: an unreachable herdr"
pboth rm -f @H/herdr/.unreachable
pboth touch @H/herdr/.server-stopped
psame c1; assert_eq "$PN_RC:$(perr)" "1:ERROR: window gone for c1" "4: a stopped server is gone"
pboth rm -f @H/herdr/.server-stopped
mkdir -p "$TMP/pnoherdr"; ln -s "$TMP/stubbin/orca" "$TMP/pnoherdr/orca"
PPATH="$TMP/pnoherdr:$(dirname "$(command -v bun)"):/usr/bin:/bin:/usr/sbin:/sbin"
if [ -z "$(PATH="$PPATH" command -v herdr || true)" ]; then
  psame c1; assert_eq "$PN_RC:$(perr)" "1:ERROR: $PUNREAD" "4: herdr absent from PATH"
else
  printf 'SKIP: row 4 herdr-absent - bun shares its directory with a herdr on this host\n'
fi
PPATH=""
pboth touch @H/herdr/.hang
PENV=(AC_HERDR_RPC_TIMEOUT=1)
psame c1; assert_eq "$PN_RC:$(perr)" "1:ERROR: $PUNREAD" "4: a wedged herdr at the ceiling"
PENV=()
pboth rm -f @H/herdr/.hang
for ph in "$POH" "$PNH"; do
  while read -r pp; do
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pp" 2>/dev/null || break; sleep 0.2; done
    ! kill -0 "$pp" 2>/dev/null || fail "4: a wedged herdr's child $pp outlived the ceiling"
  done <"$ph/herdr/hang-children"
done
# Named (D1, extended to peek): a driver that failed to LOAD is the oracle's
# 127, read as the BACKEND line; the shim has no counterpart (N/A - its backend
# verbs are native, src/lib.ts backendCall), so the oracle alone runs this row,
# through its own lab copy with the herdr driver renamed.
mkdir -p "$TMP/ploadfail"
cp -R "$pobin" "$TMP/ploadfail/bin"; ln -s "$ROOT/src" "$TMP/ploadfail/src"
sed -i.bak 's/^backend_window_alive_herdr() {/backend_window_alive_herdr_MISSING_DRIVER() {/' "$TMP/ploadfail/bin/ac-backend.sh"
rm -f "$TMP/ploadfail/bin/ac-backend.sh.bak"
PO_RC=0; prun_side "$TMP/ploadfail/bin" "$POH" o c1 || PO_RC=$?
pnorm "$TMP/o.err" "$POH" >"$TMP/o.err2"
assert_eq "$PO_RC:$(cat "$TMP/o.raw")" "1:" "4: the oracle refuses a 127 driver"
assert_contains "$(poerr)" "ERROR: $PUNREAD" "4: ...with the BACKEND line"
assert_contains "$(poerr)" "backend_window_alive_herdr: command not found" "4: ...bash names the missing driver"
pboth rm -f @H/herdr/log   # the oracle alone ran: both worlds' stub logs restart in step

# 5. <lines>: the default (absent or ''), 2, 0, -2 (BSD tail's last 2), +3
#    (from line 3, applied twice - W2), abc (tail's line twice on herdr -
#    W3), and the herdr fetch floor of 200 (5) against a larger request (250 -
#    W4).
psame c1; assert_eq "$(pout | wc -l | tr -d ' ')" 7 "5: the default prints every line"
psame c1 ''; assert_eq "$(pout | wc -l | tr -d ' ')" 7 "5: '' is the default"
psame c1 2; assert_eq "$(pout)" "peek| l6
peek| l7" "5: 2"
psame c1 0; assert_eq "$PN_RC:$(pout)" "0:" "5: 0 prints nothing, exit 0"
psame c1 -2; assert_eq "$(pout)" "peek| l6
peek| l7" "5: -2"
psame c1 +3; assert_eq "$(pout)" "peek| l5
peek| l6
peek| l7" "5 (W2): +3 is tail's from-line-3, twice"
psame c1 abc; assert_eq "$PN_RC:$(pout):$(perr)" "1::tail: illegal offset -- abc: Invalid argument
tail: illegal offset -- abc: Invalid argument" "5 (W3): abc on herdr"
pboth rm -f @H/herdr/log
psame c1 250; assert_contains "$(cat "$PNH/herdr/log")" "pane read pC1 --source recent --lines 250" "5 (W4): 250 fetches 250"
pboth rm -f @H/herdr/log
psame c1 5; assert_contains "$(cat "$PNH/herdr/log")" "pane read pC1 --source recent --lines 200" "5 (W4): 5 fetches the floor"
pboth pput herdr/panes/pC1.buf $'x\n\nb1\nb2\n'
psame c1 +2; assert_eq "$(pout)" "peek| b2" "5 (W2): +2 counts again from the first line left once the blanks are gone"

# 6. the capture's bytes: blanks dropped AFTER the raw tail (W12); CR, a
#    CR-only and a blank-only line, TAB and a last line with no LF kept (W13);
#    NUL dropped; an empty pane; a read that fails is a silent exit 1 (W5).
p6() { local i; for i in $(seq 1 150); do printf 'L%s\n\n' "$i"; done >"$H/herdr/panes/pC1.buf"; }
pboth p6
psame c1; assert_eq "$(pout | wc -l | tr -d ' '):$(pout | tail -n 1)" "20:peek| L150" "6 (W12): 40 raw lines, 20 printed"
pboth pput herdr/panes/pC1.buf $'a\r\n\r\n   \n\tb\nlast-no-lf'
psame c1; assert_eq "$(pout)" $'peek| a\r\npeek| \r\npeek|    \npeek| \tb\npeek| last-no-lf' "6 (W13): bytes kept"
pboth sh -c 'printf "x\\000y\\n" >"$0"' @H/herdr/panes/pC1.buf
psame c1; assert_eq "$(pout)" "peek| xy" "6: NUL dropped"
pboth pput herdr/panes/pC1.buf ''
psame c1; assert_eq "$PN_RC:$(pout)" "0:" "6: an empty pane prints nothing"
pboth touch @H/herdr/panes/pC1.read-fails
psame c1; assert_eq "$PN_RC:$(pout):$(perr)" "1::" "6 (W5): a failing read is a silent exit 1"
pboth rm -f @H/herdr/panes/pC1.read-fails
pclosed() {  # pclosed <bin> <side root> - the exit of a peek whose reader leaves after one line
  (cd "$2" && env -u AC_BACKEND LC_ALL=C PATH="$TMP/stubbin:$PATH" FAKE_HERDR="$2/herdr" FAKE_ORCA="$2/orca" EPOCHSECONDS="$PEPOCH" \
    AC_GUARD_ROOT="$TMP/pguard-root" AC_HOME="$2/home" bash -c '"$0/ac-peek.sh" c1 20000 | head -n 1 >/dev/null; printf "%s" "${PIPESTATUS[0]}"' "$1") </dev/null
}
pboth sh -c 'seq 1 20000 >"$0"' @H/herdr/panes/pC1.buf
assert_eq "$(pclosed "$BIN" "$PNH"):$(pclosed "$pobin" "$POH")" "141:141" "6: a reader that leaves early ends the run with SIGPIPE's 141"

# 7. locale: a byte that is not UTF-8 passes under C; under the operator's
#    UTF-8 locale sed aborts on it - the lines before it print (W6).
pboth sh -c 'printf "ok1\\n\\351bad\\nok3\\n" >"$0"' @H/herdr/panes/pC1.buf
psame c1; assert_eq "$(pout)" "peek| ok1
peek| $(printf '\351')bad
peek| ok3" "7: an invalid byte passes under C"
PLC=""; PENV=(LANG=en_US.UTF-8)
psame c1; assert_eq "$PN_RC:$(pout)" "1:peek| ok1" "7 (W6): UTF-8 cuts at the byte, exit 1"
assert_contains "$(perr)" "sed: RE error: illegal byte sequence" "7 (W6): ... with sed's own line"
PLC=C; PENV=()

# 8. orca: a live terminal is read at --limit <lines> --screen; an exited one
#    is gone; an unreachable runtime is the BACKEND line; abc is tail's line
#    once (W3).
p8() {
  printf 'backend=orca\n' >"$H/home/state/o1.meta"; printf 'term9 tab9\n' >"$H/home/state/.pane-o1"
  printf 'o1\no2\n\no3\no4\n' >"$H/orca/terminals/term9.buf"
}
pboth p8
psame o1 3; assert_eq "$PN_RC:$(pout)" "0:peek| o3
peek| o4" "8: orca alive"
assert_contains "$(cat "$PNH/orca/log")" "orca terminal read --terminal term9 --limit 3 --screen --json" "8: the orca read's argv"
psame o1 abc; assert_eq "$PN_RC:$(pout):$(perr)" "1::tail: illegal offset -- abc: Invalid argument" "8 (W3): abc on orca"
pboth touch @H/orca/terminals/term9.exited
psame o1; assert_eq "$PN_RC:$(perr)" "1:ERROR: window gone for o1" "8: an exited terminal is gone"
pboth rm -f @H/orca/terminals/term9.exited
pboth touch @H/orca/.unreachable
psame o1; assert_eq "$PN_RC:$(perr)" "1:ERROR: the BACKEND could not be read for o1 - the pane's liveness is UNKNOWN and no work is lost; check the backend itself (herdr status server), then peek again" "8: an unreachable orca"
pboth rm -f @H/orca/.unreachable

# 9. stdin by position: herdr's `pane get` reads the caller's stdin, the
#    capture's `pane read` (a pipeline member's $( )) reads /dev/null; orca
#    reads the caller's at both calls - the first drains it unless it leaves
#    it alone (a stdin-skip-<verb> sentinel).
mkdir -p "$TMP/pstdin"
for pc in herdr orca; do
  cat >"$TMP/pstdin/$pc" <<STUB
#!/bin/sh
if [ -e "\$STUB_DIR/stdin-skip-\$2" ]; then i=-; else i="\$(cat)"; fi
printf '$pc %s %s stdin=[%s]\n' "\$1" "\$2" "\$i" >>"\$STUB_DIR/stdin.log"
exec "$TMP/stubbin/$pc" "\$@" </dev/null
STUB
  chmod +x "$TMP/pstdin/$pc"
done
printf 'caller bytes\n' >"$TMP/pstdin.in"
PSTDIN="$TMP/pstdin.in"; PPATH="$TMP/pstdin:$TMP/stubbin:$PATH"
pboth p0
psame c1 1; assert_eq "$(cat "$PNH/stdin.log")" "herdr pane get stdin=[caller bytes]
herdr pane read stdin=[]" "9: herdr stdin by position"
pboth rm -f @H/stdin.log
pboth p8
psame o1 1; assert_eq "$(cat "$PNH/stdin.log")" "orca terminal show stdin=[caller bytes]
orca terminal read stdin=[]" "9: orca's first call drains the caller's stdin"
pboth rm -f @H/stdin.log
pboth touch @H/stdin-skip-show
psame o1 1; assert_eq "$(cat "$PNH/stdin.log")" "orca terminal show stdin=[-]
orca terminal read stdin=[caller bytes]" "9: orca's capture reads the caller's stdin"
PSTDIN=/dev/null; PPATH=""
pboth rm -f @H/stdin.log @H/stdin-skip-show

# 10. the guard: a stale beat with crew in flight prints WATCHER-DOWN ahead of
#     the usage line; a guard that is not executable stays silent.
pboth rm -f @H/home/state/.last-watcher-beat
psame; assert_eq "$PN_RC:$(perr)" "1:WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh
$PUSAGE" "10: the guard's block precedes the usage line"
mkdir -p "$TMP/poraclelab" "$TMP/pshimlab"
cp -R "$pobin" "$TMP/poraclelab/bin"; ln -s "$ROOT/src" "$TMP/poraclelab/src"
cp -R "$BIN" "$TMP/pshimlab/bin"; ln -s "$ROOT/src" "$TMP/pshimlab/src"
chmod -x "$TMP/poraclelab/bin/ac-guard.sh" "$TMP/pshimlab/bin/ac-guard.sh"
PO_BIN="$TMP/poraclelab/bin"; PN_BIN="$TMP/pshimlab/bin"
psame; assert_eq "$PN_RC:$(perr)" "1:$PUSAGE" "10: a non-executable guard is silent"
PO_BIN="$pobin"; PN_BIN="$BIN"

# 11. Named divergences, each side pinned by hand.
# - bun absent from PATH: the original's guard (a bun shim) printed the shim's
#   refusal and the peek went on; the port's own shim refuses alike and ends.
pboth p0
PPATH="$TMP/stubbin:/usr/bin:/bin:/usr/sbin:/sbin"
if [ -z "$(PATH="$PPATH" command -v bun || true)" ]; then
  ppair c1 1
  assert_eq "$PO_RC:$(cat "$TMP/o.out"):$(poerr)" "0:peek| l7:ERROR: required tool not found: bun" "11: bun absent - the original peeks past the guard's refusal"
  assert_eq "$PN_RC:$(pout):$(perr)" "1::ERROR: required tool not found: bun" "11: bun absent - the port's shim refuses"
else
  printf 'SKIP: row 11 bun-absent - bun sits in /usr/bin or /bin on this host\n'
fi
PPATH=""
pboth rm -f @H/herdr/log   # the oracle alone peeked: both worlds' stub logs restart in step
# - argv arrives decoded: a byte that is not UTF-8 in the id is U+FFFD in the
#   port's refusal where the original printed the byte; the exit is the same.
ppair "$(printf '\351')"
assert_eq "$PN_RC:$PO_RC" "1:1" "11: a non-UTF-8 id - the same exit"
assert_eq "$(poerr)" "ERROR: no crewmate meta for $(printf '\351')" "11: a non-UTF-8 id - the original's byte"
assert_eq "$(perr)" "ERROR: no crewmate meta for $(printf '\357\277\275')" "11: a non-UTF-8 id - the port's U+FFFD"
#   So is such a byte of the meta's backend= on its way into AC_BACKEND.
pboth pput home/state/t1.meta $'backend=tm\351x\n'
ppair t1
assert_eq "$PN_RC:$PO_RC" "1:1" "11: a non-UTF-8 backend= - the same exit"
assert_eq "$(poerr)" "ERROR: unsupported backend 'tm$(printf '\351')x' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "11: a non-UTF-8 backend= - the original's byte"
assert_eq "$(perr)" "ERROR: unsupported backend 'tm$(printf '\357\277\275')x' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "11: a non-UTF-8 backend= - the port's U+FFFD"
pboth rm -f @H/home/state/t1.meta
# - HOME RESOLUTION: an AC_HOME cd cannot enter was cd's own line in the
#   original; the port names the variable. Exit and stdout alike.
PENV=(AC_HOME=@H/missing)
ppair c1; psame_rc_out c1; psame_world c1
assert_contains "$(poerr)" "No such file or directory" "11: the original's line for an unenterable AC_HOME is cd's own"
assert_eq "$(perr)" "ERROR: AC_HOME is not a readable directory: @H/missing
ERROR: no crewmate meta for c1" "11: the port names the variable"
PENV=()

pass
