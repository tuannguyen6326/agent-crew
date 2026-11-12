#!/usr/bin/env bash
# ac-crew-state.test.sh - the one-line deterministic state renderer: window
# liveness is THREE-STATE (gone/unobservable/alive, contract: ac-backend.sh
# WINDOW LIVENESS) - only a definite rc=1 renders gone, rc=2 must name the
# BACKEND as the unknown instead (F12); and the re-emitted last-status-log
# line must never match a live AC_CAPTAIN_RE marker into whatever pane calls
# this (F13).

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

# --- the contract, row by row ------------------------------------------------
# One root ($H): a home at $H/home, a worktree at $H/wt, the fake herdr's state
# at $H/herdr and the fake orca's at $H/orca. Each run starts at $H with stdin a
# regular file (so the stub log shows which call read the caller's stdin) and
# LC_ALL=C unless a row names en_US.UTF-8; herdr and orca wrappers on PATH log
# each call with the stdin it got and exec make_fake_herdr's and
# make_fake_orca's fakes. stdout and stderr are read with the root spelled @H.
make_fake_orca
H="$TMP/cside"
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
mkdir -p "$H/home/state" "$H/home/config" "$H/wt" "$H/herdr/panes" "$H/herdr/tabs" "$H/orca/terminals"
printf 'off\n' >"$H/home/config/wedge-alarm"
# shellcheck disable=SC2059
cfmt() { mkdir -p "$(dirname "$H/$1")"; printf "${2//@H/$H}" >"$H/$1"; }   # cfmt <path under the root> <printf format, @H the root>
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
CLC=C; CENV=(); CHOMELESS=0; CHOME=home; C_RC=0
crun() {  # crun <args...> - one run; sets C_RC, stdout and stderr in $TMP/n.out and n.err2
  local e=("LC_ALL=$CLC" "PATH=$CSTUBS:$TMP/stubbin:$PATH" "STUB_DIR=$H" "FAKE_HERDR=$H/herdr" "FAKE_ORCA=$H/orca")
  [ "$CHOMELESS" = 1 ] || e+=("AC_HOME=$H/$CHOME")
  rm -f "$H/herdr/log" "$H/orca/log" "$H/stdin.log"
  C_RC=0
  (cd "$H" && env -u AC_HOME -u AC_BACKEND -u AC_FLEET_STATE -u AC_HERDR_SESSION -u AC_HERDR_RPC_TIMEOUT -u AC_BUSY_RE \
    "${e[@]}" ${CENV[@]+"${CENV[@]}"} "$BIN/ac-crew-state.sh" "$@") <"$CSTDIN" >"$TMP/n.raw" 2>"$TMP/n.err" || C_RC=$?
  LC_ALL=C sed -e "s#$H#@H#g" "$TMP/n.raw" >"$TMP/n.out"
  LC_ALL=C sed -e "s#$H#@H#g" "$TMP/n.err" >"$TMP/n.err2"
}
cout() { cat "$TMP/n.out"; }
cerr() { cat "$TMP/n.err2"; }
CUSAGE='ERROR: usage: ac-crew-state.sh <id>'
CBAD="ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)"
CNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
CUNOBS='unobservable: backend could not be read for'

# 1. usage, and the backend gate BEFORE it: none and "" are the usage line;
#    config/backend tmux refuses before the usage check and before the meta;
#    AC_BACKEND=Herdr refuses; config/backend is its first line trimmed, never
#    cut at a blank; the AC_FLEET_STATE rung is cut at its first blank.
crun; assert_eq "$C_RC:$(cout):$(cerr)" "1::$CUSAGE" "1: no argument is the usage line"
crun ""; assert_eq "$C_RC:$(cout):$(cerr)" "1::$CUSAGE" "1: an empty id is the usage line"
cfmt home/config/backend 'tmux\n'
crun; assert_eq "$C_RC:$(cerr)" "1:$CBAD" "1: config/backend tmux refuses before the usage check"
crun c1; assert_eq "$C_RC:$(cerr)" "1:$CBAD" "1: ...and before the meta"
cfmt home/config/backend ' orca extra \n'
crun c1; assert_contains "$(cerr)" "unsupported backend 'orca extra'" "1: config/backend trimmed, never cut at a blank"
rm -f "$H/home/config/backend"
CENV=(AC_BACKEND=Herdr); crun c1; CENV=()
assert_eq "$C_RC:$(cerr)" "1:ERROR: unsupported backend 'Herdr' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "1: AC_BACKEND=Herdr refuses"
cfmt fs/config/backend 'bogus\tx\n'; mkdir -p "$H/fs/state"
CENV=("AC_FLEET_STATE=$H/fs/state/"); crun c1; CENV=()
assert_contains "$(cerr)" "unsupported backend 'bogus'" "1: the AC_FLEET_STATE rung, cut at its first blank"

