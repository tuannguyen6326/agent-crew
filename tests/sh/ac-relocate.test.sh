#!/usr/bin/env bash
# ac-relocate.test.sh - family-workspace relocation: idle-only guard,
# herdr-only, adopt-by-label target resolution (FAMILY WORKSPACE GROUPING),
# session resume in the new tab, handle/meta updates, no-op when already
# in the target workspace.
# shellcheck disable=SC2016  # script bodies are deliberately unexpanded here

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

command -v jq >/dev/null || skip 'jq not available'

make_home
stub="$TMP/stubbin"
mkdir -p "$stub"
export HDLOG="$TMP/hd.log" HDSTATE="$TMP/hd.state"
printf 'idle\n' >"$HDSTATE"
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "tab get") printf '{"result":{"tab":{"tab_id":"%s","agent_status":"%s"}}}\n' "$3" "$(cat "$HDSTATE")" ;;
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wC","label":"%s · famR","tab_count":2}]}}\n' "$AC_TEST_FLEET" ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"wC:tN"},"root_pane":{"pane_id":"pNEW"}}}' ;;
  # verified sends probe by capture-change: the render must react per call
  # (the log grows on every CLI hit) or every submit would read as stranded.
  "pane read") printf 'r%s\n' "$(wc -l <"$HDLOG")" ;;
esac
exit 0
EOF
chmod +x "$stub/herdr"

relocate() { PATH="$stub:$PATH" AC_TEST_FLEET="$fleet" AC_SPAWN_SETTLE=0 "$BIN/ac-relocate.sh" "$@"; }

fleet="$(basename "$AC_HOME")"
mkdir -p "$AC_HOME/data/famR/chief"   # ac_family_of_id trusts -chief only with the nested dir
cat >"$AC_HOME/state/famR-chief.meta" <<EOF
backend=herdr
kind=roomchief
project=famR
worktree=/tmp
session_id=sid-123
EOF
printf 'p1 wA:t1\n' >"$AC_HOME/state/.pane-famR-chief"

# Refusals: unknown task, busy agent.
assert_fails relocate nosuchtask
printf 'working\n' >"$HDSTATE"
assert_fails relocate famR-chief
printf 'idle\n' >"$HDSTATE"

# Happy path: default target for famR-chief is famR's OWN family workspace,
# adopted by label; old tab closed, new tab there, handles/meta updated,
# session resumed with scope, watcher re-arm notice delivered.
out="$(relocate famR-chief)"
assert_contains "$out" "relocated famR-chief group=famR" "relocation reported"
log="$(cat "$HDLOG")"
assert_contains "$log" "tab close wA:t1" "old tab closed"
assert_contains "$log" "tab create --workspace wC" "created in the adopted family workspace"
assert_contains "$log" "AC_HOME=/tmp AC_SCOPE=famR claude --resume sid-123" "session resumed with home and scope"
assert_contains "$log" 'AC_WATCH_ONLY=$(bin/ac-ready.sh watch-set famR)' "watcher re-arm notice computes the story set"
assert_eq "$(cat "$AC_HOME/state/.pane-famR-chief")" "pNEW wC:tN" "handle updated"
assert_contains "$(cat "$AC_HOME/state/famR-chief.meta")" "window=herdr:pane-pNEW" "meta updated"

# A domainchief (an ordinary roomchief whose meta carries domain=<name>) must
# resume with AC_DOMAIN too, riding after AC_SCOPE - the ac-spawn.sh roomchief path's
# own ordering for the launch line. The needle runs contiguously through the
# part that changes, same shape as the AC_HOME/AC_SCOPE assertion above: a
# substring match that stops short of "claude --resume" would stay green
# whether or not AC_DOMAIN was ever added.
cat >"$AC_HOME/state/famD-chief.meta" <<EOF
backend=herdr
kind=roomchief
project=famD
domain=domD
worktree=/tmp
session_id=sid-999
EOF
printf 'p1 wB:t9\n' >"$AC_HOME/state/.pane-famD-chief"
relocate famD-chief --family famR >/dev/null
log="$(cat "$HDLOG")"
assert_contains "$log" "AC_HOME=/tmp AC_SCOPE=famD AC_DOMAIN=domD claude --resume sid-999" \
  "domainchief session resumed with home, scope and domain"

# Already in the target workspace: no-op success.
out="$(relocate famR-chief)"
assert_contains "$out" "already in group famR" "no-op when already there"

# No session_id -> refuse; non-herdr backend -> refuse.
cat >"$AC_HOME/state/nosid.meta" <<EOF
backend=herdr
kind=ship
worktree=/tmp
EOF
printf 'p2 wA:t2\n' >"$AC_HOME/state/.pane-nosid"
assert_fails relocate nosid
printf 'backend=tmux\nkind=ship\nworktree=/tmp\nsession_id=s\n' >"$AC_HOME/state/tm1.meta"
assert_fails relocate tm1

# --- the two steers are DIAGNOSED, never a bare errexit abort ------------------
# Contract: src/relocate.ts header. Both backend_send_line calls run under
# `set -e`, so an unacknowledged one used to abort with no diagnosis at all and
# skip the status append below it. They now split on what the failure costs.

# The RESUME line is fatal: nothing was resumed, so there is no relocation to
# record. Reads are frozen, so every submit reads as a strand.
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "tab get") printf '{"result":{"tab":{"tab_id":"%s","agent_status":"%s"}}}\n' "$3" "$(cat "$HDSTATE")" ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wC"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"wC:tX"},"root_pane":{"pane_id":"pX"}}}' ;;
  "pane read") printf 'frozen\n' ;;
esac
exit 0
EOF
mkdir -p "$AC_HOME/data/famX/chief"
cat >"$AC_HOME/state/famX-chief.meta" <<EOF
backend=herdr
kind=roomchief
project=famX
worktree=/tmp
session_id=sid-x
EOF
printf 'p1 wA:t1\n' >"$AC_HOME/state/.pane-famX-chief"
err="$(relocate famX-chief 2>&1)" && fail "an undelivered resume line must be fatal"
assert_contains "$err" "resume line NOT delivered" "the fatal names what was not delivered"
assert_no_file "$AC_HOME/state/famX-chief.status" "a relocation that never resumed records nothing"

