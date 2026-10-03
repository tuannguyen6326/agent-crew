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

# A hung remote is killed at the deadline; the sweep is not hung with it.
new_project p8
git -C "$AC_HOME/projects/p8" config protocol.ext.allow always
git -C "$AC_HOME/projects/p8" remote set-url origin "ext::sleep 30"
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
  ps -axww -o pid=,command= | awk '/remote-ext origin sleep 30/ && !/awk/ && !found {print $1; found=1}'
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


# --- differential: src/sync.ts against the frozen bash original ---------------
# DISPUTED: the implementation (tests/fixtures/ac-sync.sh under bash vs src/sync.ts through bin/ac-sync.sh)
# HELD-CONSTANT: two side roots seeded alike ($OH for the oracle, $NH for the shim) - a home at <side>/home, bare remotes under <side>/remotes, clones under the home's projects/, every commit stamped with one fixed date so the shas agree - argv and env (the side root spelled HOME), cwd (the side root), LC_ALL=C on both sides; exit status, stdout and stderr (the side root spelled HOME) compared whole, plus every ref, HEAD and the porcelain status of the clones a row touches.
obin="$(make_oracle_bin ac-sync)"
OH="$TMP/side-o"; NH="$TMP/side-n"
gitc() { GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git "$@"; }
both() {  # both <fn> <args...> - run a seeding step with H at each side root
  local h; for h in "$OH" "$NH"; do H="$h"; "$@"; done
}
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
run_side() {  # run_side <bin> <side root> <prefix> <args...> - HOME in an arg or an env value is that side's root; cwd is the root
  local bin="$1" h="$2" p="$3" x; shift 3
  local a=() e=(LC_ALL=C)
  [ "$HOMELESS" = 1 ] || e+=(AC_HOME="$h/home")
  for x in ${SYNC_ENV[@]+"${SYNC_ENV[@]}"}; do e+=("${x//HOME/$h}"); done
  for x in "$@"; do a+=("${x//HOME/$h}"); done
  (cd "$h" && env -u AC_HOME "${e[@]}" "$bin/ac-sync.sh" ${a[@]+"${a[@]}"}) >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
norm() { LC_ALL=C sed -e "s#$2#HOME#g" "$1"; }
same() {  # same <args...> - oracle on $OH and shim on $NH answer byte-identically
  local o_rc=0 n_rc=0
  run_side "$obin" "$OH" o "$@" || o_rc=$?
  run_side "$BIN" "$NH" n "$@" || n_rc=$?
  norm "$TMP/o.raw" "$OH" >"$TMP/o.out"; norm "$TMP/o.err" "$OH" >"$TMP/o.err2"
  norm "$TMP/n.raw" "$NH" >"$TMP/n.out"; norm "$TMP/n.err" "$NH" >"$TMP/n.err2"
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*'"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 6)"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 4)"
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
same_tree() {  # same_tree <path under the side root> [<refs pattern>] - refs with their upstream state, HEAD and the porcelain status agree
  local r="$1" refs="${2:-refs/}" q o n
  for q in "for-each-ref --format=%(refname):%(objectname):%(upstream:track) $refs" "rev-parse HEAD" "status --porcelain"; do
    o="$(git -C "$OH/$r" $q 2>/dev/null || printf none)"
    n="$(git -C "$NH/$r" $q 2>/dev/null || printf none)"
    assert_eq "$n" "$o" "differential tree $r: $q"
  done
}
same_project() { same_tree "home/projects/$1" ${2:+"$2"}; }
remote_sha() { git -C "$NH/remotes/$1.git" rev-parse "${2:-main}"; }
short() { git -C "$NH/remotes/$1.git" rev-parse --short "${2:-main}"; }
clone_head() { git -C "$NH/home/projects/$1" rev-parse HEAD; }
both seed_side

# 1. usage: a leading dash (-h, --help, a lone -) or two arguments - exit 2,
#    nothing on stderr, each implementation's OWN spec header on stdout: the
#    named divergence, since the shim's header is a pointer, so the port
#    prints src/sync.ts's where the original printed its bash header.
usage_row() {
  local o_rc=0 n_rc=0
  run_side "$obin" "$OH" o "$@" || o_rc=$?
  run_side "$BIN" "$NH" n "$@" || n_rc=$?
  assert_eq "$o_rc $n_rc" "2 2" "usage '$*': both exit 2"
  assert_eq "$(cat "$TMP/o.err" "$TMP/n.err")" "" "usage '$*': the header goes to stdout only"
  assert_eq "$(cat "$TMP/o.raw")" "$(awk 'NR>1{if(!/^#/)exit; print}' "$ROOT/tests/fixtures/ac-sync.sh" | sed 's/^# \{0,1\}//')" "usage '$*': the original prints its bash header"
  assert_eq "$(cat "$TMP/n.raw")" "$(awk '{if(!/^\/\//)exit; print}' "$ROOT/src/sync.ts" | sed 's/^\/\/ \{0,1\}//')" "usage '$*': the port prints the src/sync.ts spec header"
}
usage_row -h
usage_row --help
usage_row -
usage_row a b
assert_contains "$(cat "$TMP/n.raw")" "ac-sync.sh [<project>]" "the spec header carries the usage"

# 2. no argument, nothing under projects/: the WARN, exit 0; projects/ absent
#    is minted on the way (ac_projects_dir's mkdir -p)
same
assert_eq "$(shim_err)" "WARN: no projects under HOME/home/projects" "an empty projects/"
assert_eq "$(shim_out)" "" "nothing on stdout"
rmproj() { rm -rf "$H/home/projects"; }
both rmproj
same
assert_eq "$(shim_err)" "WARN: no projects under HOME/home/projects" "an absent projects/"
[ -d "$OH/home/projects" ] && [ -d "$NH/home/projects" ] || fail "projects/ must be minted on both sides"

# 3. mixed children in byte order: a symlink to a repo elsewhere (W1 - the
#    PHYSICAL basename is reported), a no-origin repo, a fresh clone, a plain
#    directory (WARN, the sweep goes on)
both project p1
mixed() {
  mkrepo "$H/elsewhere/srcname"; ln -s "$H/elsewhere/srcname" "$H/home/projects/link"
  mkrepo "$H/home/projects/noorig"
  mkdir -p "$H/home/projects/plain"
}
both mixed
same
assert_eq "$(shim_out)" "fresh srcname (no origin)
fresh noorig (no origin)
fresh p1" "byte order; the symlinked project reports its physical basename"
assert_eq "$(shim_err)" "WARN: skip plain: not a git repository" "a plain directory is skipped with a WARN"
unmix() { rm -rf "$H/home/projects/link" "$H/home/projects/noorig" "$H/home/projects/plain"; }
both unmix

# 4. a name: fresh, then synced after the remote advanced
same p1
assert_eq "$(shim_out)" "fresh p1" "a current clone is fresh"
same_project p1
old="$(short p1)"
both advance p1
same p1
assert_eq "$(shim_out)" "synced p1: main $old..$(short p1)" "the ff line names the branch and both shas"
assert_eq "$(clone_head p1)" "$(remote_sha p1)" "HEAD reached the remote's main"
same_project p1

# 5. STUCK, each with its text and exit 1, the tree untouched: a modified
#    tracked file, a staged file, off the default branch, a detached HEAD,
#    diverged; untracked files never count, and one the ff would overwrite is
#    git's refusal
both project dirty; both advance dirty
modify() { printf 'wip\n' >>"$H/home/projects/$1/f.txt"; }
both modify dirty
same dirty
assert_eq "$(shim_out)" "STUCK dirty: dirty tree (1 commits behind)" "a modified tracked file"
assert_eq "$(cat "$NH/home/projects/dirty/f.txt")" "base
wip" "the edit is untouched"
same_project dirty
both project stg; both advance stg
stage() { printf 'new\n' >"$H/home/projects/$1/new.txt"; git -C "$H/home/projects/$1" add new.txt; }
both stage stg
same stg
assert_eq "$(shim_out)" "STUCK stg: dirty tree (1 commits behind)" "a staged file is dirty"
same_project stg
both project side
onside() { git -C "$H/home/projects/$1" checkout -qb side; }
both onside side; both advance side
same side
assert_eq "$(shim_out)" "STUCK side: checked out side, not main (1 commits behind)" "off the default branch"
same_project side
both project det
detach() { git -C "$H/home/projects/$1" checkout -q --detach; }
both detach det; both advance det
same det
assert_eq "$(shim_out)" "STUCK det: checked out detached HEAD, not main (1 commits behind)" "a detached HEAD"
same_project det
both project div; both advance div; both local_commit div local
same div
assert_eq "$(shim_out)" "STUCK div: diverged, ahead 1 (1 commits behind)" "diverged"
same_project div
both project untr; both advance untr
untracked() { mkdir -p "$H/home/projects/$1/.crew"; printf 'lease\n' >"$H/home/projects/$1/.crew/state"; printf 'cache\n' >"$H/home/projects/$1/untracked.txt"; }
both untracked untr
same untr
assert_eq "$(shim_out)" "synced untr: main $(git -C "$NH/home/projects/untr" rev-parse --short HEAD~1)..$(short untr)" "untracked files do not block the ff"
assert_file "$NH/home/projects/untr/untracked.txt" "the untracked file survives"
same_project untr
both project clash
clash() {
  printf 'remote\n' >"$H/src-clash/clash.txt"; git -C "$H/src-clash" add -A; gitc -C "$H/src-clash" commit -qm clash
  git -C "$H/src-clash" push -q "$H/remotes/clash.git" main:main
  printf 'local\n' >"$H/home/projects/clash/clash.txt"
}
both clash
same clash
assert_eq "$(shim_out)" "STUCK clash: fast-forward failed (1 commits behind)" "git's refusal surfaces as STUCK"
assert_eq "$(cat "$NH/home/projects/clash/clash.txt")" "local" "the clashing file is untouched"
same_project clash

# 6. ahead only is fresh; behind as well is diverged
both project ahead; both local_commit ahead mine
same ahead
assert_eq "$(shim_out)" "fresh ahead" "an ahead-only clone is fresh"
same_project ahead
both advance ahead
same ahead
assert_eq "$(shim_out)" "STUCK ahead: diverged, ahead 1 (1 commits behind)" "ahead and behind is diverged"
same_project ahead

# 7. gone branches, in for-each-ref order: pruned unless a worktree has it
#    checked out or a slot meta leases it - `task=` empty, `leased=0` last
#    (the last line wins) and `leased= 1` (the value is ` 1`) are no lease;
#    an unreadable meta WARNs and its lease is ignored (W2 - fail-open, the
#    branch prunes); a refused `branch -D` keeps the branch
both project pr
prune_fixture() {
  gone pr crew/a; gone pr crew/b; gone pr crew/c; gone pr crew/d; gone pr crew/e; gone pr wt
  meta pr 1 'leased=1\ntask=\n'
  meta pr 2 'leased=1\ntask=b\nleased=0\n'
  meta pr 3 'leased= 1\ntask=c\n'
  meta pr 4 'leased=1\ntask=d\n'; chmod 000 "$H/home/projects/pr/.crew/slots/4.meta"
  meta pr 5 'leased=1\ntask=e\n'
  git -C "$H/home/projects/pr" worktree add -q "$H/pr-wt" wt
}
both prune_fixture
same pr
assert_eq "$(shim_out)" "fresh pr
pruned pr: branch crew/a (upstream gone)
pruned pr: branch crew/b (upstream gone)
pruned pr: branch crew/c (upstream gone)
pruned pr: branch crew/d (upstream gone)
kept pr: branch crew/e (upstream gone, still in use)
kept pr: branch wt (upstream gone, still in use)" "the prune pass over every lease form"
assert_eq "$(shim_err)" "WARN: cannot read meta file HOME/home/projects/pr/.crew/slots/4.meta" "the unreadable meta is warned once"
same_project pr
git -C "$NH/home/projects/pr" show-ref --verify --quiet refs/heads/crew/e || fail "the leased branch must survive"
git -C "$NH/home/projects/pr" show-ref --verify --quiet refs/heads/crew/d && fail "an unreadable lease must not keep its branch (W2)"
both project rf
refused() { gone rf x; chmod 555 "$H/home/projects/rf/.git/refs/heads"; }
both refused
same rf
unrefuse() { chmod 755 "$H/home/projects/rf/.git/refs/heads"; }
both unrefuse
assert_eq "$(shim_out)" "fresh rf
kept rf: branch x (upstream gone, delete refused)" "a refused delete keeps the branch"
same_project rf
#    ...and the prune pass runs after a STUCK line too
both project ps; both advance ps; both modify ps
stuckgone() { gone ps crew/z; }
both stuckgone
same ps
assert_eq "$(shim_out)" "STUCK ps: dirty tree (1 commits behind)
pruned ps: branch crew/z (upstream gone)" "the prune pass follows a STUCK line"
same_project ps

# 8. AC_SYNC_TIMEOUT=0 against a local bare: the deadline fires on the first
#    poll - FAILED, exit 1, and no prune pass although a branch is gone (the
#    remote refs are not compared: the kill races the fetch's prune of them)
both project t0
t0gone() { gone t0 crew/g; }
both t0gone
SYNC_ENV=(AC_SYNC_TIMEOUT=0)
same t0
assert_eq "$(shim_out)" "FAILED t0: fetch timed out after 0s" "an immediate deadline; no prune line"
same_project t0 refs/heads
SYNC_ENV=()

# 9. the hung remote: AC_SYNC_TIMEOUT=1 against `ext::sleep 30` - the timeout
#    line, nothing of the shell's job control on stderr, and the forked
#    remote-ext helper (with its sleep) dead on both sides
both project hung
hang() { git -C "$H/home/projects/$1" config protocol.ext.allow always; git -C "$H/home/projects/$1" remote set-url origin "ext::sleep 30"; }
both hang hung
reap_hung_child
SYNC_ENV=(AC_SYNC_TIMEOUT=1)
o_rc=0; run_side "$obin" "$OH" o hung || o_rc=$?
[ -z "$(hung_child_pid)" ] || { reap_hung_child; fail "the original's timeout left its remote-ext helper alive"; }
n_rc=0; run_side "$BIN" "$NH" n hung || n_rc=$?
[ -z "$(hung_child_pid)" ] || { reap_hung_child; fail "the port's timeout must kill the whole process group: the remote-ext helper outlived the bounded fetch"; }
SYNC_ENV=()
assert_eq "$o_rc $n_rc" "1 1" "hung remote: both exit 1"
assert_eq "$(cat "$TMP/o.raw")" "FAILED hung: fetch timed out after 1s" "hung remote: the original's line"
assert_eq "$(cat "$TMP/n.raw")" "$(cat "$TMP/o.raw")" "hung remote: the same line"
assert_eq "$(cat "$TMP/o.err" "$TMP/n.err")" "" "hung remote: nothing of the shell's job control reaches the reader"
#    ...and through a stub git whose fetch sleeps (bounded: the stub ends by
#    itself, so a broken watchdog fails the row instead of hanging the suite)
#    - the group kill takes the stub and its sleep
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
stub_log() { norm "$NH/stub.log" "$NH"; }
same_stub_log() { assert_eq "$(stub_log)" "$(norm "$OH/stub.log" "$OH")" "the stub git saw the same fetch command line"; }
both project ts
SYNC_ENV=(PATH="$STUB_PATH" GIT_STUB_LOG=HOME/stub.log GIT_STUB_SLEEP=5.37 AC_SYNC_TIMEOUT=1)
same ts
assert_eq "$(shim_out)" "FAILED ts: fetch timed out after 1s" "stub git: the timeout line"
[ -z "$(ps -axww -o command= | grep -F 'sleep 5.37' | grep -v grep)" ] || fail "the stub's sleep outlived the bounded fetch"
same_stub_log
assert_eq "$(stub_log)" "-C HOME/home/projects/ts -c http.lowSpeedLimit=1 -c http.lowSpeedTime=1 fetch origin --prune --quiet" "the fetch command line, the original's arguments"
rm -f "$OH/stub.log" "$NH/stub.log"

# 10. the deadline knob: AC_SYNC_TIMEOUT=abc reads 60 (the stub's log shows
#     the value git was given); an EMPTY variable falls to config/sync-timeout
#     (` 45 \r\n` reads 45); `=01` is printed verbatim and reads 1; a value
#     past 2^63 never fires (W3 - the real git's fetch of a local bare
#     completes and the project is fresh)
knob() { printf "$1" >"$H/home/config/sync-timeout"; }
SYNC_ENV=(PATH="$STUB_PATH" GIT_STUB_LOG=HOME/stub.log AC_SYNC_TIMEOUT=abc)
same ts
assert_eq "$(shim_out)" "fresh ts" "a non-numeric knob: the stubbed fetch returns at once"
same_stub_log
assert_contains "$(stub_log)" "http.lowSpeedTime=60 " "AC_SYNC_TIMEOUT=abc reads 60"
rm -f "$OH/stub.log" "$NH/stub.log"
both knob ' 45 \r\n'
SYNC_ENV=(PATH="$STUB_PATH" GIT_STUB_LOG=HOME/stub.log AC_SYNC_TIMEOUT=)
same ts
same_stub_log
assert_contains "$(stub_log)" "http.lowSpeedTime=45 " "an empty AC_SYNC_TIMEOUT falls to the trimmed config value"
rm -f "$OH/stub.log" "$NH/stub.log"
SYNC_ENV=(PATH="$STUB_PATH" GIT_STUB_LOG=HOME/stub.log GIT_STUB_SLEEP=5.37 AC_SYNC_TIMEOUT=01)
same ts
assert_eq "$(shim_out)" "FAILED ts: fetch timed out after 01s" "=01 is printed verbatim and read as 1"
same_stub_log
assert_contains "$(stub_log)" "http.lowSpeedTime=01 " "=01 reaches git verbatim"
rm -f "$OH/stub.log" "$NH/stub.log"
both knob '0\n'
SYNC_ENV=(PATH="$STUB_PATH" GIT_STUB_LOG=HOME/stub.log GIT_STUB_SLEEP=5.37)
same ts
assert_eq "$(shim_out)" "FAILED ts: fetch timed out after 0s" "config/sync-timeout alone decides when the variable is unset (the stub is killed before it can log)"
rm -f "$OH/stub.log" "$NH/stub.log" "$OH/home/config/sync-timeout" "$NH/home/config/sync-timeout"
both project w3; both advance w3
SYNC_ENV=(AC_SYNC_TIMEOUT=99999999999999999999)
same w3
assert_eq "$(shim_out)" "synced w3: main $(git -C "$NH/home/projects/w3" rev-parse --short HEAD~1)..$(short w3)" "a 2^63+ deadline never fires (W3): the fetch completes"
same_project w3
SYNC_ENV=()

# 11. an origin whose path does not exist: git's own 128
both project unr
unreach() { git -C "$H/home/projects/$1" remote set-url origin "$H/remotes/nope.git"; }
both unreach unr
same unr
assert_eq "$(shim_out)" "FAILED unr: fetch origin failed (exit 128)" "an unreachable origin"
same_project unr

# 12. a directory argument: the repo root, a subdirectory with a trailing
#     slash, a path relative to the cwd, a linked worktree (the MAIN repo's
#     name), a bare remote (its PARENT directory is taken for the root and has
#     no origin - kept, a wart of the original), a plain directory
same HOME/home/projects/p1
assert_eq "$(shim_out)" "fresh p1" "the repo root"
same HOME/home/projects/p1/sub/
assert_eq "$(shim_out)" "fresh p1" "a subdirectory with a trailing slash"
same home/projects/p1
assert_eq "$(shim_out)" "fresh p1" "a path relative to the cwd"
same HOME/pr-wt
assert_eq "$(shim_out)" "fresh pr
kept pr: branch crew/e (upstream gone, still in use)
kept pr: branch wt (upstream gone, still in use)" "a linked worktree resolves to its main repo"
same HOME/remotes/p1.git
assert_eq "$(shim_out)" "fresh remotes (no origin)" "a bare repo argument names its parent"
mkplain() { mkdir -p "$H/plain2"; }
both mkplain
same HOME/plain2
assert_eq "$(shim_err)" "ERROR: no such project: HOME/plain2" "a plain directory"
same HOME/missing
assert_eq "$(shim_err)" "ERROR: no such project: HOME/missing" "a missing path"
same nope
assert_eq "$(shim_err)" "ERROR: no such project: nope" "a missing name"

# 13. homeless: no argument refuses once; a name refuses TWICE (the die
#     inside `$(ac_projects_dir)` is swallowed by `[ -d ]`, kept); a directory
#     argument never needs the home
HOMELESS=1
same
assert_eq "$(shim_err)" "ERROR: $(grep -o 'AC_HOME is not set - .*one' "$ROOT/bin/ac-lib.sh" | head -n1)" "homeless sweep: one refusal"
same nope
assert_eq "$(shim_err)" "ERROR: $(grep -o 'AC_HOME is not set - .*one' "$ROOT/bin/ac-lib.sh" | head -n1)
ERROR: no such project: nope" "homeless name: two ERROR lines"
same HOME/home/projects/p1
assert_eq "$(shim_out)" "fresh p1" "homeless directory argument runs"
HOMELESS=0

# 14. the sweep's order is BYTE order (the oracle under LC_ALL=C): a
#     projects/ of no-origin repos named across cases, punctuation and a
#     multibyte name
wipe() { rm -rf "$H/home/projects"; mkdir -p "$H/home/projects"; }
both wipe
globset() { local n; for n in Zeta ac-x ac_x AC a10 a2 ac.x "$(printf '\303\251')"; do git init -q "$H/home/projects/$n"; done; }
both globset
same
assert_eq "$(shim_out)" "fresh AC (no origin)
fresh Zeta (no origin)
fresh a10 (no origin)
fresh a2 (no origin)
fresh ac-x (no origin)
fresh ac.x (no origin)
fresh ac_x (no origin)
fresh $(printf '\303\251') (no origin)" "projects in byte order"
assert_eq "$(shim_err)" "" "nothing on stderr"

pass