# 2. the meta: none; a directory named <id>.meta; homeless (the refusal, then
#    the meta line - `/<id>.meta` was read); an AC_HOME that cannot be entered;
#    an unreadable meta.
crun nope; assert_eq "$C_RC:$(cout):$(cerr)" "1::ERROR: no crewmate meta for nope" "2: no meta"
mkdir "$H/home/state/d1.meta"
crun d1; assert_eq "$C_RC:$(cerr)" "1:ERROR: no crewmate meta for d1" "2: a directory is no meta"
CHOMELESS=1
crun c1; assert_eq "$C_RC:$(cerr)" "1:$CNOHOME
ERROR: no crewmate meta for c1" "2: homeless prints the refusal, then the meta line"
crun; assert_eq "$(cerr)" "$CUSAGE" "2: homeless without an id is the usage line alone"
CHOMELESS=0
CHOME=missing
crun c1
assert_eq "$C_RC:$(cout)" "1:" "2: an AC_HOME that cannot be entered ends the run 1"
assert_contains "$(cerr)" "ERROR: AC_HOME is not a readable directory: @H/missing" "2: ...naming the variable"
CHOME=home
if [ "$(id -u)" != 0 ]; then
  cfmt home/state/u1.meta 'backend=herdr\n'; chmod 000 "$H/home/state/u1.meta"
  crun u1; assert_eq "$C_RC:$(cout):$(cerr)" "1::WARN: cannot read meta file @H/home/state/u1.meta" "2: an unreadable meta warns, exit 1"
  chmod 644 "$H/home/state/u1.meta"
fi

# 3. the ship step: the first running/fixing/awaiting_approval row after a
#    passed one, fixing before awaiting_approval, a lone awaiting_approval;
#    only queued/passed rows fall through (no handle: gone); a CR after a
#    third field rides along, a CR ending the status field matches no arm;
#    awk reads a row only to its first NUL; an unreadable steps file ends the
#    run with awk's failure; no worktree=, a missing worktree and a steps
#    DIRECTORY fall through; worktree= cut at a NUL, the last one winning.
CSTEPS=wt/.crew/ship/current/steps.tsv
cfmt home/state/s1.meta 'backend=herdr\nworktree=@H/wt\n'
cfmt $CSTEPS 'lint\tpassed\t1\nreview\trunning\t2\n'
crun s1; assert_eq "$C_RC:$(cout)" "0:validate:review:running:2" "3: the first running row after a passed one"
cfmt $CSTEPS 'a\tfixing\tx\nb\tawaiting_approval\ty\n'
crun s1; assert_eq "$(cout)" "validate:a:fixing:x" "3: fixing first wins"
cfmt $CSTEPS 'b\tawaiting_approval\n'
crun s1; assert_eq "$(cout)" "validate:b:awaiting_approval" "3: a lone awaiting_approval"
cfmt $CSTEPS 'a\tqueued\nb\tpassed\n'
crun s1; assert_eq "$(cout)" "gone" "3: only queued/passed rows fall through to liveness"
cfmt $CSTEPS 'a\trunning\t1\r\n'
crun s1; assert_eq "$(cout)" "validate:a:running:1"$'\r' "3: a CR after the third field rides along"
cfmt $CSTEPS 'a\trunning\r\n'
crun s1; assert_eq "$(cout)" "gone" "3: a CR ending the status field matches no arm"
cfmt $CSTEPS 'x\trunning\ta\000b\n'
crun s1; assert_eq "$(cout)" "validate:x:running:a" "3: awk reads a row only to its first NUL"
cfmt $CSTEPS 'x\000\trunning\n'
crun s1; assert_eq "$(cout)" "gone" "3: ...so a NUL before the status field matches no arm"
if [ "$(id -u)" != 0 ]; then
  cfmt $CSTEPS 'r\trunning\n'; chmod 000 "$H/$CSTEPS"
  crun s1; assert_eq "$(cout)" "" "3: an unreadable steps file renders nothing"
  [ "$C_RC" != 0 ] || fail "3: ...and ends the run with awk's failure"
  chmod 644 "$H/$CSTEPS"