# The NOTICE is a loud warning: it fails AFTER the tab was recreated and the
# session resumed, so dying there would leave the durable status line unwritten
# for a relocation that really happened. The stub freezes the render only once
# the notice has been TYPED, so the resume line before it still acks.
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "tab get") printf '{"result":{"tab":{"tab_id":"%s","agent_status":"%s"}}}\n' "$3" "$(cat "$HDSTATE")" ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wC"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"wC:tY"},"root_pane":{"pane_id":"pY"}}}' ;;
  "pane read")
    if grep -q 'Notice: your window was relocated' "$HDLOG"; then printf 'frozen\n'
    else printf 'r%s\n' "$(wc -l <"$HDLOG")"; fi ;;
esac
exit 0
EOF
mkdir -p "$AC_HOME/data/famY/chief"
cat >"$AC_HOME/state/famY-chief.meta" <<EOF
backend=herdr
kind=roomchief
project=famY
worktree=/tmp
session_id=sid-y
EOF
printf 'p1 wA:t1\n' >"$AC_HOME/state/.pane-famY-chief"
: >"$HDLOG"   # the freeze trigger reads this log; earlier cases already logged a notice
errf="$TMP/relocate.err"
out="$(relocate famY-chief 2>"$errf")" \
  || fail "an undelivered notice must stay non-fatal - the session is already resumed"
assert_contains "$out" "relocated famY-chief" "the relocation is still reported"
assert_contains "$(cat "$errf")" "relocation notice NOT delivered" "the lost notice is diagnosed loudly"
assert_contains "$(cat "$AC_HOME/state/famY-chief.status")" "relocated to famY" \
  "the durable status line is still appended after a lost notice"

# --- the entry, row by row ----------------------------------------------------
# One side root $RH: a home at $RH/home and the stub herdr's state and log at
# $RH/herdr. Each run starts at $RH with stdin /dev/null (unless a row feeds a
# file), LC_ALL=C (unless a row names a locale), AC_SPAWN_SETTLE=0 and
# AC_SEND_SETTLE=0 (unless a row names them) and PATH = a logging herdr stub, a
# sleep that logs its argument and fast-forwards a number, and a date pinned
# to one instant, ahead of the suite's PATH (or a PATH without herdr, jq or
# bun where a row says) - no row reaches a real herdr or orca. `@H` in an
# argument or an env value is $RH, and stdout, stderr and the stub log (which
# orders every RPC and sleep, argv bracketed) are read with $RH spelled @H.
RH="$TMP/rside"; RBIN="$TMP/rstub"
mkdir -p "$RBIN"
# A file-backed herdr: <verb>.err goes to stderr, <verb>.out replaces the
# answer, <verb>.rc then ends the call with that status, hang-<verb> wedges
# it; tab get reports the agent_status held in `status` (idle), tabs-<ws> is
# a workspace's tab list (tabs-<ws>.rc its status), close-<tab>.rc a close's.
# The pane: send-text types into `in`, an Enter submits it into `buf` until
# the Enters counted reach drop-from (and leaves draft-after in the
# composer), and a read prints buf, then the composer - claude's between two
# rules, its dim hint under --ansi when empty, when `claude` exists.
cat >"$RBIN/herdr" <<'EOF'
#!/bin/sh
d="$RSTUB"
{ printf herdr; for a in "$@"; do printf ' [%s]' "$a"; done
  [ -z "${HERDR_SESSION:-}" ] || printf ' {HERDR_SESSION=%s}' "$HERDR_SESSION"
  [ ! -e "$d/stdin-probe" ] || printf ' stdin=%s' "$(stat -L -f %HT /dev/stdin)"
  printf '\n'; } >>"$d/log"
v="$1-$2"
if [ -e "$d/hang-$v" ]; then
  ( trap '' TERM; exec /bin/sleep 97 ) &
  printf '%s\n' "$!" >>"$d/hang-children"
  wait; exit 0
fi
[ ! -e "$d/$v.err" ] || cat "$d/$v.err" >&2
[ ! -e "$d/$v.out" ] || cat "$d/$v.out"
[ ! -e "$d/$v.rc" ] || exit "$(cat "$d/$v.rc")"
[ ! -e "$d/$v.out" ] || exit 0
case "$v" in
  tab-get) printf '{"result":{"tab":{"tab_id":"%s","agent_status":"%s"}}}\n' "$3" "$(cat "$d/status" 2>/dev/null || echo idle)" ;;
  workspace-list) printf '{"result":{"workspaces":[]}}\n' ;;
  workspace-create) printf '{"result":{"workspace":{"workspace_id":"wNEW"}}}\n' ;;
  tab-list)
    [ ! -e "$d/tabs-$4.rc" ] || exit "$(cat "$d/tabs-$4.rc")"
    if [ -e "$d/tabs-$4" ]; then cat "$d/tabs-$4"; else printf '{"result":{"tabs":[]}}\n'; fi ;;
  tab-close) [ ! -e "$d/close-$3.rc" ] || exit "$(cat "$d/close-$3.rc")" ;;
  tab-create) printf '{"result":{"tab":{"tab_id":"wNEW:tN"},"root_pane":{"pane_id":"pN"}}}\n' ;;
  pane-send-text) printf '%s' "$4" >>"$d/in" ;;
  pane-send-keys)
    case "$4" in
      enter)
        n=$(($(cat "$d/enters" 2>/dev/null || echo 0) + 1)); echo "$n" >"$d/enters"
        if [ ! -e "$d/drop-from" ] || [ "$n" -lt "$(cat "$d/drop-from")" ]; then
          { cat "$d/in" 2>/dev/null; printf '\n'; } >>"$d/buf"
          if [ -e "$d/draft-after" ]; then cp "$d/draft-after" "$d/in"; else : >"$d/in"; fi
        fi ;;
      ctrl+u) : >"$d/in" ;;
    esac ;;
  pane-read)
    cat "$d/buf" 2>/dev/null
    if [ -e "$d/claude" ]; then
      echo '────────────'
      if [ -s "$d/in" ]; then printf '❯ '; cat "$d/in"; printf '\n'
      else case "$*" in *--ansi*) printf '❯ \033[2mTry "x"\033[22m\n' ;; *) echo '❯ Try "x"' ;; esac; fi
      echo '────────────'
    elif [ -s "$d/in" ]; then printf '> '; cat "$d/in"; printf '\n'; fi ;;
