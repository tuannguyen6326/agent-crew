#!/usr/bin/env bash
# ac-crew-state.test.sh - the one-line deterministic state renderer: window
# liveness is THREE-STATE (gone/unobservable/alive, contract: ac-backend.sh
# WINDOW LIVENESS) - only a definite rc=1 renders gone, rc=2 must name the
# BACKEND as the unknown instead (F12); and the re-emitted last-status-log
# line must never match a live AC_CAPTAIN_RE marker into whatever pane calls
# this (F13). The differential leg at the end holds src/crew-state.ts to the
# bash original frozen at tests/fixtures/ac-crew-state.sh.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
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

# --- F12: rc=2 (unobservable) must not render as gone -------------------------

mk_crewmate c1 pC1 tC1
touch "$FAKE_HERDR/.unreachable"
out="$("$BIN/ac-crew-state.sh" c1)"
case "$out" in gone|gone*) fail "an unreadable backend must never render as gone: $out" ;; esac
assert_contains "$out" "unobservable" "an unreadable backend names itself unobservable"
assert_contains "$out" "backend" "the state names the BACKEND as the unknown, not the pane"
rm -f "$FAKE_HERDR/.unreachable"

# A REAL gone window keeps the old wording exactly.
rm -f "$FAKE_HERDR/panes/pC1.buf" "$FAKE_HERDR/tabs/tC1"
assert_eq "$("$BIN/ac-crew-state.sh" c1)" "gone" "a real gone window is reported exactly as before"

# --- a backend that cannot be READ at all is UNOBSERVABLE, never gone ----------
# Contract: ac-backend.sh WINDOW LIVENESS is THREE-STATE (0 alive / 1 gone /
# 2 unobservable), and a `case` carrying only 0)/2) and defaulting everything
# else to gone reads any other failure as a dead pane. This row once drove a
# driver that failed to LOAD (bash's 127, through a lab bin/ with the herdr
# driver renamed); the backend verbs are native now (src/lib.ts backendCall),
# so no driver can fail to load, and the row reaches the same unobservable
# read with herdr absent from PATH (the liveness ladder's 2).
mk_crewmate lf1 pLF1 tLF1
nh_path="$(dirname "$(command -v bun)"):/usr/bin:/bin:/usr/sbin:/sbin"
if [ -z "$(PATH="$nh_path" command -v herdr || true)" ]; then
  out="$(PATH="$nh_path" "$BIN/ac-crew-state.sh" lf1)"
  case "$out" in gone|gone*) fail "THE REGRESSION: herdr absent from PATH must never render as gone: $out" ;; esac
  assert_contains "$out" "unobservable" "herdr absent from PATH names itself unobservable, same as rc=2"
else
  printf 'SKIP: crew-state with herdr absent - bun shares its directory with a herdr on this host\n'
fi

# --- F13: the last status line must not re-emit a bare captain marker ---------

mk_crewmate c2 pC2 tC2
printf '2026-07-29T00:00:00Z needs-decision: which prefix should I use?\n' >"$AC_HOME/state/c2.status"
out="$("$BIN/ac-crew-state.sh" c2)"
. "$BIN/ac-lib.sh"
case "$out" in *"needs-decision: which prefix"*) ;; *) fail "the marker text itself must survive, only its column-0 position is neutralized: $out" ;; esac
if grep -qE "$AC_CAPTAIN_RE" <<<"$out"; then
  fail "ac-crew-state.sh must not re-emit a line matching the LIVE AC_CAPTAIN_RE: $out"
fi

# --- differential: src/crew-state.ts against the frozen bash original -------
# DISPUTED: the implementation (tests/fixtures/ac-crew-state.sh under bash vs src/crew-state.ts through bin/ac-crew-state.sh)
# HELD-CONSTANT: two side roots seeded alike ($COH for the oracle, $CNH for the shim) - a home at <side>/home, a worktree at <side>/wt, the fake herdr's state at <side>/herdr and the fake orca's at <side>/orca; argv and env (the side root spelled @H, substituted in values only); cwd (the side root); stdin (a regular file, so the stub log shows which call read the caller's stdin); LC_ALL=C unless a row names en_US.UTF-8; PATH: herdr and orca wrappers that log each call with the stdin it got and exec make_fake_herdr's and make_fake_orca's fakes, then the ambient PATH, or a row's own; the live bin/ beside each entry (the oracle bin's copies, $BIN's own); exit status, stdout and stderr compared whole (the side root spelled @H, either bin root ROOT), then the world: every path under the home and the stub logs of the row.
make_fake_orca
cobin="$(make_oracle_bin ac-crew-state)"
COH="$TMP/cside-o"; CNH="$TMP/cside-n"
CSTDIN="$TMP/cstdin"; printf 'one\ntwo\n' >"$CSTDIN"
CSTUBS="$TMP/cstubs"; mkdir -p "$CSTUBS"
for c in herdr orca; do
  cat >"$CSTUBS/$c" <<STUB