fi
cfmt $CSTEPS 'r\trunning\n'
cfmt home/state/s2.meta 'backend=herdr\n'
crun s2; assert_eq "$(cout)" "gone" "3: no worktree= falls through"
cfmt home/state/s3.meta 'worktree=@H/nowt\n'
crun s3; assert_eq "$(cout)" "gone" "3: a missing worktree falls through"
cfmt home/state/s4.meta 'worktree=@H/nowt\nworktree=@H/wt\000junk\n'
crun s4; assert_eq "$(cout)" "validate:r:running" "3: worktree= cut at a NUL, the last one winning"
rm -rf "$H/wt/.crew"; mkdir -p "$H/$CSTEPS"
crun s1; assert_eq "$(cout)" "gone" "3: a steps directory falls through"
rm -rf "$H/wt/.crew"
rm -rf "$H/wt/.crew"

# 4. no handle (no .pane-<id>, or a blank one): gone; kind=self is detached,
#    exactly - `self<CR>` is gone - the last kind= winning; a self task with
#    a live pane reads its pane; a stale tmux meta is the route's ERROR, exit
#    1, a UTF-8 name refused as its bytes, one that is not UTF-8 as U+FFFD;
#    an orca meta with no handle is gone.
cfmt home/state/k1.meta 'backend=herdr\n'
crun k1; assert_eq "$(cout)" "gone" "4: no handle is gone"
cfmt home/state/k1.meta 'kind=self\n'
crun k1; assert_eq "$(cout)" "detached" "4: a self task with no handle is detached"
cfmt home/state/k1.meta 'kind=self\r\n'
crun k1; assert_eq "$(cout)" "gone" "4: self<CR> is no self"
cfmt home/state/k1.meta 'kind=self\nkind=ship\n'
crun k1; assert_eq "$(cout)" "gone" "4: the last kind= wins"
cfmt home/state/k1.meta 'kind=ship\nkind=self\n'
crun k1; assert_eq "$(cout)" "detached" "4: ...either way"
cfmt home/state/.pane-k1 '\n'
crun k1; assert_eq "$(cout)" "detached" "4: a blank handle is no handle"
clive k2 pK2 'kind=self\n'
crun k2; assert_eq "$(cout)" "idle" "4: a self task with a live pane reads its pane"
cfmt home/state/k1.meta 'backend=tmux\n'
crun k1; assert_eq "$C_RC:$(cout):$(cerr)" "1::$CBAD" "4: a stale tmux meta exits inside the route"
cfmt home/state/k1.meta 'backend=caf\303\251\n'
crun k1; assert_eq "$C_RC:$(cout):$(cerr)" "1::ERROR: unsupported backend 'caf$(printf '\303\251')' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "4: a meta's UTF-8 backend name is refused as its bytes"
cfmt home/state/k1.meta 'backend=caf\351\n'
crun k1
assert_eq "$C_RC:$(cout):$(cerr)" "1::ERROR: unsupported backend 'caf$(printf '\357\277\275')' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "4: a non-UTF-8 backend= is refused as U+FFFD"
cfmt home/state/k1.meta 'backend=orca\n'; rm -f "$H/home/state/.pane-k1"
crun k1; assert_eq "$(cout)" "gone" "4: an orca meta with no handle is gone"
cfmt home/state/k1.meta 'backend=\000orca\n'
crun k1; assert_eq "$C_RC:$(cout)" "0:gone" "4: backend= cut at a NUL is no name: herdr"

# 5. the backend unreadable: unreachable, and the pane api down with the
#    server running, are unobservable with the herdr target; a stopped server
#    holds no panes (gone); a hang past AC_HERDR_RPC_TIMEOUT is unobservable.
clive v1 pV1
touch "$H/herdr/.unreachable"
crun v1; assert_eq "$(cout)" "$CUNOBS herdr:pane-pV1" "5: unreachable"
rm -f "$H/herdr/.unreachable"; touch "$H/herdr/.pane-api-down"
crun v1; assert_eq "$(cout)" "$CUNOBS herdr:pane-pV1" "5: the pane api down, the server running"
rm -f "$H/herdr/.pane-api-down"; touch "$H/herdr/.server-stopped"
crun v1; assert_eq "$(cout)" "gone" "5: a stopped server holds no panes"
rm -f "$H/herdr/.server-stopped"; touch "$H/herdr/.hang"
CENV=(AC_HERDR_RPC_TIMEOUT=1); crun v1; CENV=()
rm -f "$H/herdr/.hang"
kill $(cat "$H/herdr/hang-children" 2>/dev/null) 2>/dev/null || true
assert_eq "$(cout)" "$CUNOBS herdr:pane-pV1" "5: a hang past the ceiling"