esac
exit 0
EOF
cat >"$RBIN/sleep" <<'EOF'
#!/bin/sh
{ printf sleep; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >>"$RSTUB/log"
case "$1" in *[0-9]*) case "$1" in *[!0-9.]*) ;; *) exit 0 ;; esac ;; esac
exec /bin/sleep "$@"
EOF
cat >"$RBIN/date" <<'EOF'
#!/bin/sh
[ ! -e "$RSTUB/date.rc" ] || exit "$(cat "$RSTUB/date.rc")"
[ "$*" != "-u +%Y-%m-%dT%H:%M:%SZ" ] || { echo 2026-01-01T00:00:00Z; exit 0; }
exec /bin/date "$@"
EOF
chmod +x "$RBIN/herdr" "$RBIN/sleep" "$RBIN/date"
rat() {  # rat <cmd> <args...> - a seeding step at the side root: H names it, and so does a literal @H in an argument
  local x a=(); H="$RH"; for x in "$@"; do a+=("${x//@H/$RH}"); done; "${a[@]}"
}
rseed() { rm -rf "$H"; mkdir -p "$H/home/state" "$H/home/config" "$H/home/data" "$H/herdr"; }
rput() { mkdir -p "$(dirname "$H/$1")"; printf '%s' "$2" >"$H/$1"; }   # rput <path under the side> <bytes>
rmate() {  # rmate <id> <meta bytes> [<handle>] - a seeded side with one crewmate: its meta and handle
  rseed; rput "home/state/$1.meta" "$2"; rput "home/state/.pane-$1" "${3-p1 wA:t1}"$'\n'
}
RMETA=$'backend=herdr\nkind=ship\nworktree=/tmp/wt\nsession_id=sid-1\n'
r0() { rmate t1 "$RMETA"; }
RLC=C; RENV=(); RHOMELESS=0; RPATH=""; RSTDIN=/dev/null; RSETTLE=0
RRC=0
rrun() {  # rrun <args...> - sets RRC; stdout in $TMP/n.out, stderr in $TMP/n.err2
  local x v
  local a=() e=("PATH=${RPATH:-$RBIN:$PATH}" "RSTUB=$RH/herdr" "AC_SEND_SETTLE=0")
  [ -z "$RLC" ] || e+=("LC_ALL=$RLC")
  [ "$RSETTLE" = unset ] || e+=("AC_SPAWN_SETTLE=$RSETTLE")
  [ "$RHOMELESS" = 1 ] || e+=("AC_HOME=$RH/home")
  for x in ${RENV[@]+"${RENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$RH}"); done
  for x in "$@"; do a+=("${x//@H/$RH}"); done
  RRC=0
  (cd "$RH" && env -u AC_HOME -u AC_BACKEND -u AC_FLEET_STATE -u AC_HERDR_SESSION -u AC_HERDR_RPC_TIMEOUT -u AC_SEND_UNPROVEN \
    -u AC_SPAWN_SETTLE -u AC_SCOPE -u AC_FLEET_SCOPE -u AC_FLEET_NAME -u LC_ALL -u LANG -u LC_CTYPE \
    "${e[@]}" "$BIN/ac-relocate.sh" ${a[@]+"${a[@]}"}) <"$RSTDIN" >"$TMP/n.raw" 2>"$TMP/n.err" || RRC=$?
  rnorm "$TMP/n.raw" >"$TMP/n.out"; rnorm "$TMP/n.err" >"$TMP/n.err2"
}
rnorm() { LC_ALL=C sed -E -e "s#$RH#@H#g" -e "s#$ROOT#ROOT#g" "$1"; }
rout() { cat "$TMP/n.out"; }
rerr() { cat "$TMP/n.err2"; }
rlog() { rnorm "$RH/herdr/log"; }
rfile() { cat "$RH/$1"; }   # rfile <path under the side root>
RUSAGE='ERROR: usage: ac-relocate.sh <id> [--family <fam> | --root]'
RNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
RDONE='relocated t1 group=t1 window=herdr:pane-pN'
RBUSY="relocate only an idle window (never kill a pane mid-write)"

# 1. argv: none and '' are the usage line, homeless too; the first argument is
#    the id whatever it spells; an unknown token, a valueless or empty
#    --family, and --family with --root in either order are refused; a missing
#    meta (a directory or a dangling link is none) is refused.
rat r0
for rv in "" "''"; do
  # shellcheck disable=SC2086
  eval rrun $rv
  assert_eq "$RRC:$(rout):$(rerr)" "1::$RUSAGE" "1: '$rv' is the usage line"
done
rrun --family x; assert_eq "$RRC:$(rerr)" "1:ERROR: unknown flag: x (usage: ac-relocate.sh <id> [--family <fam> | --root])" "1: the first argument is the id"
rrun t1 --bogus; assert_eq "$RRC:$(rerr)" "1:ERROR: unknown flag: --bogus (usage: ac-relocate.sh <id> [--family <fam> | --root])" "1: an unknown flag"
rrun t1 --family; assert_eq "$RRC:$(rerr)" "1:ERROR: --family needs a value" "1: a valueless --family"
rrun t1 --family ''; assert_eq "$RRC:$(rerr)" "1:ERROR: --family needs a value" "1: an empty --family"
rrun t1 --family a --root; assert_eq "$RRC:$(rerr)" "1:ERROR: --family and --root are mutually exclusive" "1: --family then --root"
rrun t1 --root --family a; assert_eq "$RRC:$(rerr)" "1:ERROR: --family and --root are mutually exclusive" "1: --root then --family"
rrun -h; assert_eq "$RRC:$(rerr)" "1:ERROR: no such task in flight: -h" "1: -h is an id"
rrun nope; assert_eq "$RRC:$(rerr)" "1:ERROR: no such task in flight: nope" "1: a missing meta"
RHOMELESS=1
rrun; assert_eq "$RRC:$(rerr)" "1:$RUSAGE" "1: homeless with no id is the usage line"
rrun t1; assert_eq "$RRC:$(rout):$(head -n 1 "$TMP/n.err2")" "1::$RNOHOME" "1: homeless with an id is refused"
RHOMELESS=0
rat mkdir @H/home/state/d1.meta
rrun d1; assert_eq "$RRC:$(rerr)" "1:ERROR: no such task in flight: d1" "1: a directory is no meta"
rat rmdir @H/home/state/d1.meta
rat ln -s nowhere @H/home/state/d2.meta
rrun d2; assert_eq "$RRC:$(rerr)" "1:ERROR: no such task in flight: d2" "1: a dangling link is no meta"

