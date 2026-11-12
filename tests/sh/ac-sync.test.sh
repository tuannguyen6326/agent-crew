#!/usr/bin/env bash
# ac-sync.test.sh - clone freshness sweep: ff-advance, fresh, STUCK on
# dirty/off-branch/diverged (tree never touched; untracked files never
# count as dirty), gone-upstream branch pruning vs pool-lease protection,
# fetch failure/timeout isolation, and the no-arg sweep continuing past
# failed projects.

# FAIL-CLOSED SOURCING (this suite pushes): run from anywhere but tests/sh/, the
# source below no-ops, errexit is never armed, every helper var stays EMPTY -
# and the push fixtures below then hit the REAL repo (incident 2026-07-20).
# Abort instead of running unsourced.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

new_project() {
  # new_project <name> - bare "remote" at $TMP/<name>.git (fed from a source
  # workdir at $TMP/src-<name>), clone registered at projects/<name>.
  local name="$1"
  local src="$TMP/src-$name" bare="$TMP/$name.git"
  git init -q -b main "$src"
  git -C "$src" config user.email t@t
  git -C "$src" config user.name t
  printf 'base\n' >"$src/f.txt"
  git -C "$src" add -A
  git -C "$src" commit -qm base
  git clone -q --bare "$src" "$bare"
  git clone -q "$bare" "$AC_HOME/projects/$name"
  git -C "$AC_HOME/projects/$name" config user.email t@t
  git -C "$AC_HOME/projects/$name" config user.name t
}

advance_remote() {
  # advance_remote <name> - one new commit on the remote's main.
  local name="$1"
  local src="$TMP/src-$name" bare="$TMP/$name.git"
  printf 'more\n' >>"$src/f.txt"
  git -C "$src" add -A
  git -C "$src" commit -qm advance
  git -C "$src" push -q "$bare" main:main
}

# Fresh when current; ff-advance when strictly behind.
new_project p1
out="$("$BIN/ac-sync.sh" p1 2>&1)"
assert_contains "$out" "fresh p1" "current clone is fresh"
advance_remote p1
out="$("$BIN/ac-sync.sh" p1 2>&1)"
assert_contains "$out" "synced p1: main" "ff reported with branch"
assert_eq "$(git -C "$AC_HOME/projects/p1" rev-parse HEAD)" \
  "$(git -C "$TMP/p1.git" rev-parse main)" "clone HEAD advanced to remote"

# Dirty clone behind origin: STUCK, quantified, tree untouched, exit 1.
new_project p2
advance_remote p2
printf 'wip\n' >>"$AC_HOME/projects/p2/f.txt"
before="$(git -C "$AC_HOME/projects/p2" rev-parse HEAD)"
rc=0
out="$("$BIN/ac-sync.sh" p2 2>&1)" || rc=$?
assert_eq "$rc" 1 "dirty STUCK exits 1"
assert_contains "$out" "STUCK p2: dirty tree (1 commits behind)" "dirty line"
assert_eq "$(git -C "$AC_HOME/projects/p2" rev-parse HEAD)" "$before" "HEAD untouched"
assert_contains "$(cat "$AC_HOME/projects/p2/f.txt")" "wip" "dirty edit untouched"

# Diverged clone: STUCK with ahead/behind counts, never merged.
new_project p3
advance_remote p3
git -C "$AC_HOME/projects/p3" commit -q --allow-empty -m local-only
before="$(git -C "$AC_HOME/projects/p3" rev-parse HEAD)"
rc=0
out="$("$BIN/ac-sync.sh" p3 2>&1)" || rc=$?
assert_eq "$rc" 1 "diverged STUCK exits 1"
assert_contains "$out" "STUCK p3: diverged, ahead 1 (1 commits behind)" "diverged line"
assert_eq "$(git -C "$AC_HOME/projects/p3" rev-parse HEAD)" "$before" "no merge attempted"

# Checked out off the default branch: STUCK, default branch not advanced.
new_project p6
git -C "$AC_HOME/projects/p6" checkout -qb side
advance_remote p6
rc=0
out="$("$BIN/ac-sync.sh" p6 2>&1)" || rc=$?
assert_eq "$rc" 1 "off-branch STUCK exits 1"
assert_contains "$out" "STUCK p6: checked out side, not main (1 commits behind)" "off-branch line"

