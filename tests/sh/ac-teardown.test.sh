#!/usr/bin/env bash
# ac-teardown.test.sh - the CLI contract of src/teardown.ts through its shim
# ($BIN/ac-teardown.sh), row by row in the order of the module's header - each
# row's exit status, stdout, stderr and the files it leaves asserted
# explicitly. The black-box contract lives in tests/sh/ac-spawn-teardown.test.sh
# and the suites that tear down through the entry.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_fake_orca

# --- the CLI contract, row by row ---------------------------------------------
# One side root $XH: a home at $XH/home (records/ state/ data/ config/), repos
# at $XH/r* with fixed author/committer dates and one git config
# (GIT_CONFIG_GLOBAL, no system config) so every sha is fixed, an optional bare
# origin beside them, pool slots leased by ac-tree.sh get under a PATH `od`
# (one lease_id), the fake herdr and orca (tests/sh/helpers.sh) with their
# state at $XH/fh and $XH/fo; the side root spelled @H in argv and env values;
# cwd $XH/cwd, an EMPTY dir, unless a row names a repo; stdin /dev/null;
# LC_ALL=C unless a row names en_US.UTF-8; PATH stubs - date answering one
# instant per format, od one fixed 8 bytes, sleep logging each call (and
# returning at once while $XH/stub/sleep.fast exists), a logging docker only
# where a row plants it. stdout and stderr are read with the side root spelled
# @H, the bin root ROOT, the entry's pid PID and a mktemp stamp @STAMP.
XH="$TMP/xside"
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
# docker: logs its argv; docker.fail-<task> fails that task's down
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
xdo() {  # xdo <cmd> <args...> - a seeding step at the side root: H names it, and so does a literal @H in an argument
  local x a=(); H="$XH"; for x in "$@"; do a+=("${x//@H/$H}"); done; "${a[@]}"
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
  LC_ALL=C sed -E -e "s#$2#@H#g" -e "s#$ROOT#ROOT#g" \
    -e "s/(^|[^0-9a-f])$3([^0-9a-f]|\$)/\\1PID\\2/g" -e "s/(^|[^0-9a-f])$3([^0-9a-f]|\$)/\\1PID\\2/g" \
    -e 's/1767225600\.[A-Za-z0-9]{6}/1767225600.@STAMP/g' -e 's#(\.wake-spool/[0-9]+)\.[0-9]+\.#\1.WPID.#g' "$1"
}
XRC=0
xrun() {  # xrun <args...> - the shim at the side root, its stdout and stderr normalised
  XRC=0
  xrun_side "$XNBIN" "$XH" xn "$@" || XRC=$?
  xnorm "$TMP/xn.raw" "$XH" "$(cat "$TMP/xn.pid")" >"$TMP/xn.out"; xnorm "$TMP/xn.err" "$XH" "$(cat "$TMP/xn.pid")" >"$TMP/xn.err2"
}
xrow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the suite's own line that started this row
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
xout() { cat "$TMP/xn.out"; }
xerr() { cat "$TMP/xn.err2"; }
xrefuse() {  # xrefuse <stderr> <args...> - exit 1, no stdout, exactly <stderr>, and nothing the world holds changed
  local want="$1"; shift
  xworld "$XH" >"$TMP/xw.before"
  xrun "$@"
  xworld "$XH" >"$TMP/xw.after"
  assert_eq "$XRC:$(xout):$(xerr)" "1::$want" "teardown refusal for '$*' at line $(xrow)"
  cmp -s "$TMP/xw.before" "$TMP/xw.after" || fail "teardown refusal for '$*' at line $(xrow) changed the world: $(diff "$TMP/xw.before" "$TMP/xw.after" | head -n 12)"
}
xwithout() {  # xwithout <tool> - the suite's PATH with every dir holding <tool> mirrored without it
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
XUSAGE="ERROR: usage: ac-teardown.sh <id> [--force] [--pr-ready '<the captain acceptance>'] [--ci-override '<why CI need not be green>'] [--no-lesson '<why>'] [--no-fact '<why>']"
xstub() {  # xstub <name> <body> - a stub at <side>/stubs, ahead of the suite's own when XPRE names it
  mkdir -p "$H/stubs"; printf '%s\n' "$2" >"$H/stubs/$1"; chmod +x "$H/stubs/$1"
}
XROOTED=0; [ "$(id -u)" != 0 ] || XROOTED=1

# 1. arguments, the home and the meta, in code order: the usage line (no
#    word, ''), the four value flags absent or empty, repeats, no meta, a
#    meta that is a directory, homeless (with AC_FLEET_STATE too), an AC_HOME
#    cd cannot enter, an unreadable meta, an invalid ambient backend (checked
#    before the usage), git absent.
xdo xseed
xrefuse "$XUSAGE"
xrefuse "$XUSAGE" ""
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
xrefuse "ERROR: --ci-override carries the captain's acknowledgement that CI did not verify this PR - it is the record, so an empty value is refused" x --ci-override
xrefuse "ERROR: unknown argument: b" x --ci-override why b
xdo mkdir -p @H/home/state/d.meta
xrefuse "ERROR: no crewmate meta for d" d
XHOMELESS=1
xrefuse "$XNOHOME" x
XENV=("AC_FLEET_STATE=@H/home/state")
xrefuse "$XNOHOME" x
XENV=()
xrefuse "$XUSAGE"
XHOMELESS=0
XENV=("AC_HOME=@H/nope")
xrefuse "ERROR: AC_HOME is not a readable directory: @H/nope" x
XENV=()
if [ "$XROOTED" = 0 ]; then
  xdo xput home/state/u.meta 'kind=ship
'
  xdo chmod 000 @H/home/state/u.meta
  xrefuse "WARN: cannot read meta file @H/home/state/u.meta" u
  xdo chmod 644 @H/home/state/u.meta
fi
xdo xput home/config/backend 'tmux
'
xrefuse "ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)"
xrefuse "ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" u
XENV=("AC_BACKEND=orca")
xrefuse "$XUSAGE"
XENV=()
xdo rm -f @H/home/config/backend
XPATH="$(xwithout git)"
xrefuse "ERROR: required tool not found: git" u
XPATH=""

# 2. the ship proofs: a fresh slot; a branch landed in local main, only on
#    origin's main (kept with git's own -d text), only as its own pushed
#    branch (not landed), inside another remote branch, inside the epic branch
#    (heads, -D); an unreadable ledger at the proof and at the drop;
#    pr_merged with and without pr_merged_head and a commit past it; a
#    detached commit; a commit past the landed branch; dirty (untracked-only
#    dirt listed, ten paths at most), an assume-unchanged edit; a revision on
#    its family's branch; a slot whose gitdir is gone (refused at the gate).
XS=r/.crew/worktrees/1-r
x2() { xseed; xrepo r; xlease r t; xtab t 1; }
x2br() { git -C "$H/$XS" checkout -q -b crew/t; xcommit "$XS" work.txt; }
xdo x2
xrun t
assert_eq "$XRC:$(xout)" "0:teardown t complete" "2: a fresh slot lands"
assert_contains "$(cat "$XH/home/state/archive/t/status")" "resolved: teardown" "2: ...archived with its record"
x2b() { x2; x2br; git -C "$H/r" merge -q --ff-only crew/t; }
xdo x2b
xrun t
assert_eq "$XRC:$(xout)" "0:teardown t complete" "2: a branch landed in local main lands"
# TOKEN LEDGER: the task's claude token use is appended, per model, to
# records/task-tokens.tsv once the pane is closed - a repeated usage line of
# one message counted once, subagents in.
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
xdo x2tk
xrun t
XENV=()
assert_eq "$XRC" 0 "2 (TOKEN LEDGER): the task lands"
assert_eq "$(cat "$XH/home/records/task-tokens.tsv")" "$(printf 'at\tid\tkind\tharness\tmodel\tinput\tcache_creation\tcache_read\toutput\n2026-01-01T00:00:00Z\tt\tship\tclaude\tclaude-haiku-5-5\t1\t2\t3\t4\n2026-01-01T00:00:00Z\tt\tship\tclaude\tclaude-opus-5-5\t3\t20\t100\t9')" "2 (TOKEN LEDGER): one row per model, a repeated message once, its subagents in"
xdo x2b
xrun t
assert_eq "$(cat "$XH/home/records/task-tokens.tsv")" "$(printf 'at\tid\tkind\tharness\tmodel\tinput\tcache_creation\tcache_read\toutput\n2026-01-01T00:00:00Z\tt\tship\t-\tunknown: no session_id\t\t\t\t')" "2 (TOKEN LEDGER): a task with no claude session is unknown, never zero"
x2tm() { x2tk; rm -f "$H/tx/-w/$XSID.jsonl"; }
XENV=("AC_CLAUDE_TRANSCRIPT_ROOT=@H/tx")
xdo x2tm
xrun t
XENV=()
assert_eq "$(tail -n 1 "$XH/home/records/task-tokens.tsv")" "$(printf '2026-01-01T00:00:00Z\tt\tship\tclaude\tunknown: no transcript for session %s\t\t\t\t' "$XSID")" "2 (TOKEN LEDGER): a session whose transcript is gone is unknown"
assert_eq "$(git -C "$XH/r" branch --list crew/t)" "" "2: ...and the merged branch is dropped"
x2tdot() { x2tk; mkdir -p "$H/tx/.trash"; cp "$H/tx/-w/$XSID.jsonl" "$H/tx/.trash/"; }
XENV=("AC_CLAUDE_TRANSCRIPT_ROOT=@H/tx")
xdo x2tdot
xrun t
XENV=()
assert_eq "$(tail -n 2 "$XH/home/records/task-tokens.tsv")" "$(printf '2026-01-01T00:00:00Z\tt\tship\tclaude\tclaude-haiku-5-5\t1\t2\t3\t4\n2026-01-01T00:00:00Z\tt\tship\tclaude\tclaude-opus-5-5\t3\t20\t100\t9')" "2 (TOKEN LEDGER): a copy under a dot dir is no second transcript, as <root>/*/<sid>.jsonl reads it"
x2c() { x2; xorigin r; x2br; git -C "$H/r" push -q origin crew/t:main 2>/dev/null; git -C "$H/r" fetch -q origin; }
xdo x2c
xrun t
assert_eq "$XRC" 0 "2: origin's main holds it"
assert_contains "$(xerr)" "WARN: kept crew/t in @H/r: " "2: ...the branch -d refuses is kept"
assert_contains "$(xerr)" " - reclaim: git branch -D crew/t" "2: ...with the reclaim command"
x2d() { x2; xorigin r; x2br; git -C "$H/r" push -q origin crew/t 2>/dev/null; git -C "$H/r" fetch -q origin; }
xdo x2d
xrefuse "branch crew/t ($(git -C "$XH/r" rev-parse crew/t | cut -c1-12)) is not landed: not in main (local or origin), no containing remote branch, no merged PR
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
x2e() { x2; xorigin r; x2br; git -C "$H/r" push -q origin crew/t:other 2>/dev/null; git -C "$H/r" fetch -q origin; }
xdo x2e
xrun t
assert_eq "$XRC" 0 "2: another remote branch holds it"
x2f() {
  x2; x2br; git -C "$H/r" branch ep/e1 crew/t
  xput home/records/backlog.md '# B
## In flight
- [ ] t - story epic:e1 (repo: r)
'
  xput home/data/e1/branches 'r ep/e1
'
}
xdo x2f
xrun t
assert_eq "$XRC:$(git -C "$XH/r" branch --list crew/t)" "0:" "2: the epic branch holds it, and -D drops it"
x2g() { x2b; xput home/records/backlog.md '- [ ] t - x
'; chmod 000 "$H/home/records/backlog.md"; }
x2g2() { x2; x2br; xput home/records/backlog.md '- [ ] t - x
'; chmod 000 "$H/home/records/backlog.md"; }
if [ "$XROOTED" = 0 ]; then
  xdo x2g
  xrun t
  assert_eq "$XRC:$(xerr)" "0:WARN: cannot read the ledger to resolve the epic-branch fence for t - crew/t is deleted only if -d proves it merged" "2: an unreadable ledger at the drop"
  xdo chmod 644 @H/home/records/backlog.md
  xdo x2g2
  xrun t
  xdo chmod 644 @H/home/records/backlog.md
  assert_eq "$XRC:$(xerr)" "1:WARN: cannot read the ledger to resolve the epic-branch fence for t - containment in an epic branch stays unproven
branch crew/t ($(git -C "$XH/r" rev-parse crew/t | cut -c1-12)) is not landed: not in main (local or origin), no containing remote branch, no merged PR
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" "2: an unreadable ledger at the proof"
fi
x2h() { x2; x2br; printf 'pr_merged=1\n' >>"$H/home/state/t.meta"; }
xdo x2h
xrun t
assert_eq "$XRC" 0 "2: a merged PR with no recorded head lands"
x2h2() { x2; x2br; printf 'pr_merged=1\npr_merged_head=%s\n' "$(git -C "$H/r" rev-parse crew/t)" >>"$H/home/state/t.meta"; }
xdo x2h2
xrun t
assert_eq "$XRC" 0 "2: a merged PR that contains the head lands"
x2h3() { x2h2; xcommit "$XS" past.txt; }
xdo x2h3
xrefuse "branch crew/t ($(git -C "$XH/r" rev-parse crew/t | cut -c1-12)) is not landed: not in main (local or origin), no containing remote branch, no merged PR
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
x2i() { x2; xcommit "$XS" loose.txt; }
xdo x2i
xh="$(git -C "$XH/$XS" rev-parse HEAD | cut -c1-12)"
xrefuse "worktree HEAD $xh holds commits no branch carries and nothing landed contains; put them on crew/t (git -C @H/$XS branch crew/t $xh) and land it, or --force to discard
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
x2j() { x2b; git -C "$H/$XS" checkout -q --detach; xcommit "$XS" past.txt; }
xdo x2j
xrefuse "worktree HEAD $(git -C "$XH/$XS" rev-parse HEAD | cut -c1-12) is past the landed crew/t ($(git -C "$XH/r" rev-parse crew/t | cut -c1-12)) and nothing landed contains it; move crew/t to it and land that, or --force to discard
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
x2k() { x2b; printf 'x\n' >"$H/$XS/untracked.txt"; }
xdo x2k
xrefuse "worktree is dirty: uncommitted changes that crew/t does not hold; commit them or --force to discard
untracked only, no tracked edits: untracked.txt
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
x2kt() { x2k; printf 'edit\n' >>"$H/$XS/file.txt"; }
xdo x2kt
xrefuse "worktree is dirty: uncommitted changes that crew/t does not hold; commit them or --force to discard
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
x2kc() { x2b; for f in a b c d e f g h i j k l; do printf 'x\n' >"$H/$XS/$f.txt"; done; }
xdo x2kc
xrun t
assert_eq "$XRC" 1 "2: untracked-only dirt refuses"
assert_contains "$(xerr)" "
untracked only, no tracked edits: a.txt, b.txt, c.txt, d.txt, e.txt, f.txt, g.txt, h.txt, i.txt, j.txt (+2 more)
" "2 (UNTRACKED-ONLY): at most ten paths are listed"
x2kn() { x2; printf 'x\n' >"$H/$XS/scratch.log"; }
xdo x2kn
xrefuse "worktree is dirty and no crew/t branch exists
untracked only, no tracked edits: scratch.log
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
x2l() { x2b; git -C "$H/$XS" update-index --assume-unchanged file.txt; printf 'edit\n' >>"$H/$XS/file.txt"; }
xdo x2l
xrefuse "worktree is dirty: uncommitted changes that crew/t does not hold; commit them or --force to discard
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
x2m() {
  xseed; xrepo r; xlease r t12-r2; xtab t12-r2 1
  git -C "$H/$XS" checkout -q -b crew/t12; xcommit "$XS" work.txt; git -C "$H/r" merge -q --ff-only crew/t12
}
xdo x2m
xrun t12-r2
assert_eq "$XRC:$(git -C "$XH/r" branch --list 'crew/*')" "0:" "2: a revision lands on its family's crew/t12, which is dropped"
x2n() { x2; printf 'gitdir: %s/nowhere\n' "$H" >"$H/$XS/.git"; }
xdo x2n
xrun t
assert_eq "$XRC:$(xout)" "1:" "2: a worktree git cannot read is refused"
assert_contains "$(xerr)" "worktree @H/$XS cannot be read by git, so its contents cannot be checked; repair it or --force to discard" "2: ...naming it"
[ -e "$XH/home/state/t.meta" ] || fail "2: ...with nothing archived"
x2nb() { x2; x2br; git -C "$H/r" merge -q --ff-only crew/t; printf 'gitdir: %s/nowhere\n' "$H" >"$H/$XS/.git"; }
xdo x2nb
xrun t
assert_eq "$XRC:$(xout)" "1:" "2: a worktree git cannot read is refused with a branch head too"
assert_contains "$(xerr)" "worktree @H/$XS cannot be read by git, so its contents cannot be checked; repair it or --force to discard" "2: ...naming it"

# 3. scouts: the report missing (flat, nested, merged design) and present at
#    each of those; an unlanded crew branch; dirty; HEAD past the branch.
x3() { xseed; xrepo r; xlease r "$1"; xtab "$1" 1; printf 'kind=scout\n' >>"$H/home/state/$1.meta"; }
xdo x3 s1
xrefuse "scout report missing: no report.md at @H/home/data/s1 (nor merged-design sub-stage reports)
ERROR: refusing teardown of s1 (unlanded work); land it or pass --force to discard" s1
xdo xput home/data/s1/report.md 'r'
xrun s1
assert_eq "$XRC" 0 "3: a flat report lands"
x3n() { x3 fam-spec; xput home/data/fam/spec/brief.md 'b'; }
xdo x3n
xrefuse "scout report missing: no report.md at @H/home/data/fam/spec (nor merged-design sub-stage reports)
ERROR: refusing teardown of fam-spec (unlanded work); land it or pass --force to discard" fam-spec
xdo xput home/data/fam/spec/report.md 'r'
xrun fam-spec
assert_eq "$XRC" 0 "3: a nested report lands"
for xstage in spec arch plan; do
  x3d() { x3 fd-design-r2; xput home/data/fd/design-r2/brief.md 'b'; xput "home/data/fd/$xstage/report.md" 'r'; }
  xdo x3d
  xrun fd-design-r2
  assert_eq "$XRC" 0 "3: a merged design scout's $xstage report lands it"
done
x3e() { x3 fe-design; xput home/data/fe/design/brief.md 'b'; }
xdo x3e
xrefuse "scout report missing: no report.md at @H/home/data/fe/design (nor merged-design sub-stage reports)
ERROR: refusing teardown of fe-design (unlanded work); land it or pass --force to discard" fe-design
x3b() { x3 s3; xput home/data/s3/report.md 'r'; printf 'gitdir: %s/nowhere\n' "$H" >"$H/$XS/.git"; }
xdo x3b
xrun s3
assert_eq "$XRC:$(xout)" "1:" "3: a scout whose tree git cannot read is refused"
assert_contains "$(xerr)" "worktree @H/$XS cannot be read by git, so its contents cannot be checked; repair it or --force to discard" "3: ...naming it"
x3u() { x3 s2; xput home/data/s2/report.md 'r'; git -C "$H/$XS" checkout -q -b crew/s2; xcommit "$XS" w.txt; }
xdo x3u
xrefuse "scout created crew/s2 with unlanded work; promote it (ac-promote.sh s2) or --force to discard
ERROR: refusing teardown of s2 (unlanded work); land it or pass --force to discard" s2
x3k() { x3 s3; xput home/data/s3/report.md 'r'; printf 'x\n' >"$H/$XS/u.txt"; }
xdo x3k
xrefuse "worktree is dirty: uncommitted changes that crew/s3 does not hold; commit them or --force to discard
untracked only, no tracked edits: u.txt
ERROR: refusing teardown of s3 (unlanded work); land it or pass --force to discard" s3
x3p() { x3u; git -C "$H/r" merge -q --ff-only crew/s2; git -C "$H/$XS" checkout -q --detach; xcommit "$XS" past.txt; }
xdo x3p
xrefuse "worktree HEAD $(git -C "$XH/$XS" rev-parse HEAD | cut -c1-12) holds commits nothing landed contains; put them on crew/s2 and promote it (ac-promote.sh s2), or --force to discard
ERROR: refusing teardown of s2 (unlanded work); land it or pass --force to discard" s2
# An ambiguous task dir refuses; W21's second, generic line is left unasserted.
x3a() { x3 h1; xput home/data/h1/brief.md 'b'; xput home/data/h1/implement/brief.md 'b'; xput home/data/h1/report.md 'r'; }
xdo x3a
xworld "$XH" >"$TMP/xw.before"
xrun h1
xworld "$XH" >"$TMP/xw.after"
assert_eq "$XRC:$(xout):$(head -n 1 "$TMP/xn.err2")" "1::ERROR: ambiguous task data for h1: briefs at both @H/home/data/h1/implement and @H/home/data/h1" "3: an ambiguous task dir refuses"
cmp -s "$TMP/xw.before" "$TMP/xw.after" || fail "3: an ambiguous task dir's refusal changed the world"

# 4. --pr-ready: no PR; a dependent (the strict list, a spaced list - wider
#    than the grammar on purpose - and `01` never `1`); an absent and an
#    unreadable ledger; dirty; pr_head newer, with and without a branch; the
#    happy path.
x4() { xseed; xrepo r; xlease r "$1"; xtab "$1" 1; printf 'pr=https://pr/1\n' >>"$H/home/state/$1.meta"; xput home/records/backlog.md '# B
'; }
xdo x4 t
xdo sed -i '' '/^pr=/d' @H/home/state/t.meta
xrefuse "ERROR: --pr-ready with no recorded PR for t - record it first (bin/ac-pr-check.sh t <url>)" t --pr-ready 'ok'
for xdep in 'blocked-by: a,t - waits' 'blocked-by: a, t - spaced' 'blocked-by:t'; do
  xdo x4 t
  xdo xput home/records/backlog.md "## Queued
- [ ] dep1 - row $xdep
"
  xrefuse "ERROR: --pr-ready refused: open row dep1 still waits on t (blocked-by) - a dependent starts from the merged tree, so this task lands only by the real merge" t --pr-ready 'ok'
done
x4n() { xseed; xrepo r; xlease r 1; xtab 1 1; printf 'pr=u\n' >>"$H/home/state/1.meta"; xput home/records/backlog.md '- [ ] dep - x blocked-by: 01,t1 - x
- [x] dep2 - x blocked-by: 1 - done rows never wait
'; }
xdo x4n
xrun 1 --pr-ready ok
assert_eq "$XRC" 0 "4: a dependent on 01 is no dependent on 1, and a Done row waits on nothing"
xdo x4 t
xdo rm -f @H/home/records/backlog.md
xrefuse "ERROR: --pr-ready refused: cannot read @H/home/records/backlog.md to prove no open row waits on t - an unreadable ledger must not read as 'no dependent'" t --pr-ready ok
if [ "$XROOTED" = 0 ]; then
  xdo x4 t
  xdo chmod 000 @H/home/records/backlog.md
  xrun t --pr-ready ok
  xdo chmod 644 @H/home/records/backlog.md
  assert_eq "$XRC:$(xout):$(xerr)" "1::ERROR: --pr-ready refused: cannot read @H/home/records/backlog.md to prove no open row waits on t - an unreadable ledger must not read as 'no dependent'" "4: an unreadable ledger refuses"
fi
x4d() { x4 t; printf 'x\n' >"$H/$XS/u.txt"; }
xdo x4d
xrefuse "ERROR: --pr-ready refused: the worktree holds uncommitted work the accepted PR cannot contain - commit and push it (then re-record the PR head), or discard it deliberately, before the acceptance lands:
?? u.txt" t --pr-ready ok
# A hidden edit (assume-unchanged) under a name that is not ASCII: the
# refusal carries the path's own bytes.
x4u() {
  x4 t; local f; f="caf$(printf '\303\251').txt"
  printf 'v\n' >"$H/$XS/$f"; git -C "$H/$XS" add -- "$f"; git -C "$H/$XS" commit -qm u
  git -C "$H/$XS" update-index --assume-unchanged -- "$f"; printf 'w\n' >"$H/$XS/$f"
}
xdo x4u
xrefuse "$(printf 'ERROR: --pr-ready refused: the worktree holds uncommitted work the accepted PR cannot contain - commit and push it (then re-record the PR head), or discard it deliberately, before the acceptance lands:\nH  caf\303\251.txt')" t --pr-ready ok
x4g() { x4 t; printf 'gitdir: %s/nowhere\n' "$H" >"$H/$XS/.git"; }
xdo x4g
xrun t --pr-ready ok
assert_eq "$XRC:$(xout):$(xerr | grep '^ERROR')" "1::ERROR: --pr-ready refused: worktree @H/$XS cannot be read by git, so its contents cannot be checked; repair it or --force to discard" "4: --pr-ready refuses a tree git cannot read"
x4h() { x4 t; git -C "$H/$XS" checkout -q -b crew/t; xcommit "$XS" a.txt; printf 'pr_head=%s\n' "$(git -C "$H/$XS" rev-parse HEAD)" >>"$H/home/state/t.meta"; xcommit "$XS" b.txt; }
xdo x4h
xh="$(git -C "$XH/$XS" rev-parse HEAD | cut -c1-12)"
xrefuse "--pr-ready refused: HEAD $xh is newer than the recorded PR head ($(sed -n 's/^pr_head=//p' "$XH/home/state/t.meta")) - the captain accepted the PR, not commits past it. Push and re-record (bin/ac-pr-check.sh t <url>), then ask again
branch crew/t ($xh) is not landed: not in main (local or origin), no containing remote branch, no merged PR
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t --pr-ready ok
x4h2() { x4 t; xcommit "$XS" a.txt; printf 'pr_head=%s\n' "$(git -C "$H/$XS" rev-parse HEAD)" >>"$H/home/state/t.meta"; xcommit "$XS" b.txt; }
xdo x4h2
xh="$(git -C "$XH/$XS" rev-parse HEAD | cut -c1-12)"
xrefuse "--pr-ready refused: HEAD $xh is newer than the recorded PR head ($(sed -n 's/^pr_head=//p' "$XH/home/state/t.meta")) - the captain accepted the PR, not commits past it. Push and re-record (bin/ac-pr-check.sh t <url>), then ask again
worktree HEAD $xh holds commits no branch carries and nothing landed contains; put them on crew/t (git -C @H/$XS branch crew/t $xh) and land it, or --force to discard
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t --pr-ready ok
x4ok() { x4 t; git -C "$H/$XS" checkout -q -b crew/t; xcommit "$XS" a.txt; printf 'pr_head=%s\n' "$(git -C "$H/$XS" rev-parse HEAD)" >>"$H/home/state/t.meta"; }
xdo x4ok
xrun t --pr-ready 'captain: ship it'
assert_contains "$(cat "$XH/home/state/archive/t/status")" "done: captain accepted the ready-to-merge PR - captain: ship it" "4: the acceptance is on the record"

# 4b. THE CI GATE - none/failing refuse, pending and a key-less meta (x4ok's
#     own) stay untouched, --ci-override or a trusted `ci: none` project
#     declaration lands none, failing is never excused that way.
x4ci() { x4ok; printf 'ci=%s\n' "$1" >>"$H/home/state/t.meta"; }
xdo x4ci none
xrefuse "ERROR: --pr-ready refused: no CI check verified the PR - acknowledge it explicitly with --ci-override '<why>', or re-record once checks register (bin/ac-pr-check.sh t <url>)" t --pr-ready ok
xdo x4ci failing
xrefuse "ERROR: --pr-ready refused: the recorded CI run failed - acknowledge it explicitly with --ci-override '<why>', or fix it and re-record (bin/ac-pr-check.sh t <url>)" t --pr-ready ok
xdo x4ci pending
xrun t --pr-ready ok
assert_eq "$XRC:$(xout)" "0:teardown t complete" "4b: ci=pending keeps today's behavior and lands"
xdo x4ci none
xrun t --pr-ready ok --ci-override 'captain: known gap, ship it'
assert_eq "$XRC" 0 "4b: --ci-override lands a ci=none PR"
assert_contains "$(cat "$XH/home/state/archive/t/status")" "ci override acknowledged: captain: known gap, ship it" "4b: the override is on the record, ahead of the acceptance"
xdo x4ci failing
xrun t --pr-ready ok --ci-override 'captain: known gap, ship it'
assert_eq "$XRC" 0 "4b: --ci-override lands a ci=failing PR too"
xdo x4ci none
xdo mkdir -p @H/home/projects
xdo xput home/projects/r.yaml $'ci: none\n'
xrun t --pr-ready ok
assert_eq "$XRC" 0 "4b: a trusted ci: none project declaration lands a zero-check PR without --ci-override"
xdo x4ci failing
xrefuse "ERROR: --pr-ready refused: the recorded CI run failed - acknowledge it explicitly with --ci-override '<why>', or fix it and re-record (bin/ac-pr-check.sh t <url>)" t --pr-ready ok
xdo rm -f @H/home/projects/r.yaml

# 5. the knowledge loop (kind=self): nothing written (the hint bytes, the
#    refusal, the line on the record); the waivers and the Done row; a
#    `(solo <id>)` heading, a `(by: <id>,` line and a `(by: <id>-2,` one; a
#    fact; a scoped receipt; two refused attempts then a landing (the
#    waivers recorded at the landing alone); the tick's answers - counted, a
#    keyed duplicate, the cadence lock held (every line kept and a WARN, exit
#    0) and the learning-due crossing; --force owes nothing.
x5() {
  xseed; xrepo r; xlease r "$1"; xtab "$1" 1
  sed -i '' 's/^kind=ship$/kind=self/' "$H/home/state/$1.meta"
}
xdo x5 s1
xrun s1
assert_eq "$XRC:$(xerr)" "1:ERROR: solo landing refused: the knowledge loop above is incomplete - write what is missing (or waive the lesson/fact with --no-lesson/--no-fact '<why>'), then run the teardown again" "5: nothing written refuses"
assert_eq "$(cat "$TMP/xn.out")" "knowledge loop: lessons=none repo-knowledge=none done-row=none
missing - the solo contract owes these at landing:
  lesson: ROOT/bin/ac-learn.sh note '### 2026-01-01 (solo s1)' '- <one method lesson>'   (or --no-lesson '<why nothing new>')
  repo fact: ROOT/bin/ac-know.sh add --home @H/home --repo @H/r --family s1 --src-file <path>:<line> --fact '<verified fact>'   (or --no-fact '<why none verified>')
  done row: append '- [x] s1 - <outcome>' under ## Done in @H/home/records/backlog.md" "5: the hint bytes"
x5done() { x5 s1; xput home/records/backlog.md '## Done
- [x] s1 - landed
'; }
xdo x5done
xrun s1 --no-lesson 'nothing new' --no-fact 'none verified'
assert_eq "$XRC" 0 "5: the waivers and the Done row land the slice"
[ ! -e "$XH/home/records/task-tokens.tsv" ] || fail "5 (TOKEN LEDGER): a self task runs no agent, so it records no token use"
assert_contains "$(cat "$XH/home/state/archive/s1/status")" "learning tick: tick: debriefs=" "5: ...and the tick's answer is on the record"
x5all() {
  x5done; xput home/records/learnings.md '### 2026-01-01 (solo s1)
- a lesson
'; xput home/records/repo-knowledge/r.md '- a fact | by: s1
'
}
xdo x5all
xrun s1
assert_eq "$XRC" 0 "5: all three written land the slice"
assert_contains "$(xout)" "knowledge loop: lessons=yes repo-knowledge=yes done-row=yes" "5: all three written"
x5by() { x5done; xput home/records/learnings.md '### 2026 (family f)
- x (by: s1-2, first-hand)
'; }
xdo x5by
xrun s1 --no-fact n
assert_eq "$XRC" 1 "5: (by: s1-2, is not s1's lesson"
assert_eq "$(grep -c ' repo fact waived: ' "$XH/home/state/s1.status" || true)" 0 "5: ...and the refusal records no waiver"
x5sc() { x5 f-s1; printf 'fleet_scope=f\n' >>"$H/home/state/f-s1.meta"; xput home/data/f/room.md '- [2026] f-chief> LANDED: f-s1 - ok
'; }
xdo x5sc
xrun f-s1 --no-lesson n --no-fact n
assert_eq "$XRC" 0 "5: a scoped slice lands on its receipt"
assert_contains "$(xout)" "landed-receipt=yes" "5: a scoped slice's receipt"
xdo x5done
xrun s1 --no-lesson 'nothing new'
assert_eq "$XRC:$(grep -c ' lesson waived: \| repo fact waived: ' "$XH/home/state/s1.status" || true)" "1:0" "5: a refused landing records no waiver"
xrun s1 --no-lesson 'nothing new'
assert_eq "$XRC" 1 "5: ...refused again"
xrun s1 --no-lesson 'nothing new' --no-fact 'none'
assert_eq "$XRC:$(grep -c 'lesson waived: nothing new' "$XH/home/state/archive/s1/status")" "0:1" "5: the waiver is recorded at the landing alone"
xdo x5done
xrun s1 --no-lesson n --no-fact n
assert_eq "$XRC" 0 "5: a first landing"
x5again() { xlease r s1; xtab s1 1; sed -i '' 's/^kind=ship$/kind=self/' "$H/home/state/s1.meta"; }
xdo x5again
xrun s1 --no-lesson n --no-fact n
assert_contains "$(cat "$XH/home/state/archive/s1/status")" "learning tick: tick skipped: landing s1 is already counted" "5: a keyed duplicate tick"
x5lock() { x5done; mkdir -p "$H/home/state/.learn-cadence.lock"; printf '%s\n' "$$" >"$H/home/state/.learn-cadence.lock/pid"; : >"$H/stub/sleep.fast"; }
xdo x5lock
xrun s1 --no-lesson n --no-fact n
assert_eq "$XRC" 0 "5: a tick that could not be claimed still lands, exit 0"
assert_contains "$(cat "$XH/home/state/archive/s1/status")" "learning tick: tick NOT counted: landing s1 could not be claimed (see the warning above) - re-run this tick" "5: the tick's verdict is recorded..."
assert_contains "$(grep 'learning tick: ' "$XH/home/state/archive/s1/status" | head -n1)" "learning tick: WARN: " "5: ...after the warning it points at"
assert_contains "$(xerr)" "WARN: learning tick for s1 failed (exit 1) - this landing is not counted; re-run: ROOT/bin/ac-learn.sh tick s1" "5: ...and says so"
x5due() { x5done; xput home/config/learn-every '1
'; }
xdo x5due
xrun s1 --no-lesson n --no-fact n
assert_contains "$(cat "$XH/home/state/archive/s1/status")" "learning tick: tick: debriefs=1/1" "5: the crossing tick"
xdo x5 s1
xrun s1 --force
assert_eq "$XRC:$(xout)" "0:teardown s1 complete (forced)" "5: --force owes nothing"

# 6. a direct verifier: a codereview verifier (archived, its pane reaped, its
#    lease returned by id, its stamps and lock dir gone, its status archived
#    beside its meta); an incomplete verify-qa (evidence minted, the partial
#    verdict, the pane result and the `current` run copied - a symlink or a
#    dir; an evidence dir already there; run-state already there); evidence
#    that cannot be made (the ERROR before anything is archived); a
#    re-archived verifier (the LATEST takes the fixed slot and the prior
#    moves to a stamped dir); a vanished lease, an empty entry, a lease with
#    and without its id, a re-leased slot; an orca verifier's own backend.
XV=t1-verify-codereview
x6() {
  xseed; xrepo r
  local wt; wt="$(xtree get --repo "$H/r" --id "$XV")"
  printf 'kind=verify-codereview\nbackend=herdr\ncaller=t1\nfamily=t1\nleases=%s\nlease_ids=0011223344556677\n' "$wt" >"$H/home/state/$XV.meta"
  printf 'pv tv\n' >"$H/home/state/.pane-$XV"
  local s; for s in hash change seen seen-hash stale gone ask unobservable report-hash superseded busy busy-stalled ended rewake; do : >"$H/home/state/.$s-$XV"; done
  : >"$H/home/state/.hash-t1"
  printf '2026 started\n' >"$H/home/state/$XV.status"
  mkdir -p "$H/home/state/.verify-t1-codereview.lock.d"
}
xdo x6
xrun "$XV"
assert_eq "$XRC:$(xout):$(xerr)" "0:teardown $XV complete (verifier):" "6: a direct verifier"
assert_eq "$(ls -A "$XH/home/state" | LC_ALL=C sort | tr '\n' ' ')" ".hash-t1 archive " "6: nothing of it is left in state/"
assert_eq "$(cat "$XH/home/state/archive/$XV/status")" "2026 started" "6: ...its status archived beside its meta"
assert_eq "$(ls "$XH/fh/tabs")" "" "6: ...its pane reaped"
x6pane() { x6; : >"$H/fh/panes/pv.buf"; }
xdo x6pane
xrun "$XV"
assert_eq "$XRC:$(xout)" "0:teardown $XV complete (verifier)" "6: a pane the reap left open never stops the run"
assert_contains "$(xerr)" "WARN: pane pv (@H/home/state/.pane-$XV) did not close" "6: a pane the reap left open is warned"
XQ=t2-verify-qa
x6q() {
  xseed; mkdir -p "$H/qt/.crew/qa/run1"; printf 'state\n' >"$H/qt/.crew/qa/run1/steps.tsv"; ln -s run1 "$H/qt/.crew/qa/current"
  printf '{"partial":1}\n' >"$H/out.json"; printf '{"e":1}\n' >"$H/pane.ndjson"
  printf 'kind=verify-qa\nbackend=herdr\ncaller=t2\nfamily=t2\nworktree=%s/qt\noutput=%s/out.json\npane_result=%s/pane.ndjson\n%s' "$H" "$H" "$H" "${1:-}" >"$H/home/state/$XQ.meta"
}
xdo x6q
xrun "$XQ"
assert_eq "$XRC:$(xout)" "0:teardown $XQ complete (verifier)" "6: an incomplete QA verifier lands"
assert_contains "$(cat "$XH/home/data/t2/verification/$XQ-incomplete-1767225600/incomplete-run.md")" 'Preserved at: `2026-01-01T00:00:00Z`' "6: the incomplete artifact"
assert_eq "$(cat "$XH/home/data/t2/verification/$XQ-incomplete-1767225600/run-state/steps.tsv")" "state" "6: ...the current run copied"
assert_eq "$(cd "$XH/home/data/t2/verification/$XQ-incomplete-1767225600" && cat verdict.partial.json pane-result.ndjson && sed -n 1p verifier.meta)" '{"partial":1}
{"e":1}
kind=verify-qa' "6: ...the partial verdict, the pane result and the meta preserved"
x6qe() { x6q "evidence=$H/ev
"; mkdir -p "$H/ev/run-state"; printf 'kept\n' >"$H/ev/run-state/old"; : >"$H/ev/verdict.json"; }
xdo x6qe
xrun "$XQ"
assert_eq "$(ls "$XH/ev/run-state")" "old" "6: an existing run-state is never overwritten"
x6qd() { x6q; rm "$H/qt/.crew/qa/current"; mkdir -p "$H/qt/.crew/qa/current"; printf 'dir\n' >"$H/qt/.crew/qa/current/x"; }
xdo x6qd
xrun "$XQ"
assert_eq "$XRC:$(cat "$XH/home/data/t2/verification/$XQ-incomplete-1767225600/run-state/x")" "0:dir" "6: a \`current\` that is a dir is copied"
x6qc() { x6q "evidence=$H/ev
"; mkdir -p "$H/ev/run-state"; printf '{}\n' >"$H/ev/verdict.json"; printf 'r\n' >"$H/ev/relay-report.md"; }
xdo x6qc
xrun "$XQ"
assert_eq "$XRC" 0 "6: a complete QA verifier lands"
[ ! -e "$XH/ev/incomplete-run.md" ] || fail "6: complete evidence is never re-preserved"
x6qx() { x6q "evidence=$H/afile/x
"; : >"$H/afile"; }
xdo x6qx
xrun "$XQ"
assert_eq "$XRC" 1 "6: evidence that cannot be made ends the run"
assert_contains "$(xerr)" "ERROR: cannot preserve incomplete QA verifier $XQ at @H/afile/x" "6: ...named"
[ -e "$XH/home/state/$XQ.meta" ] || fail "6: ...before anything is archived"
x6r() { x6; mkdir -p "$H/home/state/archive/$XV"; printf 'kind=verify-codereview\nround=1\n' >"$H/home/state/archive/$XV/meta"; printf '1 old\n' >"$H/home/state/archive/$XV/status"; }
xdo x6r
xrun "$XV"
assert_eq "$(sed -n 's/^caller=//p' "$XH/home/state/archive/$XV/meta")" "t1" "6: the fixed slot holds the latest"
assert_eq "$(cat "$XH"/home/state/archive/"$XV"/*/meta)" "kind=verify-codereview
round=1" "6: ...the prior one in its stamped dir"
assert_eq "$(cat "$XH/home/state/archive/$XV/status")" "2026 started" "6: ...the latest status beside the latest meta"
assert_eq "$(cat "$XH"/home/state/archive/"$XV"/*/status)" "1 old" "6: ...the prior status beside the prior meta"
x6r0() { x6r; rm "$H/home/state/$XV.status"; }
xdo x6r0
xrun "$XV"
[ ! -e "$XH/home/state/archive/$XV/status" ] || fail "6: a latest with no status leaves none at the fixed slot"
assert_eq "$(cat "$XH"/home/state/archive/"$XV"/*/status)" "1 old" "6: ...the prior status moved with its meta"
x6l() {
  xseed; xrepo r
  local wt; wt="$(xtree get --repo "$H/r" --id "$XV")"
  printf 'kind=verify-codereview\nbackend=herdr\ncaller=t1\nleases=%s/gone::%s:%s/nolease\nlease_ids=a:b:%s:c\n' "$H" "$wt" "$H" "${1:-0011223344556677}" >"$H/home/state/$XV.meta"
  mkdir -p "$H/nolease"
}
xdo x6l
xrun "$XV"
assert_contains "$(xerr)" "WARN: skipping vanished verifier lease @H/gone: directory no longer exists" "6: a vanished lease"
assert_contains "$(xerr)" "WARN: could not return verifier worktree @H/nolease (it may have been re-leased); inspect @H/home/state/archive/$XV/meta" "6: a lease with its id the pool refuses"
xdo x6l ffffffffffffffff
xrun "$XV"
assert_contains "$(xerr)" "WARN: could not return verifier worktree @H/r/.crew/worktrees/1-r (it may have been re-leased)" "6: a re-leased slot is refused by id"
x6n() { xseed; mkdir -p "$H/nolease"; printf 'kind=verify-codereview\nbackend=herdr\nworktree=%s/nolease\n' "$H" >"$H/home/state/$XV.meta"; }
xdo x6n
xrun "$XV"
assert_contains "$(xerr)" "WARN: could not return verifier worktree @H/nolease; inspect @H/home/state/archive/$XV/meta" "6: a pre-leases verifier with no id"
x6o() { xseed; mkdir -p "$H/owt"; printf 'kind=verify-codereview\nbackend=orca\nleases=%s/owt\n' "$H" >"$H/home/state/$XV.meta"; printf 'term1 tab1\n' >"$H/home/state/.pane-$XV"; }
xdo x6o
xrun "$XV"
[ ! -e "$XH/owt" ] || fail "6: an orca verifier's lease is removed by its own backend"
assert_contains "$(cat "$XH/fo/log")" "orca worktree rm --worktree path:$XH/owt --force --json" "6: ...through the orca CLI"

# 7. the task's verifiers: one linked by caller=, a legacy one by family=
#    (no caller), a co-tenant naming another caller (kept), the verifier's
#    lock dir; an incomplete QA verifier behind a refused gate (no evidence
#    written) and past it (preserved, then archived); the swept verifiers'
#    stamps reaped and status archived.
x7() {
  xseed; xrepo r; xlease r t; xtab t 1
  printf 'kind=verify-codereview\nbackend=herdr\ncaller=t\n' >"$H/home/state/t-verify-codereview.meta"
  printf 'kind=verify-codereview\nbackend=herdr\nfamily=t\n' >"$H/home/state/t-old-verify.meta"
  printf 'kind=verify-codereview\nbackend=herdr\ncaller=other\nfamily=t\n' >"$H/home/state/co-verify.meta"
  : >"$H/home/state/.change-t-verify-codereview"
  printf 'swept\n' >"$H/home/state/t-verify-codereview.status"
  mkdir -p "$H/home/state/.verify-t-codereview.lock.d"
}
xdo x7
xrun t
assert_eq "$XRC:$(xout)" "0:teardown t complete" "7: a task with verifiers lands"
assert_eq "$(ls "$XH/home/state/archive" | tr '\n' ' ')" "t t-old-verify t-verify-codereview " "7: the caller's and the legacy verifier are swept"
[ -e "$XH/home/state/co-verify.meta" ] && [ ! -e "$XH/home/state/.change-t-verify-codereview" ] || fail "7: the co-tenant stays, the swept verifier's stamps go"
[ ! -e "$XH/home/state/.verify-t-codereview.lock.d" ] || fail "7: ...and its lock dir"
[ ! -e "$XH/home/state/t-verify-codereview.status" ] || fail "7: no swept verifier status is left in state/"
assert_eq "$(cat "$XH/home/state/archive/t-verify-codereview/status")" "swept" "7: ...it is archived beside its meta"
x7q() {
  xseed; xrepo r; xlease r t; xtab t 1
  git -C "$H/$XS" checkout -q -b crew/t; xcommit "$XS" w.txt
  printf 'kind=verify-qa\nbackend=herdr\ncaller=t\nfamily=t\n' >"$H/home/state/t-verify-qa.meta"
}
xdo x7q
xrun t
assert_eq "$XRC" 1 "7: an unlanded task refuses"
[ ! -e "$XH/home/data/t/verification" ] || fail "7: a refused gate writes no evidence"
xdo git -C @H/r merge -q --ff-only crew/t
xrun t
assert_eq "$(ls "$XH/home/data/t/verification")" "t-verify-qa-incomplete-1767225600" "7: past the gate the incomplete QA is preserved"

# 8. the pane-agent sweep in a leased tree the pool refuses to reset (so what
#    it keeps stays visible): the qa agent's pane; qa runs - ours (its
#    watch.pane, and a LIVE serve process group killed), another task's
#    (untouched), no one's (each record warned) - the `current` symlink
#    skipped; a ship run by branch; a pane the reap left open; unreadable
#    and empty pane files; serve.pid dead, empty, unreadable, `abc`; an
#    unreadable run.meta (WARNed, that run left, the sweep goes on). No
#    row ever writes -1 or 0 to a serve.pid.
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
xdo x8
xserve="$(cat "$XH/lease/.crew/qa/q-ours/serve.pid")"
xrun t
xnorm "$TMP/xn.err" "$XH" "$(cat "$TMP/xn.pid")" | LC_ALL=C sed -E -e "s/qa serve pid $xdead /qa serve pid DEAD /" >"$TMP/xn.err2"
! kill -0 "$xserve" 2>/dev/null || { kill "$xserve" 2>/dev/null; fail "8: the live serve group was not ended"; }
assert_eq "$XRC:$(xout)" "0:teardown t complete" "8: the sweep never stops the run"
assert_eq "$(xerr)" "WARN: qa serve pid DEAD already gone (@H/lease/.crew/qa/q-dead/serve.pid)
WARN: not reaping pNB - run @H/lease/.crew/qa/q-none-b is attributed to no task (@H/lease/.crew/qa/q-none-b/watch.pane)
WARN: not reaping pR - run @H/lease/.crew/qa/q-none is attributed to no task (@H/lease/.crew/qa/q-none/review.pane)
WARN: not reaping pN - run @H/lease/.crew/qa/q-none is attributed to no task (@H/lease/.crew/qa/q-none/watch.pane)
WARN: not reaping 777 - run @H/lease/.crew/qa/q-none is attributed to no task (@H/lease/.crew/qa/q-none/serve.pid)
WARN: pane pSTUCK (@H/lease/.crew/ship/s-ours/watch.pane) did not close - it is orphaned in the pane-agent workspace; retire it by hand: ac-pane-agent.sh reap-pane --pane pSTUCK
WARN: could not return worktree @H/lease; check the pool with ac-tree.sh list" "8: a dead serve pid, each unattributed record by pane and path, a pane the reap left open"
for xf in qa/agent-t.pane qa/q-ours/watch.pane qa/q-ours/serve.pid qa/q-dead/watch.pane qa/q-dead/serve.pid ship/s-ours/review.pane ship/s-ours/watch.pane; do
  [ ! -e "$XH/lease/.crew/$xf" ] || fail "8: $xf is reaped"
done
[ -e "$XH/lease/.crew/qa/q-none/watch.pane" ] && [ -e "$XH/lease/.crew/qa/q-none/review.pane" ] && [ -e "$XH/lease/.crew/qa/q-none/serve.pid" ] || fail "8: an unattributed run's records are kept"
[ -e "$XH/lease/.crew/qa/q-other/watch.pane" ] && [ -e "$XH/lease/.crew/qa/q-other/serve.pid" ] || fail "8: another task's run is untouched"
# The reap is gated on the binary of the backend reap-pane itself resolves -
# ac_backend, reading the AC_BACKEND teardown pins to the task's backend=. A
# herdr task with no herdr keeps the record; an orca task with no herdr
# closes it; an orca task with herdr but no orca warns and keeps it.
x8o() {
  xseed; xrepo r; mkdir -p "$H/lease/.crew/qa"; printf 'term7\n' >"$H/lease/.crew/qa/agent-t.pane"; : >"$H/fo/terminals/term7.buf"
  git init -q "$H/lease"; printf '/.crew/\n' >>"$H/lease/.git/info/exclude"
  printf 'kind=ship\nbackend=%s\nproject_dir=%s/r\nworktree=%s/lease\nleases=%s/lease\n' "${1:-orca}" "$H" "$H" "$H" >"$H/home/state/t.meta"
}
xdo x8o herdr
XPATH="$(xwithout herdr)"
xrun t
XPATH=""
assert_eq "$XRC" 0 "8: a pane that cannot be reaped never stops the run"
assert_contains "$(xerr)" "WARN: could not reap pane term7 (@H/lease/.crew/qa/agent-t.pane): herdr or ac-pane-agent.sh unavailable" "8: a herdr task's pane is not reaped without herdr"
[ -e "$XH/lease/.crew/qa/agent-t.pane" ] && [ -e "$XH/fo/terminals/term7.buf" ] || fail "8: ...its record kept, its terminal open"
xdo x8o
XPATH="$(xwithout herdr)"
xrun t
XPATH=""
assert_eq "$XRC" 0 "8: an orca task without herdr lands"
case "$(xerr)" in *"could not reap pane"*) fail "8: an orca task's pane is reaped without herdr" ;; esac
[ ! -e "$XH/lease/.crew/qa/agent-t.pane" ] && [ ! -e "$XH/fo/terminals/term7.buf" ] || fail "8: ...the record gone, the terminal closed"
xdo x8o
XPATH="$(xwithout orca)"
xrun t
XPATH=""
assert_eq "$XRC" 0 "8: an orca task without orca lands"
assert_contains "$(xerr)" "WARN: could not reap pane term7 (@H/lease/.crew/qa/agent-t.pane): orca or ac-pane-agent.sh unavailable" "8: an orca task with no orca is warned"
[ -e "$XH/lease/.crew/qa/agent-t.pane" ] || fail "8: ...and keeps the record"
x8u() {
  x8; kill "$(cat "$H/lease/.crew/qa/q-ours/serve.pid")" 2>/dev/null || true
  printf 'abc\n' >"$H/lease/.crew/qa/q-ours/serve.pid"; : >"$H/lease/.crew/qa/q-dead/serve.pid"
  printf 'pU\n' >"$H/lease/.crew/qa/q-ours/watch.pane"
}
if [ "$XROOTED" = 0 ]; then
  xdo x8u
  xdo chmod 000 @H/lease/.crew/qa/q-ours/watch.pane @H/lease/.crew/qa/q-dead/watch.pane
  xdo chmod 000 @H/lease/.crew/qa/q-dead/serve.pid
  xrun t
  xdo chmod 644 @H/lease/.crew/qa/q-ours/watch.pane @H/lease/.crew/qa/q-dead/watch.pane @H/lease/.crew/qa/q-dead/serve.pid
  assert_eq "$XRC:$(xout)" "0:teardown t complete" "8: unreadable records never stop the run"
  assert_contains "$(xerr)" "WARN: could not read @H/lease/.crew/qa/q-ours/watch.pane: the pane could not be identified, it may be orphaned" "8: an unreadable pane file is kept"
  assert_contains "$(xerr)" "WARN: not signalling qa serve pid 'abc' (@H/lease/.crew/qa/q-ours/serve.pid): not a process id" "8: a serve.pid that is no pid"
  assert_contains "$(xerr)" "WARN: could not read @H/lease/.crew/qa/q-dead/serve.pid: a qa serve process may still be running and could not be identified" "8: an unreadable serve.pid"
  [ -e "$XH/lease/.crew/qa/q-ours/watch.pane" ] && [ -e "$XH/lease/.crew/qa/q-ours/serve.pid" ] && [ -e "$XH/lease/.crew/qa/q-dead/serve.pid" ] || fail "8: ...each record it could not read or trust is kept"
  x8w() { x8u; chmod 000 "$H/lease/.crew/qa/q-none/run.meta"; }
  xdo x8w
  xrun t
  xdo chmod 644 @H/lease/.crew/qa/q-none/run.meta
  assert_eq "$XRC:$(xout)" "0:teardown t complete" "8: an unreadable run.meta leaves that run and completes"
  assert_contains "$(xerr)" "WARN: could not read @H/lease/.crew/qa/q-none/run.meta: run @H/lease/.crew/qa/q-none was not swept - its panes and qa serve process, if any, may survive" "8: ...naming the run it left"
  [ ! -e "$XH/lease/.crew/qa/q-ours/watch.pane" ] || fail "8: ...the runs after it still swept"
  x8q() { x8u; chmod 000 "$H/lease/.crew/qa/q-ours/run.meta"; }
  xdo x8q
  xrun t
  xdo chmod 644 @H/lease/.crew/qa/q-ours/run.meta
  assert_eq "$XRC:$(xout)" "0:teardown t complete" "8: the task's own run left unread too"
  [ -e "$XH/lease/.crew/qa/q-ours/watch.pane" ] && [ -e "$XH/lease/.crew/qa/q-ours/serve.pid" ] || fail "8: ...its records kept"
  x8s() { x8u; chmod 000 "$H/lease/.crew/ship/s-ours/run.meta"; }
  xdo x8s
  xrun t
  xdo chmod 644 @H/lease/.crew/ship/s-ours/run.meta
  assert_eq "$XRC:$(xout)" "0:teardown t complete" "8: an unreadable ship run.meta leaves that ship run and completes"
  assert_contains "$(xerr)" "WARN: could not read @H/lease/.crew/ship/s-ours/run.meta: run @H/lease/.crew/ship/s-ours was not swept - its panes and qa serve process, if any, may survive" "8: ...naming it"
  [ -e "$XH/lease/.crew/ship/s-ours/review.pane" ] || fail "8: ...its panes kept"
fi

# 9. the pane kill: an owned tab closed; a stale label; a close that fails
#    on an owned tab (the WARN, the archived status line and the timeline,
#    with AC_HERDR_SESSION and with config/herdr-session); orca's terminal
#    closed and its emptied tab's family record retired; a kill that ends
#    the caller (meta and status archived, the lease left).
x9() { xseed; xrepo r; xlease r t; xtab t 1 "${1-crew:t}"; mkdir -p "$H/home/data/t"; }
xdo x9
xrun t
assert_eq "$XRC:$(xout):$(xerr)" "0:teardown t complete:" "9: an owned tab"
assert_eq "$(ls "$XH/fh/tabs")" "" "9: ...is closed"
xdo x9 crew:other
xrun t
assert_contains "$(xerr)" "WARN: not closing tab t1 for t: it is labelled 'crew:other', not crew:t - the handle is stale (close the tab by hand if it really is this task's)" "9: a stale label"
xdo x9
xdo touch @H/fh/.tab-close-fails
xrun t
assert_contains "$(xerr)" "WARN: tab t1 of t refused to close and workspace t1 could not be read - close the tab by hand
WARN: pane close FAILED for t - a live pane may survive this teardown (handle: p1 t1); close it by hand: herdr tab close t1" "9: a failed close on an owned tab"
assert_contains "$(cat "$XH/home/state/archive/t/status")" "2026-01-01T00:00:00Z warn: pane close failed - handle p1 t1; close by hand: herdr tab close t1" "9: ...on the archived record"
assert_contains "$(cat "$XH/home/data/t/timeline.log")" "warn: pane close failed" "9: ...and the timeline"
xdo x9
xdo touch @H/fh/.tab-close-fails
XENV=("AC_HERDR_SESSION=s9")
xrun t
XENV=()
assert_contains "$(xerr)" "close it by hand: herdr tab close t1 --session s9" "9: the session in the hand command"
xdo x9
xdo touch @H/fh/.tab-close-fails
xdo xput home/config/herdr-session 'cfg
'
xrun t
assert_contains "$(xerr)" "--session cfg" "9: config/herdr-session in the hand command"
x9o() {
  xseed; xrepo r; xlease r t
  sed -i '' 's/^backend=herdr$/backend=orca/' "$H/home/state/t.meta"
  : >"$H/fo/terminals/term5.buf"; printf 'tab5\n' >"$H/fo/terminals/term5.tab"
  printf 'term5 tab5\n' >"$H/home/state/.pane-t"; printf 'tab5\n' >"$H/home/state/.orca-fam-t"; printf 'tab9\n' >"$H/home/state/.orca-fam-x"
}
xdo x9o
xrun t
assert_eq "$(ls -A "$XH/home/state" | grep orca-fam)" ".orca-fam-x" "9: orca closed the terminal and retired its emptied tab's record"
xdo x9
xdo touch @H/fh/.kill-caller-on-tab-close
# The killed run's job report stays out of the suite output.
{ xrun t; } 2>/dev/null
assert_eq "$XRC:$(xout)" "137:" "9: a kill at the pane step ends the run by its signal"
[ -e "$XH/home/state/archive/t/meta" ] && [ -e "$XH/home/state/archive/t/status" ] || fail "9: ...with meta and status already archived"

# 10. the lease loop: a pre-leases meta (worktree= is the list, no id); a
#     vanished dir and an empty entry; a short id list (the first lease takes
#     the one id); companions - dirty, unlanded, covered by the task's own
#     branch, in another repo's epic tip; an orca primary beside a pool
#     companion (aligned and legacy id lists); an orca worktree git cannot
#     read (refused, its files kept); a symlink planted at each
#     <file>.tmp.<pid> (EXCLUSIVE TEMPS).
x10a() { xseed; xrepo r; xlease r t; sed -i '' -e '/^leases=/d' -e '/^lease_ids=/d' "$H/home/state/t.meta"; }
xdo x10a
xrun t
assert_eq "$XRC:$(xerr)" "0:" "10: a pre-leases meta returns worktree= with no id"
x10b() { x10a; printf 'leases=%s/gone::%s/%s\nlease_ids=a:b:0011223344556677\n' "$H" "$H" "$XS" >>"$H/home/state/t.meta"; }
xdo x10b
xrun t
assert_eq "$XRC:$(xerr)" "0:WARN: skipping vanished lease @H/gone: directory no longer exists" "10: a vanished lease warns, an empty entry is silent"
x10c() { xseed; xrepo r; xlease r t; xtree get --repo "$H/r" --id t >/dev/null; sed -i '' -e '/^leases=/d' -e '/^lease_ids=/d' "$H/home/state/t.meta"; printf 'leases=%s/%s:%s/r/.crew/worktrees/2-r\nlease_ids=0011223344556677\n' "$H" "$XS" "$H" >>"$H/home/state/t.meta"; }
xdo x10c
xrun t
assert_eq "$XRC" 0 "10: a short id list"
x10d() { x10c; xrepo r2; xtree get --repo "$H/r2" --id t >/dev/null; sed -i '' '/^leases=/s#$#:'"$H"'/r2/.crew/worktrees/1-r2#' "$H/home/state/t.meta"; }
x10dd() { x10d; printf 'x\n' >"$H/r2/.crew/worktrees/1-r2/u.txt"; }
xdo x10dd
xrefuse "lease @H/r2/.crew/worktrees/1-r2 holds uncommitted or unlanded work and would be returned with --force; land or move it, or --force to discard
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
x10dn() { x10d; printf 'gitdir: %s/nowhere\n' "$H" >"$H/r2/.crew/worktrees/1-r2/.git"; }
xdo x10dn
xrefuse "lease @H/r2/.crew/worktrees/1-r2 cannot be read by git, so its contents cannot be checked and it would be returned with --force; repair it, or --force to discard
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
x10du() { x10d; xcommit r2/.crew/worktrees/1-r2 c.txt; }
xdo x10du
xrefuse "lease @H/r2/.crew/worktrees/1-r2 holds uncommitted or unlanded work and would be returned with --force; land or move it, or --force to discard
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
x10dc() { x10c; git -C "$H/$XS" checkout -q -b crew/t; xcommit "$XS" w.txt; git -C "$H/r" merge -q --ff-only crew/t; git -C "$H/r/.crew/worktrees/2-r" checkout -q --detach crew/t; }
xdo x10dc
xrun t
assert_eq "$XRC" 0 "10: a companion the task's own branch covers lands"
x10de() {
  x10du; git -C "$H/r2" branch ep/e2 "$(git -C "$H/r2/.crew/worktrees/1-r2" rev-parse HEAD)"
  xput home/records/backlog.md '- [ ] t - x epic:e2
'; xput home/data/e2/branches 'r2 ep/e2
'
}
xdo x10de
xrun t
assert_eq "$XRC" 0 "10: a companion at its own repo's epic tip lands"
x10o() {
  xseed; xrepo r; mkdir -p "$H/fo/orca-wt"; git -C "$H/r" worktree add -q -b fakeuser/t "$H/fo/orca-wt/t" 2>/dev/null
  local wt; wt="$(xtree get --repo "$H/r" --id t)"
  printf 'kind=ship\nbackend=orca\nworktree_backend=orca\nproject_dir=%s/r\nworktree=%s/fo/orca-wt/t\nleases=%s/fo/orca-wt/t:%s\nlease_ids=%s\n' "$H" "$H" "$H" "$wt" "$1" >"$H/home/state/t.meta"
}
xdo x10o x:0011223344556677
xrun t
assert_eq "$XRC:$(xerr)" "0:" "10: an orca worktree beside a pool companion (aligned ids)"
[ ! -e "$XH/fo/orca-wt/t" ] || fail "10: ...the orca worktree removed"
xdo x10o 0011223344556677
xrun t
assert_eq "$XRC:$(xerr)" "0:" "10: ...a legacy id list keeps every id"
x10w() { x10o x:0011223344556677; printf 'precious\n' >"$H/fo/orca-wt/t/precious.txt"; printf 'gitdir: %s/nowhere\n' "$H" >"$H/fo/orca-wt/t/.git"; }
xdo x10w
xrun t
assert_eq "$XRC:$(xout)" "1:" "10: an orca worktree git cannot read is refused"
assert_contains "$(xerr)" "worktree @H/fo/orca-wt/t cannot be read by git, so its contents cannot be checked; repair it or --force to discard" "10: ...naming it"
[ -e "$XH/fo/orca-wt/t/precious.txt" ] || fail "10: ...and its files stay"
x10t() {
  x10a; printf '1\t%s/%s\tr\t2026\n2\tother\tr\t2026\n' "$H" "$XS" >"$H/home/state/port-slots.tsv"
  mkdir -p "$H/ev"; printf 'kind=verify-qa\nbackend=herdr\ncaller=t\nevidence=%s/ev\n' "$H" >"$H/home/state/t-verify-qa.meta"
  printf 'victim bytes\n' >"$H/victim1"; printf 'victim bytes\n' >"$H/victim2"
}
xdo x10t
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
xplant "$BIN" "$XH" "$TMP/xpn"
assert_eq "$(xnorm "$TMP/xpn" "$XH" "$(cat "$TMP/xpn.pid")")" "teardown t complete" "10: the planted row's stdout"
assert_eq "$(xnorm "$TMP/xpn.err" "$XH" "$(cat "$TMP/xpn.pid")")" "" "10: the planted row's stderr"
for xi in 1 2; do
  assert_eq "$(cat "$XH/victim$xi")" "victim bytes" "10: no write goes through planted temp $xi"
done
[ -f "$XH/home/state/port-slots.tsv" ] && [ ! -L "$XH/home/state/port-slots.tsv" ] && [ -f "$XH/ev/incomplete-run.md" ] && [ ! -L "$XH/ev/incomplete-run.md" ] || fail "10: the records stay regular files"
assert_eq "$(cat "$XH/home/state/port-slots.tsv")" "2	other	r	2026" "10: ...holding the released registry"

# 11. the branch drop: git's refusal with advice.forceDeleteBranch=false; a
#     branch a worktree holds (the reclaim names the worktree first); the
#     epic branch only on origin (-D); an empty project_dir from a cwd that
#     is a repo (refused, and forced looks for the branch nowhere).
x11a() { x2c; git -C "$H/r" config advice.forceDeleteBranch false; }
xdo x11a
xrun t
case "$XRC:$(xerr)" in "0:WARN: kept crew/t in @H/r: "*" - reclaim: git branch -D crew/t") ;; *) fail "11: git's own text, its advice off, is one WARN with the reclaim: $(xerr)" ;; esac
x11h() { x2b; git -C "$H/$XS" checkout -q --detach; git -C "$H/r" worktree add -q "$H/held" crew/t; }
xdo x11h
xrun t
assert_contains "$(xerr)" "- reclaim: free it from that worktree, then git branch -D crew/t" "11: a branch a worktree holds"
x11e() {
  x2; xorigin r; x2br; git -C "$H/r" push -q origin crew/t:ep/e1 2>/dev/null; git -C "$H/r" fetch -q origin
  xput home/records/backlog.md '- [ ] t - story epic:e1
'; xput home/data/e1/branches 'r ep/e1
'
}
xdo x11e
xrun t
assert_eq "$XRC:$(xerr):$(git -C "$XH/r" branch --list crew/t)" "0::" "11: the epic branch on origin alone drops it with -D"
x11w() {
  xseed; xrepo cwdrepo; git -C "$H/cwdrepo" branch crew/t
  printf 'kind=ship\nbackend=herdr\nproject_dir=\n' >"$H/home/state/t.meta"
}
xdo x11w
XCWD=cwdrepo
xrefuse "the meta of t records no project_dir, so its landed work has no repository to be proven in
ERROR: refusing teardown of t (unlanded work); land it or pass --force to discard" t
XCWD=cwd
assert_eq "$(git -C "$XH/cwdrepo" branch --list crew/t)" "  crew/t" "11: ...the caller's branch untouched"
xdo x11w
XCWD=cwdrepo
xrun t --force
XCWD=cwd
assert_eq "$XRC:$(xout):$(git -C "$XH/cwdrepo" branch --list crew/t)" "0:teardown t complete (forced):  crew/t" "11: forced, crew/t is looked for nowhere"
assert_eq "$(xerr)" "WARN: no project_dir recorded for t - crew/t was not looked for; drop it by hand in the repository that holds it" "11: ...and it says so"
# A RELATIVE project_dir (`.`) from a caller whose cwd is gone: no relative
# path is resolved at all - the shim's own cwd is then its bin's root, so it
# runs from a DECOY root holding a merged crew/t that a regression would drop.
xdecoy="$TMP/xdecoy"
rm -rf "$xdecoy"; mkdir -p "$xdecoy"; cp -R "$ROOT/bin" "$ROOT/src" "$ROOT/dashboard" "$xdecoy/"
git init -q -b main "$xdecoy"; git -C "$xdecoy" commit -q --allow-empty -m decoy; git -C "$xdecoy" branch crew/t
x11g() { xseed; printf 'kind=ship\nbackend=herdr\nproject_dir=.\n' >"$H/home/state/t.meta"; }
xdo x11g
XGONE=1; XNBIN="$xdecoy/bin"
xrun t
XGONE=0; XNBIN="$BIN"
# The shim's own bash complains of the cwd it cannot name before teardown runs.
x11cwd() { grep -v -E '^(shell-init|chdir): error retrieving current directory' "$1" | sort -u; }
assert_eq "$XRC:$(xout):$(x11cwd "$TMP/xn.err2")" "0:teardown t complete:" "11: from a nameless cwd nothing relative is resolved and nothing is said"
assert_eq "$(git -C "$xdecoy" branch --list crew/t)" "  crew/t" "11: the decoy root's merged crew/t survives"

# 12. the roomchief demote: a member by the suffix grammar, by fleet_scope; a
#     verifier and a prefix family never members; DEMOTED posted; a post
#     refused; the advisory with a queued family, with none, with ac-ready
#     failing; the qa-infra sweep in each distinct project the family's
#     archived members recorded - fam-spec by its id, zz and zy by
#     fleet_scope, sharing one - byte order, a gone one skipped; a verifier,
#     a chief and a prefix family's member recorded none.
x12() { xseed; xrepo r; printf 'kind=roomchief\nbackend=herdr\nworktree=%s/r\nproject_dir=%s/r\n' "$H" "$H" >"$H/home/state/fam-chief.meta"; xtab fam-chief 3; }
x12g() { x12; mkdir -p "$H/home/data/fam/spec"; printf 'kind=scout\n' >"$H/home/state/fam-spec.meta"; }
xdo x12g
xrefuse "family fam still has crew in flight: fam-spec
ERROR: refusing teardown of fam-chief (unlanded work); land it or pass --force to discard" fam-chief
x12s() { x12; printf 'kind=crewmate\nfleet_scope=fam\n' >"$H/home/state/zz.meta"; printf 'kind=verify-qa\nfleet_scope=fam\n' >"$H/home/state/fam-verify-qa.meta"; printf 'kind=crewmate\n' >"$H/home/state/fam2-x.meta"; }
xdo x12s
xrefuse "family fam still has crew in flight: zz
ERROR: refusing teardown of fam-chief (unlanded work); land it or pass --force to discard" fam-chief
x12v() { x12; printf 'kind=verify-qa\nfleet_scope=fam\n' >"$H/home/state/fam-verify-qa.meta"; printf 'kind=crewmate\n' >"$H/home/state/fam2-x.meta"; }
xdo x12v
xrun fam-chief
assert_eq "$XRC:$(xout)" "0:teardown fam-chief complete" "12: a verifier and a prefix family are no members"
assert_contains "$(cat "$XH/home/data/fam/room.md")" "crewchief> DEMOTED: roomchief closed" "12: DEMOTED posted"
x12q() { x12; xput home/records/backlog.md '# Backlog

## Queued
- [ ] nextup - ordinary queued work (repo: r)
'; }
xdo x12q
xrun fam-chief --force
assert_eq "$(xout)" "teardown fam-chief complete (forced)
a chief slot is free - next queued family: nextup (promote with bin/ac-spawn.sh --roomchief nextup)" "12: the advisory names the next queued family"
assert_contains "$(cat "$XH/home/data/fam/room.md")" "DEMOTED: roomchief closed (forced)" "12: a forced demote says so"
if [ "$XROOTED" = 0 ]; then
  xdo x12q
  xdo chmod 000 @H/home/records/backlog.md
  xrun fam-chief
  xdo chmod 644 @H/home/records/backlog.md
  assert_eq "$XRC:$(xout)" "0:teardown fam-chief complete" "12: a failing ac-ready advises nothing"
fi
x12b() { xseed; printf 'kind=roomchief\nbackend=herdr\n' >"$H/home/state/dem bad-chief.meta"; }
xdo x12b
xrun "dem bad-chief"
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
xdo x12w
xrun fam-chief
assert_eq "$XRC:$(xerr)" "0:" "12: both sweeps complete, silent"
assert_eq "$(cat "$XH/stub/docker.log")" "compose -p crew-qa-r-fam-chief down -v --remove-orphans
compose -p crew-qa-r-fam-qa down -v --remove-orphans
compose -p crew-qa-r2-fam-chief down -v --remove-orphans
compose -p crew-qa-r2-fam-qa down -v --remove-orphans" "12: the sweep runs in each project the family's members recorded"
xdo x12w
xdo touch @H/stub/docker.fail-fam-qa
xrun fam-chief
assert_eq "$XRC:$(xout)" "0:teardown fam-chief complete" "12: a failed sweep never stops the run"
assert_eq "$(xerr)" "WARN: qa-infra sweep for fam-chief did not complete (status 7, bound 30s) - docker is unusable or hung; any task stack survives: (cd @H/r && ROOT/bin/ac-qa.sh infra down --task fam-chief && ROOT/bin/ac-qa.sh infra down --task fam-qa)
WARN: qa-infra sweep for fam-chief did not complete (status 7, bound 30s) - docker is unusable or hung; any task stack survives: (cd @H/r2 && ROOT/bin/ac-qa.sh infra down --task fam-chief && ROOT/bin/ac-qa.sh infra down --task fam-qa)" "12: each project's failure warned with its own hand command"
xdo x12
xrun fam-chief
assert_eq "$XRC:$(xout):$(xerr)" "0:teardown fam-chief complete:" "12: a memberless family lands"
[ ! -e "$XH/stub/docker.log" ] || fail "12: a family no member of which recorded a project sweeps nowhere"
XDOCK=0

# 13. a crewdeputy: a home with crew in flight refuses; an empty home lands;
#     its home is no repo, so nothing is swept for a deputy.
x13() { xseed; mkdir -p "$H/dhome/state"; printf 'kind=crewdeputy\nbackend=herdr\nworktree=%s/dhome\nproject_dir=%s/dhome\n' "$H" "$H" >"$H/home/state/dq.meta"; }
x13b() { x13; printf 'kind=ship\n' >"$H/dhome/state/x.meta"; }
xdo x13b
xrefuse "crewdeputy home still has crew in flight: @H/dhome/state/*.meta
ERROR: refusing teardown of dq (unlanded work); land it or pass --force to discard" dq
xdo x13
xrun dq
assert_eq "$XRC:$(xout):$(xerr)" "0:teardown dq complete:" "13: an empty deputy home lands"
xdo x13
XDOCK=1
xrun dq
XDOCK=0
assert_eq "$XRC:$(xout):$(xerr)" "0:teardown dq complete:" "13: a deputy sweeps nothing"
[ ! -e "$XH/stub/docker.log" ] || fail "13: ...and calls no docker"

# 14. the qa-infra sweep: docker absent (skipped); both downs; a member in
#     flight (the family stack kept, on stdout); a family stack that is the
#     id; each down failing; a hung docker under AC_TEARDOWN_QA_TIMEOUT=1
#     (124 and the hint - the bound ends the docker grandchild with its
#     group); bounds 0, abc, 010; URG at the step (the evidence, the run
#     completes) and TERM (the evidence, 143, no completion); an id that is
#     shell text (named as text, never run). Each chief's family has a
#     member archived with project_dir r, the one project swept in.
x14m() { xput "home/state/archive/q-a/meta" "kind=crewmate
fleet_scope=$1
project_dir=@H/r
"; }
x14() { xseed; xrepo r; printf 'kind=roomchief\nbackend=herdr\nproject_dir=%s/r\n' "$H" >"$H/home/state/q-chief.meta"; x14m q; }
xdo x14
xrun q-chief
assert_eq "$XRC:$(xout):$(xerr)" "0:teardown q-chief complete:" "14: no docker"
[ ! -e "$XH/stub/docker.log" ] || fail "14: no docker, no sweep"
XDOCK=1
xdo x14
xrun q-chief
assert_eq "$(cat "$XH/stub/docker.log")" "compose -p crew-qa-r-q-chief down -v --remove-orphans
compose -p crew-qa-r-q-qa down -v --remove-orphans" "14: both downs"
x14t() { xseed; xrepo r; printf 'kind=scout\nbackend=herdr\nproject_dir=%s/r\n' "$H" >"$H/home/state/q-spec.meta"; printf 'kind=crewmate\nfleet_scope=q\n' >"$H/home/state/q-member.meta"; mkdir -p "$H/home/data/q/spec"; }
xdo x14t
xrun q-spec --force
assert_eq "$(xout)" "qa-infra: family stack q-qa kept - q-member is still in flight and its qa run may hold it
teardown q-spec complete (forced)" "14: a member in flight keeps the family stack"
assert_eq "$(cat "$XH/stub/docker.log")" "compose -p crew-qa-r-q-spec down -v --remove-orphans" "14: ...and only the task's own stack goes down"
x14i() { xseed; xrepo r; mkdir -p "$H/home/data/q/qa"; printf 'kind=crewmate\nbackend=herdr\nproject_dir=%s/r\n' "$H" >"$H/home/state/q-qa.meta"; }
xdo x14i
xrun q-qa --force
assert_eq "$(cat "$XH/stub/docker.log")" "compose -p crew-qa-r-q-qa down -v --remove-orphans" "14: a family stack that is the id goes down once"
xdo x14
xdo touch @H/stub/docker.fail-q-chief
xrun q-chief
assert_contains "$(xerr)" "WARN: qa-infra sweep for q-chief did not complete (status 7, bound 30s) - docker is unusable or hung; any task stack survives: (cd @H/r && ROOT/bin/ac-qa.sh infra down --task q-chief && ROOT/bin/ac-qa.sh infra down --task q-qa)" "14: the task's own down failing"
xdo x14
xdo touch @H/stub/docker.fail-q-qa
xrun q-chief
assert_contains "$(xerr)" "(status 7, bound 30s)" "14: the family's down failing"
xdo x14
xdo touch @H/stub/docker.hang
XENV=("AC_TEARDOWN_QA_TIMEOUT=1")
xrun q-chief
XENV=()
assert_contains "$(xerr)" "did not complete (status 124, bound 1s)" "14: a hung docker is bounded"
assert_contains "$(xout)" "teardown q-chief complete" "14: ...and the run completes"
xndock="$(cat "$XH/stub/docker.pid")"
! kill -0 "$xndock" 2>/dev/null || { kill "$xndock" 2>/dev/null; fail "14: the bound ends the docker grandchild with its group"; }
for xb in 0 abc 010; do
  xdo x14
  XENV=("AC_TEARDOWN_QA_TIMEOUT=$xb")
  xrun q-chief
  XENV=()
  assert_eq "$XRC:$(xout)" "0:teardown q-chief complete" "14: a bound of '$xb' completes the run"
  case "$xb" in
    0) assert_eq "$(xerr)" "WARN: qa-infra sweep for q-chief did not complete (status 124, bound 0s) - docker is unusable or hung; any task stack survives: (cd @H/r && ROOT/bin/ac-qa.sh infra down --task q-chief && ROOT/bin/ac-qa.sh infra down --task q-qa)" "14: a bound of 0 is spent at once" ;;
    abc) assert_eq "$(xerr)" "" "14: a bound that is no digits is thirty seconds" ;;
    010) assert_eq "$(xerr)" "" "14: a bound of 010 is ten seconds" ;;
  esac
done
xdo x14
xdo xput stub/docker.signal 'URG'
xrun q-chief
assert_eq "$XRC:$(xerr)" "0:WARN: teardown q-chief: caught SIGURG during the qa-infra sweep" "14: URG names itself and the run goes on"
assert_contains "$(xout)" "teardown q-chief complete" "14: ...to completion"
xdo x14
xdo xput stub/docker.signal 'TERM'
{ xrun q-chief; } 2>/dev/null
assert_eq "$XRC:$(xout):$(xerr)" "143::WARN: teardown q-chief: caught SIGTERM during the qa-infra sweep" "14: TERM names itself and ends the run"
# TERM ends the run but not the sweep's child, which goes on to the family's
# down; the next row reseeds the side root that child still writes to.
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [ "$(grep -c . "$XH/stub/docker.log" 2>/dev/null)" -lt 2 ] || break
  /bin/sleep 0.25
done
x14j() { xseed; xrepo r; printf 'kind=roomchief\nbackend=herdr\nproject_dir=%s/r\n' "$H" >"$H/home/state/inj\$(echo PWNED-BY-TRAP >&2)-chief.meta"; x14m 'inj$(echo PWNED-BY-TRAP >&2)'; printf 'URG\n' >"$H/stub/docker.signal"; }
xdo x14j
xrun 'inj$(echo PWNED-BY-TRAP >&2)-chief'
assert_eq "$XRC" 0 "14: an id that is shell text completes"
assert_contains "$(xerr)" 'WARN: teardown inj$(echo PWNED-BY-TRAP >&2)-chief: caught SIGURG during the qa-infra sweep' "14: the id is named as text"
! grep -qx 'PWNED-BY-TRAP' "$TMP/xn.err2" || fail "14: the id is never run"
XDOCK=0

# 15. the archive epochs: a reused id (the prior meta and status moved to a
#     stamped dir, the latest at the fixed slot), a prior with no status, and
#     a status the append cannot write (exit 1, nothing moved).
x15() { x2; mkdir -p "$H/home/state/archive/t"; printf 'kind=ship\nround=1\n' >"$H/home/state/archive/t/meta"; printf 'old status\n' >"$H/home/state/archive/t/status"; }
xdo x15
xrun t
assert_eq "$(cat "$XH/home/state/archive/t/1767225600."*/status)" "old status" "15: the prior epoch moved whole"
x15n() { x15; rm "$H/home/state/archive/t/status"; }
xdo x15n
xrun t
assert_eq "$XRC:$(ls "$XH/home/state/archive/t/1767225600."*/):$(sed -n 's/^round=//p' "$XH/home/state/archive/t/1767225600."*/meta)" "0:meta:1" "15: a prior with no status moves its meta alone"
if [ "$XROOTED" = 0 ]; then
  x15u() { x2; printf 'x\n' >"$H/home/state/t.status"; chmod 444 "$H/home/state/t.status"; }
  xdo x15u
  xrun t
  assert_eq "$XRC:$(xout):$(xerr)" "1::" "15: a status the append cannot write ends the run"
  [ -e "$XH/home/state/t.meta" ] && [ ! -e "$XH/home/state/archive/t/meta" ] || fail "15: ...with nothing moved"
fi

# 16. bun off PATH: the shim refuses before anything durable.
xdo x2
XPATH="$(xwithout bun)"
xrefuse "ERROR: required tool not found: bun" t
XPATH=""

pass