# 2. the backend: the fleet's name is checked before usage (AC_BACKEND,
#    config/backend); the meta's backend= - the last one, an empty one absent,
#    herdr without one - must be herdr, its bytes named in the refusal; a
#    config/backend=orca home relocates a herdr task; an unreadable meta WARNs
#    and ends the run.
RENV=(AC_BACKEND=tmux)
rrun; assert_eq "$RRC:$(rerr)" "1:ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "2: AC_BACKEND=tmux refuses before usage"
RENV=()
rat rput home/config/backend $'tmux\n'
rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "2: config/backend=tmux"
rat rput home/config/backend $'orca\n'
rrun t1; assert_eq "$RRC:$(rout)" "0:$RDONE" "2: a herdr meta relocates on an orca home"
for rv in tmux orca $'herdr\nbackend=tmux' $'tm\351x'; do
  rat rmate t1 "backend=$rv"$'\nkind=ship\nworktree=/tmp/wt\nsession_id=sid-1\n'
  rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: relocate is herdr-only; backend of t1 is ${rv##*=}" "2: backend=$rv is refused by its bytes"
done
for rv in $'backend=herdr\nbackend=\n' ''; do
  rat rmate t1 "$rv"$'kind=ship\nworktree=/tmp/wt\nsession_id=sid-1\n'
  rrun t1; assert_eq "$RRC:$(rout)" "0:$RDONE" "2: '$rv' reads herdr"
done
rat r0; rat sh -c 'printf "backend=herdr\\000x\\nkind=ship\\nworktree=/tmp/wt\\nsession_id=sid-1\\n" >"$0"' @H/home/state/t1.meta
rrun t1; assert_eq "$RRC:$(rout)" "0:$RDONE" "2: backend= is read up to a NUL"
if [ "$(id -u)" != 0 ]; then
  rat r0; rat chmod 000 @H/home/state/t1.meta
  rrun t1; assert_eq "$(rout)" "" "2: an unreadable meta relocates nothing"
  [ "$RRC" -ne 0 ] || fail "2: an unreadable meta must end the run"
  assert_contains "$(rerr)" "WARN: cannot read meta file @H/home/state/t1.meta" "2: ... after the WARN"
  rat chmod 644 @H/home/state/t1.meta
fi

# 3. the tools, after the backend: herdr, then jq, absent from PATH.
mkdir -p "$TMP/rbase" "$TMP/rjq"
for rd in /usr/bin /bin; do
  for rf in "$rd"/*; do
    case "${rf##*/}" in jq | herdr | orca) continue ;; esac
    [ -e "$TMP/rbase/${rf##*/}" ] || ln -s "$rf" "$TMP/rbase/${rf##*/}"
  done
done
ln -s "$(command -v jq)" "$TMP/rjq/jq"
RBUN="$(dirname "$(command -v bun)")"
rat r0
RPATH="$TMP/rjq:$RBUN:$TMP/rbase"
if [ -z "$(PATH="$RPATH" command -v herdr || true)" ]; then
  rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: required tool not found: herdr" "3: herdr absent from PATH"
else
  printf 'SKIP: row 3 herdr-absent - a herdr shares a directory with bun on this host\n'
fi
RPATH="$RBIN:$RBUN:$TMP/rbase"
if [ -z "$(PATH="$RPATH" command -v jq || true)" ]; then
  rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: required tool not found: jq" "3: jq absent from PATH"
else
  printf 'SKIP: row 3 jq-absent - a jq shares a directory with bun on this host\n'
fi
RPATH=""

# 4. the meta's fields: a missing or empty session_id or worktree is refused.
rat rmate t1 $'backend=herdr\nkind=ship\nworktree=/tmp/wt\n'
rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: no session_id recorded for t1 - cannot resume; respawn instead" "4: no session_id"
rat rmate t1 $'backend=herdr\nkind=ship\nworktree=/tmp/wt\nsession_id=\n'
rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: no session_id recorded for t1 - cannot resume; respawn instead" "4: an empty session_id"
rat rmate t1 $'backend=herdr\nkind=ship\nsession_id=s\n'
rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: no worktree recorded for t1" "4: no worktree"

# 5. the handle, read after the workspace resolved: none, one field or an empty
#    file is refused; the first line's first two blank-separated fields count;
#    a tab with no `:` is its own workspace prefix.
for rv in "" p1; do
  rat rmate t1 "$RMETA" "$rv"
  rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: no window handle for t1" "5: handle '$rv'"
done
rat rm -f @H/home/state/.pane-t1
rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: no window handle for t1" "5: no handle file"
assert_contains "$(rlog)" "herdr [workspace] [create]" "5: ... after the workspace resolved"
for rv in "p1 wA:t1 extra" "p1 t1" $'  p1\twA:t1\nother line'; do
  rat rmate t1 "$RMETA" "$rv"
  rrun t1; assert_eq "$RRC:$(rout)" "0:$RDONE" "5: handle '$rv'"
done

# 6. already there: the handle's tab names the resolved workspace - the no-op
#    line, nothing written, even for a busy agent (it precedes the idle gate).
RWS_A='{"result":{"workspaces":[{"workspace_id":"wA","label":"home · t1","tab_count":1}]}}'
rat r0; rat rput herdr/workspace-list.out "$RWS_A"$'\n'
rrun t1; assert_eq "$RRC:$(rout)" "0:t1 already in group t1 (workspace wA)" "6: the no-op line"
rat rput herdr/status $'working\n'
rrun t1; assert_eq "$RRC:$(rout)" "0:t1 already in group t1 (workspace wA)" "6: ... before the idle gate"