# A local branch whose upstream is gone is pruned.
new_project p4
proj="$AC_HOME/projects/p4"
git -C "$proj" checkout -qb feature
git -C "$proj" push -qu origin feature
git -C "$proj" checkout -q main
git -C "$TMP/p4.git" branch -qD feature
out="$("$BIN/ac-sync.sh" p4 2>&1)"
assert_contains "$out" "pruned p4: branch feature (upstream gone)" "prune line"
git -C "$proj" show-ref --verify --quiet refs/heads/feature \
  && fail "gone-upstream branch should be deleted"

# ...but KEPT while a pool lease (slot meta) still needs crew/<task>.
new_project p5
proj="$AC_HOME/projects/p5"
git -C "$proj" checkout -qb crew/t9
git -C "$proj" push -qu origin crew/t9
git -C "$proj" checkout -q main
git -C "$TMP/p5.git" branch -qD crew/t9
mkdir -p "$proj/.crew/slots"
printf 'created_at=now\nleased=1\ntask=t9\nholder=crew:t9\nowner_pid=\n' \
  >"$proj/.crew/slots/1.meta"
out="$("$BIN/ac-sync.sh" p5 2>&1)"
assert_contains "$out" "kept p5: branch crew/t9" "lease keeps the branch"
git -C "$proj" show-ref --verify --quiet refs/heads/crew/t9 \
  || fail "leased crew branch must survive pruning"

# Unreachable origin: FAILED with a note, exit 1, tree untouched.
new_project p7
git -C "$AC_HOME/projects/p7" remote set-url origin "$TMP/nope.git"
rc=0
out="$("$BIN/ac-sync.sh" p7 2>&1)" || rc=$?
assert_eq "$rc" 1 "failed fetch exits 1"
assert_contains "$out" "FAILED p7: fetch origin failed" "failure note"

# No-arg sweep covers every project and continues past failures.
rc=0
out="$("$BIN/ac-sync.sh" 2>&1)" || rc=$?
assert_eq "$rc" 1 "sweep exits 1 while any project is STUCK/FAILED"
assert_contains "$out" "fresh p1" "sweep reaches p1"
assert_contains "$out" "STUCK p2" "sweep reaches p2"
assert_contains "$out" "STUCK p3" "sweep reaches p3"
assert_contains "$out" "kept p5: branch crew/t9" "sweep re-checks lease protection"
assert_contains "$out" "FAILED p7" "sweep records the failed project"

# The leak checks below find a sleep in the HOST process table, so each run
# sleeps a duration only it uses: a second checkout running this file at the
# same time would otherwise be seen, and reaped, as this run's leak.
hang_secs="30.$$"
stub_secs="5.$$"

# A hung remote is killed at the deadline; the sweep is not hung with it.
new_project p8
git -C "$AC_HOME/projects/p8" config protocol.ext.allow always
git -C "$AC_HOME/projects/p8" remote set-url origin "ext::sleep $hang_secs"
rc=0
out="$(AC_SYNC_TIMEOUT=1 "$BIN/ac-sync.sh" p8 2>&1)" || rc=$?
assert_eq "$rc" 1 "timed-out fetch exits 1"
assert_contains "$out" "FAILED p8: fetch timed out after 1s" "timeout note"
# ...and that note is ALL a sweep reader gets. Job control announces the
# signalled job on the real stderr with an internal pid and the whole git
# command line - neither of which a reader can act on, and the command line
# carries exactly the internal detail the public-text posture keeps out of
# user-facing output.
case "$out" in
  *Terminated*|*lowSpeedLimit*|*"fetch origin --prune"*)
    fail "the timeout path leaked the shell's job-control notice into the sweep output: $out" ;;
esac

