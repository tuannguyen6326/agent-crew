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

# --- the view, row by row -------------------------------------------------------
# One side root ($H): a home at $H/home whose state/ each row seeds, the
# caller's cwd $H/cwd, one fake herdr (helpers.sh), stdin /dev/null unless the
# row names a file, LC_ALL=C. HOME in an argument or an env value is $H, and $H
# reads HOME in what the run printed.
make_fake_herdr
make_fake_orca
H="$TMP/side-n"
HOMELESS=0
FV_ENV=()
NBIN="$BIN"
FV_RC=0
view() {  # view <args...> - the shim from $H/${FV_CWD:-cwd}; sets FV_RC
  local x v
  local a=() e=(LC_ALL=C)
  [ "$HOMELESS" = 1 ] || e+=(AC_HOME="$H/home")
  for x in ${FV_ENV[@]+"${FV_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$H}"); done
  for x in "$@"; do a+=("${x//HOME/$H}"); done
  FV_RC=0
  (cd "$H/${FV_CWD:-cwd}" && env -u AC_HOME "${e[@]}" "$NBIN/ac-fleet-view.sh" ${a[@]+"${a[@]}"}) <"${FV_STDIN:-/dev/null}" >"$TMP/n.raw" 2>"$TMP/n.err" || FV_RC=$?
  LC_ALL=C sed -e "s#$H#HOME#g" "$TMP/n.raw" >"$TMP/n.out"
  LC_ALL=C sed -e "s#$H#HOME#g" "$TMP/n.err" >"$TMP/n.err2"
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
shows() {  # shows <stdout> <label> - exit 0, exactly that view, silent on stderr
  assert_eq "$FV_RC:$(shim_out):$(shim_err)" "0:$1:" "$2"
}
fresh() { rm -rf "$H/home" "$H/cwd"; mkdir -p "$H/home/state" "$H/cwd"; }
m() { printf "$2" >"$H/home/state/$1.meta"; }  # m <name> <printf format> - one meta
NO_HOME_LINE="ERROR: $(/usr/bin/grep -m1 -o 'AC_HOME is not set - .*one' "$ROOT/bin/ac-lib.sh")"

# 1. the home: an empty state/ (`no crewmates in flight`); an absent state/ is
#    minted; a state/ that is a regular file is an empty view, exit 0;
#    arguments are never read; homeless is one ERROR line, exit 1; a relative
#    AC_HOME is the caller's cwd's; one that cannot be entered is refused.
fresh
view
shows "no crewmates in flight" "row 1: an empty state/"
rm -rf "$H/home/state"
view
shows "no crewmates in flight" "row 1: an absent state/"
[ -d "$H/home/state" ] || fail "row 1: state/ is minted"
rm -rf "$H/home/state"; printf 'x\n' >"$H/home/state"
view
assert_eq "$FV_RC:$(shim_out)" "0:no crewmates in flight" "row 1: a state/ that is a file is an empty view"
seed1() { fresh; m t1 'kind=ship\nproject=p\nmode=local-only\nwindow=w\n'; }
seed1
view -h extra
shows "t1	ship	p	local-only	gone	w" "row 1: arguments are never read"
HOMELESS=1
view
assert_eq "$FV_RC:$(shim_out):$(shim_err)" "1::$NO_HOME_LINE" "row 1: homeless is ac_home's refusal, once"
FV_ENV=("AC_HOME=home"); FV_CWD=.
view
shows "t1	ship	p	local-only	gone	w" "row 1: a relative AC_HOME resolves from the caller's cwd"
unset FV_CWD
FV_ENV=("AC_HOME=HOME/missing")
view
assert_eq "$FV_RC:$(shim_out):$(shim_err)" "1::ERROR: AC_HOME is not a readable directory: HOME/missing" "row 1: an unenterable AC_HOME names the variable"
FV_ENV=(); HOMELESS=0
# A relative AC_HOME from a caller cwd with no name is refused, never resolved
# inside the distro root bun started in.
gone_rc() {  # gone_rc <AC_HOME> - the entry's exit, run from a deleted cwd
  local rc=0
  mkdir -p "$TMP/gone"
  (cd "$TMP/gone" && rmdir "$TMP/gone" && env -u AC_HOME AC_HOME="$1" LC_ALL=C "$BIN/ac-fleet-view.sh") >/dev/null 2>"$TMP/gone.err" </dev/null || rc=$?
  printf '%s\n' "$rc"
}
for rel in rel .; do
  assert_eq "$(gone_rc "$rel")" "1" "row 1: a relative AC_HOME ($rel) from a nameless cwd exits 1"
  assert_contains "$(cat "$TMP/gone.err")" "ERROR: AC_HOME is not a readable directory: $rel" "row 1: ... and says which ($rel)"
done

# 2. rows: the LAST kind= wins (`ship` then `self`: a self row, detached), a
#    roomchief and a crewdeputy are rows (accounting skips only verify), a
#    verify-only state/ is `no crewmates in flight`, a verify meta beside
#    crew is skipped.
fresh; m k1 'kind=ship\nkind=self\nproject=p\n'; m fam-chief 'kind=roomchief\nproject=fam\n'; m dep1 'kind=crewdeputy\n'; m vfy 'kind=verify-codereview\nproject=p\n'
view
shows $'dep1\tcrewdeputy\t\t\tgone\t\nfam-chief\troomchief\tfam\t\tgone\t\nk1\tself\tp\t\tdetached\t' "row 2: last kind wins; chiefs are rows; verify is skipped"
fresh; m vfy 'kind=verify-codereview\n'
view
shows "no crewmates in flight" "row 2: a verify-only state/"

# 3. values: `window=x=y` is `x=y`, a CR is kept.
fresh; m v1 'kind=ship\nproject=a\nwindow=x=y\n'; m v2 'kind=ship\nproject=p\nmode=m\r\n'
view
shows "v1	ship	a		gone	x=y
v2	ship	p	m$(printf '\r')	gone	" "row 3: x=y, CR kept"

# 4. names: byte order under every locale; `b8.y.meta` is b8.y, `x.meta.meta`
#    is x.meta, a dot name is never listed.
fresh; for n in _u A2 b1 b8.y x.meta .hidden; do m "$n" 'kind=ship\n'; done
view
assert_eq "$FV_RC:$(shim_out | cut -f1)" "0:A2
_u
b1
b8.y
x.meta" "row 4: byte order, one .meta stripped, the dot name absent"
if /usr/bin/grep -qx en_US.UTF-8 <<<"$(locale -a 2>/dev/null)"; then
  FV_ENV=("LC_ALL=en_US.UTF-8")
  view
  FV_ENV=()
  assert_eq "$(shim_out | cut -f1 | tr '\n' ' ')" "A2 _u b1 b8.y x.meta " "row 4: byte order under a UTF-8 locale too"
fi

# 5. the state column is the live ac-crew-state.sh's: a crew-ship step
#    (validate:), a busy pane, an idle pane with a status line, a paneless
#    self task (detached); the backend unreachable (unobservable); an
#    AC_BACKEND crew-state refuses (every row unknown).
live() {  # live <id> <pane buffer> - a handle in state/ and the fake herdr's tab and pane
  printf 'p%s t%s\n' "$1" "$1" >"$H/home/state/.pane-$1"
  printf 'p%s\n' "$1" >"$FAKE_HERDR/tabs/t$1"
  printf '%s\n' "$2" >"$FAKE_HERDR/panes/p$1.buf"
}
fresh; m busy1 'kind=ship\n'; live busy1 "Thinking..."
m stat1 'kind=ship\n'; live stat1 '$ '; printf '2026-01-01T00:00:00Z working: x\n' >"$H/home/state/stat1.status"
m self1 'kind=self\n'
m val1 "kind=ship\nworktree=$H/wt\n"; mkdir -p "$H/wt/.crew/ship/current"; printf 'review\trunning\tr1\n' >"$H/wt/.crew/ship/current/steps.tsv"
view
shows $'busy1\tship\t\t\tbusy\t\nself1\tself\t\t\tdetached\t\nstat1\tship\t\t\tstatus| working: x\t\nval1\tship\t\t\tvalidate:review:running:r1\t' "row 5: crew-state's own lines"
touch "$FAKE_HERDR/.unreachable"
view
rm -f "$FAKE_HERDR/.unreachable"
assert_eq "$FV_RC" "0" "row 5: an unreachable backend still renders"
assert_contains "$(shim_out)" "busy1	ship			unobservable: backend could not be read for herdr:pane-pbusy1	" "row 5: an unreachable backend is unobservable"
FV_ENV=("AC_BACKEND=tmux")
view
FV_ENV=()
assert_eq "$FV_RC:$(shim_out | cut -f5 | sort -u)" "0:unknown" "row 5: a backend crew-state refuses makes every row unknown"

# 6. through a STUB ac-crew-state.sh in a lab copy (bin/ copied, src/ carried
#    as a link): a child killed silently or one that cannot run is unknown,
#    NULs drop and trailing LFs strip, stderr is dropped, and every child
#    reads the CALLER's stdin in row order.
lab="$TMP/lab-fleet-view"; mkdir -p "$lab/bin"; cp "$BIN"/*.sh "$lab/bin/"; ln -s "$ROOT/src" "$lab/src"; ln -s "$ROOT/dashboard" "$lab/dashboard"
NBIN="$lab/bin"
stub_state() { printf '%s\n' '#!/bin/sh' "$1" >"$lab/bin/ac-crew-state.sh"; }
fresh; m t1 'kind=ship\n'; m t2 'kind=ship\n'
stub_state 'kill -TERM $$'; view
shows $'t1\tship\t\t\tunknown\t\nt2\tship\t\t\tunknown\t' "row 6: a child killed silently"
stub_state 'printf "a\0b\n\n\n"; printf "done: x\n" >&2'; view
shows $'t1\tship\t\t\tab\t\nt2\tship\t\t\tab\t' "row 6: NULs dropped, trailing LFs stripped, the child's stderr dropped"
stub_state 'IFS= read -r l; printf "got:%s" "$l"'
printf 'line1\nline2\nline3\n' >"$TMP/stdin10"
FV_STDIN="$TMP/stdin10"; view; unset FV_STDIN
shows $'t1\tship\t\t\tgot:line1\t\nt2\tship\t\t\tgot:line2\t' "row 6: each child reads the caller's stdin in turn"
chmod 644 "$lab/bin/ac-crew-state.sh"; view
shows $'t1\tship\t\t\tunknown\t\nt2\tship\t\t\tunknown\t' "row 6: a crew-state that cannot run is unknown"
NBIN="$BIN"

# 7. a reader that has closed stdout ends the view silently with 141
#    (SIGPIPE); a stdout closed outright (>&-, no pipe) ends it 1.
pipe_rc() {  # pipe_rc - the entry's status with a pipe nobody reads as stdout
  (cd "$H/cwd" && env -u AC_HOME AC_HOME="$H/home" LC_ALL=C python3 -c 'import os, signal, sys
r, w = os.pipe(); os.close(r); os.dup2(w, 1); os.close(w)
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
os.execvp("bash", ["bash", "-c", "\"$0\" 2>\"$1\"; echo $? >&2", sys.argv[1], sys.argv[2]])' "$BIN/ac-fleet-view.sh" "$TMP/pipe.err") 2>&1 </dev/null
}
seed1
assert_eq "$(pipe_rc)" "141" "row 7: a closed reader is 141"
assert_eq "$(cat "$TMP/pipe.err")" "" "row 7: silently"
shut_rc="$(cd "$H/cwd" && env -u AC_HOME AC_HOME="$H/home" LC_ALL=C bash -c '"$0" >&- 2>/dev/null; printf "%s" "$?"' "$BIN/ac-fleet-view.sh" </dev/null)"
assert_eq "$shut_rc" "1" "row 7: a closed stdout is 1"

pass