# 7. the idle gate: idle and done pass; any other status - '' included, unknown
#    when the answer has none, every line of a two-document answer - is
#    refused; a failing tab get ends the run silently with its status, herdr's
#    own stderr kept (V15); an answer jq cannot parse ends it; a wedged one at
#    a 1 s ceiling ends it with 124.
rat r0; rat rput herdr/status $'done\n'
rrun t1; assert_eq "$RRC:$(rout)" "0:$RDONE" "7: done passes"
for rv in working ''; do
  rat r0; rat rput herdr/status "$rv"$'\n'
  rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: agent of t1 is '$rv' - $RBUSY" "7: '$rv' is refused"
done
rat r0; rat rput herdr/tab-get.out $'{}\n'
rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: agent of t1 is 'unknown' - $RBUSY" "7: no status reads unknown"
rat r0; rat rput herdr/tab-get.out $'{"result":{"tab":{"agent_status":"idle"}}}\n{"result":{"tab":{"agent_status":"done"}}}\n'
rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: agent of t1 is 'idle
done' - $RBUSY" "7: two answers are two lines"
rat r0; rat rput herdr/tab-get.rc $'3\n'; rat rput herdr/tab-get.err $'tab gone\n'
rrun t1; assert_eq "$RRC:$(rout):$(rerr)" "3::tab gone" "7 (V15): a failing tab get is a silent exit with its status"
rat r0; rat rput herdr/tab-get.out $'xx\n'
rrun t1; assert_eq "$(rout)" "" "7: an answer jq cannot parse relocates nothing"
[ "$RRC" -ne 0 ] || fail "7: an answer jq cannot parse must end the run"
rat r0; rat touch @H/herdr/hang-tab-get
RENV=(AC_HERDR_RPC_TIMEOUT=1)
rrun t1; assert_eq "$RRC:$(rout):$(rerr)" "124::" "7: a wedged tab get ends the run at the ceiling with 124"
RENV=()
while read -r rp; do
  for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$rp" 2>/dev/null || break; sleep 0.2; done
  ! kill -0 "$rp" 2>/dev/null || fail "7: a wedged herdr's child $rp outlived the ceiling"
done <"$RH/herdr/hang-children"

# 8. the target: --root is the fleet's own workspace (group root); --family
#    names one (the last wins);
#    a crewdeputy defaults to root; otherwise AC_SCOPE, then AC_FLEET_SCOPE,
#    each only inside [A-Za-z0-9_-]+, then the id's family (a stage suffix
#    trusted only with its data/<fam>/<stage> dir).
rat r0
rrun t1 --root; assert_eq "$RRC:$(rout)" "0:relocated t1 group=root window=herdr:pane-pN" "8: --root"
assert_contains "$(rlog)" "herdr [workspace] [create] [--label] [home] [--no-focus]" "8: ... the fleet's own label"
rat r0
rrun t1 --root --root; assert_eq "$RRC:$(rout)" "0:relocated t1 group=root window=herdr:pane-pN" "8: --root twice"
rat r0
rrun t1 --family a --family b; assert_eq "$RRC:$(rout)" "0:relocated t1 group=b window=herdr:pane-pN" "8: the last --family wins"
rat rmate t1 $'backend=herdr\nkind=crewdeputy\nworktree=/tmp/dh\nsession_id=s\n'
rrun t1; assert_eq "$RRC:$(rout)" "0:relocated t1 group=root window=herdr:pane-pN" "8: a crewdeputy defaults to root"
assert_contains "$(rlog)" "[send-text] [pN] [AC_HOME=/tmp/dh claude --resume s]" "8: ... and resumes with its home"
rat rmate famR-chief "$RMETA"
rrun famR-chief; assert_eq "$RRC:$(rout)" "0:relocated famR-chief group=famR-chief window=herdr:pane-pN" "8: a -chief suffix without its stage dir is the id"
rat rmate famR-chief "$RMETA"; rat mkdir -p @H/home/data/famR/chief
rrun famR-chief; assert_eq "$RRC:$(rout)" "0:relocated famR-chief group=famR window=herdr:pane-pN" "8: ... with it, the family"
for rv in "AC_SCOPE=other:other" "AC_SCOPE=a/b:t1" "AC_FLEET_SCOPE=fs:fs" "AC_SCOPE=:t1"; do
  rat r0
  RENV=("${rv%:*}" AC_FLEET_SCOPE=x.y)
  [ "${rv%%=*}" != AC_FLEET_SCOPE ] || RENV=("${rv%:*}")
  rrun t1; assert_eq "$RRC:$(rout)" "0:relocated t1 group=${rv##*:} window=herdr:pane-pN" "8: ${rv%:*}"
done
RENV=()