# ...and the CHILD that hung remote forked is dead too, not orphaned under
# ppid=1: `ext::sleep 30` makes git fork a `git remote-ext` helper which forks
# the sleep itself, so killing the fetch pid alone leaves both alive. Found by
# command line (git's own helper naming is stable and specific enough on a dev
# host) rather than by process group: under the suite runner, each test file
# backgrounds under its own `set -m`, so this file's own group IS this file -
# a group kill here would be suicide; run standalone, there is no such
# isolation and the group is whatever invoked this file - a group kill here
# would take that down instead.
hung_child_pid() {
  # No `exit` inside the awk: under this suite's `pipefail`, an awk that quits
  # early closes the pipe while `ps` is still writing, `ps` dies of SIGPIPE,
  # and that non-zero status - not awk's - is what pipefail reports (measured:
  # exit 141 aborted the whole suite under `set -e`).
  # `!/awk/` excludes this very awk's OWN process: its argv is the pattern
  # source text, which contains the same needle it searches for, so without
  # the exclusion it can match itself and report a bogus, already-dead pid -
  # a false GREEN that never observed the real helper at all (measured).
  ps -axww -o pid=,command= | awk -v needle="remote-ext origin sleep $hang_secs" 'index($0, needle) && !/awk/ && !found {print $1; found=1}'
}
reap_hung_child() {
  # reap_hung_child - kill a leaked helper AND its own sleep child by exact
  # pid: a test proving a leak is fixed must not itself leak, on any exit
  # path including a failing assertion.
  local helper leaf
  helper="$(hung_child_pid)"
  [ -n "$helper" ] || return 0
  leaf="$(ps -axww -o pid=,ppid= | awk -v p="$helper" '$2==p && !found {print $1; found=1}')"
  [ -z "$leaf" ] || kill -9 "$leaf" 2>/dev/null || true
  kill -9 "$helper" 2>/dev/null || true
}
reap_hung_child   # baseline clean: a stray helper from any earlier invocation
                  # must not be mistaken for the one this case forks below

rc=0
AC_SYNC_TIMEOUT=1 "$BIN/ac-sync.sh" p8 >"$TMP/p8-child.out" 2>&1 &
sync_job=$!
helper=""
for _ in $(seq 1 50); do
  helper="$(hung_child_pid)"
  [ -n "$helper" ] && break
  sleep 0.1
done
wait "$sync_job" || rc=$?
if [ -z "$helper" ]; then
  fail "p8's hung remote never forked its child - nothing was measured"
fi
if kill -0 "$helper" 2>/dev/null; then
  reap_hung_child
  fail "fetch_bounded's timeout must kill the whole process group: the forked remote-ext helper (and the sleep under it) outlived the bounded fetch"
fi
reap_hung_child

# Untracked files never count as dirty: the ff-advance proceeds past them.
new_project p9
proj="$AC_HOME/projects/p9"
advance_remote p9
mkdir -p "$proj/.crew"
printf 'lease\n' >"$proj/.crew/state"
printf 'cache\n' >"$proj/untracked.txt"
out="$("$BIN/ac-sync.sh" p9 2>&1)"
assert_contains "$out" "synced p9: main" "untracked files do not block ff"
assert_file "$proj/untracked.txt" "untracked file survives the ff"
assert_eq "$(git -C "$proj" rev-parse HEAD)" \
  "$(git -C "$TMP/p9.git" rev-parse main)" "clone advanced past untracked files"

# ...a genuinely MODIFIED tracked file is still STUCK, untracked bystanders
# or not.
advance_remote p9
printf 'wip\n' >>"$proj/f.txt"
rc=0
out="$("$BIN/ac-sync.sh" p9 2>&1)" || rc=$?
assert_eq "$rc" 1 "modified tracked file still exits 1"
assert_contains "$out" "STUCK p9: dirty tree (1 commits behind)" "modified tracked file still STUCK"

# ...and an untracked file the ff would overwrite surfaces naturally: git
# refuses, STUCK (fast-forward failed), the file untouched.
new_project p10
proj="$AC_HOME/projects/p10"
printf 'remote\n' >"$TMP/src-p10/clash.txt"
git -C "$TMP/src-p10" add -A
git -C "$TMP/src-p10" commit -qm clash
git -C "$TMP/src-p10" push -q "$TMP/p10.git" main:main
printf 'local\n' >"$proj/clash.txt"
rc=0
out="$("$BIN/ac-sync.sh" p10 2>&1)" || rc=$?
assert_eq "$rc" 1 "overwrite-refused ff exits 1"
assert_contains "$out" "STUCK p10: fast-forward failed" "git refusal surfaces as STUCK"
assert_eq "$(cat "$proj/clash.txt")" "local" "clashing untracked file untouched"