# 6. an alive pane: an empty capture is idle; each AC_BUSY_RE arm is busy
#    (`Working…` its three UTF-8 bytes under C); the window: a busy line 25th
#    from the end is busy, 26th is not, one before 15 lines and 15 blanks is
#    (counted after the blanks are gone), one 42nd or 41st from the end of the
#    read is past the 40-line capture, and 40th - trailing blanks cut - is
#    inside it;
#    AC_BUSY_RE overrides, an empty one is the default, a bad ERE is no
#    match; under C a busy line holding a byte that is not UTF-8 matches; a
#    pane read that fails is exit 1, nothing on stdout; busy
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
clive b1 pB1
crun b1; assert_eq "$C_RC:$(cout)" "0:idle" "6: an empty capture is idle"
for cb in 'Thinking' 'still thinking' 'esc to interrupt' '(esc interrupt)' 'Working...' 'Working\342\200\246' 'Ctrl+c:cancel'; do
  cbuf pB1 "x\n$cb\ny\n"
  crun b1; assert_eq "$(cout)" "busy" "6: '$cb' is busy"
done
cwin 24 0; crun b1; assert_eq "$(cout)" "busy" "6: 25th from the end is inside the window"
cwin 25 0; crun b1; assert_eq "$(cout)" "idle" "6: 26th is not"
cwin 15 1; crun b1; assert_eq "$(cout)" "busy" "6: the window is counted after the blank lines are gone"
cwin 21 1; crun b1; assert_eq "$(cout)" "idle" "6: a busy line past the 40-line capture is not seen"
cwin 20 1; crun b1; assert_eq "$(cout)" "busy" "6: the read's trailing blank lines are cut before the 40"
cbuf pB1 "Thinking\n$(printf '\\nl%s\\n' $(seq 0 19))"
crun b1; assert_eq "$(cout)" "idle" "6: 41st from the end of the read is past the capture"
cbuf pB1 'Thinking\n'
CENV=(AC_BUSY_RE=zzz); crun b1; assert_eq "$(cout)" "idle" "6: AC_BUSY_RE overrides the default"
cbuf pB1 'a zzz b\n'; crun b1; assert_eq "$(cout)" "busy" "6: ...as the ERE matched"
CENV=(AC_BUSY_RE=); cbuf pB1 'Thinking\n'; crun b1; assert_eq "$(cout)" "busy" "6: an empty AC_BUSY_RE is the default"
CENV=('AC_BUSY_RE=('); crun b1; assert_eq "$(cout)" "idle" "6: an ERE grep refuses is no match"
CENV=()
cbuf pB1 'x\nThinking \351\n'
crun b1; assert_eq "$(cout)" "busy" "6: under C a byte that is not UTF-8 on the busy line still matches"
touch "$H/herdr/panes/pB1.read-fails"
crun b1; assert_eq "$C_RC:$(cout)" "1:" "6: a pane read that fails ends the run 1, nothing on stdout"
rm -f "$H/herdr/panes/pB1.read-fails"
cbuf pB1 'Thinking\n'; cfmt home/state/b1.status 't done: x\n'
crun b1; assert_eq "$(cout)" "busy" "6: busy outranks a status line"
rm -f "$H/home/state/b1.status"
CENV=(AC_HERDR_SESSION=s1); crun b1; CENV=()
assert_contains "$(cat "$H/herdr/log")" "herdr pane read pB1 --source recent --lines 200 --session s1" "6: the session rides the read"
cbuf pB1 'quiet\n'
crun b1
assert_eq "$(cat "$H/stdin.log")" "herdr pane get pB1 stdin=caller
herdr pane read pB1 --source recent --lines 200 stdin=null" "6: the probe reads the caller's stdin, the capture /dev/null"