#!/bin/sh
if [ -c /dev/stdin ]; then i=null; else i=caller; fi
printf '%s %s stdin=%s\n' $c "\$*" "\$i" >>"\$STUB_DIR/stdin.log"
exec "$TMP/stubbin/$c" "\$@"
STUB
  chmod +x "$CSTUBS/$c"
done
cboth() {  # cboth <cmd> <args...> - a seeding step at each side root: H names it, and so does a literal @H in an argument
  local h x a; for h in "$COH" "$CNH"; do H="$h"; a=(); for x in "$@"; do a+=("${x//@H/$h}"); done; "${a[@]}"; done
}
cseed() {
  rm -rf "$H"; mkdir -p "$H/home/state" "$H/home/config" "$H/wt" "$H/herdr/panes" "$H/herdr/tabs" "$H/orca/terminals"
  printf 'off\n' >"$H/home/config/wedge-alarm"
}
# shellcheck disable=SC2059
cfmt() { mkdir -p "$(dirname "$H/$1")"; printf "${2//@H/$H}" >"$H/$1"; }   # cfmt <path under the side> <printf format>
clive() {  # clive <id> <pane> [<meta format>] - a meta, a handle and a pane the fake herdr answers for
  cfmt "home/state/$1.meta" "${3:-backend=herdr\n}"
  printf '%s t%s\n' "$2" "$2" >"$H/home/state/.pane-$1"
  printf '%s\n' "$2" >"$H/herdr/tabs/t$2"; : >"$H/herdr/panes/$2.buf"
}
corca() {  # corca <id> <handle> - an orca meta, a handle and a terminal the fake orca answers for
  printf 'backend=orca\n' >"$H/home/state/$1.meta"
  printf '%s tab-%s\n' "$2" "$2" >"$H/home/state/.pane-$1"
  : >"$H/orca/terminals/$2.buf"
}
CLC=C; CENV=(); CHOMELESS=0; CHOME=home; CPATH=""
crun_side() {  # crun_side <bin> <side root> <prefix> <args...>
  local bin="$1" h="$2" p="$3" x v; shift 3
  local a=() e=("LC_ALL=$CLC" "PATH=${CPATH:-$CSTUBS:$TMP/stubbin:$PATH}" "STUB_DIR=$h" "FAKE_HERDR=$h/herdr" "FAKE_ORCA=$h/orca")
  [ "$CHOMELESS" = 1 ] || e+=("AC_HOME=$h/$CHOME")
  for x in ${CENV[@]+"${CENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$h}"); done
  for x in "$@"; do a+=("${x//@H/$h}"); done
  rm -f "$h/herdr/log" "$h/orca/log" "$h/stdin.log"
  (cd "$h" && env -u AC_HOME -u AC_BACKEND -u AC_FLEET_STATE -u AC_HERDR_SESSION -u AC_HERDR_RPC_TIMEOUT -u AC_BUSY_RE \
    "${e[@]}" "$bin/ac-crew-state.sh" ${a[@]+"${a[@]}"}) <"$CSTDIN" >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
cnorm() {
  LC_ALL=C sed -E -e "s#$2#@H#g" -e "s#$TMP/oracle-ac-crew-state#ROOT#g" -e "s#$TMP/cloadfail#ROOT#g" -e "s#$ROOT#ROOT#g" "$1"
}
CO_RC=0; CN_RC=0
cpair() {  # cpair <args...> - both sides run, outputs normalised, nothing compared yet
  CO_RC=0; CN_RC=0
  crun_side "$cobin" "$COH" o "$@" || CO_RC=$?
  crun_side "$BIN" "$CNH" n "$@" || CN_RC=$?
  cnorm "$TMP/o.raw" "$COH" >"$TMP/o.out"; cnorm "$TMP/o.err" "$COH" >"$TMP/o.err2"
  cnorm "$TMP/n.raw" "$CNH" >"$TMP/n.out"; cnorm "$TMP/n.err" "$CNH" >"$TMP/n.err2"
}
crow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
csame_rc_out() {
  assert_eq "$CN_RC" "$CO_RC" "crew-state differential exit for '$*' at line $(crow)"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "crew-state differential stdout differs for '$*' at line $(crow): $(diff "$TMP/o.out" "$TMP/n.out" | head -n 8)"
}
csame_io() {
  csame_rc_out "$@"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "crew-state differential stderr differs for '$*' at line $(crow): $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 8)"
}
cworld() {  # cworld <side root> - what a row may change or call
  local h="$1" f
  (cd "$h/home" && find . | LC_ALL=C sort)
  for f in "$h/herdr/log" "$h/orca/log" "$h/stdin.log"; do
    [ -f "$f" ] || continue
    printf '== %s\n' "${f#"$h"/}"; cat "$f"
  done
}
csame_world() {
  cworld "$COH" >"$TMP/o.world"; cworld "$CNH" >"$TMP/n.world"
  cnorm "$TMP/o.world" "$COH" >"$TMP/o.world2"; cnorm "$TMP/n.world" "$CNH" >"$TMP/n.world2"
  cmp -s "$TMP/o.world2" "$TMP/n.world2" || fail "crew-state differential world differs after '$*' at line $(crow): $(diff "$TMP/o.world2" "$TMP/n.world2" | head -n 10)"
}
csame() { cpair "$@"; csame_io "$@"; csame_world "$@"; }
cout() { cat "$TMP/n.out"; }
cerr() { cat "$TMP/n.err2"; }
coerr() { cat "$TMP/o.err2"; }
CUSAGE='ERROR: usage: ac-crew-state.sh <id>'
CBAD="ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)"
CNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
CUNOBS='unobservable: backend could not be read for'
cboth cseed

# 1. usage, and the backend gate BEFORE it: none and "" are the usage line;
#    config/backend tmux refuses before the usage check and before the meta;
#    AC_BACKEND=Herdr refuses; config/backend is its first line trimmed, never
#    cut at a blank; the AC_FLEET_STATE rung is cut at its first blank.
csame; assert_eq "$CN_RC:$(cout):$(cerr)" "1::$CUSAGE" "1: no argument is the usage line"
csame ""; assert_eq "$CN_RC:$(cout):$(cerr)" "1::$CUSAGE" "1: an empty id is the usage line"
cboth cfmt home/config/backend 'tmux\n'
csame; assert_eq "$CN_RC:$(cerr)" "1:$CBAD" "1: config/backend tmux refuses before the usage check"
csame c1; assert_eq "$CN_RC:$(cerr)" "1:$CBAD" "1: ...and before the meta"
cboth cfmt home/config/backend ' orca extra \n'
csame c1; assert_contains "$(cerr)" "unsupported backend 'orca extra'" "1: config/backend trimmed, never cut at a blank"
cboth rm -f @H/home/config/backend
CENV=(AC_BACKEND=Herdr); csame c1; CENV=()
assert_eq "$CN_RC:$(cerr)" "1:ERROR: unsupported backend 'Herdr' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "1: AC_BACKEND=Herdr refuses"
cboth cfmt fs/config/backend 'bogus\tx\n'; cboth mkdir -p @H/fs/state
CENV=(AC_FLEET_STATE=@H/fs/state/); csame c1; CENV=()
assert_contains "$(cerr)" "unsupported backend 'bogus'" "1: the AC_FLEET_STATE rung, cut at its first blank"

# 2. the meta: none; a directory named <id>.meta; homeless (the refusal, then
#    the meta line - `/<id>.meta` was read); an AC_HOME that cannot be entered
#    (named: the original's lines there are cd's own); an unreadable meta.
csame nope; assert_eq "$CN_RC:$(cout):$(cerr)" "1::ERROR: no crewmate meta for nope" "2: no meta"
cboth mkdir @H/home/state/d1.meta
csame d1; assert_eq "$CN_RC:$(cerr)" "1:ERROR: no crewmate meta for d1" "2: a directory is no meta"
CHOMELESS=1
csame c1; assert_eq "$CN_RC:$(cerr)" "1:$CNOHOME
ERROR: no crewmate meta for c1" "2: homeless prints the refusal, then the meta line"
csame; assert_eq "$(cerr)" "$CUSAGE" "2: homeless without an id is the usage line alone"
CHOMELESS=0
CHOME=missing
cpair c1; csame_rc_out c1; csame_world c1
assert_eq "$CN_RC" 1 "2: an AC_HOME that cannot be entered ends the run 1"
assert_contains "$(coerr)" "No such file or directory" "2: the original's line for an unenterable AC_HOME is cd's own"
assert_contains "$(cerr)" "ERROR: AC_HOME is not a readable directory: @H/missing" "2: the port names the variable (named)"
CHOME=home
if [ "$(id -u)" != 0 ]; then
  cboth cfmt home/state/u1.meta 'backend=herdr\n'; cboth chmod 000 @H/home/state/u1.meta
  csame u1; assert_eq "$CN_RC:$(cout):$(cerr)" "1::WARN: cannot read meta file @H/home/state/u1.meta" "2: an unreadable meta warns, exit 1"
  cboth chmod 644 @H/home/state/u1.meta
fi

# 3. the ship step: the first running/fixing/awaiting_approval row after a
#    passed one, fixing before awaiting_approval, a lone awaiting_approval;
#    only queued/passed rows fall through (no handle: gone); a CR after a
#    third field rides along, a CR ending the status field matches no arm;
#    awk reads a row only to its first NUL; an unreadable steps file is awk's
#    line and status; no worktree=, a missing worktree and a steps DIRECTORY
#    fall through; worktree= cut at a NUL, the last one winning; under UTF-8
#    awk matches a row holding a byte that is not UTF-8 and tr cuts the row
#    there (W2).
CSTEPS=wt/.crew/ship/current/steps.tsv
cboth cfmt home/state/s1.meta 'backend=herdr\nworktree=@H/wt\n'
cboth cfmt $CSTEPS 'lint\tpassed\t1\nreview\trunning\t2\n'
csame s1; assert_eq "$CN_RC:$(cout)" "0:validate:review:running:2" "3: the first running row after a passed one"
cboth cfmt $CSTEPS 'a\tfixing\tx\nb\tawaiting_approval\ty\n'
csame s1; assert_eq "$(cout)" "validate:a:fixing:x" "3: fixing first wins"
cboth cfmt $CSTEPS 'b\tawaiting_approval\n'
csame s1; assert_eq "$(cout)" "validate:b:awaiting_approval" "3: a lone awaiting_approval"
cboth cfmt $CSTEPS 'a\tqueued\nb\tpassed\n'
csame s1; assert_eq "$(cout)" "gone" "3: only queued/passed rows fall through to liveness"
cboth cfmt $CSTEPS 'a\trunning\t1\r\n'
csame s1; assert_eq "$(cout)" "validate:a:running:1"$'\r' "3: a CR after the third field rides along"
cboth cfmt $CSTEPS 'a\trunning\r\n'
csame s1; assert_eq "$(cout)" "gone" "3: a CR ending the status field matches no arm"
cboth cfmt $CSTEPS 'x\trunning\ta\000b\n'
csame s1; assert_eq "$(cout)" "validate:x:running:a" "3: awk reads a row only to its first NUL"
cboth cfmt $CSTEPS 'x\000\trunning\n'
csame s1; assert_eq "$(cout)" "gone" "3: ...so a NUL before the status field matches no arm"
if [ "$(id -u)" != 0 ]; then
  cboth cfmt $CSTEPS 'r\trunning\n'; cboth chmod 000 @H/$CSTEPS
  csame s1; assert_eq "$CN_RC:$(cout)" "2:" "3: an unreadable steps file ends the run with awk's status"
  assert_contains "$(cerr)" "can't open file" "3: ...and awk's own line"
  cboth chmod 644 @H/$CSTEPS
fi
cboth cfmt $CSTEPS 'r\trunning\n'
cboth cfmt home/state/s2.meta 'backend=herdr\n'
csame s2; assert_eq "$(cout)" "gone" "3: no worktree= falls through"
cboth cfmt home/state/s3.meta 'worktree=@H/nowt\n'
csame s3; assert_eq "$(cout)" "gone" "3: a missing worktree falls through"
cboth cfmt home/state/s4.meta 'worktree=@H/nowt\nworktree=@H/wt\000junk\n'
csame s4; assert_eq "$(cout)" "validate:r:running" "3: worktree= cut at a NUL, the last one winning"
cboth rm -rf @H/wt/.crew; cboth mkdir -p @H/$CSTEPS
csame s1; assert_eq "$(cout)" "gone" "3: a steps directory falls through"
cboth rm -rf @H/wt/.crew
CLC=en_US.UTF-8
cboth cfmt $CSTEPS 'caf\303\251\trunning\tx\351y\tz\n'
csame s1; assert_eq "$(cout)" "validate:caf"$'\303\251'":running:x" "3 (W2): under UTF-8 tr cuts the row at a byte that is not UTF-8"
assert_eq "$(cerr)" "tr: Illegal byte sequence" "3 (W2): ...with tr's own line"
cboth cfmt $CSTEPS 'b\351d\trunning\n'
csame s1; assert_eq "$(cout)" "validate:b" "3 (W2): ...awk having matched it"
CLC=C
cboth rm -rf @H/wt/.crew

# 4. no handle (no .pane-<id>, or a blank one): gone; kind=self is detached,
#    exactly - `self<CR>` is gone - the last kind= winning; a self task with
#    a live pane reads its pane; a stale tmux meta is the route's ERROR, exit
#    1, a UTF-8 name refused as its bytes, one that is not UTF-8 as U+FFFD
#    (named); an orca meta with no handle is gone.
cboth cfmt home/state/k1.meta 'backend=herdr\n'
csame k1; assert_eq "$(cout)" "gone" "4: no handle is gone"
cboth cfmt home/state/k1.meta 'kind=self\n'
csame k1; assert_eq "$(cout)" "detached" "4: a self task with no handle is detached"
cboth cfmt home/state/k1.meta 'kind=self\r\n'
csame k1; assert_eq "$(cout)" "gone" "4: self<CR> is no self"
cboth cfmt home/state/k1.meta 'kind=self\nkind=ship\n'
csame k1; assert_eq "$(cout)" "gone" "4: the last kind= wins"
cboth cfmt home/state/k1.meta 'kind=ship\nkind=self\n'
csame k1; assert_eq "$(cout)" "detached" "4: ...either way"
cboth cfmt home/state/.pane-k1 '\n'
csame k1; assert_eq "$(cout)" "detached" "4: a blank handle is no handle"
cboth clive k2 pK2 'kind=self\n'
csame k2; assert_eq "$(cout)" "idle" "4: a self task with a live pane reads its pane"
cboth cfmt home/state/k1.meta 'backend=tmux\n'
csame k1; assert_eq "$CN_RC:$(cout):$(cerr)" "1::$CBAD" "4: a stale tmux meta exits inside the route"
cboth cfmt home/state/k1.meta 'backend=caf\303\251\n'
csame k1; assert_eq "$CN_RC:$(cout):$(cerr)" "1::ERROR: unsupported backend 'caf$(printf '\303\251')' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "4: a meta's UTF-8 backend name is refused as its bytes"
cboth cfmt home/state/k1.meta 'backend=caf\351\n'
cpair k1; csame_rc_out k1; csame_world k1
assert_eq "$(coerr)" "ERROR: unsupported backend 'caf$(printf '\351')' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "4: a non-UTF-8 backend= - the original's byte"
assert_eq "$(cerr)" "ERROR: unsupported backend 'caf$(printf '\357\277\275')' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "4: a non-UTF-8 backend= - the port's U+FFFD (named)"
cboth cfmt home/state/k1.meta 'backend=orca\n'; cboth rm -f @H/home/state/.pane-k1
csame k1; assert_eq "$(cout)" "gone" "4: an orca meta with no handle is gone"
cboth cfmt home/state/k1.meta 'backend=\000orca\n'
csame k1; assert_eq "$CN_RC:$(cout)" "0:gone" "4: backend= cut at a NUL is no name: herdr"

# 5. the backend unreadable: unreachable, and the pane api down with the
#    server running, are unobservable with the herdr target; a stopped server
#    holds no panes (gone); a hang past AC_HERDR_RPC_TIMEOUT is unobservable;
#    so is herdr absent from PATH.
cboth clive v1 pV1
cboth touch @H/herdr/.unreachable
csame v1; assert_eq "$(cout)" "$CUNOBS herdr:pane-pV1" "5: unreachable"
cboth rm -f @H/herdr/.unreachable; cboth touch @H/herdr/.pane-api-down
csame v1; assert_eq "$(cout)" "$CUNOBS herdr:pane-pV1" "5: the pane api down, the server running"
cboth rm -f @H/herdr/.pane-api-down; cboth touch @H/herdr/.server-stopped
csame v1; assert_eq "$(cout)" "gone" "5: a stopped server holds no panes"
cboth rm -f @H/herdr/.server-stopped; cboth touch @H/herdr/.hang
CENV=(AC_HERDR_RPC_TIMEOUT=1); csame v1; CENV=()
cboth rm -f @H/herdr/.hang
for h in "$COH" "$CNH"; do kill $(cat "$h/herdr/hang-children" 2>/dev/null) 2>/dev/null || true; done
assert_eq "$(cout)" "$CUNOBS herdr:pane-pV1" "5: a hang past the ceiling"
CPATH="$(dirname "$(command -v bun)"):/usr/bin:/bin:/usr/sbin:/sbin"
if [ -z "$(PATH="$CPATH" command -v herdr || true)" ]; then
  csame v1; assert_eq "$(cout)" "$CUNOBS herdr:pane-pV1" "5: herdr absent from PATH"
else
  printf 'SKIP: row 5 herdr-absent - bun shares its directory with a herdr on this host\n'
fi
CPATH=""
# Named: a driver that failed to LOAD is the oracle's 127, read as
# unobservable; the shim has no counterpart (N/A - its backend verbs are
# native, src/lib.ts backendCall), so the oracle alone runs this row, through
# its own lab copy with the herdr driver renamed.
mkdir -p "$TMP/cloadfail"; cp -R "$cobin" "$TMP/cloadfail/bin"; ln -s "$ROOT/src" "$TMP/cloadfail/src"
sed -i.bak 's/^backend_window_alive_herdr() {/backend_window_alive_herdr_MISSING_DRIVER() {/' "$TMP/cloadfail/bin/ac-backend.sh"
rm -f "$TMP/cloadfail/bin/ac-backend.sh.bak"
CO_RC=0; crun_side "$TMP/cloadfail/bin" "$COH" o v1 || CO_RC=$?
cnorm "$TMP/o.raw" "$COH" >"$TMP/o.out"; cnorm "$TMP/o.err" "$COH" >"$TMP/o.err2"
assert_eq "$CO_RC:$(cat "$TMP/o.out")" "0:$CUNOBS herdr:pane-pV1" "5: the oracle's 127 driver is unobservable"
assert_contains "$(coerr)" "backend_window_alive_herdr: command not found" "5: ...bash names the missing driver"

# 6. an alive pane: an empty capture is idle; each AC_BUSY_RE arm is busy
#    (`Working…` its three UTF-8 bytes under C); the window: a busy line 25th
#    from the end is busy, 26th is not, one before 15 lines and 15 blanks is
#    (counted after the blanks are gone), one 42nd or 41st from the end of the
#    read is past the 40-line capture, and 40th - trailing blanks cut - is
#    inside it;
#    AC_BUSY_RE overrides, an empty one is the default, a bad ERE is grep's
#    line and no match; under C a busy line holding a byte that is not UTF-8
#    matches, under UTF-8 any such byte is sed's abort - exit 1, nothing on
#    stdout; a pane read that fails is exit 1, nothing on stdout; busy
#    outranks a status line; the session knob rides every RPC; the probe
#    reads the caller's stdin, the capture /dev/null.
# shellcheck disable=SC2059
cbuf() { printf "$2" >"$H/herdr/panes/$1.buf"; }   # cbuf <pane> <printf format>
cwin() {  # cwin <n> <blanks> - pB1 reads Thinking, then <n> lines, each followed by <blanks> blank lines
  local i=0 j
  { printf 'Thinking\n'
    while [ "$i" -lt "$1" ]; do
      printf 'l%s\n' "$i"; j=0; while [ "$j" -lt "$2" ]; do printf '\n'; j=$((j + 1)); done; i=$((i + 1))
    done; } >"$H/herdr/panes/pB1.buf"
}
cboth clive b1 pB1
csame b1; assert_eq "$CN_RC:$(cout)" "0:idle" "6: an empty capture is idle"
for cb in 'Thinking' 'still thinking' 'esc to interrupt' '(esc interrupt)' 'Working...' 'Working\342\200\246' 'Ctrl+c:cancel'; do
  cboth cbuf pB1 "x\n$cb\ny\n"
  csame b1; assert_eq "$(cout)" "busy" "6: '$cb' is busy"
done
cboth cwin 24 0; csame b1; assert_eq "$(cout)" "busy" "6: 25th from the end is inside the window"
cboth cwin 25 0; csame b1; assert_eq "$(cout)" "idle" "6: 26th is not"
cboth cwin 15 1; csame b1; assert_eq "$(cout)" "busy" "6: the window is counted after the blank lines are gone"
cboth cwin 21 1; csame b1; assert_eq "$(cout)" "idle" "6: a busy line past the 40-line capture is not seen"
cboth cwin 20 1; csame b1; assert_eq "$(cout)" "busy" "6: the read's trailing blank lines are cut before the 40"
cboth cbuf pB1 "Thinking\n$(printf '\\nl%s\\n' $(seq 0 19))"
csame b1; assert_eq "$(cout)" "idle" "6: 41st from the end of the read is past the capture"
cboth cbuf pB1 'Thinking\n'
CENV=(AC_BUSY_RE=zzz); csame b1; assert_eq "$(cout)" "idle" "6: AC_BUSY_RE overrides the default"
cboth cbuf pB1 'a zzz b\n'; csame b1; assert_eq "$(cout)" "busy" "6: ...as the ERE matched"
CENV=(AC_BUSY_RE=); cboth cbuf pB1 'Thinking\n'; csame b1; assert_eq "$(cout)" "busy" "6: an empty AC_BUSY_RE is the default"
CENV=('AC_BUSY_RE=('); csame b1; assert_eq "$(cout)" "idle" "6: an ERE grep refuses is no match"
assert_contains "$(cerr)" "grep" "6: ...grep's own line"
CENV=()
cboth cbuf pB1 'x\nThinking \351\n'
csame b1; assert_eq "$(cout)" "busy" "6: under C a byte that is not UTF-8 on the busy line still matches"
CLC=en_US.UTF-8; csame b1; CLC=C
assert_eq "$CN_RC:$(cout)" "1:" "6: under UTF-8 sed aborts on it - exit 1, nothing on stdout"
assert_contains "$(cerr)" "illegal byte sequence" "6: ...sed's own line"
cboth touch @H/herdr/panes/pB1.read-fails
csame b1; assert_eq "$CN_RC:$(cout)" "1:" "6: a pane read that fails ends the run 1, nothing on stdout"
cboth rm -f @H/herdr/panes/pB1.read-fails
cboth cbuf pB1 'Thinking\n'; cboth cfmt home/state/b1.status 't done: x\n'
csame b1; assert_eq "$(cout)" "busy" "6: busy outranks a status line"
cboth rm -f @H/home/state/b1.status
CENV=(AC_HERDR_SESSION=s1); csame b1; CENV=()
assert_contains "$(cat "$CNH/herdr/log")" "herdr pane read pB1 --source recent --lines 200 --session s1" "6: the session rides the read"
cboth cbuf pB1 'quiet\n'
csame b1
assert_eq "$(cat "$CNH/stdin.log")" "herdr pane get pB1 stdin=caller
herdr pane read pB1 --source recent --lines 200 stdin=null" "6: the probe reads the caller's stdin, the capture /dev/null"

# 7. the status line: the text past its first space; no space passes whole;
#    an empty last line is nothing; a CR kept; a NUL dropped; a long line
#    whole; a file of one LF is not empty; an empty file, a dangling link and
#    a FIFO are idle; a link to a file is followed; a directory counts; an
#    unreadable one is tail's line and nothing; under UTF-8 cut prints nothing
#    for a line holding a byte that is not UTF-8 (W3); the marker survives
#    prefixed (F13); gone outranks a status line; arguments past <id> are
#    never read.
cboth clive t1 pT1
cst() { cboth cfmt home/state/t1.status "$1"; csame t1; }
cst '2026-01-01T00:00:00Z done: x\n'; assert_eq "$(cout)" "status| done: x" "7: the text past the first space"
cst 'a\nnospace\n'; assert_eq "$(cout)" "status| nospace" "7: no space passes whole"
cst 'a b\n\n'; assert_eq "$(cout)" "status| " "7: an empty last line"
cst 't done: x\r\n'; assert_eq "$(cout)" "status| done: x"$'\r' "7: a CR kept"
cst 't a\000b\n'; assert_eq "$(cout)" "status| ab" "7: a NUL dropped"
cst '\n'; assert_eq "$(cout)" "status| " "7: a file of one LF is not empty"
cst ''; assert_eq "$(cout)" "idle" "7: an empty file is idle"
clong="$(printf 'y%.0s' $(seq 1 400))"
cst "t $clong\n"; assert_eq "$(cout)" "status| $clong" "7: a long line whole"
cboth rm -f @H/home/state/t1.status; cboth cfmt real.status 't linked: x\n'; cboth ln -s @H/real.status @H/home/state/t1.status
csame t1; assert_eq "$(cout)" "status| linked: x" "7: a link is followed"
cboth rm -f @H/home/state/t1.status; cboth ln -s @H/nowhere @H/home/state/t1.status
csame t1; assert_eq "$(cout)" "idle" "7: a dangling link is idle"
cboth rm -f @H/home/state/t1.status; cboth mkfifo @H/home/state/t1.status
csame t1; assert_eq "$(cout)" "idle" "7: a FIFO is idle"
cboth rm -f @H/home/state/t1.status; cboth mkdir @H/home/state/t1.status
csame t1; assert_contains "$(cout)" "status| " "7: a directory counts"
cboth rmdir @H/home/state/t1.status
if [ "$(id -u)" != 0 ]; then
  cboth cfmt home/state/t1.status 't x y\n'; cboth chmod 000 @H/home/state/t1.status
  csame t1; assert_eq "$(cout)" "status| " "7: an unreadable status file is an empty rest"
  assert_contains "$(cerr)" "Permission denied" "7: ...and tail's own line"
  cboth chmod 644 @H/home/state/t1.status
fi
CLC=en_US.UTF-8
cst 't caf\351 x\n'; assert_eq "$(cout):$(cerr)" "status| :cut: stdin: Illegal byte sequence" "7 (W3): under UTF-8 cut prints nothing for a byte that is not UTF-8"
cst 't caf\303\251 x\n'; assert_eq "$(cout)" "status| caf"$'\303\251'" x" "7: a UTF-8 line under UTF-8"
CLC=C
cst 't needs-decision: which?\n'; assert_eq "$(cout)" "status| needs-decision: which?" "7 (F13): the marker survives prefixed"
csame t1 extra args; assert_eq "$(cout)" "status| needs-decision: which?" "7: arguments past <id> are never read"
cboth rm -f @H/herdr/panes/pT1.buf @H/herdr/tabs/tpT1
csame t1; assert_eq "$(cout)" "gone" "7: gone outranks a status line"

# 8. an orca task: alive and idle, busy, an exited terminal is gone, an
#    unreachable orca is unobservable with the orca target; every orca call
#    reads the caller's stdin.
cboth corca o1 term1
csame o1; assert_eq "$(cout)" "idle" "8: an orca terminal alive and idle"
assert_eq "$(cat "$CNH/stdin.log")" "orca terminal show --terminal term1 --json stdin=caller
orca terminal read --terminal term1 --limit 40 --screen --json stdin=caller" "8: every orca call reads the caller's stdin"
cboth cfmt orca/terminals/term1.buf 'x\nThinking\n'
csame o1; assert_eq "$(cout)" "busy" "8: busy on orca"
cboth touch @H/orca/terminals/term1.exited
csame o1; assert_eq "$(cout)" "gone" "8: an exited terminal is gone"
cboth rm -f @H/orca/terminals/term1.exited; cboth touch @H/orca/.unreachable
csame o1; assert_eq "$(cout)" "$CUNOBS orca:term1" "8: an unreachable orca"
cboth rm -f @H/orca/.unreachable

# 9. a reader that has closed stdout: the original died of SIGPIPE, the port
#    exits 141 silently.
cclosed() {  # cclosed <bin> <side root> <prefix> - t1 into a pipe whose reader is gone
  (cd "$2" && env -u AC_HOME -u AC_BACKEND -u AC_BUSY_RE LC_ALL=C PATH="$CSTUBS:$TMP/stubbin:$PATH" STUB_DIR="$2" FAKE_HERDR="$2/herdr" \
    AC_HOME="$2/home" "$1/ac-crew-state.sh" t1 <"$CSTDIN" 2>"$TMP/$3.err" | :; printf '%s' "${PIPESTATUS[0]}")
}
assert_eq "$(cclosed "$BIN" "$CNH" n)" "$(cclosed "$cobin" "$COH" o)" "9: the same status into a closed pipe"
assert_eq "$(cclosed "$BIN" "$CNH" n):$(cat "$TMP/n.err")" "141:" "9: 141, silently"
# A stdout closed outright (>&-, no pipe): the state line's write fails and
# ends both 1 - bash's printf with its own `write error` line (SHELL-OWN), the
# port's write with EBADF.
cshut() {  # cshut <bin> <side root> <prefix> - t1 with stdout closed
  (cd "$2" && env -u AC_HOME -u AC_BACKEND -u AC_BUSY_RE LC_ALL=C PATH="$CSTUBS:$TMP/stubbin:$PATH" STUB_DIR="$2" FAKE_HERDR="$2/herdr" \
    AC_HOME="$2/home" bash -c '"$0" t1 >&- 2>"$1"; printf "%s" "$?"' "$1/ac-crew-state.sh" "$TMP/$3.err" <"$CSTDIN")
}
assert_eq "$(cshut "$BIN" "$CNH" n) $(cshut "$cobin" "$COH" o)" "1 1" "9: a closed stdout ends both 1"
assert_contains "$(cat "$TMP/o.err")" "write error: Bad file descriptor" "9: ... at the original's printf"
assert_contains "$(cat "$TMP/n.err")" "EBADF" "9: ... at the port's write"

# 10. Named: argv and the environment arrive decoded. An id holding a byte that
#     is not UTF-8 names no meta on either side (APFS refuses such a name) but
#     the refusal spells it U+FFFD; an AC_BUSY_RE holding one is U+FFFD in
#     grep's argv, so the byte it matched in the window no longer matches.
cpair $'b\351d'; csame_rc_out $'b\351d'; csame_world $'b\351d'
assert_eq "$(coerr)" "ERROR: no crewmate meta for b"$'\351'"d" "10: the original names the raw byte"
assert_eq "$(cerr)" "ERROR: no crewmate meta for b"$'\357\277\275'"d" "10: the port names U+FFFD (named)"
cboth clive e1 pE1; cboth cbuf pE1 'x \351 y\n'
CENV=($'AC_BUSY_RE=\351'); cpair e1; CENV=()
assert_eq "$CO_RC:$(cat "$TMP/o.out")|$CN_RC:$(cout)" "0:busy|0:idle" "10: a byte AC_BUSY_RE matched in the original is U+FFFD in the port (named)"

pass