# 9. the workspace, adopted by label (FAMILY WORKSPACE GROUPING): the busiest
#    twin adopted, an empty twin closed, a twin holding a tab or whose tabs
#    cannot be read WARNed, a close herdr refuses by workspace_group_close_required
#    WARNed; with none, created - a failing create is herdr's stderr and the
#    refusal, an answer without the id (or not JSON) the parse refusal.
r9() {
  r0
  rput herdr/workspace-list.out '{"result":{"workspaces":[{"workspace_id":"w1","label":"home · t1","tab_count":1},{"workspace_id":"w2","label":"home · t1","tab_count":5},{"workspace_id":"w3","label":"home · t1"},{"workspace_id":"w4","label":"home · t1","tab_count":2},{"workspace_id":"w9","label":"other","tab_count":9}]}}'$'\n'
  rput herdr/tabs-w1 $'{"result":{"tabs":[{"label":"1"}]}}\n'
  rput herdr/tabs-w3 $'{"result":{"tabs":[{"label":"crew:x"}]}}\n'
  rput herdr/tabs-w4.rc $'1\n'
  rput herdr/workspace-close.rc $'3\n'; rput herdr/workspace-close.err $'{"error":{"code":"workspace_group_close_required"}}\n'
}
rat r9
rrun t1; assert_eq "$RRC:$(rout)" "0:relocated t1 group=t1 window=herdr:pane-pN" "9: the busiest twin adopted"
assert_eq "$(rerr)" "WARN: twin workspace w4 left open: its tab list could not be read - a close cannot be proven safe
WARN: workspace w1 left open: herdr refused the close with workspace_group_close_required (it heads a linked-worktree group, which this sweep is not authorized to close)
WARN: twin workspace w3 left open: it holds a tab other than herdr's default '1' - closing the workspace would take that tab with it" "9: the sweep's three WARNs, busiest twin first"
assert_contains "$(rlog)" "herdr [tab] [create] [--workspace] [w2]" "9: ... the new tab in w2"
rat r0; rat rput herdr/workspace-create.rc $'1\n'; rat rput herdr/workspace-create.err $'{"error":{"code":"server_not_running"}}\n'
rrun t1; assert_eq "$RRC:$(rerr)" '1:{"error":{"code":"server_not_running"}}
ERROR: herdr workspace create failed (is the herdr server running?)' "9: a failing create"
rat r0; rat rput herdr/workspace-create.out $'{"result":{}}\n'
rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: could not parse herdr workspace create output" "9: a create answer without the id"
rat r0; rat rput herdr/workspace-create.out $'oops\n'
rrun t1; assert_contains "$(rerr)" "ERROR: could not parse herdr workspace create output" "9: a create answer that is not JSON"
rat r0; rat rput herdr/workspace-list.out $'oops\n'
rrun t1; assert_eq "$RRC:$(rout)" "0:$RDONE" "9: a list that is not JSON creates"
rat r0; rat rput herdr/workspace-list.rc $'1\n'
rrun t1; assert_eq "$RRC:$(rout)" "0:$RDONE" "9: a list that fails creates"

# 10. the old tab and the new: a failing close is a WARN and the move goes on;
#     a failing create is herdr's stderr and the refusal with nothing written;
#     an answer without both ids is the parse refusal; one jq cannot parse ends
#     the run.
rat r0; rat rput "herdr/close-wA:t1.rc" $'1\n'
rrun t1; assert_eq "$RRC:$(rout):$(rerr)" "0:$RDONE:WARN: old tab wA:t1 already gone" "10: a failing close"
rat r0; rat rput herdr/tab-create.rc $'1\n'; rat rput herdr/tab-create.err $'create refused\n'
rrun t1; assert_eq "$RRC:$(rerr)" "1:create refused
ERROR: herdr tab create failed (workspace wNEW)" "10: a failing create"
assert_eq "$(rfile home/state/.pane-t1)" "p1 wA:t1" "10: ... the handle untouched"
rat r0; rat rput herdr/tab-create.out $'{"result":{"tab":{"tab_id":"x"}}}\n'
rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: could not parse herdr tab create output" "10: no pane id"
rat r0; rat rput herdr/tab-create.out $'oops\n'
rrun t1; assert_eq "$(rout)" "" "10: an answer jq cannot parse relocates nothing"
[ "$RRC" -ne 0 ] || fail "10: an answer jq cannot parse must end the run"

# 11. herdr's default `1` tabs in the target closed after the create, each
#     close best-effort; a list that fails closes none.
rat r0
rat rput herdr/tabs-wNEW $'{"result":{"tabs":[{"label":"1","tab_id":"wNEW:t0"},{"label":"crew:x","tab_id":"wNEW:t9"},{"label":"1","tab_id":"wNEW:t2"},{"label":"1"}]}}\n'
rat rput "herdr/close-wNEW:t0.rc" $'7\n'
rrun t1; assert_eq "$RRC:$(rout)" "0:$RDONE" "11: the default tabs closed"
assert_contains "$(rlog)" "herdr [tab] [close] [wNEW:t0]
herdr [tab] [close] [wNEW:t2]
herdr [tab] [close] [null]" "11: ... each of them"
rat r0; rat rput herdr/tabs-wNEW.rc $'1\n'
rrun t1; assert_eq "$RRC:$(rout)" "0:$RDONE" "11: a list that fails"

# 12. the resume line: a roomchief resumes with its home and scope (printf %q,
#     an empty one ''), a domainchief with AC_DOMAIN after them, and is told to
#     re-arm its watcher; its status line is mirrored into data/<fam>/chief.
rc12() { rmate famR-chief "$1"; mkdir -p "$H/home/data/famR/chief"; }
rat rc12 $'backend=herdr\nkind=roomchief\nproject=famR\nworktree=/tmp/hm\nsession_id=sid-r\n'
rrun famR-chief; assert_eq "$RRC:$(rout)" "0:relocated famR-chief group=famR window=herdr:pane-pN" "12: a roomchief"
assert_contains "$(rlog)" "[send-text] [pN] [AC_HOME=/tmp/hm AC_SCOPE=famR claude --resume sid-r]" "12: ... resumed with home and scope"
assert_contains "$(rlog)" 'AC_WATCH_ONLY=$(bin/ac-ready.sh watch-set famR) bin/ac-watch.sh' "12: ... told to re-arm"
assert_eq "$(rfile home/data/famR/chief/timeline.log)" "2026-01-01T00:00:00Z working: relocated to famR (wNEW)" "12: ... the status mirrored"
for rv in "domD:AC_DOMAIN=domD " "d d:AC_DOMAIN=d\\ d " $'d\tx:AC_DOMAIN=$\'d\\tx\' '; do
  rat rc12 $'backend=herdr\nkind=roomchief\nproject=famR\n'"domain=${rv%%:*}"$'\nworktree=/tmp/hm\nsession_id=s\n'
  rrun famR-chief; assert_contains "$(rlog)" "[AC_HOME=/tmp/hm AC_SCOPE=famR ${rv#*:}claude --resume s]" "12: domain '${rv%%:*}'"