# --- the report, line by line -------------------------------------------------
# One side root $H: a home at $H/home, bare remotes under $H/remotes, clones
# under the home's projects/, every commit stamped with one fixed date. Each
# run starts at $H under LC_ALL=C; `HOME` in an argument or an env value is
# $H, and stdout and stderr are read with $H spelled HOME.
H="$TMP/side"
gitc() { GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git "$@"; }
seed_side() { mkdir -p "$H/home/projects" "$H/home/config" "$H/remotes"; }
mkrepo() {  # mkrepo <dir> - one fixed-date commit on main, a tracked sub/ so a subdirectory exists
  mkdir -p "$1/sub"
  git init -q -b main "$1"
  git -C "$1" config user.email test@test; git -C "$1" config user.name test
  printf 'base\n' >"$1/f.txt"; printf 's\n' >"$1/sub/s.txt"
  git -C "$1" add -A; gitc -C "$1" commit -qm base
}
project() {  # project <name> - bare remote <side>/remotes/<name>.git fed from <side>/src-<name>, clone at projects/<name>
  mkrepo "$H/src-$1"
  git clone -q --bare "$H/src-$1" "$H/remotes/$1.git"
  git clone -q "$H/remotes/$1.git" "$H/home/projects/$1"
  git -C "$H/home/projects/$1" config user.email test@test; git -C "$H/home/projects/$1" config user.name test
}
advance() {  # advance <name> [<msg>] - one more fixed-date commit on the remote's main
  printf '%s\n' "${2:-more}" >>"$H/src-$1/f.txt"; git -C "$H/src-$1" add -A; gitc -C "$H/src-$1" commit -qm "${2:-more}"
  git -C "$H/src-$1" push -q "$H/remotes/$1.git" main:main
}
local_commit() {  # local_commit <name> <msg> - one fixed-date commit in the clone
  printf '%s\n' "$2" >"$H/home/projects/$1/$2.txt"; git -C "$H/home/projects/$1" add -A; gitc -C "$H/home/projects/$1" commit -qm "$2"
}
gone() {  # gone <name> <branch> - a local branch pushed with an upstream, then deleted on the remote
  local p="$H/home/projects/$1"
  git -C "$p" checkout -qb "$2"; git -C "$p" push -qu origin "$2"; git -C "$p" checkout -q main
  git -C "$H/remotes/$1.git" branch -qD "$2"
}
meta() { mkdir -p "$H/home/projects/$1/.crew/slots"; printf "$3" >"$H/home/projects/$1/.crew/slots/$2.meta"; }
HOMELESS=0
SYNC_ENV=()
run() {  # run <args...> - sets rc, stdout in $TMP/n.out, stderr in $TMP/n.err2
  local x v
  local a=() e=(LC_ALL=C)
  [ "$HOMELESS" = 1 ] || e+=(AC_HOME="$H/home")
  for x in ${SYNC_ENV[@]+"${SYNC_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$H}"); done
  for x in "$@"; do a+=("${x//HOME/$H}"); done
  rc=0
  (cd "$H" && env -u AC_HOME "${e[@]}" "$BIN/ac-sync.sh" ${a[@]+"${a[@]}"}) <"${SYNC_STDIN:-/dev/stdin}" >"$TMP/n.raw" 2>"$TMP/n.err" || rc=$?
  norm "$TMP/n.raw" >"$TMP/n.out"; norm "$TMP/n.err" >"$TMP/n.err2"
}
norm() { LC_ALL=C sed -e "s#$H#HOME#g" "$1"; }
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
remote_sha() { git -C "$H/remotes/$1.git" rev-parse "${2:-main}"; }
short() { git -C "$H/remotes/$1.git" rev-parse --short "${2:-main}"; }
clone_head() { git -C "$H/home/projects/$1" rev-parse HEAD; }
seed_side

# 1. usage: a leading dash (-h, --help, a lone -) or two arguments - exit 2,
#    nothing on stderr, the src/sync.ts spec header on stdout
usage_row() {
  run "$@"
  assert_eq "$rc" "2" "usage '$*' exits 2"
  assert_eq "$(cat "$TMP/n.err")" "" "usage '$*': the header goes to stdout only"
  assert_eq "$(cat "$TMP/n.raw")" "$(awk '{if(!/^\/\//)exit; print}' "$ROOT/src/sync.ts" | sed 's/^\/\/ \{0,1\}//')" "usage '$*' prints the src/sync.ts spec header"
}
usage_row -h
usage_row --help
usage_row -
usage_row a b
assert_contains "$(cat "$TMP/n.raw")" "ac-sync.sh [<project>]" "the spec header carries the usage"