# 7. the status line: the text past its first space; no space passes whole;
#    an empty last line is nothing; a CR kept; a NUL dropped; a long line
#    whole; a file of one LF is not empty; an empty file, a dangling link and
#    a FIFO are idle; a link to a file is followed; a directory counts; an
#    unreadable one is an empty rest; the marker survives prefixed (F13); gone outranks a status line; arguments past <id> are
#    never read.
clive t1 pT1
cst() { cfmt home/state/t1.status "$1"; crun t1; }
cst '2026-01-01T00:00:00Z done: x\n'; assert_eq "$(cout)" "status| done: x" "7: the text past the first space"
cst 'a\nnospace\n'; assert_eq "$(cout)" "status| nospace" "7: no space passes whole"
cst 'a b\n\n'; assert_eq "$(cout)" "status| " "7: an empty last line"
cst 't done: x\r\n'; assert_eq "$(cout)" "status| done: x"$'\r' "7: a CR kept"
cst 't a\000b\n'; assert_eq "$(cout)" "status| ab" "7: a NUL dropped"
cst '\n'; assert_eq "$(cout)" "status| " "7: a file of one LF is not empty"
cst ''; assert_eq "$(cout)" "idle" "7: an empty file is idle"
clong="$(printf 'y%.0s' $(seq 1 400))"
cst "t $clong\n"; assert_eq "$(cout)" "status| $clong" "7: a long line whole"
rm -f "$H/home/state/t1.status"; cfmt real.status 't linked: x\n'; ln -s "$H/real.status" "$H/home/state/t1.status"
crun t1; assert_eq "$(cout)" "status| linked: x" "7: a link is followed"
rm -f "$H/home/state/t1.status"; ln -s "$H/nowhere" "$H/home/state/t1.status"
crun t1; assert_eq "$(cout)" "idle" "7: a dangling link is idle"
rm -f "$H/home/state/t1.status"; mkfifo "$H/home/state/t1.status"
crun t1; assert_eq "$(cout)" "idle" "7: a FIFO is idle"
rm -f "$H/home/state/t1.status"; mkdir "$H/home/state/t1.status"
crun t1; assert_contains "$(cout)" "status| " "7: a directory counts"
rmdir "$H/home/state/t1.status"
if [ "$(id -u)" != 0 ]; then
  cfmt home/state/t1.status 't x y\n'; chmod 000 "$H/home/state/t1.status"
  crun t1; assert_eq "$(cout)" "status| " "7: an unreadable status file is an empty rest"
  chmod 644 "$H/home/state/t1.status"
fi
CLC=en_US.UTF-8
cst 't caf\303\251 x\n'; assert_eq "$(cout)" "status| caf"$'\303\251'" x" "7: a UTF-8 line under UTF-8"
CLC=C
cst 't needs-decision: which?\n'; assert_eq "$(cout)" "status| needs-decision: which?" "7 (F13): the marker survives prefixed"
crun t1 extra args; assert_eq "$(cout)" "status| needs-decision: which?" "7: arguments past <id> are never read"
rm -f "$H/herdr/panes/pT1.buf" "$H/herdr/tabs/tpT1"
crun t1; assert_eq "$(cout)" "gone" "7: gone outranks a status line"

# 8. an orca task: alive and idle, busy, an exited terminal is gone, an
#    unreachable orca is unobservable with the orca target; every orca call
#    reads the caller's stdin.
corca o1 term1
crun o1; assert_eq "$(cout)" "idle" "8: an orca terminal alive and idle"
assert_eq "$(cat "$H/stdin.log")" "orca terminal show --terminal term1 --json stdin=caller
orca terminal read --terminal term1 --limit 40 --screen --json stdin=caller" "8: every orca call reads the caller's stdin"
cfmt orca/terminals/term1.buf 'x\nThinking\n'
crun o1; assert_eq "$(cout)" "busy" "8: busy on orca"
touch "$H/orca/terminals/term1.exited"
crun o1; assert_eq "$(cout)" "gone" "8: an exited terminal is gone"
rm -f "$H/orca/terminals/term1.exited"; touch "$H/orca/.unreachable"
crun o1; assert_eq "$(cout)" "$CUNOBS orca:term1" "8: an unreachable orca"
rm -f "$H/orca/.unreachable"

# 9. a reader that has closed stdout: exit 141, silently.
cclosed() {  # cclosed - t1 into a pipe whose reader is gone
  (cd "$H" && env -u AC_HOME -u AC_BACKEND -u AC_BUSY_RE LC_ALL=C PATH="$CSTUBS:$TMP/stubbin:$PATH" STUB_DIR="$H" FAKE_HERDR="$H/herdr" \
    AC_HOME="$H/home" "$BIN/ac-crew-state.sh" t1 <"$CSTDIN" 2>"$TMP/n.err" | :; printf '%s' "${PIPESTATUS[0]}")
}
assert_eq "$(cclosed):$(cat "$TMP/n.err")" "141:" "9: 141, silently"

# 10. argv arrives decoded: an id holding a byte that is not UTF-8 names no
#     meta, and the refusal spells it U+FFFD.
crun $'b\351d'
assert_eq "$C_RC:$(cout):$(cerr)" "1::ERROR: no crewmate meta for b"$'\357\277\275'"d" "10: a non-UTF-8 id is refused as U+FFFD"

pass
