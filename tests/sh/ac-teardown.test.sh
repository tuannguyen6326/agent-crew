#!/usr/bin/env bash
# ac-teardown.test.sh - the differential leg of src/teardown.ts: the shim
# ($BIN/ac-teardown.sh) beside the frozen bash original
# (tests/fixtures/ac-teardown.sh, run from make_oracle_bin's copy of bin/),
# row by row in the order of the module's header - each row's exit status,
# stdout, stderr and world compared whole, every named divergence its own
# row. The black-box contract lives in tests/sh/ac-spawn-teardown.test.sh and
# the suites that tear down through the entry.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_fake_orca

# --- differential: src/teardown.ts against the frozen bash original --------
# DISPUTED: the implementation (tests/fixtures/ac-teardown.sh under bash vs src/teardown.ts through bin/ac-teardown.sh)
# HELD-CONSTANT: two side roots seeded alike ($XOH for the oracle, $XNH for the shim) - a home at <side>/home (records/ state/ data/ config/), repos at <side>/r* built by the same commands with fixed author/committer dates and one git config (GIT_CONFIG_GLOBAL, no system config) so every sha matches, an optional bare origin beside them, pool slots leased by the same ac-tree.sh get under a PATH `od` (one lease_id), the fake herdr and orca (tests/sh/helpers.sh) with their state at <side>/fh and <side>/fo; argv and env (the side root spelled @H, substituted in values only); cwd (<side>/cwd, an EMPTY dir, unless a row names a repo); stdin (/dev/null); LC_ALL=C unless a row names en_US.UTF-8; PATH stubs on both sides - date answering one instant per format, od one fixed 8 bytes, sleep logging each call (and returning at once while <side>/stub/sleep.fast exists), a logging docker only where a row plants it - plus a row's own stubs; the live bin/ beside each entry (the oracle bin's copies, $BIN's own); exit status, stdout and stderr compared whole (the side root spelled @H, either bin root ROOT, the entry's pid PID, a mktemp stamp @STAMP), then the world a row may touch: every path under the side root (git objects aside), every file under the home with its bytes, each repo's branches, worktrees and slot metas, each slot's HEAD and porcelain, the fake herdr's log and tabs, the fake orca's log and terminals, and the docker log.
xobin="$(make_oracle_bin ac-teardown)"
cmp -s "$xobin/ac-teardown.sh" "$ROOT/tests/fixtures/ac-teardown.sh" || fail "the oracle bin holds the frozen original"
XOH="$TMP/xside-o"; XNH="$TMP/xside-n"
XSTUBS="$TMP/xstubs"; mkdir -p "$XSTUBS"
XDOCKER="$TMP/xdocker"; mkdir -p "$XDOCKER"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' >"$TMP/xgitconfig"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/xgitconfig"
export GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
cat >"$XSTUBS/date" <<'STUB'
#!/bin/sh
case "$*" in
  *%Y-%m-%dT*) echo 2026-01-01T00:00:00Z ;;
  *%Y-%m-%d*) echo 2026-01-01 ;;
  *%s*) echo 1767225600 ;;
  *) exec /bin/date "$@" ;;
esac
STUB
cat >"$XSTUBS/od" <<'STUB'
#!/bin/sh
case "$*" in *urandom*) printf ' 00 11 22 33 44 55 66 77\n' ;; *) exec /usr/bin/od "$@" ;; esac
STUB
cat >"$XSTUBS/sleep" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/sleep.log"
[ ! -e "$STUB_DIR/sleep.fast" ] || exit 0
exec /bin/sleep "$@"
STUB
# docker: logs its argv per side; docker.fail-<task> fails that task's down
# (exit 7), docker.hang parks it (its pid recorded, TERM ignored by nothing),
# docker.signal sends <signal> to the recorded teardown pid first.
cat >"$XDOCKER/docker" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$STUB_DIR/docker.log"
if [ -e "$STUB_DIR/docker.signal" ]; then
  kill -"$(cat "$STUB_DIR/docker.signal")" "$(cat "$STUB_DIR/td.pid")"
  rm -f "$STUB_DIR/docker.signal"
fi
if [ -e "$STUB_DIR/docker.hang" ]; then
  printf '%s\n' "$$" >"$STUB_DIR/docker.pid"
  exec /bin/sleep 30
fi
for f in "$STUB_DIR"/docker.fail-*; do
  [ -e "$f" ] || continue
  case "$*" in *"-${f##*docker.fail-} down"*) exit 7 ;; esac