# 2. no argument, nothing under projects/: the WARN, exit 0; projects/ absent
#    is minted on the way
run
assert_eq "$rc" "0" "an empty projects/ exits 0"
assert_eq "$(shim_err)" "WARN: no projects under HOME/home/projects" "an empty projects/"
assert_eq "$(shim_out)" "" "nothing on stdout"
rmproj() { rm -rf "$H/home/projects"; }
rmproj
run
assert_eq "$(shim_err)" "WARN: no projects under HOME/home/projects" "an absent projects/"
[ -d "$H/home/projects" ] || fail "projects/ must be minted"

# 3. mixed children in byte order: a no-origin repo, a fresh clone, a plain
#    directory (WARN, the sweep goes on)
project p1
mixed() {
  mkrepo "$H/home/projects/noorig"
  mkdir -p "$H/home/projects/plain"
}
mixed
run
assert_eq "$rc" "0" "a skipped directory does not fail the sweep"
assert_eq "$(shim_out)" "fresh noorig (no origin)
fresh p1" "byte order"
assert_eq "$(shim_err)" "WARN: skip plain: not a git repository" "a plain directory is skipped with a WARN"
unmix() { rm -rf "$H/home/projects/noorig" "$H/home/projects/plain"; }
unmix

# 4. a name: fresh, then synced after the remote advanced
run p1
assert_eq "$(shim_out)" "fresh p1" "a current clone is fresh"
old="$(short p1)"
advance p1
run p1
assert_eq "$(shim_out)" "synced p1: main $old..$(short p1)" "the ff line names the branch and both shas"
assert_eq "$(clone_head p1)" "$(remote_sha p1)" "HEAD reached the remote's main"

# 5. STUCK, each with its text and exit 1: a staged file, a detached HEAD
modify() { printf 'wip\n' >>"$H/home/projects/$1/f.txt"; }
project stg; advance stg
stage() { printf 'new\n' >"$H/home/projects/$1/new.txt"; git -C "$H/home/projects/$1" add new.txt; }
stage stg
run stg
assert_eq "$rc" "1" "a staged file exits 1"
assert_eq "$(shim_out)" "STUCK stg: dirty tree (1 commits behind)" "a staged file is dirty"
project det
detach() { git -C "$H/home/projects/$1" checkout -q --detach; }
detach det; advance det
run det
assert_eq "$(shim_out)" "STUCK det: checked out detached HEAD, not main (1 commits behind)" "a detached HEAD"

# 6. ahead only is fresh
project ahead; local_commit ahead mine
run ahead
assert_eq "$rc" "0" "an ahead-only clone exits 0"
assert_eq "$(shim_out)" "fresh ahead" "an ahead-only clone is fresh"

# 7. gone branches, in for-each-ref order: pruned unless a worktree has it
#    checked out or a slot meta leases it - `task=` empty, `leased=0` last
#    (the last line wins) and `leased= 1` (the value is ` 1`) are no lease;
#    a refused `branch -D` keeps the branch
project pr
prune_fixture() {
  gone pr crew/a; gone pr crew/b; gone pr crew/c; gone pr crew/e; gone pr wt
  meta pr 1 'leased=1\ntask=\n'
  meta pr 2 'leased=1\ntask=b\nleased=0\n'
  meta pr 3 'leased= 1\ntask=c\n'
  meta pr 5 'leased=1\ntask=e\n'
  git -C "$H/home/projects/pr" worktree add -q "$H/pr-wt" wt
}
prune_fixture
run pr
assert_eq "$(shim_out)" "fresh pr
pruned pr: branch crew/a (upstream gone)
pruned pr: branch crew/b (upstream gone)
pruned pr: branch crew/c (upstream gone)
kept pr: branch crew/e (upstream gone, still in use)
kept pr: branch wt (upstream gone, still in use)" "the prune pass over every lease form"
assert_eq "$(shim_err)" "" "a readable pool says nothing on stderr"
git -C "$H/home/projects/pr" show-ref --verify --quiet refs/heads/crew/e || fail "the leased branch must survive"
git -C "$H/home/projects/pr" show-ref --verify --quiet refs/heads/crew/a && fail "a pruned branch must be gone"
project rf
refused() { gone rf x; chmod 555 "$H/home/projects/rf/.git/refs/heads"; }
refused
run rf
unrefuse() { chmod 755 "$H/home/projects/rf/.git/refs/heads"; }
unrefuse
assert_eq "$(shim_out)" "fresh rf
kept rf: branch x (upstream gone, delete refused)" "a refused delete keeps the branch"
#    ...and the prune pass runs after a STUCK line too
project ps; advance ps; modify ps
stuckgone() { gone ps crew/z; }
stuckgone
run ps
assert_eq "$(shim_out)" "STUCK ps: dirty tree (1 commits behind)
pruned ps: branch crew/z (upstream gone)" "the prune pass follows a STUCK line"
assert_eq "$rc" "1" "a STUCK project exits 1 after its prune pass"