done
for rv in 'p$x:p\$x' ":''" "a b:a\\ b"; do
  rat rc12 $'backend=herdr\nkind=roomchief\n'"project=${rv%%:*}"$'\nworktree=/tmp/x y\nsession_id=s\n'
  rrun famR-chief; assert_contains "$(rlog)" "[AC_HOME=/tmp/x\\ y AC_SCOPE=${rv#*:} claude --resume s]" "12: project '${rv%%:*}'"
done
rat rc12 $'backend=herdr\nkind=roomchief\nproject=famR\nworktree=/tmp/\346\227\245\nsession_id=s\n'
rrun famR-chief; assert_contains "$(rlog)" "[AC_HOME=\$'/tmp/\\346\\227\\245' AC_SCOPE=famR claude --resume s]" "12: a UTF-8 home under C is octal"

# 13. the two steers: an undelivered resume line dies after the handle and meta
#     were rewritten, with no status line; an undelivered notice WARNs and the
#     status line is still appended. The resume is typed unproven (the
#     composer is not read), the notice proven on a claude meta unless the
#     caller exports AC_SEND_UNPROVEN=1; a draft in the composer refuses it.
rat r0; rat rput herdr/drop-from $'1\n'
rrun t1; assert_eq "$RRC:$(rout)" "1:" "13: an undelivered resume line is fatal"
assert_contains "$(rerr)" "ERROR: resume line NOT delivered to t1 (see stderr above) - the session was never resumed; the new tab exists, so re-send it by hand: bin/ac-send.sh t1 'claude --resume sid-1'" "13: ... diagnosed"
assert_eq "$(rfile home/state/.pane-t1):$(test -e "$RH/home/state/t1.status" && echo status)" "pN wNEW:tN:" "13: ... after the handle, with no status"
rat r0; rat rput herdr/drop-from $'2\n'
rrun t1; assert_eq "$RRC:$(rout)" "0:$RDONE" "13: an undelivered notice is not fatal"
assert_contains "$(rerr)" "WARN: relocation notice NOT delivered to t1 (see stderr above) - the session IS resumed, so re-send it only if the agent looks confused: bin/ac-send.sh t1 'Notice: your window was relocated to the t1 workspace (wNEW) - same session, nothing lost. Continue where you left off.'" "13: ... WARNed"
assert_eq "$(rfile home/state/t1.status)" "2026-01-01T00:00:00Z working: relocated to t1 (wNEW)" "13: ... and recorded"
RCLAUDE=$'backend=herdr\nkind=ship\nharness=claude\nworktree=/tmp/wt\nsession_id=sid-1\n'
for rv in "" AC_SEND_UNPROVEN=0 AC_SEND_UNPROVEN=1; do
  rat rmate t1 "$RCLAUDE"; rat touch @H/herdr/claude
  RENV=(${rv:+"$rv"})
  rrun t1; assert_eq "$RRC:$(rout)" "0:$RDONE" "13: a claude pane, '$rv'"
  assert_eq "$(rlog | grep -c -e '\[--ansi\]' || true)" "$([ "$rv" = AC_SEND_UNPROVEN=1 ] && echo 0 || echo 2)" "13: the notice's composer read, the resume's never, '$rv'"
done
RENV=()
rat rmate t1 "$RCLAUDE"; rat touch @H/herdr/claude; rat rput herdr/draft-after 'stale draft'
rrun t1; assert_eq "$RRC:$(rout)" "0:$RDONE" "13: a draft refuses the notice"
assert_contains "$(rerr)" "ac-backend: the composer of herdr:pane-pN holds an unsent draft" "13: ... named by the driver"

# 14. AC_SPAWN_SETTLE: unset or empty is 8; a number is slept between the two
#     lines; anything else is refused with nothing typed.
for rv in "unset:8" ":8" ".5:.5" "5.:5."; do
  rat r0; RSETTLE="${rv%%:*}"
  rrun t1; assert_contains "$(rlog)" "herdr [pane] [read] [pN] [--source] [recent] [--lines] [200]
