#!/usr/bin/env bash
# ac-fleet-view.test.sh - accounting excludes verification agents from
# crewmate rows (contract: ac_crew_metas "verify" skip-class, bin/ac-lib.sh -
# the same class dashboard-verifier-kind-hardcode/ac-dash-crew-heading-
# swallows-verifiers fixed for the OTHER two fleet views).

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

printf 'kind=ship\nproject=alpha\nmode=local-only\nwindow=w1\nbackend=herdr\n' >"$AC_HOME/state/crew1.meta"
printf 'kind=verify-codereview\nproject=alpha\nbackend=herdr\n' >"$AC_HOME/state/vfy1.meta"

# A self task with no live pane is DETACHED (the tail died with its session,
# the slice did not); a crewmate in the same shape is GONE.
printf 'kind=self\nproject=alpha\nmode=local-only\nbackend=herdr\n' >"$AC_HOME/state/self1.meta"
printf 'kind=ship\nproject=alpha\nmode=local-only\nbackend=herdr\n' >"$AC_HOME/state/crew2.meta"
out="$("$BIN/ac-fleet-view.sh")"
assert_contains "$out" "crew1" "an ordinary crewmate still renders its row"
assert_contains "$out" "self1	self	alpha	local-only	detached" "a paneless self task reads detached"
assert_contains "$out" "crew2	ship	alpha	local-only	gone" "a paneless crewmate still reads gone"
case "$out" in *vfy1*) fail "a verify-* pane agent must not render as a crewmate row: $out" ;; esac

