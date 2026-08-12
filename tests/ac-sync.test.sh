#!/usr/bin/env bash
# ac-sync.test.sh - clone freshness sweep: ff-advance, fresh, STUCK on
# dirty/off-branch/diverged (tree never touched; untracked files never
# count as dirty), gone-upstream branch pruning vs pool-lease protection,
# fetch failure/timeout isolation, and the no-arg sweep continuing past
# failed projects.

# FAIL-CLOSED SOURCING (this suite pushes): run from anywhere but tests/, the
# source below no-ops, errexit is never armed, every helper var stays EMPTY -
# and the push fixtures below then hit the REAL repo (incident 2026-07-20).
# Abort instead of running unsourced.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

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

pass