sleep [${rv#*:}]
herdr [pane] [send-text] [pN] [Notice: " "14: AC_SPAWN_SETTLE '${rv%%:*}'"
done
for rv in abc 1.2.3 -1; do
  rat r0; RSETTLE="$rv"
  rrun t1; assert_eq "$RRC:$(rerr)" "1:ERROR: AC_SPAWN_SETTLE must be a number: $rv" "14: '$rv' is refused"
  assert_eq "$(rlog | grep -c send-text || true)" "0" "14: ... with nothing typed"
done
RSETTLE=0

# 15. the meta: every window= line dropped and the new one appended; the
#     status line appended (date failing ends the run with date's status first).
rat rmate t1 $'backend=herdr\nwindow=herdr:pane-OLD\nkind=ship\nworktree=/tmp/wt\nsession_id=sid-1\nwindow=x\n'
rrun t1; assert_eq "$(rfile home/state/t1.meta)" "backend=herdr
kind=ship
worktree=/tmp/wt
session_id=sid-1
window=herdr:pane-pN" "15: window= replaced"
rat r0; rat rput herdr/date.rc $'3\n'
rrun t1; assert_eq "$RRC:$(rout):$(test -e "$RH/home/state/t1.status" && echo status)" "3::" "15: date failing ends the run before the status line"
rclosed() {  # the exit of a relocate whose reader left before its last line
  (cd "$RH" && env -u AC_BACKEND -u AC_SEND_UNPROVEN LC_ALL=C PATH="$RBIN:$PATH" RSTUB="$RH/herdr" AC_HOME="$RH/home" AC_SPAWN_SETTLE=0 \
    bash -c '"$0/ac-relocate.sh" t1 | true; printf "%s" "${PIPESTATUS[0]}"' "$BIN") </dev/null 2>/dev/null
}
rat r0
assert_eq "$(rclosed)" "141" "15: a reader that left ends the run with SIGPIPE's 141"
# A stdout closed outright (>&-, no pipe): the last line's write fails with
# EBADF and ends the run 1 after the move.
rshut() {  # the exit of a relocate with stdout closed
  (cd "$RH" && env -u AC_BACKEND -u AC_SEND_UNPROVEN LC_ALL=C PATH="$RBIN:$PATH" RSTUB="$RH/herdr" AC_HOME="$RH/home" AC_SPAWN_SETTLE=0 \
    bash -c '"$0/ac-relocate.sh" t1 >&- 2>"$1"; printf "%s" "$?"' "$BIN" "$TMP/rshut.n") </dev/null
}
rat r0
assert_eq "$(rshut)" "1" "15: a closed stdout ends the run 1"
assert_contains "$(cat "$TMP/rshut.n")" "EBADF" "15: ... at the last line's write"

# 16. sessions: AC_HERDR_SESSION, else config/herdr-session, rides every RPC as
#     a trailing --session and HERDR_SESSION.
rat r0
RENV=(AC_HERDR_SESSION=s1)
rrun t1; assert_eq "$(rlog | grep '^herdr' | grep -vc -e '\[--session\] \[s1\] {HERDR_SESSION=s1}$' || true)" 0 "16: AC_HERDR_SESSION on every RPC"
RENV=()
rat r0; rat rput home/config/herdr-session $'s2\n'
rrun t1; assert_eq "$(rlog | grep '^herdr' | grep -vc -e '\[--session\] \[s2\] {HERDR_SESSION=s2}$' || true)" 0 "16: config/herdr-session on every RPC"

# 17. locale: under UTF-8 a family's bytes label its workspace; printf %q keeps
#     a byte it can print (0xA0-0xFF) and octal-escapes the rest.
RLC=""; RENV=(LANG=en_US.UTF-8)
rat r0
rrun t1 --family "$(printf 'caf\303\251')"; assert_eq "$RRC:$(rout)" "0:relocated t1 group=$(printf 'caf\303\251') window=herdr:pane-pN" "17: a UTF-8 family"
rat rc12 $'backend=herdr\nkind=roomchief\nproject=caf\303\251\nworktree=/tmp/wt\nsession_id=s\n'
rrun famR-chief; assert_contains "$(rlog)" "[AC_HOME=/tmp/wt AC_SCOPE=$(printf 'caf\303\251') claude --resume s]" "17: a printable UTF-8 scope stays raw"
RLC=C; RENV=()

# 18. stdin by position: the old tab's close and the sends read the caller's
#     stdin, every other herdr call /dev/null - the twin sweep's and the
#     workspace create's too.
rsummary() { LC_ALL=C sed -nE 's/^herdr \[([^]]*)\] \[([^]]*)\].* stdin=(.*)$/\1 \2 \3/p' "$1" | uniq | tr '\n' ';'; }
printf 'caller bytes\n' >"$TMP/rstdin.in"
RSTDIN="$TMP/rstdin.in"
rat r9; rat rm -f @H/herdr/workspace-close.rc; rat touch @H/herdr/stdin-probe
rrun t1
assert_eq "$RRC:$(rsummary "$RH/herdr/log")" "0:workspace list Character Device;tab list Character Device;workspace close Character Device;tab list Character Device;tab get Character Device;tab close Regular File;tab create Character Device;tab list Character Device;pane send-text Regular File;pane read Character Device;pane send-keys Regular File;pane read Character Device;pane send-text Regular File;pane read Character Device;pane send-keys Regular File;pane read Character Device;" "18: stdin by position through the sweep"
rat r0; rat touch @H/herdr/stdin-probe
rrun t1
assert_contains "$(rsummary "$RH/herdr/log")" "workspace list Character Device;workspace create Character Device;" "18: the workspace create reads /dev/null"
RSTDIN=/dev/null
# 19. the scope grammar is read per its text under any locale: AC_SCOPE=é is
#     no scope, and the id's family groups.
RLC=""; RENV=(LANG=en_US.UTF-8 "AC_SCOPE=$(printf '\303\251')")
rat r0
rrun t1
assert_eq "$RRC:$(rout)" "0:$RDONE" "19: é is no scope under UTF-8"
RLC=C; RENV=()
# 20. a meta holding a NUL keeps every byte through the window= rewrite.
rat rmate t1 $'backend=herdr\nkind=ship\nworktree=/tmp/wt\nsession_id=sid-1\nnote=a\001b\n'
rat sh -c 'printf "note2=x\\000y\\n" >>"$0"' @H/home/state/t1.meta
rrun t1
printf 'backend=herdr\nkind=ship\nworktree=/tmp/wt\nsession_id=sid-1\nnote=a\001b\nnote2=x\000y\nwindow=herdr:pane-pN\n' >"$TMP/rmeta.want"
cmp -s "$TMP/rmeta.want" "$RH/home/state/t1.meta" || fail "20: a meta's bytes are kept: $(od -c "$RH/home/state/t1.meta" | head -n 8)"
# 21. writes that fail: a status log that is a directory and a read-only handle
#     end the run with 1.
rat r0; rat mkdir @H/home/state/t1.status
rrun t1
assert_eq "$RRC" "1" "21: a status log that cannot be written ends the run"
if [ "$(id -u)" != 0 ]; then
  rat r0; rat chmod 444 @H/home/state/.pane-t1
  rrun t1
  assert_eq "$RRC" "1" "21: a handle that cannot be written ends the run"
fi
# 22. argv arrives decoded: a byte that is not UTF-8 in the id is U+FFFD in
#     the refusal.
rat r0
rrun "$(printf 'a\351')"
assert_eq "$RRC:$(rerr)" "1:ERROR: no such task in flight: $(printf 'a\357\277\275')" "22: a non-UTF-8 id"
# 23. an AC_HOME cd cannot enter is named.
RENV=(AC_HOME=@H/missing)
rrun t1
assert_eq "$RRC:$(rout):$(head -n 1 "$TMP/n.err2")" "1::ERROR: AC_HOME is not a readable directory: @H/missing" "23: an unenterable AC_HOME"
RENV=()
# 24. bun absent from PATH: the shim refuses.
rat r0
RPATH="$RBIN:$TMP/rjq:$TMP/rbase"
if [ -z "$(PATH="$RPATH" command -v bun || true)" ]; then
  rrun t1
  assert_eq "$RRC:$(rout):$(rerr)" "1::ERROR: required tool not found: bun" "24: bun absent"
else
  printf 'SKIP: row 24 bun-absent - bun sits in /usr/bin or /bin on this host\n'
fi
RPATH=""

pass