done
exit 0
STUB
chmod +x "$XSTUBS/date" "$XSTUBS/od" "$XSTUBS/sleep" "$XDOCKER/docker"
xboth() {  # xboth <cmd> <args...> - a seeding step at each side root: H names it, and so does a literal @H in an argument
  local h x a; for h in "$XOH" "$XNH"; do H="$h"; a=(); for x in "$@"; do a+=("${x//@H/$h}"); done; "${a[@]}"; done
}
xseed() { rm -rf "$H"; mkdir -p "$H/home/records" "$H/home/state" "$H/home/data" "$H/home/config" "$H/cwd" "$H/stub" "$H/fh/panes" "$H/fh/tabs" "$H/fo/terminals"; }
xrepo() {  # xrepo <name> - a repo with one commit on main
  git init -q -b main "$H/$1"; printf 'hello\n' >"$H/$1/file.txt"; git -C "$H/$1" add -A; git -C "$H/$1" commit -qm init
}
xorigin() {  # xorigin <repo> - a bare origin at <repo>.git, main pushed and fetched
  git init -q --bare -b main "$H/$1.git"; git -C "$H/$1" remote add origin "$H/$1.git"
  git -C "$H/$1" push -q origin main 2>/dev/null; git -C "$H/$1" fetch -q origin
}
xput() { mkdir -p "$(dirname "$H/$1")"; printf '%s' "${2//@H/$H}" >"$H/$1"; }   # xput <path under the side> <bytes>
xcommit() {  # xcommit <tree under the side> <file> - one more commit there
  printf '%s\n' "$2" >"$H/$1/$2"; git -C "$H/$1" add "$2"; git -C "$H/$1" commit -qm "$2"
}
xtree() {  # xtree <args...> - the live ac-tree.sh at this side, its home and stubs
  env -u AC_FLEET_STATE AC_HOME="$H/home" PATH="$XSTUBS:$PATH" STUB_DIR="$H/stub" LC_ALL=C "$BIN/ac-tree.sh" "$@" </dev/null 2>/dev/null
}
xlease() {  # xlease <repo> <id> - one leased slot, the meta's worktree/leases/lease_ids
  local wt; wt="$(xtree get --repo "$H/$1" --id "$2")"
  printf 'kind=ship\nbackend=herdr\nproject_dir=%s\nworktree=%s\nleases=%s\nlease_ids=0011223344556677\n' "$H/$1" "$wt" "$wt" >"$H/home/state/$2.meta"
}
xtab() {  # xtab <id> <n> [<label>] - the fake herdr's tab t<n> / pane p<n> and state/.pane-<id>
  printf 'p%s %s\n' "$2" "${3-crew:$1}" >"$H/fh/tabs/t$2"; : >"$H/fh/panes/p$2.buf"
  printf 'p%s t%s\n' "$2" "$2" >"$H/home/state/.pane-$1"
}
XLC=C; XENV=(); XHOMELESS=0; XCWD=cwd; XGONE=0; XPRE=""; XPATH=""; XDOCK=0; XNBIN="$BIN"
xrun_side() {  # xrun_side <bin> <side root> <prefix> <args...>
  local bin="$1" h="$2" p="$3" x v path; shift 3
  path="$XSTUBS:$PATH"; [ "$XDOCK" = 0 ] || path="$XDOCKER:$path"; [ -z "$XPRE" ] || path="${XPRE//@H/$h}:$path"; [ -z "$XPATH" ] || path="${XPATH//@H/$h}"
  local a=() e=("LC_ALL=$XLC" "PATH=$path" "STUB_DIR=$h/stub" "FAKE_HERDR=$h/fh" "FAKE_ORCA=$h/fo" "AC_HERDR_RPC_TIMEOUT=10")
  [ "$XHOMELESS" = 1 ] || e+=("AC_HOME=$h/home")
  for x in ${XENV[@]+"${XENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$h}"); done
  for x in "$@"; do a+=("${x//@H/$h}"); done
  (cd "$h/$XCWD" && { [ "$XGONE" != 1 ] || rmdir "$h/$XCWD"; } && exec env -u AC_HOME -u AC_FLEET_STATE -u AC_BACKEND -u AC_HERDR_SESSION -u AC_TEARDOWN_QA_TIMEOUT -u AC_LOCK_STALE_GRACE -u EPOCHSECONDS \
    "${e[@]}" /bin/sh -c 'printf %s "$$" >"$0"; printf %s "$$" >"$1"; shift; exec "$@"' "$TMP/$p.pid" "$h/stub/td.pid" "$bin/ac-teardown.sh" ${a[@]+"${a[@]}"}) </dev/null >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
xnorm() {  # xnorm <file> <side root> <pid> - the pid only between non-hex bytes, never inside a sha
  LC_ALL=C sed -E -e "s#$2#@H#g" -e "s#$TMP/oracle-ac-teardown#ROOT#g" -e "s#$ROOT#ROOT#g" \
    -e "s/(^|[^0-9a-f])$3([^0-9a-f]|\$)/\\1PID\\2/g" -e "s/(^|[^0-9a-f])$3([^0-9a-f]|\$)/\\1PID\\2/g" \
    -e 's/1767225600\.[A-Za-z0-9]{6}/1767225600.@STAMP/g' -e 's#(\.wake-spool/[0-9]+)\.[0-9]+\.#\1.WPID.#g' "$1"
}
XO_RC=0; XN_RC=0
xpair() {  # xpair <args...> - both sides run, outputs normalised, nothing compared yet
  XO_RC=0; XN_RC=0
  xrun_side "$xobin" "$XOH" xo "$@" || XO_RC=$?
  xrun_side "$XNBIN" "$XNH" xn "$@" || XN_RC=$?
  xnorm "$TMP/xo.raw" "$XOH" "$(cat "$TMP/xo.pid")" >"$TMP/xo.out"; xnorm "$TMP/xo.err" "$XOH" "$(cat "$TMP/xo.pid")" >"$TMP/xo.err2"
  xnorm "$TMP/xn.raw" "$XNH" "$(cat "$TMP/xn.pid")" >"$TMP/xn.out"; xnorm "$TMP/xn.err" "$XNH" "$(cat "$TMP/xn.pid")" >"$TMP/xn.err2"
}
xrow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
xsame_rc_out() {
  assert_eq "$XN_RC" "$XO_RC" "teardown differential exit for '$*' at line $(xrow)"
  cmp -s "$TMP/xo.out" "$TMP/xn.out" || fail "teardown differential stdout differs for '$*' at line $(xrow): $(diff "$TMP/xo.out" "$TMP/xn.out" | head -n 8)"
}
xsame_err() {
  cmp -s "$TMP/xo.err2" "$TMP/xn.err2" || fail "teardown differential stderr differs for '$*' at line $(xrow): $(diff "$TMP/xo.err2" "$TMP/xn.err2" | head -n 8)"
}
xworld() {  # xworld <side root> - what a row may change
  local h="$1" r f w
  (cd "$h" && find . -path '*/.git' -prune -o -path ./stub/sleep.log -prune -o -path ./stub/td.pid -prune -o -path ./home/records/task-tokens.tsv -prune -o -print 2>/dev/null | LC_ALL=C sort)
  (cd "$h" && find home stub fh fo -type f ! -name sleep.log ! -name td.pid ! -name docker.pid ! -name task-tokens.tsv 2>/dev/null | LC_ALL=C sort) | while IFS= read -r f; do
    printf '== %s %s\n' "$f" "$(ls -l "$h/$f" | cut -c1-10)"; cat "$h/$f" 2>/dev/null || printf '<unreadable>'; printf '\n'
  done
  for r in "$h"/r*; do
    [ -d "$r/.git" ] || continue
    printf '== repo %s\n' "$r"
    git -C "$r" for-each-ref --format='%(refname) %(objectname)' refs/heads 2>&1 || true
    git -C "$r" worktree list --porcelain 2>&1 || true
    for f in "$r"/.crew/slots/* "$r"/.crew/lock/pid; do
      [ -f "$f" ] || continue
      printf '== %s\n' "$f"; cat "$f" 2>/dev/null || printf '<unreadable>'; printf '\n'
    done
    for w in "$r"/.crew/worktrees/*; do
      [ -d "$w" ] || continue
      printf '== slot %s\n' "$w"; git -C "$w" status --porcelain=v2 --branch 2>&1 || true
    done
  done
}
xsame_world() {
  xworld "$XOH" >"$TMP/xo.world"; xworld "$XNH" >"$TMP/xn.world"
  xnorm "$TMP/xo.world" "$XOH" "$(cat "$TMP/xo.pid")" >"$TMP/xo.world2"; xnorm "$TMP/xn.world" "$XNH" "$(cat "$TMP/xn.pid")" >"$TMP/xn.world2"
  cmp -s "$TMP/xo.world2" "$TMP/xn.world2" || fail "teardown differential world differs after '$*' at line $(xrow): $(diff "$TMP/xo.world2" "$TMP/xn.world2" | head -n 12)"
}
xsame() { xpair "$@"; xsame_rc_out "$@"; xsame_err "$@"; xsame_world "$@"; }
xout() { cat "$TMP/xn.out"; }
xerr() { cat "$TMP/xn.err2"; }
xoerr() { cat "$TMP/xo.err2"; }
xrefuse() {  # xrefuse <stderr> <args...> - both sides refuse alike: exit 1, no stdout, exactly <stderr>
  local want="$1"; shift
  xsame "$@"
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::$want" "teardown refusal for '$*' at line $(xrow)"
}
# SHELL-OWN STDERR (named): the original's `<script>: line N: ...` lines are
# dropped from its stderr before the compare; the port never prints them.
xsame_shellnoise() {
  xpair "$@"; xsame_rc_out "$@"
  grep -q -E ': line [0-9]+: ' "$TMP/xo.err2" || fail "the row at line $(xrow) names shell noise the original did not print: $(xoerr)"
  grep -v -E ': line [0-9]+: ' "$TMP/xo.err2" >"$TMP/xo.err3" || true
  cmp -s "$TMP/xo.err3" "$TMP/xn.err2" || fail "teardown differential stderr (shell lines aside) differs for '$*' at line $(xrow): $(diff "$TMP/xo.err3" "$TMP/xn.err2" | head -n 8)"
  xsame_world "$@"
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
  printf '%s:%s\n' "$XSTUBS" "$out"
}
XNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
XUSAGE="ERROR: usage: ac-teardown.sh <id> [--force] [--pr-ready '<the captain acceptance>'] [--no-lesson '<why>'] [--no-fact '<why>']"
xstub() {  # xstub <name> <body> - a stub at <side>/stubs, ahead of the leg's own when XPRE names it
  mkdir -p "$H/stubs"; printf '%s\n' "$2" >"$H/stubs/$1"; chmod +x "$H/stubs/$1"
}
XROOTED=0; [ "$(id -u)" != 0 ] || XROOTED=1

# 1. arguments, the home and the meta, in code order: the usage line (no
#    word, ''), the id always the FIRST word (W1: -h is an id, `--force t1`
#    an unknown argument), the three value flags absent or empty, a value
#    flag swallowing the next word (W2 - row 4 lands it), repeats, no meta, a
#    meta that is a directory, homeless (with AC_FLEET_STATE too), an AC_HOME
#    cd cannot enter (HOME RESOLUTION, named), an unreadable meta, an invalid
#    ambient backend (checked before the usage, as sourcing did), git absent.
xboth xseed
xrefuse "$XUSAGE"
xrefuse "$XUSAGE" ""
xrefuse "ERROR: no crewmate meta for -h" -h
xrefuse "ERROR: unknown argument: t1" --force t1
xrefuse "ERROR: unknown argument: --bogus" x --bogus
xrefuse "ERROR: --pr-ready carries the captain's acceptance words - they are the proof, so an empty value is refused" x --pr-ready
xrefuse "ERROR: --pr-ready carries the captain's acceptance words - they are the proof, so an empty value is refused" x --pr-ready ''
xrefuse "ERROR: --no-lesson carries why the slice learned nothing new - it is the record, so an empty value is refused" x --no-lesson
xrefuse "ERROR: --no-lesson carries why the slice learned nothing new - it is the record, so an empty value is refused" x --force --no-lesson ''
xrefuse "ERROR: --no-fact carries why the slice verified no repo fact - it is the record, so an empty value is refused" x --no-fact
xrefuse "ERROR: --no-fact carries why the slice verified no repo fact - it is the record, so an empty value is refused" x --no-fact ''
xrefuse "ERROR: unknown argument: y" x --no-fact why y
xrefuse "ERROR: no crewmate meta for x" x --force --force --pr-ready a --pr-ready b --no-lesson l --no-fact f
xrefuse "ERROR: unknown argument: b" x --pr-ready a b --force
xboth mkdir -p @H/home/state/d.meta
xrefuse "ERROR: no crewmate meta for d" d
XHOMELESS=1
xrefuse "$XNOHOME" x
XENV=("AC_FLEET_STATE=@H/home/state")
xrefuse "$XNOHOME" x
XENV=()
xrefuse "$XUSAGE"
XHOMELESS=0
XENV=("AC_HOME=@H/nope")
xpair x
xsame_rc_out x
assert_eq "$XN_RC:$(xerr)" "1:ERROR: AC_HOME is not a readable directory: @H/nope" "1 (HOME RESOLUTION, named): an AC_HOME cd cannot enter is named"
grep -q -E ': line [0-9]+: cd: ' "$TMP/xo.err2" || fail "1: the original's line for that home is cd's own"
XENV=()
if [ "$XROOTED" = 0 ]; then
  xboth xput home/state/u.meta 'kind=ship
'
  xboth chmod 000 @H/home/state/u.meta
  xrefuse "WARN: cannot read meta file @H/home/state/u.meta" u
  xboth chmod 644 @H/home/state/u.meta
fi
xboth xput home/config/backend 'tmux
'
xrefuse "ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)"
xrefuse "ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" u
XENV=("AC_BACKEND=orca")
xrefuse "$XUSAGE"
XENV=()
xboth rm -f @H/home/config/backend
XPATH="$(xwithout git)"
xrefuse "ERROR: required tool not found: git" u
XPATH=""

# 2. the ship proofs: a fresh slot; a branch landed in local main, only on
#    origin's main (kept with git's own -d text), only as its own pushed
#    branch (not landed), inside another remote branch, inside the epic branch
#    (heads, -D); an unreadable ledger at the proof and at the drop;
#    pr_merged with and without pr_merged_head and a commit past it; a
#    detached commit; a commit past the landed branch; dirty (UNTRACKED-ONLY,
#    named: the port lists untracked-only dirt, ten paths at most), an
#    assume-unchanged edit; a revision on its family's branch; a slot whose
#    gitdir is gone (W8, named: the original read it clean and only the
#    pool's return refused it; the port refuses at the gate).
XS=r/.crew/worktrees/1-r
x2() { xseed; xrepo r; xlease r t; xtab t 1; }
x2br() { git -C "$H/$XS" checkout -q -b crew/t; xcommit "$XS" work.txt; }
xboth x2
xsame t
assert_eq "$XN_RC:$(xout)" "0:teardown t complete" "2: a fresh slot lands"
assert_contains "$(cat "$XNH/home/state/archive/t/status")" "resolved: teardown" "2: ...archived with its record"
x2b() { x2; x2br; git -C "$H/r" merge -q --ff-only crew/t; }
xboth x2b
xsame t
assert_eq "$XN_RC:$(xout)" "0:teardown t complete" "2: a branch landed in local main lands"
# TOKEN LEDGER (named): the port appends the task's claude token use, per
# model, to records/task-tokens.tsv once the pane is closed; the original
# wrote nothing, so the world comparison leaves that file out and these rows
# pin it - a repeated usage line of one message counted once, subagents in.
XSID=5e551011-0000-4000-8000-000000000001
x2tk() {
  x2b; printf 'harness=claude\nsession_id=%s\n' "$XSID" >>"$H/home/state/t.meta"
  mkdir -p "$H/tx/-w/$XSID/subagents"
  printf '%s\n' '{"message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":3,"cache_creation_input_tokens":20,"cache_read_input_tokens":100,"output_tokens":1}}}' \
    '{"message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":3,"cache_creation_input_tokens":20,"cache_read_input_tokens":100,"output_tokens":9}}}' \
    '{"type":"user","message":{"role":"user","content":"hi"}}' >"$H/tx/-w/$XSID.jsonl"
  printf '%s\n' '{"message":{"id":"s1","model":"claude-haiku-5-5","usage":{"input_tokens":1,"cache_creation_input_tokens":2,"cache_read_input_tokens":3,"output_tokens":4}}}' >"$H/tx/-w/$XSID/subagents/agent-a.jsonl"
}
XENV=("AC_CLAUDE_TRANSCRIPT_ROOT=@H/tx")
xboth x2tk
xsame t
XENV=()
assert_eq "$XN_RC" 0 "2 (TOKEN LEDGER): the task lands"
assert_eq "$(cat "$XNH/home/records/task-tokens.tsv")" "$(printf 'at\tid\tkind\tharness\tmodel\tinput\tcache_creation\tcache_read\toutput\n2026-01-01T00:00:00Z\tt\tship\tclaude\tclaude-haiku-5-5\t1\t2\t3\t4\n2026-01-01T00:00:00Z\tt\tship\tclaude\tclaude-opus-5-5\t3\t20\t100\t9')" "2 (TOKEN LEDGER, named): one row per model, a repeated message once, its subagents in"
[ ! -e "$XOH/home/records/task-tokens.tsv" ] || fail "2 (TOKEN LEDGER): the original wrote no ledger"
xboth x2b
xsame t
assert_eq "$(cat "$XNH/home/records/task-tokens.tsv")" "$(printf 'at\tid\tkind\tharness\tmodel\tinput\tcache_creation\tcache_read\toutput\n2026-01-01T00:00:00Z\tt\tship\t-\tunknown: no session_id\t\t\t\t')" "2 (TOKEN LEDGER, named): a task with no claude session is unknown, never zero"
x2tm() { x2tk; rm -f "$H/tx/-w/$XSID.jsonl"; }
XENV=("AC_CLAUDE_TRANSCRIPT_ROOT=@H/tx")
xboth x2tm
xsame t
XENV=()
assert_eq "$(tail -n 1 "$XNH/home/records/task-tokens.tsv")" "$(printf '2026-01-01T00:00:00Z\tt\tship\tclaude\tunknown: no transcript for session %s\t\t\t\t' "$XSID")" "2 (TOKEN LEDGER, named): a session whose transcript is gone is unknown"
assert_eq "$(git -C "$XNH/r" branch --list crew/t)" "" "2: ...and the merged branch is dropped"
x2tdot() { x2tk; mkdir -p "$H/tx/.trash"; cp "$H/tx/-w/$XSID.jsonl" "$H/tx/.trash/"; }
XENV=("AC_CLAUDE_TRANSCRIPT_ROOT=@H/tx")
xboth x2tdot
xsame t
XENV=()
assert_eq "$(tail -n 2 "$XNH/home/records/task-tokens.tsv")" "$(printf '2026-01-01T00:00:00Z\tt\tship\tclaude\tclaude-haiku-5-5\t1\t2\t3\t4\n2026-01-01T00:00:00Z\tt\tship\tclaude\tclaude-opus-5-5\t3\t20\t100\t9')" "2 (TOKEN LEDGER): a copy under a dot dir is no second transcript, as <root>/*/<sid>.jsonl reads it"
x2c() { x2; xorigin r; x2br; git -C "$H/r" push -q origin crew/t:main 2>/dev/null; git -C "$H/r" fetch -q origin; }
xboth x2c
xsame t
assert_eq "$XN_RC" 0 "2: origin's main holds it"
assert_contains "$(xerr)" "WARN: kept crew/t in @H/r: error: the branch 'crew/t' is not fully merged" "2: ...-d refuses in git's own words"
x2d() { x2; xorigin r; x2br; git -C "$H/r" push -q origin crew/t 2>/dev/null; git -C "$H/r" fetch -q origin; }
xboth x2d
xrefuse "branch crew/t ($(git -C "$XNH/r" rev-parse crew/t | cut -c1-12)) is not landed: not in main (local or origin), no containing remote branch, no merged PR
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
x2e() { x2; xorigin r; x2br; git -C "$H/r" push -q origin crew/t:other 2>/dev/null; git -C "$H/r" fetch -q origin; }
xboth x2e
xsame t
assert_eq "$XN_RC" 0 "2: another remote branch holds it"
x2f() {
  x2; x2br; git -C "$H/r" branch ep/e1 crew/t
  xput home/records/backlog.md '# B
## In flight
- [ ] t - story epic:e1 (repo: r)
'
  xput home/data/e1/branches 'r ep/e1
'
}
xboth x2f
xsame t
assert_eq "$XN_RC:$(git -C "$XNH/r" branch --list crew/t)" "0:" "2: the epic branch holds it, and -D drops it"
x2g() { x2b; xput home/records/backlog.md '- [ ] t - x
'; chmod 000 "$H/home/records/backlog.md"; }
x2g2() { x2; x2br; xput home/records/backlog.md '- [ ] t - x
'; chmod 000 "$H/home/records/backlog.md"; }
if [ "$XROOTED" = 0 ]; then
  xboth x2g
  xsame t
  assert_eq "$(xerr)" "WARN: cannot read the ledger to resolve the epic-branch fence for t - crew/t is deleted only if -d proves it merged" "2: an unreadable ledger at the drop"
  xboth chmod 644 @H/home/records/backlog.md
  xboth x2g2
  xpair t
  xboth chmod 644 @H/home/records/backlog.md
  xsame_rc_out t; xsame_err t; xsame_world t
  assert_contains "$(xerr)" "WARN: cannot read the ledger to resolve the epic-branch fence for t - containment in an epic branch stays unproven" "2: an unreadable ledger at the proof"
fi
x2h() { x2; x2br; printf 'pr_merged=1\n' >>"$H/home/state/t.meta"; }
xboth x2h
xsame t
assert_eq "$XN_RC" 0 "2: a merged PR with no recorded head lands"
x2h2() { x2; x2br; printf 'pr_merged=1\npr_merged_head=%s\n' "$(git -C "$H/r" rev-parse crew/t)" >>"$H/home/state/t.meta"; }
xboth x2h2
xsame t
assert_eq "$XN_RC" 0 "2: a merged PR that contains the head lands"
x2h3() { x2h2; xcommit "$XS" past.txt; }
xboth x2h3
xsame t
assert_eq "$XN_RC" 1 "2: a commit past the merged PR's head is not landed"
x2i() { x2; xcommit "$XS" loose.txt; }
xboth x2i
xsame t
assert_contains "$(xerr)" "holds commits no branch carries and nothing landed contains; put them on crew/t (git -C @H/$XS branch crew/t " "2: a detached commit is refused"
x2j() { x2b; git -C "$H/$XS" checkout -q --detach; xcommit "$XS" past.txt; }
xboth x2j
xsame t
assert_contains "$(xerr)" "is past the landed crew/t" "2: a commit past the landed branch is refused"
x2k() { x2b; printf 'x\n' >"$H/$XS/untracked.txt"; }
xboth x2k
xpair t
assert_eq "$XO_RC:$(xoerr)" "1:worktree is dirty: uncommitted changes that crew/t does not hold; commit them or --force to discard
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" "2 (UNTRACKED-ONLY): the original said only that the tree is dirty"
assert_eq "$XN_RC:$(xout):$(xerr)" "1::worktree is dirty: uncommitted changes that crew/t does not hold; commit them or --force to discard
untracked only, no tracked edits: untracked.txt
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" "2 (UNTRACKED-ONLY, named): the port names untracked-only dirt and its paths"
x2kt() { x2k; printf 'edit\n' >>"$H/$XS/file.txt"; }
xboth x2kt
xrefuse "worktree is dirty: uncommitted changes that crew/t does not hold; commit them or --force to discard
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
x2kc() { x2b; for f in a b c d e f g h i j k l; do printf 'x\n' >"$H/$XS/$f.txt"; done; }
xboth x2kc
xpair t
assert_contains "$(xerr)" "
untracked only, no tracked edits: a.txt, b.txt, c.txt, d.txt, e.txt, f.txt, g.txt, h.txt, i.txt, j.txt (+2 more)
" "2 (UNTRACKED-ONLY, named): at most ten paths are listed"
x2kn() { x2; printf 'x\n' >"$H/$XS/scratch.log"; }
xboth x2kn
xpair t
assert_eq "$XO_RC:$(xoerr)" "1:worktree is dirty and no crew/t branch exists
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" "2 (UNTRACKED-ONLY): no branch, the original said only that the tree is dirty"
assert_eq "$XN_RC:$(xout):$(xerr)" "1::worktree is dirty and no crew/t branch exists
untracked only, no tracked edits: scratch.log
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" "2 (UNTRACKED-ONLY, named): ...and the port names it with no branch too"
x2l() { x2b; git -C "$H/$XS" update-index --assume-unchanged file.txt; printf 'edit\n' >>"$H/$XS/file.txt"; }
xboth x2l
xsame t
assert_eq "$XN_RC" 1 "2: an assume-unchanged edit is dirty"
x2m() {
  xseed; xrepo r; xlease r t12-r2; xtab t12-r2 1
  git -C "$H/$XS" checkout -q -b crew/t12; xcommit "$XS" work.txt; git -C "$H/r" merge -q --ff-only crew/t12
}
xboth x2m
xsame t12-r2
assert_eq "$XN_RC:$(git -C "$XNH/r" branch --list 'crew/*')" "0:" "2: a revision lands on its family's crew/t12, which is dropped"
x2n() { x2; printf 'gitdir: %s/nowhere\n' "$H" >"$H/$XS/.git"; }
xboth x2n
xpair t
assert_eq "$XO_RC" 0 "2 (W8): the original read a slot git cannot read as clean"
assert_contains "$(xoerr)" "WARN: could not return worktree @H/$XS (it may have been re-leased); check the pool with ac-tree.sh list" "2 (W8): ...and only the pool's return refused it"
assert_eq "$XN_RC:$(xout)" "1:" "2 (W8, named): the port refuses a worktree git cannot read"
assert_contains "$(xerr)" "worktree @H/$XS cannot be read by git, so its contents cannot be checked; repair it or --force to discard" "2 (W8, named): ...naming it"
[ -e "$XNH/home/state/t.meta" ] || fail "2 (W8, named): ...with nothing archived"
x2nb() { x2; x2br; git -C "$H/r" merge -q --ff-only crew/t; printf 'gitdir: %s/nowhere\n' "$H" >"$H/$XS/.git"; }
xboth x2nb
xpair t
assert_eq "$XO_RC" 0 "2 (W8): the original passed a slot git cannot read past its landed branch"
assert_eq "$XN_RC:$(xout)" "1:" "2 (W8, named): the port refuses it with a branch head too"
assert_contains "$(xerr)" "worktree @H/$XS cannot be read by git, so its contents cannot be checked; repair it or --force to discard" "2 (W8, named): ...naming it"

# 3. scouts: the report missing (flat, nested, merged design) and present at
#    each of those; an unlanded crew branch; dirty; HEAD past the branch; an
#    ambiguous task dir (W21: taskDir's ERROR, then the generic refusal).
x3() { xseed; xrepo r; xlease r "$1"; xtab "$1" 1; printf 'kind=scout\n' >>"$H/home/state/$1.meta"; }
xboth x3 s1
xrefuse "scout report missing: no report.md at @H/home/data/s1 (nor merged-design sub-stage reports)
ERROR: refusing teardown of s1 (unlanded work); land it or pass --force to discard" s1
xboth xput home/data/s1/report.md 'r'
xsame s1
assert_eq "$XN_RC" 0 "3: a flat report lands"
x3n() { x3 fam-spec; xput home/data/fam/spec/brief.md 'b'; }
xboth x3n
xrefuse "scout report missing: no report.md at @H/home/data/fam/spec (nor merged-design sub-stage reports)
ERROR: refusing teardown of fam-spec (unlanded work); land it or pass --force to discard" fam-spec
xboth xput home/data/fam/spec/report.md 'r'
xsame fam-spec
assert_eq "$XN_RC" 0 "3: a nested report lands"
for xstage in spec arch plan; do
  x3d() { x3 fd-design-r2; xput home/data/fd/design-r2/brief.md 'b'; xput "home/data/fd/$xstage/report.md" 'r'; }
  xboth x3d
  xsame fd-design-r2
  assert_eq "$XN_RC" 0 "3: a merged design scout's $xstage report lands it"
done
x3e() { x3 fe-design; xput home/data/fe/design/brief.md 'b'; }
xboth x3e
xsame fe-design
assert_eq "$XN_RC" 1 "3: a merged design scout with no sub-stage report"
x3b() { x3 s3; xput home/data/s3/report.md 'r'; printf 'gitdir: %s/nowhere\n' "$H" >"$H/$XS/.git"; }
xboth x3b
xpair s3
assert_eq "$XO_RC" 0 "3 (W8): the original passed a scout whose tree git cannot read"
assert_eq "$XN_RC:$(xout)" "1:" "3 (W8, named): the port refuses it"
assert_contains "$(xerr)" "worktree @H/$XS cannot be read by git, so its contents cannot be checked; repair it or --force to discard" "3 (W8, named): ...naming it"
x3u() { x3 s2; xput home/data/s2/report.md 'r'; git -C "$H/$XS" checkout -q -b crew/s2; xcommit "$XS" w.txt; }
xboth x3u
xrefuse "scout created crew/s2 with unlanded work; promote it (ac-promote.sh s2) or --force to discard
ERROR: refusing teardown of s2 (unlanded work); land it or pass --force to discard" s2
x3k() { x3 s3; xput home/data/s3/report.md 'r'; printf 'x\n' >"$H/$XS/u.txt"; }
xboth x3k
xpair s3
assert_eq "$XO_RC:$(xoerr)" "1:worktree is dirty: uncommitted changes that crew/s3 does not hold; commit them or --force to discard
ERROR: refusing teardown of s3 (unlanded work); land it or pass --force to discard" "3 (UNTRACKED-ONLY): the original said only that the scout's tree is dirty"
assert_eq "$XN_RC:$(xout):$(xerr)" "1::worktree is dirty: uncommitted changes that crew/s3 does not hold; commit them or --force to discard
untracked only, no tracked edits: u.txt
ERROR: refusing teardown of s3 (unlanded work); land it or pass --force to discard" "3 (UNTRACKED-ONLY, named): the port names a scout's untracked-only dirt"
x3p() { x3u; git -C "$H/r" merge -q --ff-only crew/s2; git -C "$H/$XS" checkout -q --detach; xcommit "$XS" past.txt; }
xboth x3p
xsame s2
assert_contains "$(xerr)" "holds commits nothing landed contains; put them on crew/s2 and promote it (ac-promote.sh s2), or --force to discard" "3: a scout's HEAD past its branch"
x3a() { x3 h1; xput home/data/h1/brief.md 'b'; xput home/data/h1/implement/brief.md 'b'; xput home/data/h1/report.md 'r'; }
xboth x3a
xrefuse "ERROR: ambiguous task data for h1: briefs at both @H/home/data/h1/implement and @H/home/data/h1
ERROR: refusing teardown of h1 (unlanded work); land it or pass --force to discard" h1

# 4. --pr-ready: no PR; a dependent (the strict list, a spaced list - wider
#    than the grammar on purpose - and `01` never `1`); an absent and an
#    unreadable ledger; dirty; pr_head newer, with and without a branch; the
#    happy path; --force --pr-ready (W3: both records); a flag swallowing
#    --force (W2: landed UNFORCED on the words `--force`).
x4() { xseed; xrepo r; xlease r "$1"; xtab "$1" 1; printf 'pr=https://pr/1\n' >>"$H/home/state/$1.meta"; xput home/records/backlog.md '# B
'; }
xboth x4 t
xboth sed -i '' '/^pr=/d' @H/home/state/t.meta
xrefuse "ERROR: --pr-ready with no recorded PR for t - record it first (bin/ac-pr-check.sh t <url>)" t --pr-ready 'ok'
for xdep in 'blocked-by: a,t - waits' 'blocked-by: a, t - spaced' 'blocked-by:t'; do
  xboth x4 t
  xboth xput home/records/backlog.md "## Queued
- [ ] dep1 - row $xdep
"
  xrefuse "ERROR: --pr-ready refused: open row dep1 still waits on t (blocked-by) - a dependent starts from the merged tree, so this task lands only by the real merge" t --pr-ready 'ok'
done
x4n() { xseed; xrepo r; xlease r 1; xtab 1 1; printf 'pr=u\n' >>"$H/home/state/1.meta"; xput home/records/backlog.md '- [ ] dep - x blocked-by: 01,t1 - x
- [x] dep2 - x blocked-by: 1 - done rows never wait
'; }
xboth x4n
xsame 1 --pr-ready ok
assert_eq "$XN_RC" 0 "4: a dependent on 01 is no dependent on 1, and a Done row waits on nothing"
xboth x4 t
xboth rm -f @H/home/records/backlog.md
xrefuse "ERROR: --pr-ready refused: cannot read @H/home/records/backlog.md to prove no open row waits on t - an unreadable ledger must not read as 'no dependent'" t --pr-ready ok
if [ "$XROOTED" = 0 ]; then
  xboth x4 t
  xboth chmod 000 @H/home/records/backlog.md
  xpair t --pr-ready ok
  xboth chmod 644 @H/home/records/backlog.md
  xsame_rc_out; xsame_err; xsame_world
  assert_contains "$(xerr)" "cannot read @H/home/records/backlog.md" "4: an unreadable ledger refuses"
fi
x4d() { x4 t; printf 'x\n' >"$H/$XS/u.txt"; }
xboth x4d
xrefuse "ERROR: --pr-ready refused: the worktree holds uncommitted work the accepted PR cannot contain - commit and push it (then re-record the PR head), or discard it deliberately, before the acceptance lands:
?? u.txt" t --pr-ready ok
# A hidden edit (assume-unchanged) under a name that is not ASCII: the
# refusal carries the path's own bytes.
x4u() {
  x4 t; local f; f="caf$(printf '\303\251').txt"
  printf 'v\n' >"$H/$XS/$f"; git -C "$H/$XS" add -- "$f"; git -C "$H/$XS" commit -qm u
  git -C "$H/$XS" update-index --assume-unchanged -- "$f"; printf 'w\n' >"$H/$XS/$f"
}
xboth x4u
xsame t --pr-ready ok
assert_contains "$(xerr)" "$(printf 'H  caf\303\251.txt')" "4: a hidden edit's non-ASCII path keeps its bytes in the refusal"
x4g() { x4 t; printf 'gitdir: %s/nowhere\n' "$H" >"$H/$XS/.git"; }
xboth x4g
xpair t --pr-ready ok
assert_eq "$XO_RC" 0 "4 (W8): the original's --pr-ready read a tree git cannot read as clean"
assert_eq "$XN_RC:$(xout):$(xerr | grep '^ERROR')" "1::ERROR: --pr-ready refused: worktree @H/$XS cannot be read by git, so its contents cannot be checked; repair it or --force to discard" "4 (W8, named): the port's --pr-ready refuses it"
x4h() { x4 t; git -C "$H/$XS" checkout -q -b crew/t; xcommit "$XS" a.txt; printf 'pr_head=%s\n' "$(git -C "$H/$XS" rev-parse HEAD)" >>"$H/home/state/t.meta"; xcommit "$XS" b.txt; }
xboth x4h
xsame t --pr-ready ok
assert_contains "$(xerr)" "--pr-ready refused: HEAD " "4: a head past the recorded PR head is refused"
x4h2() { x4 t; xcommit "$XS" a.txt; printf 'pr_head=%s\n' "$(git -C "$H/$XS" rev-parse HEAD)" >>"$H/home/state/t.meta"; xcommit "$XS" b.txt; }
xboth x4h2
xsame t --pr-ready ok
assert_contains "$(xerr)" "holds commits no branch carries" "4: ...and with no branch, the worktree HEAD past it"
x4ok() { x4 t; git -C "$H/$XS" checkout -q -b crew/t; xcommit "$XS" a.txt; printf 'pr_head=%s\n' "$(git -C "$H/$XS" rev-parse HEAD)" >>"$H/home/state/t.meta"; }
xboth x4ok
xsame t --pr-ready 'captain: ship it'
assert_contains "$(cat "$XNH/home/state/archive/t/status")" "done: captain accepted the ready-to-merge PR - captain: ship it" "4: the acceptance is on the record"
xboth x4ok
xsame t --force --pr-ready 'captain: ship it'
assert_eq "$(sed 's/^[^ ]* //' "$XNH/home/state/archive/t/status")" "done: captain accepted the ready-to-merge PR - captain: ship it
resolved: teardown (forced)" "4 (W3): --force --pr-ready records both"
xboth x4ok
xsame t --pr-ready --force
assert_eq "$(xout):$(sed 's/^[^ ]* //' "$XNH/home/state/archive/t/status")" "teardown t complete:done: captain accepted the ready-to-merge PR - --force
resolved: teardown" "4 (W2): the value flag swallows --force - landed UNFORCED on the words '--force'"

# 5. the knowledge loop (kind=self): nothing written (the hint bytes, the
#    refusal, the line on the record); the waivers and the Done row; a
#    `(solo <id>)` heading, a `(by: <id>,` line and a `(by: <id>-2,` one; a
#    fact; a scoped receipt; two refused attempts then a landing (W4, named:
#    the original recorded the waivers at each, the port at the landing
#    alone); the tick's answers - counted, a keyed duplicate, the cadence
#    lock held (W5, named: the original kept the last line and said nothing,
#    exit 0; the port keeps every line and WARNs, exit 0) and the
#    learning-due crossing; --force owes nothing.
x5() {
  xseed; xrepo r; xlease r "$1"; xtab "$1" 1
  sed -i '' 's/^kind=ship$/kind=self/' "$H/home/state/$1.meta"
}
xboth x5 s1
xsame s1
assert_eq "$XN_RC:$(xerr)" "1:ERROR: solo landing refused: the knowledge loop above is incomplete - write what is missing (or waive the lesson/fact with --no-lesson/--no-fact '<why>'), then run the teardown again" "5: nothing written refuses"
assert_eq "$(cat "$TMP/xn.out")" "knowledge loop: lessons=none repo-knowledge=none done-row=none
missing - the solo contract owes these at landing:
  lesson: ROOT/bin/ac-learn.sh note '### 2026-01-01 (solo s1)' '- <one method lesson>'   (or --no-lesson '<why nothing new>')
  repo fact: ROOT/bin/ac-know.sh add --home @H/home --repo @H/r --family s1 --src-file <path>:<line> --fact '<verified fact>'   (or --no-fact '<why none verified>')
  done row: append '- [x] s1 - <outcome>' under ## Done in @H/home/records/backlog.md" "5: the hint bytes"
x5done() { x5 s1; xput home/records/backlog.md '## Done
- [x] s1 - landed
'; }
xboth x5done
xsame s1 --no-lesson 'nothing new' --no-fact 'none verified'
assert_eq "$XN_RC" 0 "5: the waivers and the Done row land the slice"
[ ! -e "$XNH/home/records/task-tokens.tsv" ] || fail "5 (TOKEN LEDGER): a self task runs no agent, so it records no token use"
assert_contains "$(cat "$XNH/home/state/archive/s1/status")" "learning tick: tick: debriefs=" "5: ...and the tick's answer is on the record"
x5all() {
  x5done; xput home/records/learnings.md '### 2026-01-01 (solo s1)
- a lesson
'; xput home/records/repo-knowledge/r.md '- a fact | by: s1
'
}
xboth x5all
xsame s1
assert_contains "$(xout)" "knowledge loop: lessons=yes repo-knowledge=yes done-row=yes" "5: all three written"
x5by() { x5done; xput home/records/learnings.md '### 2026 (family f)
- x (by: s1-2, first-hand)
'; }
xboth x5by
xpair s1 --no-fact n; xsame_rc_out; xsame_err
assert_eq "$XN_RC" 1 "5: (by: s1-2, is not s1's lesson"
assert_eq "$(grep -c ' repo fact waived: ' "$XNH/home/state/s1.status" || true)" 0 "5 (W4, named): ...and the refusal records no waiver"
x5sc() { x5 f-s1; printf 'fleet_scope=f\n' >>"$H/home/state/f-s1.meta"; xput home/data/f/room.md '- [2026] f-chief> LANDED: f-s1 - ok
'; }
xboth x5sc
xsame f-s1 --no-lesson n --no-fact n
assert_contains "$(xout)" "landed-receipt=yes" "5: a scoped slice's receipt"
xboth x5done
xpair s1 --no-lesson 'nothing new'; xsame_rc_out; xsame_err
assert_eq "$(grep -c ' lesson waived: \| repo fact waived: ' "$XNH/home/state/s1.status" || true)" 0 "5 (W4, named): the port's refused landing records no waiver"
xpair s1 --no-lesson 'nothing new'; xsame_rc_out; xsame_err
xpair s1 --no-lesson 'nothing new' --no-fact 'none'; xsame_rc_out; xsame_err
assert_eq "$(grep -c 'lesson waived: nothing new' "$XOH/home/state/archive/s1/status"):$(grep -c 'lesson waived: nothing new' "$XNH/home/state/archive/s1/status")" "3:1" "5 (W4, named): the original recorded the waiver at all three attempts, the port at the landing alone"
xboth x5done
xsame s1 --no-lesson n --no-fact n
x5again() { xlease r s1; xtab s1 1; sed -i '' 's/^kind=ship$/kind=self/' "$H/home/state/s1.meta"; }
xboth x5again
xsame s1 --no-lesson n --no-fact n
assert_contains "$(cat "$XNH/home/state/archive/s1/status")" "learning tick: tick skipped: landing s1 is already counted" "5: a keyed duplicate tick"
x5lock() { x5done; mkdir -p "$H/home/state/.learn-cadence.lock"; printf '%s\n' "$$" >"$H/home/state/.learn-cadence.lock/pid"; : >"$H/stub/sleep.fast"; }
xboth x5lock
xpair s1 --no-lesson n --no-fact n; xsame_rc_out
assert_eq "$XN_RC" 0 "5 (W5): a tick that could not be claimed still lands, exit 0"
assert_eq "$(grep -c '^.* learning tick: ' "$XOH/home/state/archive/s1/status")" 1 "5 (W5): the original recorded the tick's last line alone, and said nothing"
assert_contains "$(cat "$XNH/home/state/archive/s1/status")" "learning tick: tick NOT counted: landing s1 could not be claimed (see the warning above) - re-run this tick" "5 (W5, named): the port records the tick's verdict..."
assert_contains "$(grep 'learning tick: ' "$XNH/home/state/archive/s1/status" | head -n1)" "learning tick: WARN: " "5 (W5, named): ...after the warning it points at"
assert_contains "$(xerr)" "WARN: learning tick for s1 failed (exit 1) - this landing is not counted; re-run: ROOT/bin/ac-learn.sh tick s1" "5 (W5, named): ...and says so"
x5due() { x5done; xput home/config/learn-every '1
'; }
xboth x5due
xsame s1 --no-lesson n --no-fact n
assert_contains "$(cat "$XNH/home/state/archive/s1/status")" "learning tick: tick: debriefs=1/1" "5: the crossing tick"
xboth x5 s1
xsame s1 --force
assert_eq "$XN_RC:$(xout)" "0:teardown s1 complete (forced)" "5: --force owes nothing"

# 6. a direct verifier: a codereview verifier (archived, its pane reaped, its
#    lease returned by id, its stamps and lock dir gone, its status archived
#    beside its meta - W11, named: the original left it); an incomplete
#    verify-qa (evidence minted, the partial verdict, the pane result and the
#    `current` run copied; an evidence dir already there; run-state already
#    there); evidence that cannot be made (the ERROR before anything is
#    archived); a re-archived verifier (W12, named: the LATEST takes the
#    fixed slot and the prior moves to a stamped dir, where the original
#    kept the oldest); a vanished lease, an empty entry, a lease with and
#    without its id, a re-leased slot; an orca verifier's own backend.
XV=t1-verify-codereview
x6() {
  xseed; xrepo r
  local wt; wt="$(xtree get --repo "$H/r" --id "$XV")"
  printf 'kind=verify-codereview\nbackend=herdr\ncaller=t1\nfamily=t1\nleases=%s\nlease_ids=0011223344556677\n' "$wt" >"$H/home/state/$XV.meta"
  printf 'pv tv\n' >"$H/home/state/.pane-$XV"
  local s; for s in hash change seen seen-hash stale gone ask unobservable report-hash superseded busy busy-stalled; do : >"$H/home/state/.$s-$XV"; done
  : >"$H/home/state/.hash-t1"
  printf '2026 started\n' >"$H/home/state/$XV.status"
  mkdir -p "$H/home/state/.verify-t1-codereview.lock.d"
}
xboth x6
xpair "$XV"; xsame_rc_out "$XV"; xsame_err "$XV"
assert_eq "$XN_RC:$(xout)" "0:teardown $XV complete (verifier)" "6: a direct verifier"
assert_eq "$(ls -A "$XOH/home/state" | LC_ALL=C sort | tr '\n' ' ')" ".hash-t1 archive t1-verify-codereview.status " "6 (W11): the original's stamps and lock dir gone, its status left"
assert_eq "$(ls -A "$XNH/home/state" | LC_ALL=C sort | tr '\n' ' ')" ".hash-t1 archive " "6 (W11, named): the port leaves nothing of it in state/"
assert_eq "$(cat "$XNH/home/state/archive/$XV/status")" "2026 started" "6 (W11, named): ...its status archived beside its meta"
x6pane() { x6; : >"$H/fh/panes/pv.buf"; }
xboth x6pane
xpair "$XV"; xsame_rc_out "$XV"; xsame_err "$XV"
assert_contains "$(xerr)" "WARN: pane pv (@H/home/state/.pane-$XV) did not close" "6: a pane the reap left open is warned"
XQ=t2-verify-qa
x6q() {
  xseed; mkdir -p "$H/qt/.crew/qa/run1"; printf 'state\n' >"$H/qt/.crew/qa/run1/steps.tsv"; ln -s run1 "$H/qt/.crew/qa/current"
  printf '{"partial":1}\n' >"$H/out.json"; printf '{"e":1}\n' >"$H/pane.ndjson"
  printf 'kind=verify-qa\nbackend=herdr\ncaller=t2\nfamily=t2\nworktree=%s/qt\noutput=%s/out.json\npane_result=%s/pane.ndjson\n%s' "$H" "$H" "$H" "${1:-}" >"$H/home/state/$XQ.meta"
}
xboth x6q
xsame "$XQ"
assert_contains "$(cat "$XNH/home/data/t2/verification/$XQ-incomplete-1767225600/incomplete-run.md")" 'Preserved at: `2026-01-01T00:00:00Z`' "6: the incomplete artifact"
assert_eq "$(cat "$XNH/home/data/t2/verification/$XQ-incomplete-1767225600/run-state/steps.tsv")" "state" "6: ...the current run copied"
x6qe() { x6q "evidence=$H/ev
"; mkdir -p "$H/ev/run-state"; printf 'kept\n' >"$H/ev/run-state/old"; : >"$H/ev/verdict.json"; }
xboth x6qe
xsame "$XQ"
assert_eq "$(ls "$XNH/ev/run-state")" "old" "6: an existing run-state is never overwritten"
x6qd() { x6q; rm "$H/qt/.crew/qa/current"; mkdir -p "$H/qt/.crew/qa/current"; printf 'dir\n' >"$H/qt/.crew/qa/current/x"; }
xboth x6qd
xsame "$XQ"
x6qc() { x6q "evidence=$H/ev
"; mkdir -p "$H/ev/run-state"; printf '{}\n' >"$H/ev/verdict.json"; printf 'r\n' >"$H/ev/relay-report.md"; }
xboth x6qc
xsame "$XQ"
[ ! -e "$XNH/ev/incomplete-run.md" ] || fail "6: complete evidence is never re-preserved"
x6qx() { x6q "evidence=$H/afile/x
"; : >"$H/afile"; }
xboth x6qx
xsame "$XQ"
assert_eq "$XN_RC" 1 "6: evidence that cannot be made ends the run"
assert_contains "$(xerr)" "ERROR: cannot preserve incomplete QA verifier $XQ at @H/afile/x" "6: ...named"
[ -e "$XNH/home/state/$XQ.meta" ] || fail "6: ...before anything is archived"
x6r() { x6; mkdir -p "$H/home/state/archive/$XV"; printf 'kind=verify-codereview\nround=1\n' >"$H/home/state/archive/$XV/meta"; printf '1 old\n' >"$H/home/state/archive/$XV/status"; }
xboth x6r
xpair "$XV"; xsame_rc_out "$XV"; xsame_err "$XV"
assert_eq "$(cat "$XOH/home/state/archive/$XV/meta")" "kind=verify-codereview
round=1" "6 (W12): the original kept the oldest at the fixed slot"
assert_eq "$(sed -n 's/^caller=//p' "$XNH/home/state/archive/$XV/meta")" "t1" "6 (W12, named): the port's fixed slot holds the latest"
assert_eq "$(cat "$XNH"/home/state/archive/"$XV"/*/meta)" "kind=verify-codereview
round=1" "6 (W12, named): ...the prior one in its stamped dir"
assert_eq "$(cat "$XNH/home/state/archive/$XV/status")" "2026 started" "6 (W12, named): ...the latest status beside the latest meta"
assert_eq "$(cat "$XNH"/home/state/archive/"$XV"/*/status)" "1 old" "6 (W12, named): ...the prior status beside the prior meta"
x6r0() { x6r; rm "$H/home/state/$XV.status"; }
xboth x6r0
xpair "$XV"; xsame_rc_out "$XV"; xsame_err "$XV"
[ ! -e "$XNH/home/state/archive/$XV/status" ] || fail "6 (W12, named): a latest with no status leaves none at the fixed slot"
assert_eq "$(cat "$XNH"/home/state/archive/"$XV"/*/status)" "1 old" "6 (W12, named): ...the prior status moved with its meta"
x6l() {
  xseed; xrepo r
  local wt; wt="$(xtree get --repo "$H/r" --id "$XV")"
  printf 'kind=verify-codereview\nbackend=herdr\ncaller=t1\nleases=%s/gone::%s:%s/nolease\nlease_ids=a:b:%s:c\n' "$H" "$wt" "$H" "${1:-0011223344556677}" >"$H/home/state/$XV.meta"
  mkdir -p "$H/nolease"
}
xboth x6l
xsame "$XV"
assert_contains "$(xerr)" "WARN: skipping vanished verifier lease @H/gone: directory no longer exists" "6: a vanished lease"
assert_contains "$(xerr)" "WARN: could not return verifier worktree @H/nolease (it may have been re-leased); inspect @H/home/state/archive/$XV/meta" "6: a lease with its id the pool refuses"
xboth x6l ffffffffffffffff
xsame "$XV"
assert_contains "$(xerr)" "WARN: could not return verifier worktree @H/r/.crew/worktrees/1-r (it may have been re-leased)" "6: a re-leased slot is refused by id"
x6n() { xseed; mkdir -p "$H/nolease"; printf 'kind=verify-codereview\nbackend=herdr\nworktree=%s/nolease\n' "$H" >"$H/home/state/$XV.meta"; }
xboth x6n
xsame "$XV"
assert_contains "$(xerr)" "WARN: could not return verifier worktree @H/nolease; inspect @H/home/state/archive/$XV/meta" "6: a pre-leases verifier with no id"
x6o() { xseed; mkdir -p "$H/owt"; printf 'kind=verify-codereview\nbackend=orca\nleases=%s/owt\n' "$H" >"$H/home/state/$XV.meta"; printf 'term1 tab1\n' >"$H/home/state/.pane-$XV"; }
xboth x6o
xsame "$XV"
[ ! -e "$XNH/owt" ] || fail "6: an orca verifier's lease is removed by its own backend"
assert_contains "$(cat "$XNH/fo/log")" "orca worktree rm --worktree path:$XNH/owt --force --json" "6: ...through the orca CLI"

# 7. the task's verifiers: one linked by caller=, a legacy one by family=
#    (no caller), a co-tenant naming another caller (kept), the verifier's
#    lock dir; an incomplete QA verifier behind a refused gate (no evidence
#    written) and past it (preserved, then archived); the swept verifiers'
#    stamps reaped and status archived (W11, named: the original left them).
x7() {
  xseed; xrepo r; xlease r t; xtab t 1
  printf 'kind=verify-codereview\nbackend=herdr\ncaller=t\n' >"$H/home/state/t-verify-codereview.meta"
  printf 'kind=verify-codereview\nbackend=herdr\nfamily=t\n' >"$H/home/state/t-old-verify.meta"
  printf 'kind=verify-codereview\nbackend=herdr\ncaller=other\nfamily=t\n' >"$H/home/state/co-verify.meta"
  : >"$H/home/state/.change-t-verify-codereview"
  printf 'swept\n' >"$H/home/state/t-verify-codereview.status"
  mkdir -p "$H/home/state/.verify-t-codereview.lock.d"
}
xboth x7
xpair t; xsame_rc_out t; xsame_err t
assert_eq "$(ls "$XNH/home/state/archive" | tr '\n' ' ')" "t t-old-verify t-verify-codereview " "7: the caller's and the legacy verifier are swept"
[ -e "$XOH/home/state/.change-t-verify-codereview" ] || fail "7 (W11): the original left the swept verifier's stamps"
[ -e "$XNH/home/state/co-verify.meta" ] && [ ! -e "$XNH/home/state/.change-t-verify-codereview" ] || fail "7 (W11, named): the co-tenant stays, the swept verifier's stamps go"
[ -e "$XOH/home/state/t-verify-codereview.status" ] || fail "7 (W11): the original left the swept verifier's status"
[ ! -e "$XNH/home/state/t-verify-codereview.status" ] || fail "7 (W11, named): the port leaves no swept verifier status in state/"
assert_eq "$(cat "$XNH/home/state/archive/t-verify-codereview/status")" "swept" "7 (W11, named): ...it is archived beside its meta"
x7q() {
  xseed; xrepo r; xlease r t; xtab t 1
  git -C "$H/$XS" checkout -q -b crew/t; xcommit "$XS" w.txt
  printf 'kind=verify-qa\nbackend=herdr\ncaller=t\nfamily=t\n' >"$H/home/state/t-verify-qa.meta"
}
xboth x7q
xsame t
assert_eq "$XN_RC" 1 "7: an unlanded task refuses"
[ ! -e "$XNH/home/data/t/verification" ] || fail "7: a refused gate writes no evidence"
xboth git -C @H/r merge -q --ff-only crew/t
xsame t
assert_eq "$(ls "$XNH/home/data/t/verification")" "t-verify-qa-incomplete-1767225600" "7: past the gate the incomplete QA is preserved"

# 8. the pane-agent sweep in a leased tree the pool refuses to reset (so what
#    it keeps stays visible): the qa agent's pane; qa runs - ours (its
#    watch.pane, and a LIVE serve process group killed), another task's
#    (untouched), no one's (each record warned) - the `current` symlink
#    skipped; a ship run by branch; a pane the reap left open; unreadable
#    and empty pane files; serve.pid dead, empty, unreadable, `abc`; an
#    unreadable run.meta (W13, named: the original ended mid-sweep with
#    sed's status; the port WARNs, leaves that run and goes on). No
#    row ever writes -1 or 0 to a serve.pid (W9).
x8() {
  xseed; xrepo r
  local l="$H/lease"; mkdir -p "$l/.crew/qa/q-ours" "$l/.crew/qa/q-other" "$l/.crew/qa/q-none" "$l/.crew/qa/q-dead" "$l/.crew/ship/s-ours" "$l/.crew/ship/s-none"
  # A clean git tree, so the gate reads it; .crew/ is the pool's own.
  git init -q "$l"; printf '/.crew/\n' >>"$l/.git/info/exclude"
  printf 'kind=ship\nbackend=herdr\nproject_dir=%s/r\nworktree=%s\nleases=%s\n' "$H" "$l" "$l" >"$H/home/state/t.meta"
  xtab t 1
  printf 'pA\n' >"$l/.crew/qa/agent-t.pane"
  printf 'id=q1\ntask=t\ntask=ignored\n' >"$l/.crew/qa/q-ours/run.meta"; printf 'pW tW\n' >"$l/.crew/qa/q-ours/watch.pane"
  # Its own process group, started in a subshell so no job notice reaches this shell.
  ( set -m; /bin/sleep 300 </dev/null >/dev/null 2>&1 & printf '%s\n' "$!" >"$l/.crew/qa/q-ours/serve.pid" )
  printf 'task=x\n' >"$l/.crew/qa/q-other/run.meta"; printf 'pX\n' >"$l/.crew/qa/q-other/watch.pane"; printf '%s\n' "$$" >"$l/.crew/qa/q-other/serve.pid"
  printf 'id=q3\n' >"$l/.crew/qa/q-none/run.meta"; printf 'pN\n' >"$l/.crew/qa/q-none/watch.pane"; printf 'pR\n' >"$l/.crew/qa/q-none/review.pane"; printf '777\n' >"$l/.crew/qa/q-none/serve.pid"
  # The glob sorts whole paths: q-none-b/run.meta before q-none/run.meta.
  mkdir -p "$l/.crew/qa/q-none-b"; printf 'id=q4\n' >"$l/.crew/qa/q-none-b/run.meta"; printf 'pNB\n' >"$l/.crew/qa/q-none-b/watch.pane"
  printf 'task=t\n' >"$l/.crew/qa/q-dead/run.meta"; printf '%s\n' "$xdead" >"$l/.crew/qa/q-dead/serve.pid"; : >"$l/.crew/qa/q-dead/watch.pane"
  ln -s q-ours "$l/.crew/qa/current"
  printf 'branch=crew/t\n' >"$l/.crew/ship/s-ours/run.meta"; printf 'pSR\n' >"$l/.crew/ship/s-ours/review.pane"; printf 'pSTUCK\n' >"$l/.crew/ship/s-ours/watch.pane"
  : >"$H/fh/panes/pSTUCK.buf"
  printf 'id=s2\n' >"$l/.crew/ship/s-none/run.meta"
}
sleep 0.1 &
xdead=$!
wait "$xdead" 2>/dev/null || true
xboth x8
xserve_o="$(cat "$XOH/lease/.crew/qa/q-ours/serve.pid")"; xserve_n="$(cat "$XNH/lease/.crew/qa/q-ours/serve.pid")"
xpair t
x8n() { LC_ALL=C sed -E -e "s/qa serve pid $xdead /qa serve pid DEAD /"; }
xnorm "$TMP/xo.err" "$XOH" "$(cat "$TMP/xo.pid")" | x8n >"$TMP/xo.err2"; xnorm "$TMP/xn.err" "$XNH" "$(cat "$TMP/xn.pid")" | x8n >"$TMP/xn.err2"
xsame_rc_out t; xsame_err t; xsame_world t
for xp in "$xserve_o" "$xserve_n"; do
  ! kill -0 "$xp" 2>/dev/null || { kill "$xp" 2>/dev/null; fail "8: the live serve group was not ended"; }
done
assert_contains "$(xerr)" "WARN: not reaping pN - run @H/lease/.crew/qa/q-none is attributed to no task (@H/lease/.crew/qa/q-none/watch.pane)" "8: an unattributed run is warned by pane and path"
assert_contains "$(xerr)" "WARN: qa serve pid DEAD already gone (@H/lease/.crew/qa/q-dead/serve.pid)" "8: a dead serve pid"
assert_contains "$(xerr)" "WARN: pane pSTUCK (@H/lease/.crew/ship/s-ours/watch.pane) did not close" "8: a pane the reap left open"
[ -e "$XNH/lease/.crew/qa/q-other/watch.pane" ] && [ -e "$XNH/lease/.crew/qa/q-other/serve.pid" ] || fail "8: another task's run is untouched"
# W10 (named): the reap is gated on the binary of the backend reap-pane
# itself resolves - ac_backend, reading the AC_BACKEND teardown pins to the
# task's backend= - where the original asked for herdr whatever the backend.
# A herdr task with no herdr: both keep the record. An orca task with no
# herdr: the original never closed the pane and kept its record, the port
# closes it. With herdr but no orca, the original's reap-pane read the
# unreachable terminal as closed and dropped the record, where the port
# warns and keeps it.
x8o() {
  xseed; xrepo r; mkdir -p "$H/lease/.crew/qa"; printf 'term7\n' >"$H/lease/.crew/qa/agent-t.pane"; : >"$H/fo/terminals/term7.buf"
  git init -q "$H/lease"; printf '/.crew/\n' >>"$H/lease/.git/info/exclude"
  printf 'kind=ship\nbackend=%s\nproject_dir=%s/r\nworktree=%s/lease\nleases=%s/lease\n' "${1:-orca}" "$H" "$H" "$H" >"$H/home/state/t.meta"
}
xboth x8o herdr
XPATH="$(xwithout herdr)"
xsame t
XPATH=""
assert_contains "$(xerr)" "WARN: could not reap pane term7 (@H/lease/.crew/qa/agent-t.pane): herdr or ac-pane-agent.sh unavailable" "8 (W10): a herdr task's pane is not reaped without herdr"
[ -e "$XNH/lease/.crew/qa/agent-t.pane" ] && [ -e "$XNH/fo/terminals/term7.buf" ] || fail "8 (W10): ...its record kept, its terminal open"
xboth x8o
XPATH="$(xwithout herdr)"
xpair t; xsame_rc_out t
XPATH=""
assert_contains "$(xoerr)" "WARN: could not reap pane term7 (@H/lease/.crew/qa/agent-t.pane): herdr or ac-pane-agent.sh unavailable" "8 (W10): the original asked an orca task for herdr"
[ -e "$XOH/lease/.crew/qa/agent-t.pane" ] && [ -e "$XOH/fo/terminals/term7.buf" ] || fail "8 (W10): ...and kept the record, the terminal open"
case "$(xerr)" in *"could not reap pane"*) fail "8 (W10, named): the port reaps an orca task's pane without herdr" ;; esac
[ ! -e "$XNH/lease/.crew/qa/agent-t.pane" ] && [ ! -e "$XNH/fo/terminals/term7.buf" ] || fail "8 (W10, named): ...the record gone, the terminal closed"
xboth x8o
XPATH="$(xwithout orca)"
xpair t; xsame_rc_out t
XPATH=""
[ ! -e "$XOH/lease/.crew/qa/agent-t.pane" ] && [ -e "$XOH/fo/terminals/term7.buf" ] || fail "8 (W10): the original dropped an orca pane's record with no orca to close it"
assert_contains "$(xerr)" "WARN: could not reap pane term7 (@H/lease/.crew/qa/agent-t.pane): orca or ac-pane-agent.sh unavailable" "8 (W10, named): the port warns an orca task with no orca"
[ -e "$XNH/lease/.crew/qa/agent-t.pane" ] || fail "8 (W10, named): ...and keeps the record"
x8u() {
  x8; kill "$(cat "$H/lease/.crew/qa/q-ours/serve.pid")" 2>/dev/null || true
  printf 'abc\n' >"$H/lease/.crew/qa/q-ours/serve.pid"; : >"$H/lease/.crew/qa/q-dead/serve.pid"
  printf 'pU\n' >"$H/lease/.crew/qa/q-ours/watch.pane"
}
if [ "$XROOTED" = 0 ]; then
  xboth x8u
  xboth chmod 000 @H/lease/.crew/qa/q-ours/watch.pane @H/lease/.crew/qa/q-dead/watch.pane
  xboth chmod 000 @H/lease/.crew/qa/q-dead/serve.pid
  xpair t
  xboth chmod 644 @H/lease/.crew/qa/q-ours/watch.pane @H/lease/.crew/qa/q-dead/watch.pane @H/lease/.crew/qa/q-dead/serve.pid
  xsame_rc_out t; xsame_err t; xsame_world t
  assert_contains "$(xerr)" "WARN: could not read @H/lease/.crew/qa/q-ours/watch.pane: the pane could not be identified, it may be orphaned" "8: an unreadable pane file is kept"
  assert_contains "$(xerr)" "WARN: not signalling qa serve pid 'abc' (@H/lease/.crew/qa/q-ours/serve.pid): not a process id" "8: a serve.pid that is no pid"
  assert_contains "$(xerr)" "WARN: could not read @H/lease/.crew/qa/q-dead/serve.pid: a qa serve process may still be running and could not be identified" "8: an unreadable serve.pid"
  x8w() { x8u; chmod 000 "$H/lease/.crew/qa/q-none/run.meta"; }
  xboth x8w
  xpair t
  xboth chmod 644 @H/lease/.crew/qa/q-none/run.meta
  assert_eq "$XO_RC:$(cat "$TMP/xo.out")" "1:" "8 (W13): the original's unreadable run.meta ended the run mid-sweep, no completion"
  assert_eq "$XN_RC:$(xout)" "0:teardown t complete" "8 (W13, named): the port leaves that run and completes"
  assert_contains "$(xerr)" "sed: @H/lease/.crew/qa/q-none/run.meta: Permission denied" "8 (W13): ...after sed's own line"
  assert_contains "$(xerr)" "WARN: could not read @H/lease/.crew/qa/q-none/run.meta: run @H/lease/.crew/qa/q-none was not swept - its panes and qa serve process, if any, may survive" "8 (W13, named): ...naming the run it left"
  [ ! -e "$XNH/lease/.crew/qa/q-ours/watch.pane" ] || fail "8 (W13, named): ...the runs after it still swept"
  x8q() { x8u; chmod 000 "$H/lease/.crew/qa/q-ours/run.meta"; }
  xboth x8q
  xpair t
  xboth chmod 644 @H/lease/.crew/qa/q-ours/run.meta
  assert_eq "$XN_RC:$(xout)" "0:teardown t complete" "8 (W13, named): the task's own run left unread too"
  [ -e "$XNH/lease/.crew/qa/q-ours/watch.pane" ] && [ -e "$XNH/lease/.crew/qa/q-ours/serve.pid" ] || fail "8 (W13, named): ...its records kept"
  x8s() { x8u; chmod 000 "$H/lease/.crew/ship/s-ours/run.meta"; }
  xboth x8s
  xpair t
  xboth chmod 644 @H/lease/.crew/ship/s-ours/run.meta
  assert_eq "$XO_RC:$(cat "$TMP/xo.out")" "1:" "8 (W13): an unreadable ship run.meta ended the original mid-sweep"
  assert_eq "$XN_RC:$(xout)" "0:teardown t complete" "8 (W13, named): the port leaves that ship run and completes"
  assert_contains "$(xerr)" "WARN: could not read @H/lease/.crew/ship/s-ours/run.meta: run @H/lease/.crew/ship/s-ours was not swept - its panes and qa serve process, if any, may survive" "8 (W13, named): ...naming it"
  [ -e "$XNH/lease/.crew/ship/s-ours/review.pane" ] || fail "8 (W13, named): ...its panes kept"
fi

# 9. the pane kill: an owned tab closed; a stale label; herdr unreachable
#    (W18: read as stale, no failure recorded); a close that fails on an
#    owned tab (the WARN, the archived status line and the timeline, with
#    AC_HERDR_SESSION and with config/herdr-session); orca's terminal closed
#    and its emptied tab's family record retired; an unsupported task
#    backend (W6: archived first, then the ERROR, the pane and the lease
#    left); a kill that ends the caller (meta and status archived, the lease
#    left).
x9() { xseed; xrepo r; xlease r t; xtab t 1 "${1-crew:t}"; mkdir -p "$H/home/data/t"; }
xboth x9
xsame t
assert_eq "$(ls "$XNH/fh/tabs")" "" "9: an owned tab is closed"
xboth x9 crew:other
xsame t
assert_contains "$(xerr)" "WARN: not closing tab t1 for t: it is labelled 'crew:other', not crew:t - the handle is stale (close the tab by hand if it really is this task's)" "9: a stale label"
xboth x9
xboth touch @H/fh/.unreachable
xsame t
assert_contains "$(xerr)" "labelled 'none'" "9 (W18): an unreachable herdr reads as a stale handle"
xboth x9
xboth touch @H/fh/.tab-close-fails
xsame t
assert_contains "$(xerr)" "WARN: tab t1 of t refused to close and workspace t1 could not be read - close the tab by hand
WARN: pane close FAILED for t - a live pane may survive this teardown (handle: p1 t1); close it by hand: herdr tab close t1" "9: a failed close on an owned tab"
assert_contains "$(cat "$XNH/home/state/archive/t/status")" "2026-01-01T00:00:00Z warn: pane close failed - handle p1 t1; close by hand: herdr tab close t1" "9: ...on the archived record"
assert_contains "$(cat "$XNH/home/data/t/timeline.log")" "warn: pane close failed" "9: ...and the timeline"
xboth x9
xboth touch @H/fh/.tab-close-fails
XENV=("AC_HERDR_SESSION=s9")
xsame t
XENV=()
assert_contains "$(xerr)" "close it by hand: herdr tab close t1 --session s9" "9: the session in the hand command"
xboth x9
xboth touch @H/fh/.tab-close-fails
xboth xput home/config/herdr-session 'cfg
'
xsame t
assert_contains "$(xerr)" "--session cfg" "9: config/herdr-session in the hand command"
x9o() {
  xseed; xrepo r; xlease r t
  sed -i '' 's/^backend=herdr$/backend=orca/' "$H/home/state/t.meta"
  : >"$H/fo/terminals/term5.buf"; printf 'tab5\n' >"$H/fo/terminals/term5.tab"
  printf 'term5 tab5\n' >"$H/home/state/.pane-t"; printf 'tab5\n' >"$H/home/state/.orca-fam-t"; printf 'tab9\n' >"$H/home/state/.orca-fam-x"
}
xboth x9o
xsame t
assert_eq "$(ls -A "$XNH/home/state" | grep orca-fam)" ".orca-fam-x" "9: orca closed the terminal and retired its emptied tab's record"
xboth x9
xboth sed -i '' 's/^backend=herdr$/backend=tmux/' @H/home/state/t.meta
xsame t
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "9 (W6): an unsupported task backend ends the run at the pane kill"
[ -e "$XNH/home/state/archive/t/meta" ] && [ -e "$XNH/home/state/.pane-t" ] || fail "9 (W6): ...after the archive, the pane handle kept"
xboth x9
xboth touch @H/fh/.kill-caller-on-tab-close
# The killed sides' job reports stay out of the suite output.
{ xpair t; } 2>/dev/null
xsame_rc_out t; xsame_err t; xsame_world t
assert_eq "$XN_RC:$(xout)" "137:" "9: a kill at the pane step ends the run by its signal"
[ -e "$XNH/home/state/archive/t/meta" ] && [ -e "$XNH/home/state/archive/t/status" ] || fail "9: ...with meta and status already archived"

# 10. the lease loop: a pre-leases meta (worktree= is the list, no id); a
#     vanished dir and an empty entry; a short id list (the first lease takes
#     the one id); companions - dirty, unlanded, covered by the task's own
#     branch, in another repo's epic tip; an orca primary beside a pool
#     companion (aligned and legacy id lists); an orca worktree git cannot
#     read (W8, named: the original removed it, the port refuses); a held
#     port-slot lock (W20: the row stays, silently); a symlink planted at
#     each <file>.tmp.<pid> (EXCLUSIVE TEMPS, named).
x10a() { xseed; xrepo r; xlease r t; sed -i '' -e '/^leases=/d' -e '/^lease_ids=/d' "$H/home/state/t.meta"; }
xboth x10a
xsame t
assert_eq "$XN_RC:$(xerr)" "0:" "10: a pre-leases meta returns worktree= with no id"
x10b() { x10a; printf 'leases=%s/gone::%s/%s\nlease_ids=a:b:0011223344556677\n' "$H" "$H" "$XS" >>"$H/home/state/t.meta"; }
xboth x10b
xsame t
assert_eq "$XN_RC:$(xerr)" "0:WARN: skipping vanished lease @H/gone: directory no longer exists" "10: a vanished lease warns, an empty entry is silent"
x10c() { xseed; xrepo r; xlease r t; xtree get --repo "$H/r" --id t >/dev/null; sed -i '' -e '/^leases=/d' -e '/^lease_ids=/d' "$H/home/state/t.meta"; printf 'leases=%s/%s:%s/r/.crew/worktrees/2-r\nlease_ids=0011223344556677\n' "$H" "$XS" "$H" >>"$H/home/state/t.meta"; }
xboth x10c
xsame t
assert_eq "$XN_RC" 0 "10: a short id list"
x10d() { x10c; xrepo r2; xtree get --repo "$H/r2" --id t >/dev/null; sed -i '' '/^leases=/s#$#:'"$H"'/r2/.crew/worktrees/1-r2#' "$H/home/state/t.meta"; }
x10dd() { x10d; printf 'x\n' >"$H/r2/.crew/worktrees/1-r2/u.txt"; }
xboth x10dd
xrefuse "lease @H/r2/.crew/worktrees/1-r2 holds uncommitted or unlanded work and would be returned with --force; land or move it, or --force to discard
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
x10dn() { x10d; printf 'gitdir: %s/nowhere\n' "$H" >"$H/r2/.crew/worktrees/1-r2/.git"; }
xboth x10dn
xpair t
assert_eq "$XO_RC" 0 "10 (W8): the original took a companion git cannot read as safe"
assert_eq "$XN_RC:$(xout)" "1:" "10 (W8, named): the port refuses it"
assert_contains "$(xerr)" "lease @H/r2/.crew/worktrees/1-r2 cannot be read by git, so its contents cannot be checked and it would be returned with --force; repair it, or --force to discard" "10 (W8, named): ...naming the lease"
x10du() { x10d; xcommit r2/.crew/worktrees/1-r2 c.txt; }
xboth x10du
xsame t
assert_eq "$XN_RC" 1 "10: an unlanded companion refuses"
x10dc() { x10c; git -C "$H/$XS" checkout -q -b crew/t; xcommit "$XS" w.txt; git -C "$H/r" merge -q --ff-only crew/t; git -C "$H/r/.crew/worktrees/2-r" checkout -q --detach crew/t; }
xboth x10dc
xsame t
assert_eq "$XN_RC" 0 "10: a companion the task's own branch covers lands"
x10de() {
  x10du; git -C "$H/r2" branch ep/e2 "$(git -C "$H/r2/.crew/worktrees/1-r2" rev-parse HEAD)"
  xput home/records/backlog.md '- [ ] t - x epic:e2
'; xput home/data/e2/branches 'r2 ep/e2
'
}
xboth x10de
xsame t
assert_eq "$XN_RC" 0 "10: a companion at its own repo's epic tip lands"
x10o() {
  xseed; xrepo r; mkdir -p "$H/fo/orca-wt"; git -C "$H/r" worktree add -q -b fakeuser/t "$H/fo/orca-wt/t" 2>/dev/null
  local wt; wt="$(xtree get --repo "$H/r" --id t)"
  printf 'kind=ship\nbackend=orca\nworktree_backend=orca\nproject_dir=%s/r\nworktree=%s/fo/orca-wt/t\nleases=%s/fo/orca-wt/t:%s\nlease_ids=%s\n' "$H" "$H" "$H" "$wt" "$1" >"$H/home/state/t.meta"
}
xboth x10o x:0011223344556677
xsame t
assert_eq "$XN_RC:$(xerr)" "0:" "10: an orca worktree beside a pool companion (aligned ids)"
[ ! -e "$XNH/fo/orca-wt/t" ] || fail "10: ...the orca worktree removed"
xboth x10o 0011223344556677
xsame t
assert_eq "$XN_RC:$(xerr)" "0:" "10: ...a legacy id list keeps every id"
x10w() { x10o x:0011223344556677; printf 'precious\n' >"$H/fo/orca-wt/t/precious.txt"; printf 'gitdir: %s/nowhere\n' "$H" >"$H/fo/orca-wt/t/.git"; }
xboth x10w
xpair t
[ ! -e "$XOH/fo/orca-wt/t/precious.txt" ] || fail "10 (W8): the original's gate passed an orca worktree git cannot read, and it was removed"
assert_eq "$XN_RC:$(xout)" "1:" "10 (W8, named): the port refuses it"
[ -e "$XNH/fo/orca-wt/t/precious.txt" ] || fail "10 (W8, named): ...and its files stay"
x10l() { x10a; printf '1\t%s/%s\tr\t2026\n' "$H" "$XS" >"$H/home/state/port-slots.tsv"; mkdir -p "$H/home/state/port-slots.tsv.lock"; printf '%s\n' "$$" >"$H/home/state/port-slots.tsv.lock/pid"; : >"$H/stub/sleep.fast"; }
xboth x10l
xsame t
assert_eq "$XN_RC:$(xerr):$(cut -f1 "$XNH/home/state/port-slots.tsv")" "0::1" "10 (W20): a held registry lock leaves the row, silently"
assert_eq "$(grep -c '^1$' "$XNH/stub/sleep.log")" 10 "10 (W20): ...after ten waits"
x10t() {
  x10a; printf '1\t%s/%s\tr\t2026\n2\tother\tr\t2026\n' "$H" "$XS" >"$H/home/state/port-slots.tsv"
  mkdir -p "$H/ev"; printf 'kind=verify-qa\nbackend=herdr\ncaller=t\nevidence=%s/ev\n' "$H" >"$H/home/state/t-verify-qa.meta"
  printf 'victim bytes\n' >"$H/victim1"; printf 'victim bytes\n' >"$H/victim2"
}
xboth x10t
cat >"$TMP/xgate.sh" <<'GATE'
#!/usr/bin/env bash
_id="$(/bin/ps -o lstart= -p $$)"
_wd="$( ( sleep 60; [ "$(/bin/ps -o lstart= -p $$)" != "$_id" ] || kill -9 $$ 2>/dev/null ) >/dev/null 2>&1 & printf '%s' $! )"
read -r _ <"$1"
kill "$_wd" 2>/dev/null || true
cd "$2" || exit 1
b="$3"; shift 3
exec "$b/ac-teardown.sh" "$@"
GATE
chmod +x "$TMP/xgate.sh"
xplant() {  # xplant <bin> <side root> <out> - one gated teardown, a symlink to <side>/victim<i> planted at each temp name its pid makes
  local b="$1" h="$2" o="$3" gate pid; gate="$h/gate.fifo"; mkfifo "$gate"
  env -u AC_FLEET_STATE -u AC_BACKEND LC_ALL=C AC_HOME="$h/home" PATH="$XSTUBS:$PATH" STUB_DIR="$h/stub" FAKE_HERDR="$h/fh" FAKE_ORCA="$h/fo" \
    "$TMP/xgate.sh" "$gate" "$h/cwd" "$b" t </dev/null >"$o" 2>"$o.err" &
  pid=$!
  ln -s "$h/victim1" "$h/home/state/port-slots.tsv.tmp.$pid"
  ln -s "$h/victim2" "$h/ev/incomplete-run.md.tmp.$pid"
  printf x >"$gate"
  wait "$pid" || fail "10: the planted row under $b failed: $(cat "$o.err")"
  rm -f "$gate"; printf '%s' "$pid" >"$o.pid"
}
xplant "$xobin" "$XOH" "$TMP/xpo"; xplant "$BIN" "$XNH" "$TMP/xpn"
assert_eq "$(xnorm "$TMP/xpn" "$XNH" "$(cat "$TMP/xpn.pid")")" "$(xnorm "$TMP/xpo" "$XOH" "$(cat "$TMP/xpo.pid")")" "10: the planted row's stdout"
assert_eq "$(xnorm "$TMP/xpn.err" "$XNH" "$(cat "$TMP/xpn.pid")")" "$(xnorm "$TMP/xpo.err" "$XOH" "$(cat "$TMP/xpo.pid")")" "10: the planted row's stderr"
for xi in 1 2; do
  assert_eq "$(cat "$XNH/victim$xi")" "victim bytes" "10: the port never writes through planted temp $xi"
  [ "$(cat "$XOH/victim$xi")" != "victim bytes" ] || fail "10: the original wrote through planted temp $xi (the divergence's bash side)"
done
[ -L "$XOH/home/state/port-slots.tsv" ] && [ -L "$XOH/ev/incomplete-run.md" ] || fail "10: the original renamed its planted links over the records"
[ -f "$XNH/home/state/port-slots.tsv" ] && [ ! -L "$XNH/home/state/port-slots.tsv" ] && [ -f "$XNH/ev/incomplete-run.md" ] && [ ! -L "$XNH/ev/incomplete-run.md" ] || fail "10: the port's records stay regular files"
assert_eq "$(cat "$XNH/home/state/port-slots.tsv")" "2	other	r	2026" "10: ...holding the released registry"

# 11. the branch drop: git's refusal with advice.forceDeleteBranch=false; a
#     branch a worktree holds (the reclaim names the worktree first); the
#     epic branch only on origin (-D); an empty project_dir from a cwd that
#     is a repo (W7, named: the original dropped the CALLER's crew/t; the
#     port refuses, and forced looks for the branch nowhere).
x11a() { x2c; git -C "$H/r" config advice.forceDeleteBranch false; }
xboth x11a
xsame t
assert_eq "$(xerr)" "WARN: kept crew/t in @H/r: error: the branch 'crew/t' is not fully merged - reclaim: git branch -D crew/t" "11: git's own text, its advice off"
x11h() { x2b; git -C "$H/$XS" checkout -q --detach; git -C "$H/r" worktree add -q "$H/held" crew/t; }
xboth x11h
xsame t
assert_contains "$(xerr)" "- reclaim: free it from that worktree, then git branch -D crew/t" "11: a branch a worktree holds"
x11e() {
  x2; xorigin r; x2br; git -C "$H/r" push -q origin crew/t:ep/e1 2>/dev/null; git -C "$H/r" fetch -q origin
  xput home/records/backlog.md '- [ ] t - story epic:e1
'; xput home/data/e1/branches 'r ep/e1
'
}
xboth x11e
xsame t
assert_eq "$XN_RC:$(xerr):$(git -C "$XNH/r" branch --list crew/t)" "0::" "11: the epic branch on origin alone drops it with -D"
x11w() {
  xseed; xrepo cwdrepo; git -C "$H/cwdrepo" branch crew/t
  printf 'kind=ship\nbackend=herdr\nproject_dir=\n' >"$H/home/state/t.meta"
}
xboth x11w
XCWD=cwdrepo
xpair t
XCWD=cwd
assert_eq "$XO_RC:$(git -C "$XOH/cwdrepo" branch --list crew/t)" "0:" "11 (W7): the original's empty project_dir dropped the caller's own crew/t"
assert_eq "$XN_RC:$(xout)" "1:" "11 (W7, named): the port refuses a meta with no project_dir"
assert_contains "$(xerr)" "the meta of t records no project_dir, so its landed work has no repository to be proven in" "11 (W7, named): ...saying why"
assert_eq "$(git -C "$XNH/cwdrepo" branch --list crew/t)" "  crew/t" "11 (W7, named): ...the caller's branch untouched"
xboth x11w
XCWD=cwdrepo
xpair t --force
XCWD=cwd
assert_eq "$XO_RC:$(git -C "$XOH/cwdrepo" branch --list crew/t)" "0:" "11 (W7): forced, the original dropped the caller's crew/t too"
assert_eq "$XN_RC:$(xout):$(git -C "$XNH/cwdrepo" branch --list crew/t)" "0:teardown t complete (forced):  crew/t" "11 (W7, named): forced, the port looks for crew/t nowhere"
assert_contains "$(xerr)" "WARN: no project_dir recorded for t - crew/t was not looked for; drop it by hand in the repository that holds it" "11 (W7, named): ...and says so"
# A RELATIVE project_dir (`.`) from a caller whose cwd is gone (named): the
# original's gits fail to read the cwd and print so; the port resolves no
# relative path at all - its own cwd is then its bin's root, so the shim runs
# from a DECOY root holding a merged crew/t that a regression would drop.
xdecoy="$TMP/xdecoy"
rm -rf "$xdecoy"; mkdir -p "$xdecoy"; cp -R "$ROOT/bin" "$ROOT/src" "$ROOT/dashboard" "$xdecoy/"
git init -q -b main "$xdecoy"; git -C "$xdecoy" commit -q --allow-empty -m decoy; git -C "$xdecoy" branch crew/t
x11g() { xseed; printf 'kind=ship\nbackend=herdr\nproject_dir=.\n' >"$H/home/state/t.meta"; }
xboth x11g
XGONE=1; XNBIN="$xdecoy/bin"
xpair t
XGONE=0; XNBIN="$BIN"
xsame_rc_out t; xsame_world t
# Both bashes' own shell-init/chdir complaints about the cwd aside (SHELL-OWN).
x11cwd() { grep -v -E '^(shell-init|chdir): error retrieving current directory' "$1" | sort -u; }
assert_eq "$XN_RC:$(x11cwd "$TMP/xn.err2")" "0:" "11 (named): from a nameless cwd the port resolves nothing and says nothing"
assert_eq "$(x11cwd "$TMP/xo.err2")" "fatal: Unable to read current working directory: No such file or directory" "11: ...where the original's gits failed on the cwd"
assert_eq "$(git -C "$xdecoy" branch --list crew/t)" "  crew/t" "11: the decoy root's merged crew/t survives"

# 12. the roomchief demote: a member by the suffix grammar, by fleet_scope; a
#     verifier and a prefix family never members; three members, the first
#     in byte order (W16 - the original's UTF-8 glob named another, named);
#     DEMOTED posted; a post refused; the advisory with a queued family,
#     with none, with ac-ready failing; the qa-infra sweep (W14, named: the
#     original swept under the chief's own project_dir, the distro root - the
#     port sweeps in each distinct project the family's archived members
#     recorded - fam-spec by its id, zz and zy by fleet_scope, sharing one -
#     byte order, a gone one skipped; a verifier, a chief and a prefix
#     family's member recorded none).
x12() { xseed; xrepo r; printf 'kind=roomchief\nbackend=herdr\nworktree=%s/r\nproject_dir=%s/r\n' "$H" "$H" >"$H/home/state/fam-chief.meta"; xtab fam-chief 3; }
x12g() { x12; mkdir -p "$H/home/data/fam/spec"; printf 'kind=scout\n' >"$H/home/state/fam-spec.meta"; }
xboth x12g
xrefuse "family fam still has crew in flight: fam-spec
ERROR: refusing teardown of fam-chief (unlanded work); land it or pass --force to discard" fam-chief
x12s() { x12; printf 'kind=crewmate\nfleet_scope=fam\n' >"$H/home/state/zz.meta"; printf 'kind=verify-qa\nfleet_scope=fam\n' >"$H/home/state/fam-verify-qa.meta"; printf 'kind=crewmate\n' >"$H/home/state/fam2-x.meta"; }
xboth x12s
xrefuse "family fam still has crew in flight: zz
ERROR: refusing teardown of fam-chief (unlanded work); land it or pass --force to discard" fam-chief
x12m() { x12; local m; for m in Zeta _mid alpha; do printf 'kind=crewmate\nfleet_scope=fam\n' >"$H/home/state/$m.meta"; done; }
xboth x12m
xrefuse "family fam still has crew in flight: Zeta
ERROR: refusing teardown of fam-chief (unlanded work); land it or pass --force to discard" fam-chief
XLC=en_US.UTF-8
xpair fam-chief
XLC=C
assert_eq "$XO_RC:$(xoerr)" "1:family fam still has crew in flight: _mid
ERROR: refusing teardown of fam-chief (unlanded work); land it or pass --force to discard" "12 (W16): the original's UTF-8 glob names _mid"
assert_eq "$XN_RC:$(xerr)" "1:family fam still has crew in flight: Zeta
ERROR: refusing teardown of fam-chief (unlanded work); land it or pass --force to discard" "12 (ORDER, named): the port names the first in byte order"
x12v() { x12; printf 'kind=verify-qa\nfleet_scope=fam\n' >"$H/home/state/fam-verify-qa.meta"; printf 'kind=crewmate\n' >"$H/home/state/fam2-x.meta"; }
xboth x12v
xsame fam-chief
assert_eq "$XN_RC:$(xout)" "0:teardown fam-chief complete" "12: a verifier and a prefix family are no members"
assert_contains "$(cat "$XNH/home/data/fam/room.md")" "crewchief> DEMOTED: roomchief closed" "12: DEMOTED posted"
x12q() { x12; xput home/records/backlog.md '# Backlog

## Queued
- [ ] nextup - ordinary queued work (repo: r)
'; }
xboth x12q
xsame fam-chief --force
assert_eq "$(xout)" "teardown fam-chief complete (forced)
a chief slot is free - next queued family: nextup (promote with bin/ac-spawn.sh --roomchief nextup)" "12: the advisory names the next queued family"
assert_contains "$(cat "$XNH/home/data/fam/room.md")" "DEMOTED: roomchief closed (forced)" "12: a forced demote says so"
if [ "$XROOTED" = 0 ]; then
  xboth x12q
  xboth chmod 000 @H/home/records/backlog.md
  xpair fam-chief
  xboth chmod 644 @H/home/records/backlog.md
  xsame_rc_out; xsame_err; xsame_world
  assert_eq "$(xout)" "teardown fam-chief complete" "12: a failing ac-ready advises nothing"
fi
x12b() { xseed; printf 'kind=roomchief\nbackend=herdr\n' >"$H/home/state/dem bad-chief.meta"; }
xboth x12b
xsame "dem bad-chief"
assert_contains "$(xerr)" "WARN: could not post DEMOTED to room dem bad: " "12: a refused post warns"
assert_contains "$(xerr)" "post it by hand: ROOT/bin/ac-room.sh post dem bad crewchief \"DEMOTED: roomchief closed\"" "12: ...with the hand command"
x12w() {
  x12; xrepo d; xrepo r2; xrepo v; xrepo e
  xput home/state/fam-chief.meta 'kind=roomchief
backend=herdr
worktree=@H/d
project_dir=@H/d
'
  mkdir -p "$H/home/data/fam/spec"
  xput home/state/archive/fam-spec/meta 'kind=scout
project_dir=@H/r2
'
  xput home/state/archive/zz/meta 'kind=crewmate
fleet_scope=fam
project_dir=@H/r
'
  xput home/state/archive/zy/meta 'kind=self
fleet_scope=fam
project_dir=@H/r
'
  xput home/state/archive/zx/meta 'kind=crewmate
fleet_scope=fam
project_dir=@H/gone
'
  xput home/state/archive/fam-verify-qa/meta 'kind=verify-qa
fleet_scope=fam
project_dir=@H/v
'
  xput home/state/archive/fam2-x/meta 'kind=crewmate
project_dir=@H/e
'
}
XDOCK=1
xboth x12w
xpair fam-chief; xsame_rc_out fam-chief; xsame_err fam-chief
assert_eq "$XN_RC:$(xerr)" "0:" "12 (W14): both sweeps complete, silent"
assert_eq "$(cat "$XOH/stub/docker.log")" "compose -p crew-qa-d-fam-chief down -v --remove-orphans
compose -p crew-qa-d-fam-qa down -v --remove-orphans" "12 (W14): the original swept under the chief's own project_dir"
assert_eq "$(cat "$XNH/stub/docker.log")" "compose -p crew-qa-r-fam-chief down -v --remove-orphans
compose -p crew-qa-r-fam-qa down -v --remove-orphans
compose -p crew-qa-r2-fam-chief down -v --remove-orphans
compose -p crew-qa-r2-fam-qa down -v --remove-orphans" "12 (W14, named): the port sweeps in each project the family's members recorded"
xboth x12w
xboth touch @H/stub/docker.fail-fam-qa
xpair fam-chief; xsame_rc_out fam-chief
assert_eq "$(xerr)" "WARN: qa-infra sweep for fam-chief did not complete (status 7, bound 30s) - docker is unusable or hung; any task stack survives: (cd @H/r && ROOT/bin/ac-qa.sh infra down --task fam-chief && ROOT/bin/ac-qa.sh infra down --task fam-qa)
WARN: qa-infra sweep for fam-chief did not complete (status 7, bound 30s) - docker is unusable or hung; any task stack survives: (cd @H/r2 && ROOT/bin/ac-qa.sh infra down --task fam-chief && ROOT/bin/ac-qa.sh infra down --task fam-qa)" "12 (W14, named): each project's failure warned with its own hand command"
xboth x12
xpair fam-chief; xsame_rc_out fam-chief; xsame_err fam-chief
[ -e "$XOH/stub/docker.log" ] || fail "12 (W14): the original swept a memberless family under the chief's project_dir"
[ ! -e "$XNH/stub/docker.log" ] || fail "12 (W14, named): a family no member of which recorded a project sweeps nowhere"
XDOCK=0

# 13. a crewdeputy: a home with crew in flight refuses; an empty home lands;
#     its home is no repo, so the original's sweep warned a false docker
#     failure there (W15, named: the port sweeps nothing for a deputy).
x13() { xseed; mkdir -p "$H/dhome/state"; printf 'kind=crewdeputy\nbackend=herdr\nworktree=%s/dhome\nproject_dir=%s/dhome\n' "$H" "$H" >"$H/home/state/dq.meta"; }
x13b() { x13; printf 'kind=ship\n' >"$H/dhome/state/x.meta"; }
xboth x13b
xrefuse "crewdeputy home still has crew in flight: @H/dhome/state/*.meta
ERROR: refusing teardown of dq (unlanded work); land it or pass --force to discard" dq
xboth x13
xsame dq
assert_eq "$XN_RC:$(xout):$(xerr)" "0:teardown dq complete:" "13: an empty deputy home lands"
xboth x13
XDOCK=1
xpair dq; xsame_rc_out dq
XDOCK=0
assert_contains "$(xoerr)" "WARN: qa-infra sweep for dq did not complete (status 1, bound 30s) - docker is unusable or hung" "13 (W15): the original's deputy home warned a false docker failure"
assert_eq "$XN_RC:$(xout):$(xerr)" "0:teardown dq complete:" "13 (W15, named): the port's deputy sweeps nothing"
[ ! -e "$XNH/stub/docker.log" ] || fail "13 (W15, named): ...and calls no docker"

# 14. the qa-infra sweep: docker absent (skipped); both downs; a member in
#     flight (the family stack kept, on stdout); a family stack that is the
#     id; each down failing; a hung docker under AC_TEARDOWN_QA_TIMEOUT=1
#     (124 and the hint - the port's bound ends the docker grandchild with
#     its group, the original orphaned it: named); bounds 0, abc, 010; URG at
#     the step (the evidence, the run completes) and TERM (the evidence, 143,
#     no completion); an id that is shell text (W17, named: the original's
#     trap evaluated it). Each chief's family has a member archived with
#     project_dir r, the one project both sides sweep in (W14 is row 12).
x14m() { xput "home/state/archive/q-a/meta" "kind=crewmate
fleet_scope=$1
project_dir=@H/r
"; }
x14() { xseed; xrepo r; printf 'kind=roomchief\nbackend=herdr\nproject_dir=%s/r\n' "$H" >"$H/home/state/q-chief.meta"; x14m q; }
xboth x14
xsame q-chief
[ ! -e "$XNH/stub/docker.log" ] || fail "14: no docker, no sweep"
XDOCK=1
xboth x14
xsame q-chief
assert_eq "$(cat "$XNH/stub/docker.log")" "compose -p crew-qa-r-q-chief down -v --remove-orphans
compose -p crew-qa-r-q-qa down -v --remove-orphans" "14: both downs"
x14t() { xseed; xrepo r; printf 'kind=scout\nbackend=herdr\nproject_dir=%s/r\n' "$H" >"$H/home/state/q-spec.meta"; printf 'kind=crewmate\nfleet_scope=q\n' >"$H/home/state/q-member.meta"; mkdir -p "$H/home/data/q/spec"; }
xboth x14t
xsame q-spec --force
assert_eq "$(xout)" "qa-infra: family stack q-qa kept - q-member is still in flight and its qa run may hold it
teardown q-spec complete (forced)" "14: a member in flight keeps the family stack"
assert_eq "$(cat "$XNH/stub/docker.log")" "compose -p crew-qa-r-q-spec down -v --remove-orphans" "14: ...and only the task's own stack goes down"
x14i() { xseed; xrepo r; mkdir -p "$H/home/data/q/qa"; printf 'kind=crewmate\nbackend=herdr\nproject_dir=%s/r\n' "$H" >"$H/home/state/q-qa.meta"; }
xboth x14i
xsame q-qa --force
assert_eq "$(cat "$XNH/stub/docker.log")" "compose -p crew-qa-r-q-qa down -v --remove-orphans" "14: a family stack that is the id goes down once"
xboth x14
xboth touch @H/stub/docker.fail-q-chief
xsame q-chief
assert_contains "$(xerr)" "WARN: qa-infra sweep for q-chief did not complete (status 7, bound 30s) - docker is unusable or hung; any task stack survives: (cd @H/r && ROOT/bin/ac-qa.sh infra down --task q-chief && ROOT/bin/ac-qa.sh infra down --task q-qa)" "14: the task's own down failing"
xboth x14
xboth touch @H/stub/docker.fail-q-qa
xsame q-chief
assert_contains "$(xerr)" "(status 7, bound 30s)" "14: the family's down failing"
xboth x14
xboth touch @H/stub/docker.hang
XENV=("AC_TEARDOWN_QA_TIMEOUT=1")
xsame q-chief
XENV=()
assert_contains "$(xerr)" "did not complete (status 124, bound 1s)" "14: a hung docker is bounded"
assert_contains "$(xout)" "teardown q-chief complete" "14: ...and the run completes"
xodock="$(cat "$XOH/stub/docker.pid")"; xndock="$(cat "$XNH/stub/docker.pid")"
kill -0 "$xodock" 2>/dev/null || fail "14: the original's bound orphaned its docker grandchild"
! kill -0 "$xndock" 2>/dev/null || fail "14 (named): the port's bound ends the docker grandchild with its group"
kill "$xodock" 2>/dev/null || true
# A bound of 0 TERMs the original's subshell the instant it forks, and bash
# 3.2 can then print its own `warning: run_pending_traps: ...` pair (SHELL-OWN
# STDERR, named): dropped before the compare.
for xb in 0 abc 010; do
  xboth x14
  XENV=("AC_TEARDOWN_QA_TIMEOUT=$xb")
  xpair q-chief
  XENV=()
  grep -v 'ac-teardown.sh: warning: run_pending_traps: ' "$TMP/xo.err2" >"$TMP/xo.err3" || true
  mv "$TMP/xo.err3" "$TMP/xo.err2"
  xsame_rc_out q-chief; xsame_err q-chief; xsame_world q-chief
done
assert_eq "$(xerr)" "" "14: a bound of 010 is ten seconds"
xboth x14
xboth xput stub/docker.signal 'URG'
xsame q-chief
assert_eq "$XN_RC:$(xerr)" "0:WARN: teardown q-chief: caught SIGURG during the qa-infra sweep" "14: URG names itself and the run goes on"
assert_contains "$(xout)" "teardown q-chief complete" "14: ...to completion"
xboth x14
xboth xput stub/docker.signal 'TERM'
{ xpair q-chief; } 2>/dev/null
xsame_rc_out q-chief; xsame_err q-chief; xsame_world q-chief
assert_eq "$XN_RC:$(xout):$(xerr)" "143::WARN: teardown q-chief: caught SIGTERM during the qa-infra sweep" "14: TERM names itself and ends the run"
x14j() { xseed; xrepo r; printf 'kind=roomchief\nbackend=herdr\nproject_dir=%s/r\n' "$H" >"$H/home/state/inj\$(echo PWNED-BY-TRAP >&2)-chief.meta"; x14m 'inj$(echo PWNED-BY-TRAP >&2)'; printf 'URG\n' >"$H/stub/docker.signal"; }
xboth x14j
xpair 'inj$(echo PWNED-BY-TRAP >&2)-chief'
assert_eq "$XO_RC:$XN_RC" "0:0" "14 (W17): both complete"
grep -qx 'PWNED-BY-TRAP' "$TMP/xo.err2" || fail "14 (W17): the original's trap string evaluated the id"
assert_contains "$(xerr)" 'WARN: teardown inj$(echo PWNED-BY-TRAP >&2)-chief: caught SIGURG during the qa-infra sweep' "14 (W17, named): the port names the id as text"
! grep -qx 'PWNED-BY-TRAP' "$TMP/xn.err2" || fail "14 (W17): the port never runs the id"
XDOCK=0

# 15. the archive epochs: a reused id (the prior meta and status moved to a
#     stamped dir, the latest at the fixed slot), a prior with no status, and
#     a status the append cannot write (exit 1, nothing moved; the
#     original's shell line not reproduced, named).
x15() { x2; mkdir -p "$H/home/state/archive/t"; printf 'kind=ship\nround=1\n' >"$H/home/state/archive/t/meta"; printf 'old status\n' >"$H/home/state/archive/t/status"; }
xboth x15
xsame t
assert_eq "$(cat "$XNH/home/state/archive/t/1767225600."*/status)" "old status" "15: the prior epoch moved whole"
x15n() { x15; rm "$H/home/state/archive/t/status"; }
xboth x15n
xsame t
if [ "$XROOTED" = 0 ]; then
  x15u() { x2; printf 'x\n' >"$H/home/state/t.status"; chmod 444 "$H/home/state/t.status"; }
  xboth x15u
  xsame_shellnoise t
  assert_eq "$XN_RC:$(xout):$(xerr)" "1::" "15: a status the append cannot write ends the run"
  [ -e "$XNH/home/state/t.meta" ] && [ ! -e "$XNH/home/state/archive/t/meta" ] || fail "15: ...with nothing moved"
fi

# 16. bun off PATH (named): the original archived, killed the pane and
#     completed with its children's WARNs (W22); the shim refuses before
#     anything durable.
xboth x2
XPATH="$(xwithout bun)"
xpair t
XPATH=""
assert_eq "$XO_RC:$(cat "$TMP/xo.out")" "0:teardown t complete" "16 (W22): the original completed without bun"
assert_contains "$(xoerr)" "WARN: could not return worktree @H/$XS" "16 (W22): ...its lease left"
assert_eq "$XN_RC:$(xout):$(xerr)" "1::ERROR: required tool not found: bun" "16 (named): the shim refuses"
[ -e "$XNH/home/state/t.meta" ] && [ ! -e "$XNH/home/state/archive" ] || fail "16: ...before anything durable"

pass