# ...an unreadable slot meta WARNs and its lease is unknowable - fail closed:
# the gone branch it might have leased is KEPT, never pruned - row
# bug-shaped-rows.md:151, src/sync.ts's neededBranches W2.
project pu
gone pu crew/u1
meta pu 1 'created_at=now\nleased=1\ntask=u1\nholder=crew:u1\nowner_pid=\n'
chmod 000 "$H/home/projects/pu/.crew/slots/1.meta"
run pu
chmod 644 "$H/home/projects/pu/.crew/slots/1.meta"
assert_contains "$(shim_err)" "cannot read meta file" "the WARN still fires for the unreadable meta"
assert_eq "$(shim_out)" "fresh pu
kept pu: branch crew/u1 (upstream gone, lease unreadable)" "an unreadable lease protects its branch rather than guessing it is safe to prune"
git -C "$H/home/projects/pu" show-ref --verify --quiet refs/heads/crew/u1 \
  || fail "an unreadable-lease branch must survive pruning"

# 8. AC_SYNC_TIMEOUT=0 against a local bare: the deadline fires on the first
#    poll - FAILED, exit 1, and no prune pass although a branch is gone
project t0
t0gone() { gone t0 crew/g; }
t0gone
SYNC_ENV=(AC_SYNC_TIMEOUT=0)
run t0
assert_eq "$rc" "1" "a timed-out fetch exits 1"
assert_eq "$(shim_out)" "FAILED t0: fetch timed out after 0s" "an immediate deadline; no prune line"
git -C "$H/home/projects/t0" show-ref --verify --quiet refs/heads/crew/g || fail "a timed-out project must not be pruned"
SYNC_ENV=()

# 9. a stub git whose fetch sleeps (bounded: the stub ends by itself, so a
#    broken watchdog fails the row instead of hanging the suite) - the group
#    kill takes the stub and its sleep
mkdir -p "$TMP/stub"
cat >"$TMP/stub/git" <<STUB
#!/usr/bin/env bash
case " \$* " in
  *" fetch "*) printf '%s\n' "\$*" >>"\${GIT_STUB_LOG:?}"; sleep "\${GIT_STUB_SLEEP:-0}"; exit 0 ;;
esac
exec "$(command -v git)" "\$@"
STUB
chmod +x "$TMP/stub/git"
STUB_PATH="$TMP/stub:$PATH"
stub_log() { norm "$H/stub.log"; }
project ts
SYNC_ENV=(PATH="$STUB_PATH" GIT_STUB_LOG=HOME/stub.log GIT_STUB_SLEEP="$stub_secs" AC_SYNC_TIMEOUT=1)
run ts
assert_eq "$(shim_out)" "FAILED ts: fetch timed out after 1s" "stub git: the timeout line"
[ -z "$(ps -axww -o command= | grep -F "sleep $stub_secs" | grep -v grep)" ] || fail "the stub's sleep outlived the bounded fetch"
assert_eq "$(stub_log)" "-C HOME/home/projects/ts -c http.lowSpeedLimit=1 -c http.lowSpeedTime=1 fetch origin --prune --quiet" "the fetch command line"
rm -f "$H/stub.log"