# --- differential: src/fleet-view.ts against the frozen bash original ---------
# DISPUTED: the implementation (tests/fixtures/ac-fleet-view.sh under bash vs src/fleet-view.ts through bin/ac-fleet-view.sh)
# HELD-CONSTANT: two side roots seeded alike ($OH for the oracle, $NH for the shim) - a home at <side>/home whose state/ one function per row seeds, the caller's cwd <side>/cwd - one fake herdr both sides read (helpers.sh), the live ac-crew-state.sh beside each entry (the oracle bin's copy, $BIN's own; a row that stubs it stubs both), argv, env (the side root spelled HOME), stdin (/dev/null unless the row names a file), LC_ALL=C on both sides; exit status, stdout and stderr (the side root spelled HOME) compared whole.
make_fake_herdr
make_fake_orca
obin="$(make_oracle_bin ac-fleet-view)"
OH="$TMP/side-o"; NH="$TMP/side-n"
HOMELESS=0
FV_ENV=()
run_side() {  # run_side <bin> <side root> <prefix> <args...> - HOME in an arg or an env value is that side's root; cwd is <side>/${FV_CWD:-cwd}
  local bin="$1" h="$2" p="$3" x v; shift 3
  local a=() e=(LC_ALL=C)
  [ "$HOMELESS" = 1 ] || e+=(AC_HOME="$h/home")
  for x in ${FV_ENV[@]+"${FV_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$h}"); done
  for x in "$@"; do a+=("${x//HOME/$h}"); done
  (cd "$h/${FV_CWD:-cwd}" && env -u AC_HOME "${e[@]}" "$bin/ac-fleet-view.sh" ${a[@]+"${a[@]}"}) <"${FV_STDIN:-/dev/null}" >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
norm() { LC_ALL=C sed -e "s#$2#HOME#g" "$1"; }
compare() {  # compare <o_rc> <n_rc> <what> - both sides' answers, normalized, byte-identical
  norm "$TMP/o.raw" "$OH" >"$TMP/o.out"; norm "$TMP/o.err" "$OH" >"$TMP/o.err2"
  norm "$TMP/n.raw" "$NH" >"$TMP/n.out"; norm "$TMP/n.err" "$NH" >"$TMP/n.err2"
  assert_eq "$2" "$1" "differential exit for $3"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for $3: $(diff "$TMP/o.out" "$TMP/n.out" | head -n 6)"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "differential stderr differs for $3: $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 4)"
}
NBIN="$BIN"
same() {  # same <args...> - the oracle on $OH and the shim on $NH answer byte-identically
  local o_rc=0 n_rc=0
  run_side "$obin" "$OH" o "$@" || o_rc=$?
  run_side "$NBIN" "$NH" n "$@" || n_rc=$?
  compare "$o_rc" "$n_rc" "'$*' (${FV_ENV[*]+${FV_ENV[*]}}) at line ${BASH_LINENO[0]}"
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
both() {  # both <fn> <args...> - run a seeding step with H at each side root
  local h; for h in "$OH" "$NH"; do H="$h"; "$@"; done
}
fresh() { rm -rf "$H/home" "$H/cwd"; mkdir -p "$H/home/state" "$H/cwd"; }
m() { printf "$2" >"$H/home/state/$1.meta"; }  # m <name> <printf format> - one meta
NO_HOME_LINE="ERROR: $(/usr/bin/grep -m1 -o 'AC_HOME is not set - .*one' "$ROOT/bin/ac-lib.sh")"

# 1. the home: an empty state/ (`no crewmates in flight`); an absent state/ is
#    minted; a state/ that is a regular file is mkdir's own line and an empty
#    view, exit 0; arguments are never read; homeless is one ERROR line, exit
#    1; a relative AC_HOME is the caller's cwd's.
both fresh
same
assert_eq "$(shim_out)" "no crewmates in flight" "row 1: an empty state/"
rmstate() { rm -rf "$H/home/state"; }
both rmstate
same
[ -d "$OH/home/state" ] && [ -d "$NH/home/state" ] || fail "row 1: state/ is minted on both sides"
filestate() { rm -rf "$H/home/state"; printf 'x\n' >"$H/home/state"; }
both filestate
same
assert_eq "$(shim_err)" "mkdir: HOME/home/state: File exists" "row 1: a state/ that is a file is mkdir's own line"
assert_eq "$(shim_out)" "no crewmates in flight" "row 1: ... and the view goes on"
seed1() { fresh; m t1 'kind=ship\nproject=p\nmode=local-only\nwindow=w\n'; }
both seed1
same -h extra
assert_eq "$(shim_out)" "t1	ship	p	local-only	gone	w" "row 1: arguments are never read"
HOMELESS=1
same
assert_eq "$(shim_err)" "$NO_HOME_LINE" "row 1: homeless is ac_home's refusal, once"
assert_eq "$(shim_out)" "" "row 1: homeless prints nothing on stdout"
FV_ENV=("AC_HOME=home"); FV_CWD=.
same
assert_eq "$(shim_out)" "t1	ship	p	local-only	gone	w" "row 1: a relative AC_HOME resolves from the caller's cwd"
FV_ENV=(); unset FV_CWD
# Named (HOME RESOLUTION): an AC_HOME that cannot be entered exits 1 on both
# sides; the original's line is the shell's own `cd:`, the port names the
# variable.
FV_ENV=("AC_HOME=HOME/missing")
o_rc=0; run_side "$obin" "$OH" o || o_rc=$?
n_rc=0; run_side "$NBIN" "$NH" n || n_rc=$?
FV_ENV=(); HOMELESS=0
assert_eq "$n_rc $o_rc" "1 1" "row 1: an unenterable AC_HOME exits 1 on both sides"
assert_contains "$(cat "$TMP/o.err")" "No such file or directory" "row 1: the original's line is cd's own"
assert_eq "$(norm "$TMP/n.err" "$NH")" "ERROR: AC_HOME is not a readable directory: HOME/missing" "row 1: the port names the variable (named)"
assert_eq "$(cat "$TMP/o.raw" "$TMP/n.raw")" "" "row 1: nothing on stdout"
# Named: a relative AC_HOME from a caller cwd with no name exits 1 on both
# sides for a name that is not there; for `.` the original printed the
# shell's getcwd lines and an empty view (exit 0), the port refuses it rather
# than resolve it inside the distro root bun started in.
gone_rc() {  # gone_rc <bin> <AC_HOME> - the entry's exit, run from a deleted cwd
  local rc=0
  mkdir -p "$TMP/gone"
  (cd "$TMP/gone" && rmdir "$TMP/gone" && env -u AC_HOME AC_HOME="$2" LC_ALL=C "$1/ac-fleet-view.sh") >/dev/null 2>"$TMP/gone.err" </dev/null || rc=$?
  printf '%s\n' "$rc"
}
assert_eq "$(gone_rc "$obin" rel) $(gone_rc "$NBIN" rel)" "1 1" "row 1: a relative AC_HOME from a nameless cwd exits 1 on both sides"
assert_eq "$(gone_rc "$NBIN" .)" "1" "row 1: the port never resolves a relative AC_HOME inside the distro root (named)"
assert_contains "$(cat "$TMP/gone.err")" "ERROR: AC_HOME is not a readable directory: ." "row 1: ... and says which"

# 2. rows: the LAST kind= wins (`ship` then `self`: a self row, detached), a
#    roomchief and a crewdeputy are rows (accounting skips only verify), a
#    verify-only state/ is `no crewmates in flight`, a verify meta beside
#    crew is skipped.
seed2() { fresh; m k1 'kind=ship\nkind=self\nproject=p\n'; m fam-chief 'kind=roomchief\nproject=fam\n'; m dep1 'kind=crewdeputy\n'; m vfy 'kind=verify-codereview\nproject=p\n'; }
both seed2
same
assert_eq "$(shim_out)" $'dep1\tcrewdeputy\t\t\tgone\t\nfam-chief\troomchief\tfam\t\tgone\t\nk1\tself\tp\t\tdetached\t' "row 2: last kind wins; chiefs are rows; verify is skipped"
vfyonly() { fresh; m vfy 'kind=verify-codereview\n'; }
both vfyonly
same
assert_eq "$(shim_out)" "no crewmates in flight" "row 2: a verify-only state/"

# 3. values: a TAB kept raw shifts the columns (W8), `window=x=y` is `x=y`,
#    a value is cut at its first NUL (W7), a CR is kept.
seed3() { fresh; m v1 'kind=ship\nproject=a\tb\nwindow=x=y\n'; m v2 'kind=sh\0ip\nproject=p\0q\nmode=m\r\n'; }
both seed3
same
assert_eq "$(shim_out)" "v1	ship	a	b		gone	x=y
v2	sh	p	m$(printf '\r')	gone	" "row 3: TAB raw, x=y, NUL cut, CR kept"

# 4. names: byte order under LC_ALL=C; `b8.y.meta` is b8.y, `x.meta.meta` is
#    x.meta, a dot name is never listed. W9 (named): under a UTF-8 locale the
#    original's glob followed libc collation, the port keeps byte order.
seed4() { fresh; for n in _u A2 b1 b8.y x.meta .hidden; do m "$n" 'kind=ship\n'; done; }
both seed4
same
assert_eq "$(shim_out | cut -f1)" "A2
_u
b1
b8.y
x.meta" "row 4: byte order, one .meta stripped, the dot name absent"
if /usr/bin/grep -qx en_US.UTF-8 <<<"$(locale -a 2>/dev/null)"; then
  utf_ids() { (cd "$2/cwd" && env -u AC_HOME AC_HOME="$2/home" LC_ALL=en_US.UTF-8 "$1/ac-fleet-view.sh" </dev/null | cut -f1 | tr '\n' ' '); }
  assert_eq "$(utf_ids "$obin" "$OH")" "_u A2 b1 b8.y x.meta " "row 4 (W9): the original under UTF-8 follows collation"
  assert_eq "$(utf_ids "$NBIN" "$NH")" "A2 _u b1 b8.y x.meta " "row 4 (W9): the port keeps byte order (named)"
fi

# 5. W1: a dangling symlink sorting FIRST hides every meta; W4: one sorting
#    later is a row of empty fields reading unknown.
seed5() { fresh; m a1 'kind=ship\n'; m c3 'kind=ship\n'; ln -s nowhere "$H/home/state/0dangle.meta"; }
both seed5
same
assert_eq "$(shim_out)" "no crewmates in flight" "row 5 (W1): a dangling first entry blanks the view"
seed5b() { rm "$H/home/state/0dangle.meta"; ln -s nowhere "$H/home/state/z9dangle.meta"; }
both seed5b
same
assert_eq "$(shim_out)" $'a1\tship\t\t\tgone\t\nc3\tship\t\t\tgone\t\nz9dangle\t\t\t\tunknown\t' "row 5 (W4): a later dangling meta is a kind-less unknown row"

# 6. W2: a directory named b2.meta aborts awk there - awk's two lines on
#    stderr, every meta after it lost, exit 0.
seed6() { fresh; m a1 'kind=ship\n'; mkdir "$H/home/state/b2.meta"; m c3 'kind=ship\n'; }
both seed6
same
assert_eq "$(shim_out)" "a1	ship			gone	" "row 6 (W2): only the metas before the directory"
assert_eq "$(shim_err)" "awk: i/o error occurred on HOME/home/state/b2.meta
 source line number 7" "row 6 (W2): awk's own lines"

# 7. W5: an unreadable meta between two good ones - four WARNs, a row of
#    empty fields reading unknown.
if [ "$(id -u)" != 0 ]; then
  seed7() { fresh; m a1 'kind=ship\n'; m b5 'kind=ship\n'; chmod 000 "$H/home/state/b5.meta"; m c3 'kind=ship\n'; }
  both seed7
  same
  unseed7() { chmod 644 "$H/home/state/b5.meta"; }
  both unseed7
  assert_eq "$(shim_out)" $'a1\tship\t\t\tgone\t\nb5\t\t\t\tunknown\t\nc3\tship\t\t\tgone\t' "row 7 (W5): the unreadable row still prints"
  w="WARN: cannot read meta file HOME/home/state/b5.meta"
  assert_eq "$(shim_err)" "$w
$w
$w
$w" "row 7 (W5): one WARN per field read"
fi

# 8. W6: `b7<LF>x.meta` arrives as `<state>/b7` and a relative `x.meta`, read
#    from the caller's cwd - with an x.meta there, and without.
seed8() { fresh; m a1 'kind=ship\n'; printf 'kind=ship\nproject=lf\n' >"$H/home/state/b7
x.meta"; }
both seed8
same
assert_eq "$(shim_out)" $'a1\tship\t\t\tgone\t\nb7\t\t\t\tunknown\t\nx\t\t\t\tunknown\t' "row 8 (W6): an LF-named meta is two kind-less rows"
cwdx() { printf 'kind=FROMCWD\nproject=cwdproj\n' >"$H/cwd/x.meta"; }
both cwdx
same
assert_contains "$(shim_out)" "x	FROMCWD	cwdproj		unknown	" "row 8 (W6): the second half reads the caller's cwd"
# The halves are named by basename's rules: `<LF>l1.meta` leaves `<state>/`,
# whose basename is the state dir's own name; `y<LF>.meta` leaves `.meta`,
# which is no suffix of itself.
seed8b() { fresh; printf 'kind=ship\n' >"$H/home/state/
l1.meta"; printf 'kind=ship\n' >"$H/home/state/y
.meta"; }
both seed8b
same
assert_eq "$(shim_out)" $'state\t\t\t\tunknown\t\nl1\t\t\t\tunknown\t\ny\t\t\t\tunknown\t\n.meta\t\t\t\tunknown\t' "row 8 (W6): the halves' ids are basename's"
# NAMED: a half led by `-` is a row of its own here, where the original's
# basename read it as an option and errexit ended the run before c3.
seed8c() { fresh; m a1 'kind=ship\n'; printf 'kind=ship\n' >"$H/home/state/b7
-x.meta"; m c3 'kind=ship\n'; }
both seed8c
o_rc=0; n_rc=0
run_side "$obin" "$OH" o || o_rc=$?
run_side "$NBIN" "$NH" n || n_rc=$?
assert_eq "$o_rc $n_rc" "1 0" "row 8 (W6): a dash-led half - the original's exit, the port's"
assert_eq "$(cat "$TMP/o.raw")" $'a1\tship\t\t\tgone\t\nb7\t\t\t\tunknown\t' "row 8 (W6): the original stopped at the dash-led half"
assert_contains "$(cat "$TMP/o.err")" "basename" "row 8 (W6): basename's own lines on the original"
assert_eq "$(cat "$TMP/n.raw")" $'a1\tship\t\t\tgone\t\nb7\t\t\t\tunknown\t\n-x\t\t\t\tunknown\t\nc3\tship\t\t\tgone\t' "row 8 (W6): the port renders it and goes on"

# 9. the state column is the live ac-crew-state.sh's: a crew-ship step
#    (validate:), a busy pane, an idle pane with a status line, a paneless
#    self task (detached); the backend unreachable (unobservable); an
#    AC_BACKEND crew-state refuses (every row unknown).
live() {  # live <id> <pane buffer> - a handle in state/ and the fake herdr's tab and pane
  printf 'p%s t%s\n' "$1" "$1" >"$H/home/state/.pane-$1"
  printf 'p%s\n' "$1" >"$FAKE_HERDR/tabs/t$1"
  printf '%s\n' "$2" >"$FAKE_HERDR/panes/p$1.buf"
}
seed9() {
  fresh; m busy1 'kind=ship\n'; live busy1 "Thinking..."
  m stat1 'kind=ship\n'; live stat1 '$ '; printf '2026-01-01T00:00:00Z working: x\n' >"$H/home/state/stat1.status"
  m self1 'kind=self\n'
  m val1 "kind=ship\nworktree=$H/wt\n"; mkdir -p "$H/wt/.crew/ship/current"; printf 'review\trunning\tr1\n' >"$H/wt/.crew/ship/current/steps.tsv"
}
both seed9
same
assert_eq "$(shim_out)" $'busy1\tship\t\t\tbusy\t\nself1\tself\t\t\tdetached\t\nstat1\tship\t\t\tstatus| working: x\t\nval1\tship\t\t\tvalidate:review:running:r1\t' "row 9: crew-state's own lines"
touch "$FAKE_HERDR/.unreachable"
same
rm -f "$FAKE_HERDR/.unreachable"
assert_contains "$(shim_out)" "busy1	ship			unobservable: backend could not be read for herdr:pane-pbusy1	" "row 9: an unreachable backend is unobservable"
FV_ENV=("AC_BACKEND=tmux")
same
FV_ENV=()
assert_eq "$(shim_out | cut -f5 | sort -u)" "unknown" "row 9: a backend crew-state refuses makes every row unknown"

# 10. W10, through a STUB ac-crew-state.sh in the oracle's bin and in a
#     shim-side lab copy (bin/ copied, src/ carried as a link - the TEST
#     MECHANICS rule): text then a failure is `<text>unknown`, a signal is a
#     failure, NULs drop and trailing LFs strip, stderr is dropped, a
#     crew-state that cannot run is unknown, and every child reads the
#     CALLER's stdin in row order.
lab="$TMP/lab-fleet-view"; mkdir -p "$lab/bin"; cp "$BIN"/*.sh "$lab/bin/"; ln -s "$ROOT/src" "$lab/src"; ln -s "$ROOT/dashboard" "$lab/dashboard"
NBIN="$lab/bin"
stub_state() { printf '%s\n' '#!/bin/sh' "$1" >"$obin/ac-crew-state.sh"; printf '%s\n' '#!/bin/sh' "$1" >"$lab/bin/ac-crew-state.sh"; }
seed10() { fresh; m t1 'kind=ship\n'; m t2 'kind=ship\n'; }
both seed10
stub_state 'printf half; exit 3'; same
assert_contains "$(shim_out)" "t1	ship			halfunknown	" "row 10 (W10): text then a failure"
stub_state 'printf part; kill -TERM $$'; same
assert_contains "$(shim_out)" "t1	ship			partunknown	" "row 10 (W10): a signal is a failure"
stub_state 'kill -TERM $$'; same
assert_contains "$(shim_out)" "t1	ship			unknown	" "row 10: a child killed silently"
stub_state 'printf "a\0b\n\n\n"; printf "done: x\n" >&2'; same
assert_contains "$(shim_out)" "t1	ship			ab	" "row 10: NULs dropped, trailing LFs stripped"
assert_eq "$(shim_err)" "" "row 10: the child's stderr is dropped"
stub_state 'IFS= read -r l; printf "got:%s" "$l"'
printf 'line1\nline2\nline3\n' >"$TMP/stdin10"
FV_STDIN="$TMP/stdin10"; same; unset FV_STDIN
assert_eq "$(shim_out)" $'t1\tship\t\t\tgot:line1\t\nt2\tship\t\t\tgot:line2\t' "row 10: each child reads the caller's stdin in turn"
chmod 644 "$obin/ac-crew-state.sh" "$lab/bin/ac-crew-state.sh"; same
assert_contains "$(shim_out)" "t1	ship			unknown	" "row 10: a crew-state that cannot run is unknown"
cp "$BIN/ac-crew-state.sh" "$obin/ac-crew-state.sh"; cp "$BIN/ac-crew-state.sh" "$lab/bin/ac-crew-state.sh"
chmod 755 "$obin/ac-crew-state.sh" "$lab/bin/ac-crew-state.sh"
NBIN="$BIN"

# 11. W3, bounded: a FIFO named b2.meta holds awk in its open - both sides
#     print the rows before it and wait; a writer that closes at once then
#     releases each awk (an empty, kind-less meta) and both finish alike, so no
#     awk is left behind.
seed11() { fresh; m a1 'kind=ship\n'; mkfifo "$H/home/state/b2.meta"; m c3 'kind=ship\n'; }
both seed11
o_rc=0; n_rc=0
run_side "$obin" "$OH" o & opid=$!
run_side "$NBIN" "$NH" n & npid=$!
held() {  # held <raw stdout> - the a1 row arrived within ~20 s
  local i=0
  until /usr/bin/grep -q '^a1' "$1" 2>/dev/null; do i=$((i + 1)); [ "$i" -lt 200 ] || return 1; sleep 0.1; done
}
o_held=0; held "$TMP/o.raw" || o_held=1
n_held=0; held "$TMP/n.raw" || n_held=1
cp "$TMP/o.raw" "$TMP/o.part"; cp "$TMP/n.raw" "$TMP/n.part"
writers=""
for f in "$OH/home/state/b2.meta" "$NH/home/state/b2.meta"; do (: >"$f") & writers="$writers $!"; done
wait "$opid" || o_rc=$?
wait "$npid" || n_rc=$?
for w in $writers; do kill "$w" 2>/dev/null || true; done
assert_eq "$o_held $n_held" "0 0" "row 11 (W3): both sides render the rows before the FIFO"
assert_eq "$(cat "$TMP/n.part")" "$(cat "$TMP/o.part")" "row 11 (W3): the same rows while awk waits"
assert_eq "$(cat "$TMP/n.part")" "a1	ship			gone	" "row 11 (W3): only the rows before the FIFO"
compare "$o_rc" "$n_rc" "row 11 (W3) once released"
assert_eq "$(shim_out)" $'a1\tship\t\t\tgone\t\nb2\t\t\t\tunknown\t\nc3\tship\t\t\tgone\t' "row 11 (W3): the released view"

# 12. a reader that has closed stdout ends both silently with 141 (SIGPIPE).
pipe_rc() {  # pipe_rc <bin> <side root> - the entry's status with a pipe nobody reads as stdout
  (cd "$2/cwd" && env -u AC_HOME AC_HOME="$2/home" LC_ALL=C python3 -c 'import os, signal, sys
r, w = os.pipe(); os.close(r); os.dup2(w, 1); os.close(w)
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
os.execvp("bash", ["bash", "-c", "\"$0\" 2>\"$1\"; echo $? >&2", sys.argv[1], sys.argv[2]])' "$1/ac-fleet-view.sh" "$TMP/pipe.err") 2>&1 </dev/null
}
both seed1
assert_eq "$(pipe_rc "$obin" "$OH") $(pipe_rc "$NBIN" "$NH")" "141 141" "row 12: a closed reader is 141 on both sides"
assert_eq "$(cat "$TMP/pipe.err")" "" "row 12: silently"
# A stdout closed outright (>&-, no pipe): the first row's write fails and ends
# both 1 - bash's printf with its own `write error` line (SHELL-OWN), the
# port's write with EBADF.
shut_rc() {  # shut_rc <bin> <side root> <side> - the entry's status with stdout closed
  (cd "$2/cwd" && env -u AC_HOME AC_HOME="$2/home" LC_ALL=C bash -c '"$0" >&- 2>"$1"; printf "%s" "$?"' "$1/ac-fleet-view.sh" "$TMP/shut.$3") </dev/null
}
assert_eq "$(shut_rc "$obin" "$OH" o) $(shut_rc "$NBIN" "$NH" n)" "1 1" "row 12: a closed stdout is 1 on both sides"
assert_contains "$(cat "$TMP/shut.o")" "write error: Bad file descriptor" "row 12: ... at the original's printf"
assert_contains "$(cat "$TMP/shut.n")" "EBADF" "row 12: ... at the port's write"

pass