# 10. the deadline knob: AC_SYNC_TIMEOUT=abc reads 60 (the stub's log shows
#     the value git was given); an EMPTY variable falls to config/sync-timeout
#     (` 45 \r\n` reads 45); `=01` is printed verbatim and reads 1
knob() { printf "$1" >"$H/home/config/sync-timeout"; }
SYNC_ENV=(PATH="$STUB_PATH" GIT_STUB_LOG=HOME/stub.log AC_SYNC_TIMEOUT=abc)
run ts
assert_eq "$(shim_out)" "fresh ts" "a non-numeric knob: the stubbed fetch returns at once"
assert_contains "$(stub_log)" "http.lowSpeedTime=60 " "AC_SYNC_TIMEOUT=abc reads 60"
rm -f "$H/stub.log"
knob ' 45 \r\n'
SYNC_ENV=(PATH="$STUB_PATH" GIT_STUB_LOG=HOME/stub.log AC_SYNC_TIMEOUT=)
run ts
assert_contains "$(stub_log)" "http.lowSpeedTime=45 " "an empty AC_SYNC_TIMEOUT falls to the trimmed config value"
rm -f "$H/stub.log"
SYNC_ENV=(PATH="$STUB_PATH" GIT_STUB_LOG=HOME/stub.log GIT_STUB_SLEEP="$stub_secs" AC_SYNC_TIMEOUT=01)
run ts
assert_eq "$(shim_out)" "FAILED ts: fetch timed out after 01s" "=01 is printed verbatim and read as 1"
assert_contains "$(stub_log)" "http.lowSpeedTime=01 " "=01 reaches git verbatim"
rm -f "$H/stub.log"
knob '0\n'
SYNC_ENV=(PATH="$STUB_PATH" GIT_STUB_LOG=HOME/stub.log GIT_STUB_SLEEP="$stub_secs")
run ts
assert_eq "$(shim_out)" "FAILED ts: fetch timed out after 0s" "config/sync-timeout alone decides when the variable is unset (the stub is killed before it can log)"
rm -f "$H/stub.log" "$H/home/config/sync-timeout"
SYNC_ENV=()

# 11. an origin whose path does not exist: git's own 128
project unr
unreach() { git -C "$H/home/projects/$1" remote set-url origin "$H/remotes/nope.git"; }
unreach unr
run unr
assert_eq "$rc" "1" "an unreachable origin exits 1"
assert_eq "$(shim_out)" "FAILED unr: fetch origin failed (exit 128)" "an unreachable origin"

# 12. a directory argument: the repo root, a subdirectory with a trailing
#     slash, a path relative to the cwd, a linked worktree (the MAIN repo's
#     name), a plain directory
run HOME/home/projects/p1
assert_eq "$(shim_out)" "fresh p1" "the repo root"
run HOME/home/projects/p1/sub/
assert_eq "$(shim_out)" "fresh p1" "a subdirectory with a trailing slash"
run home/projects/p1
assert_eq "$(shim_out)" "fresh p1" "a path relative to the cwd"
run HOME/pr-wt
assert_eq "$(shim_out)" "fresh pr
kept pr: branch crew/e (upstream gone, still in use)
kept pr: branch wt (upstream gone, still in use)" "a linked worktree resolves to its main repo"
mkplain() { mkdir -p "$H/plain2"; }
mkplain
run HOME/plain2
assert_eq "$rc" "1" "no such project exits 1"
assert_eq "$(shim_err)" "ERROR: no such project: HOME/plain2" "a plain directory"
run HOME/missing
assert_eq "$(shim_err)" "ERROR: no such project: HOME/missing" "a missing path"
run nope
assert_eq "$(shim_err)" "ERROR: no such project: nope" "a missing name"

# 13. homeless: no argument refuses; a directory argument never needs the home
HOMELESS=1
run
assert_eq "$(shim_err)" "ERROR: $(grep -o 'AC_HOME is not set - .*one' "$ROOT/bin/ac-lib.sh" | head -n1)" "homeless sweep: one refusal"
assert_eq "$rc" "1" "a homeless sweep exits 1"
run HOME/home/projects/p1
assert_eq "$(shim_out)" "fresh p1" "homeless directory argument runs"
HOMELESS=0

# 14. the sweep's order is BYTE order: a
#     projects/ of no-origin repos named across cases, punctuation and a
#     multibyte name
wipe() { rm -rf "$H/home/projects"; mkdir -p "$H/home/projects"; }
wipe
globset() { local n; for n in Zeta ac-x ac_x AC a10 a2 ac.x "$(printf '\303\251')"; do git init -q "$H/home/projects/$n"; done; }
globset
run
assert_eq "$(shim_out)" "fresh AC (no origin)
fresh Zeta (no origin)
fresh a10 (no origin)
fresh a2 (no origin)
fresh ac-x (no origin)
fresh ac.x (no origin)
fresh ac_x (no origin)
fresh $(printf '\303\251') (no origin)" "projects in byte order"
assert_eq "$(shim_err)" "" "nothing on stderr"

# 15. a slot meta value is awk's C string: `leased=1<NUL>` and `task=t9<NUL>`
#     still protect crew/t9; `leased=1<NUL>x` too
seed15() { project p15; gone p15 crew/t9; gone p15 crew/t10; meta p15 s1 'task=t9\0\nleased=1\0\n'; meta p15 s2 'task=t10\0junk\nleased=1\0x\n'; }
seed15
run p15
assert_contains "$(shim_out)" "kept p15: branch crew/t9 (upstream gone, still in use)" "row 15: NUL-cut lease and task keep the branch"
assert_contains "$(shim_out)" "kept p15: branch crew/t10 (upstream gone, still in use)" "row 15: NUL-cut values beyond the NUL are gone"

# 16. config/sync-timeout this user cannot read: the knob reads "" and falls
#     back to 60, the project syncs and the NEXT one is visited
if [ "$(id -u)" != 0 ]; then
  project p16a; project p16b
  printf '7\n' >"$H/home/config/sync-timeout"; chmod 000 "$H/home/config/sync-timeout"
  SYNC_ENV=(PATH="$STUB_PATH" GIT_STUB_LOG=HOME/stub.log)
  run
  SYNC_ENV=()
  chmod 644 "$H/home/config/sync-timeout"
  assert_eq "$rc" "0" "row 16: the sweep ends 0"
  assert_contains "$(shim_out)" "fresh p16b" "row 16: the next project is still visited"
  assert_contains "$(stub_log)" "http.lowSpeedTime=60 " "row 16: an unreadable knob reads 60"
  rm -f "$H/home/config/sync-timeout" "$H/stub.log"
fi

# 17. every git inherits the caller's stdin: a PATH git whose fetch reads it
#     logs the caller's bytes
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/gitin"; printf '#!/bin/sh\ncase " $* " in *" fetch "*) cat >"$GITIN_LOG"; exit 0 ;; esac\nexec %s "$@"\n' "$REAL_GIT" >"$TMP/gitin/git"; chmod +x "$TMP/gitin/git"
project p17
printf 'fed to the fetch\n' >"$TMP/stdin17"
SYNC_ENV=("GITIN_LOG=HOME/gitin.log" "PATH=$TMP/gitin:$PATH"); SYNC_STDIN="$TMP/stdin17"
run p17
SYNC_ENV=(); unset SYNC_STDIN
assert_eq "$(cat "$H/gitin.log")" "fed to the fetch" "row 17: the caller's bytes reached the fetch"

# 18. the knob is not read under a non-empty AC_SYNC_TIMEOUT: an AC_HOME that
#     does not exist never matters to a directory argument
project p18
HOMELESS=1; SYNC_ENV=("AC_HOME=HOME/missing" "AC_SYNC_TIMEOUT=1")
run HOME/home/projects/p18
HOMELESS=0; SYNC_ENV=()
assert_eq "$(shim_out)" "fresh p18" "row 18: the override spares the knob read"

# 19. without the override the knob of an AC_HOME that cannot be entered reads
#     "" - 60 - and the sweep goes on
HOMELESS=1; SYNC_ENV=("AC_HOME=HOME/missing")
run HOME/home/projects/p18
HOMELESS=0; SYNC_ENV=()
assert_eq "$rc" "0" "row 19: the sweep ends 0"
assert_eq "$(shim_out)" "fresh p18" "row 19: the default answered"
assert_eq "$(shim_err)" "" "row 19: nothing on stderr"

pass
