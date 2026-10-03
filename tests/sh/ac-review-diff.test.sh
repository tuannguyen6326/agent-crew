#!/usr/bin/env bash
# ac-review-diff.test.sh - show a crewmate's change as a diff against the
# authoritative base, LOCAL-ONLY-AWARE.
#
# The base is merge-base(default-ref, crew/<id>). ac_default_ref is origin-wins,
# but a local-only fleet never pushes its default branch, so origin/<default>
# sits frozen behind the real LOCAL default and every already-landed commit
# renders as fresh diff (root cause in records/learnings.md; teardown's
# head_landed already fixed this class). ac-review-diff.sh now trusts the LOCAL
# default branch when origin is absent or strictly BEHIND it, and keeps
# origin-wins for push-mode where landings live on origin.
#
# Both directions are proven with throwaway git repos:
#   1. local-only / origin frozen behind local -> base against LOCAL default;
#      already-landed commits must NOT appear in the diff (this is the bug).
#   2. push-mode / origin fresh (ahead of a stale local) -> origin-wins;
#      landed work on origin must NOT appear, proving the origin path is intact.
# Pure git + meta - no backend needed.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# mk_meta <id> <worktree> - the minimal crewmate meta ac-review-diff.sh reads.
mk_meta() {
  local m="$AC_HOME/state/$1.meta"
  mkdir -p "$AC_HOME/state"
  printf 'project_dir=%s\n' "$2" >"$m"
  printf 'worktree=%s\n' "$2" >>"$m"
}

# git_id <repo> - stamp a throwaway identity so commits succeed hermetically.
git_id() { git -C "$1" config user.email test@test; git -C "$1" config user.name test; }

# commit <repo> <file> <msg> - add one file and commit; prints the new sha.
commit() {
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add -A
  git -C "$1" commit -qm "$3"
  git -C "$1" rev-parse HEAD
}

# ---- Case 1: local-only, origin frozen BEHIND local -> base against LOCAL ----
#      genesis is all origin/main knows; local main then lands two commits that
#      were never pushed, and crew/c1 branches from that fresh local tip. The
#      diff must show ONLY the crew commit - the two landed commits are already
#      in the base and must not resurface.
r1="$TMP/local-only"
git init -q -b main "$r1"; git_id "$r1"
genesis="$(commit "$r1" file.txt genesis)"
git -C "$r1" update-ref refs/remotes/origin/main "$genesis"   # origin frozen at genesis
commit "$r1" landed1.txt "landed one" >/dev/null              # local main advances,
commit "$r1" landed2.txt "landed two" >/dev/null              # never pushed
git -C "$r1" checkout -q -b crew/c1
commit "$r1" crewdelta.txt "the real delta" >/dev/null
git -C "$r1" checkout -q main
mk_meta c1 "$r1"

out="$("$BIN/ac-review-diff.sh" c1)"
assert_contains "$out" "crewdelta.txt" "local-only full diff shows the crew delta"
case "$out" in *landed1.txt*|*landed2.txt*)
  fail "local-only full diff buried the delta under already-landed commits" ;;
esac
stat="$("$BIN/ac-review-diff.sh" c1 --stat)"
assert_contains "$stat" "crewdelta.txt" "local-only --stat shows the crew delta"
case "$stat" in *landed1.txt*|*landed2.txt*)
  fail "local-only --stat buried the delta under already-landed commits" ;;
esac

# --no-guard is for a caller that never reads stderr (the dashboard's
# /api/diff): the guard would stamp its quiet window there and so swallow the
# same warning from the chief's next command.
printf 'kind=ship\n' >"$AC_HOME/state/inflight.meta"
rm -f "$AC_HOME/state/.guard-stamp"
err="$("$BIN/ac-review-diff.sh" c1 --stat --no-guard 2>&1 >/dev/null)"
case "$err" in *WATCHER-DOWN*) fail "--no-guard must not run the guard: $err" ;; esac
assert_no_file "$AC_HOME/state/.guard-stamp" "--no-guard leaves the guard's quiet window alone"
assert_contains "$("$BIN/ac-review-diff.sh" c1 --stat 2>&1 >/dev/null)" "WATCHER-DOWN" "without it the advisory still rides along"
rm -f "$AC_HOME/state/inflight.meta" "$AC_HOME/state/.guard-stamp"

# ---- Case 2: push-mode, origin FRESH ahead of a stale local -> origin-wins ---
#      landed work lives on origin/main; local main lags at genesis (as if never
#      fetched down). crew/c2 branches from the fresh origin tip. The base must
#      resolve against origin, so the landed commits stay out of the diff -
#      keying on the stale LOCAL main here would resurface them.
r2="$TMP/push-mode"
git init -q -b main "$r2"; git_id "$r2"
commit "$r2" file.txt genesis >/dev/null
commit "$r2" landed1.txt "landed one" >/dev/null
fresh="$(commit "$r2" landed2.txt "landed two")"
git -C "$r2" update-ref refs/remotes/origin/main "$fresh"     # origin holds the landed work
git -C "$r2" checkout -q -b crew/c2 "$fresh"
commit "$r2" crewdelta.txt "the real delta" >/dev/null
git -C "$r2" checkout -q main
git -C "$r2" reset -q --hard "$(git -C "$r2" rev-list --max-parents=0 HEAD)"  # local main back to genesis (stale)
mk_meta c2 "$r2"

out="$("$BIN/ac-review-diff.sh" c2)"
assert_contains "$out" "crewdelta.txt" "push-mode full diff shows the crew delta"
case "$out" in *landed1.txt*|*landed2.txt*)
  fail "push-mode full diff resurfaced origin-landed commits (origin-wins broken)" ;;
esac
stat="$("$BIN/ac-review-diff.sh" c2 --stat)"
assert_contains "$stat" "crewdelta.txt" "push-mode --stat shows the crew delta"
case "$stat" in *landed1.txt*|*landed2.txt*)
  fail "push-mode --stat resurfaced origin-landed commits (origin-wins broken)" ;;
esac

# ---- Case 3: family-scoped id -> diff against crew/<family>, never a raw ---
#      alias. id foo-r2 belongs to family foo (ac_family_of_id strips the -r2
#      revision suffix); the branch actually created (via ac_crew_branch, the
#      SAME derivation ac-brief.sh/ac-merge-local.sh use) is crew/foo, never a
#      hand-made crew/foo-r2 alias. Before the fix, ac-review-diff.sh built the
#      raw "crew/$id" name, found no such branch, fell back to head="HEAD" (the
#      worktree's current checkout at main) and silently showed an EMPTY diff
#      instead of the crew delta.
r3="$TMP/family-scoped"
git init -q -b main "$r3"; git_id "$r3"
genesis3="$(commit "$r3" file.txt genesis)"
git -C "$r3" update-ref refs/remotes/origin/main "$genesis3"
git -C "$r3" checkout -q -b crew/foo
commit "$r3" crewdelta.txt "the real delta" >/dev/null
git -C "$r3" checkout -q main
mk_meta foo-r2 "$r3"

out="$("$BIN/ac-review-diff.sh" foo-r2)"
assert_contains "$out" "crewdelta.txt" \
  "family-scoped id diffs against crew/<family>, not a raw crew/<id> alias"

# ---- Case 4: --live shows the WORKING TREE - uncommitted edits and untracked
#      files included - while the default stays committed-only. A crewmate
#      mid-task has most of its change uncommitted; the dashboard's live view
#      reads base -> worktree, not base -> branch tip.
r4="$TMP/live-tree"
git init -q -b main "$r4"; git_id "$r4"
commit "$r4" file.txt genesis >/dev/null
git -C "$r4" checkout -q -b crew/c4
commit "$r4" committed.txt "committed delta" >/dev/null
printf 'uncommitted edit\n' >>"$r4/file.txt"          # tracked, dirty
printf 'brand new\n' >"$r4/untracked.txt"             # untracked
mk_meta c4 "$r4"

out="$("$BIN/ac-review-diff.sh" c4)"
assert_contains "$out" "committed.txt" "default diff still shows the committed delta"
case "$out" in *"uncommitted edit"*|*untracked.txt*)
  fail "default diff leaked working-tree changes (must stay committed-only)" ;;
esac

live="$("$BIN/ac-review-diff.sh" c4 --live)"
assert_contains "$live" "committed.txt" "--live keeps the committed delta"
assert_contains "$live" "uncommitted edit" "--live shows an uncommitted tracked edit"
assert_contains "$live" "+++ b/untracked.txt" \
  "--live shows an untracked new file under its repo-relative path"
case "$live" in *"b$r4/untracked.txt"*)
  fail "--live leaked the absolute worktree path into the untracked file's header" ;;
esac

# ---- Case 5: --tree diffs a NAMED worktree - the pool is the truth of trees
#      (a multi-repo task holds several leases, and a pool lease can outlive
#      its task meta). The id still names the crew branch; the meta is not
#      required. A non-repo path refuses. Pool MEMBERSHIP is the dashboard's
#      gate (its /api/diff only forwards trees the ac-tree pool lists) - the
#      CLI trusts its operator like every other bin/ script.
r5a="$TMP/multi-a"; r5b="$TMP/multi-b"
for r in "$r5a" "$r5b"; do git init -q -b main "$r"; git_id "$r"; done
commit "$r5a" file.txt genesis >/dev/null
commit "$r5b" file.txt genesis >/dev/null
git -C "$r5b" checkout -q -b crew/c5
commit "$r5b" second-tree.txt "second tree delta" >/dev/null
mk_meta c5 "$r5a"
printf 'leases=%s:%s\n' "$r5a" "$r5b" >>"$AC_HOME/state/c5.meta"

t5="$("$BIN/ac-review-diff.sh" c5 --live --tree "$r5b")"
assert_contains "$t5" "second-tree.txt" "--tree diffs the named second worktree"
if "$BIN/ac-review-diff.sh" c5 --tree "$TMP" >/dev/null 2>&1; then
  fail "--tree accepted a non-repo path (must refuse)"
fi
rm "$AC_HOME/state/c5.meta"
t5o="$("$BIN/ac-review-diff.sh" c5 --live --tree "$r5b")"
assert_contains "$t5o" "second-tree.txt" \
  "--tree still diffs when the task meta is gone (orphan pool lease)"

# ---- Case 6: the three SCM groups split cleanly (dashboard file lists).
#      --uncommitted = HEAD -> worktree, tracked only; --untracked = untracked
#      new-file diffs only; default stays base -> branch tip (committed).
#      Reuses case 4's r4: committed.txt (committed), file.txt (dirty edit),
#      untracked.txt (untracked).
unc="$("$BIN/ac-review-diff.sh" c4 --uncommitted)"
assert_contains "$unc" "uncommitted edit" "--uncommitted shows the dirty tracked edit"
case "$unc" in *committed.txt*|*untracked.txt*)
  fail "--uncommitted leaked committed or untracked content" ;;
esac
unt="$("$BIN/ac-review-diff.sh" c4 --untracked)"
assert_contains "$unt" "+++ b/untracked.txt" "--untracked shows only untracked files"
case "$unt" in *committed.txt*|*"uncommitted edit"*)
  fail "--untracked leaked tracked content" ;;
esac

# ---- Case 7: a worktree pinned to REWRITTEN history has no merge-base with
#      the default branch (measured live: a pool tree leased before a
#      commit-tree history scrub). No base -> the committed view is empty and
#      the working tree is still shown, never a hard death.
r7="$TMP/orphan-history"
git init -q -b main "$r7"; git_id "$r7"
commit "$r7" file.txt genesis >/dev/null
git -C "$r7" checkout -q --orphan side
git -C "$r7" -c user.email=test@test -c user.name=test commit -qm rootless
printf 'dirty after the rewrite\n' >"$r7/wip.txt"
mk_meta c7 "$r7"

out7="$("$BIN/ac-review-diff.sh" c7)" || fail "orphan-history committed view died instead of printing empty"
[ -z "$out7" ] || fail "orphan-history committed view should be empty (no base to diff against)"
live7="$("$BIN/ac-review-diff.sh" c7 --live)"
assert_contains "$live7" "wip.txt" "orphan-history --live still shows the working tree"

# ---- Case 8: --graph prints the branch topology (git's own text graph, the
#      dashboard Worktrees tab's Graph group). Reuses case 4's r4: crew/c4
#      carries "committed delta" on top of genesis.
gr="$("$BIN/ac-review-diff.sh" c4 --graph)"
assert_contains "$gr" "committed delta" "--graph shows the crew branch's commit"
assert_contains "$gr" "genesis" "--graph keeps surrounding topology context"
case "$gr" in \**) : ;; *) fail "--graph output does not look like a git graph (no * node)" ;; esac

# ---- Case 9: --graph-data prints the machine-readable topology the dashboard
#      draws its lane graph from: hash<TAB>parents<TAB>refs<TAB>subject, one
#      commit per line, newest first.
gd="$("$BIN/ac-review-diff.sh" c4 --graph-data)"
first="$(printf '%s\n' "$gd" | head -1)"
assert_contains "$first" "committed delta" "--graph-data leads with the tree's tip"
[ "$(printf '%s' "$first" | awk -F'\t' '{print NF}')" = 4 ] \
  || fail "--graph-data rows are not 4 tab-separated fields"
assert_contains "$gd" "genesis" "--graph-data reaches the surrounding topology"
# The trailer names the BASE the crew branch grew from, so the dashboard can
# mark where the checkout happened.
gbase="$(git -C "$r4" rev-parse --short main)"
assert_contains "$gd" "#base	$gbase" "--graph-data trails the merge-base marker"

# ---- Case 9b: the graph traverses PARKED crew/* branches too - code waiting
#      to land must be visible in the topology, not only where HEAD stands.
r9="$TMP/parked-graph"
git init -q -b main "$r9"; git_id "$r9"
commit "$r9" file.txt genesis >/dev/null
git -C "$r9" checkout -q -b crew/parked
commit "$r9" parked.txt "parked delta" >/dev/null
git -C "$r9" checkout -q main
mk_meta c9 "$r9"
g9="$("$BIN/ac-review-diff.sh" c9 --graph-data)"
assert_contains "$g9" "parked delta" "--graph-data reaches a parked crew branch off HEAD"
assert_contains "$g9" "crew/parked" "--graph-data decorates the parked branch tip"
g9t="$("$BIN/ac-review-diff.sh" c9 --graph)"
assert_contains "$g9t" "parked delta" "--graph reaches the parked branch too"
# ...even when the default branch has out-scrolled the 40-commit window: an
# old parked tip must still ride the data (its own slice is fetched per ref).
# Filler commits get strictly NEWER dates - same-second ties would let the
# parked tip sneak into the window and pass vacuously.
for i in $(seq 1 45); do
  GIT_COMMITTER_DATE="@$((1900000000+i)) +0000" GIT_AUTHOR_DATE="@$((1900000000+i)) +0000" \
    commit "$r9" "f$i.txt" "filler $i" >/dev/null
done
g9w="$("$BIN/ac-review-diff.sh" c9 --graph-data)"
assert_contains "$g9w" "parked delta" "--graph-data keeps an out-of-window parked branch visible"
# Non-crew LOCAL branches (an epic integration branch) are unlanded work too.
git -C "$r9" checkout -q -b epic-integration "$(git -C "$r9" rev-parse main~40)"
GIT_COMMITTER_DATE='@1899000000 +0000' GIT_AUTHOR_DATE='@1899000000 +0000' \
  commit "$r9" epicfile.txt "epic integration delta" >/dev/null
git -C "$r9" checkout -q main
g9e="$("$BIN/ac-review-diff.sh" c9 --graph-data)"
assert_contains "$g9e" "epic integration delta" "--graph-data reaches a non-crew local branch"
assert_contains "$g9e" "epic-integration" "--graph-data decorates the local branch tip"
# --ref <branch> FOCUSES the graph on that branch (the GitLens branch picker):
# its own history only - other branches' work stays out.
g9r="$("$BIN/ac-review-diff.sh" c9 --graph-data --ref epic-integration)"
assert_contains "$g9r" "epic integration delta" "--ref shows the chosen branch's history"
case "$g9r" in *"parked delta"*)
  fail "--ref leaked another branch's commits into a focused graph" ;;
esac
if "$BIN/ac-review-diff.sh" c9 --graph-data --ref '-evil' >/dev/null 2>&1; then
  fail "--ref accepted a flag-shaped name"
fi

# ---- Case 10: --commit <sha> shows ONE commit's own change (the graph's
#      click-through). Bad shas refuse.
csha="$(git -C "$r4" rev-parse --short crew/c4)"
cm="$("$BIN/ac-review-diff.sh" c4 --commit "$csha")"
assert_contains "$cm" "committed delta" "--commit shows that commit's own diff"
assert_contains "$cm" "+++ b/committed.txt" "--commit output is a unified diff"
if "$BIN/ac-review-diff.sh" c4 --commit 'evil;rm' >/dev/null 2>&1; then
  fail "--commit accepted a non-sha argument"
fi

# --- differential: src/review-diff.ts against the frozen bash original --------
# DISPUTED: the implementation (tests/fixtures/ac-review-diff.sh under bash vs src/review-diff.ts through bin/ac-review-diff.sh)
# HELD-CONSTANT: ONE fleet home ($AC_HOME, the file's own metas plus each row's seeds) and ONE repo per row, shared by both sides - the entry is read-only over both, so the oracle and the shim read the very same refs, index and working tree; the home's one write (state/.guard-stamp) is removed before each side and its presence compared after; argv, cwd ($TMP unless a row says), LC_ALL=C, AC_GUARD_ROOT pointed at a non-repo dir so the guard's checkout checks (TANGLE, WIP-TOOLING, DISTRO-LAG name where bin/ sits, which differs by construction) are silent on both sides, PATH stubs for herdr/orca/gh/claude that log and refuse; exit status, stdout and stderr compared whole (ERR=own marks the rows whose stderr is compared by hand and names why), and the repo's refs and status and the home's entries unchanged across the row.
obin="$(make_oracle_bin ac-review-diff)"
STUBS="$TMP/rdstubs"; mkdir -p "$STUBS" "$TMP/guard-root"
for t in herdr orca gh claude; do
  printf '#!/bin/sh\nprintf "STUB %%s %%s\\n" "$0" "$*" >>"%s/rdstub.log"\nexit 1\n' "$TMP" >"$STUBS/$t"; chmod +x "$STUBS/$t"
done
gitc() { GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git "$@"; }
R=""  # the row's repo, whose refs, status and HEAD must survive both sides
repo_state() {
  [ -n "$R" ] && git -C "$R" rev-parse --git-dir >/dev/null 2>&1 || return 0
  git -C "$R" for-each-ref; git -C "$R" status --porcelain -z | tr '\0' '\n'; git -C "$R" rev-parse HEAD 2>/dev/null || true
}
home_state() { (cd "$AC_HOME" && find . -mindepth 1 ! -name '.guard-stamp' | LC_ALL=C sort); }
run_side() {  # run_side <out> <err> <cmd...> - one side, the guard's quiet window reset first
  local o="$1" e="$2"; shift 2
  local -a home
  if [ "${HOMELESS-}" = 1 ]; then home=(-u AC_HOME); else home=(AC_HOME="${AC_HOME_ROW:-$AC_HOME}"); fi
  rm -f "$AC_HOME/state/.guard-stamp"
  (cd "${RD_CWD:-$TMP}" && env "${home[@]}" AC_GUARD_ROOT="$TMP/guard-root" LC_ALL=C PATH="${RD_PATH:-$STUBS:$PATH}" "$@") <"${RD_STDIN:-/dev/null}" >"$o" 2>"$e"
}
LAST_RC=0
same() {  # same <args...> - oracle and shim answer byte-identically and leave the world as it was
  local o_rc=0 n_rc=0 before_repo before_home o_stamp=none n_stamp=none
  before_repo="$(repo_state)"; before_home="$(home_state)"
  run_side "$TMP/o.out" "$TMP/o.err" "$obin/ac-review-diff.sh" "$@" || o_rc=$?
  [ ! -e "$AC_HOME/state/.guard-stamp" ] || o_stamp=stamped
  run_side "$TMP/n.out" "$TMP/n.err" "$BIN/ac-review-diff.sh" "$@" || n_rc=$?
  [ ! -e "$AC_HOME/state/.guard-stamp" ] || n_stamp=stamped
  LAST_RC=$n_rc
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*'"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 6)"
  [ "${ERR-}" = own ] || cmp -s "$TMP/o.err" "$TMP/n.err" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err" "$TMP/n.err" | head -n 6)"
  assert_eq "$n_stamp" "$o_stamp" "differential guard stamp for '$*'"
  assert_eq "$(repo_state)" "$before_repo" "row '$*' left the repo as it was"
  assert_eq "$(home_state)" "$before_home" "row '$*' left the home as it was"
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err"; }
shim_err_last() { tail -n 1 "$TMP/n.err"; }
nowarn() { case "$(shim_err)" in *WATCHER-DOWN*) fail "$1: the guard ran" ;; esac; }
USAGE='ERROR: usage: ac-review-diff.sh <id> [--stat | --live | --uncommitted | --untracked | --graph | --graph-data | --commit <sha> | --ref <branch>] [--tree <worktree>] [--no-guard]'
NOHOME_LINE='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'

# 1. argument refusals (the guard rides the rows without --no-guard: its one
#    WATCHER-DOWN line precedes the refusal on both sides - c1..c9 are in flight
#    and no beacon exists)
R="$r1"
same
assert_eq "$(shim_err_last)" "$USAGE" "no id: the usage line"
assert_contains "$(shim_err)" "WATCHER-DOWN" "the guard precedes the usage die"
same ""
assert_eq "$(shim_err_last)" "$USAGE" "an empty id: the usage line"
same --live
assert_eq "$(shim_err_last)" "ERROR: no crewmate meta for --live" "a flag in the id's place IS the id"
same -h --no-guard
assert_eq "$(shim_err)" "ERROR: no crewmate meta for -h" "no help verb"
same c1 --bogus --no-guard
assert_eq "$(shim_err)" "ERROR: unknown argument: --bogus" "an unknown flag"
same c1 --no-guard --commit
same c1 --no-guard --commit ''
same c1 --no-guard --commit 'evil;rm'
assert_eq "$(shim_err)" "ERROR: --commit needs a sha" "a non-sha"
same c1 --no-guard --commit abcd --commit
assert_eq "$(shim_err)" "ERROR: --commit needs a sha" "a second --commit with no value"
# W1 (kept): the `grep -Eq <<<` guard passes a multi-line value when ANY line
# matches; git then refuses the value itself, exit 128.
same c1 --no-guard --commit $'abcd\nxx'
assert_eq "$LAST_RC" 128 "W1: a multi-line sha passes the guard and dies in git"
assert_contains "$(shim_err)" "fatal: ambiguous argument" "W1: git's own refusal"
same c1 --no-guard --commit $'xx\nabcd'
assert_eq "$LAST_RC" 128 "W1: any matching line passes, not only the first"
same c1 --no-guard --ref -evil
assert_eq "$(shim_err)" "ERROR: --ref needs a branch name" "a flag-shaped ref"
same c1 --no-guard --ref ''
same c1 --no-guard --ref $'main\n-x'
assert_eq "$LAST_RC" 0 "W1: a multi-line ref passes the guard; the default mode never reads it"
same c1 --no-guard --graph --ref $'main\n-x'
assert_eq "$LAST_RC" 128 "W1: the multi-line ref reaches git in a graph mode"
same c1 --no-guard --tree
assert_eq "$(shim_err)" "ERROR: --tree needs a path" "--tree without a value"
same c1 --no-guard --tree ''

# 2. meta refusals
same nosuch --no-guard
assert_eq "$(shim_err)" "ERROR: no crewmate meta for nosuch" "an unknown id"
mkdir -p "$AC_HOME/state/d.meta"
same d --no-guard
assert_eq "$(shim_err)" "ERROR: no crewmate meta for d" "a directory named <id>.meta is no meta"
same d
assert_contains "$(shim_err)" "WATCHER-DOWN" "the guard still rides a directory meta"
rmdir "$AC_HOME/state/d.meta"
if [ "$(id -u)" != 0 ]; then
  printf 'worktree=%s\n' "$r1" >"$AC_HOME/state/locked.meta"; chmod 000 "$AC_HOME/state/locked.meta"
  same locked --no-guard
  assert_eq "$LAST_RC" 1 "an unreadable meta: exit 1"
  assert_eq "$(shim_err)" "WARN: cannot read meta file $AC_HOME/state/locked.meta" "an unreadable meta: the helper's WARN alone, no ERROR line"
  assert_eq "$(shim_out)" "" "an unreadable meta: nothing rendered"
  chmod 644 "$AC_HOME/state/locked.meta"; rm -f "$AC_HOME/state/locked.meta"
fi
printf 'project_dir=%s\n' "$r1" >"$AC_HOME/state/nowt.meta"
same nowt --no-guard
assert_eq "$(shim_err)" "ERROR: worktree gone: " "a meta without worktree= names an empty path"
printf 'worktree=%s \n' "$r1" >"$AC_HOME/state/trail.meta"
same trail --no-guard
assert_eq "$(shim_err)" "ERROR: worktree gone: $r1 " "a trailing space is part of the path, printed raw"
printf 'worktree=%s\r\n' "$r1" >"$AC_HOME/state/cr.meta"
same cr --no-guard
assert_eq "$(shim_err)" "$(printf 'ERROR: worktree gone: %s\r' "$r1")" "a CR is part of the path, printed raw (W5)"
printf 'worktree=%s' "$r1" >"$AC_HOME/state/unterm.meta"
same unterm --graph --no-guard
assert_contains "$(shim_out)" "the real delta" "an unterminated meta line still reads"
printf 'worktree=%s\0junk\n' "$r1" >"$AC_HOME/state/nul.meta"
same nul --graph --no-guard
assert_contains "$(shim_out)" "the real delta" "a NUL cuts the value as awk handed it over"
printf 'worktree=/nope\nworktree=%s\n' "$r1" >"$AC_HOME/state/last.meta"
same last --graph --no-guard
assert_contains "$(shim_out)" "the real delta" "the last worktree= line wins"
rm -f "$AC_HOME/state/nowt.meta" "$AC_HOME/state/trail.meta" "$AC_HOME/state/cr.meta" "$AC_HOME/state/unterm.meta" "$AC_HOME/state/nul.meta" "$AC_HOME/state/last.meta"

# 3. the guard: rides unless the token --no-guard appears anywhere in argv -
#    as a value, or inside one argument (the `case " $* "` substring, kept)
same c1 --stat
assert_contains "$(shim_err)" "WATCHER-DOWN" "the guard rides"
assert_file "$AC_HOME/state/.guard-stamp" "the guard stamps its quiet window (W4)"
same c1 --stat --no-guard
nowarn "--no-guard"; assert_no_file "$AC_HOME/state/.guard-stamp" "--no-guard leaves no stamp"
same c1 --tree --no-guard
nowarn "--tree --no-guard"
assert_eq "$(shim_err)" "ERROR: not a git worktree: --no-guard" "--no-guard as the tree's value skips the guard and is the tree"
same c1 "x --no-guard y"
nowarn "an argument holding the token"
assert_eq "$(shim_err)" "ERROR: unknown argument: x --no-guard y" "then the argument is refused"
same c1 --stat --no-guardx
assert_contains "$(shim_err)" "WATCHER-DOWN" "a near-miss token does not skip the guard"
assert_eq "$(shim_err_last)" "ERROR: unknown argument: --no-guardx" "and is refused"

# 4. the base: local-only, push-mode, family id, orphan history
same c1 --no-guard
same c1 --stat --no-guard
R="$r2"; same c2 --no-guard; same c2 --stat --no-guard
R="$r3"; same foo-r2 --no-guard; same foo-r2 --stat --no-guard
R="$r7"; same c7 --no-guard; same c7 --stat --no-guard; same c7 --live --no-guard
same c7 --graph-data --no-guard
case "$(shim_out)" in *'#base'*) fail "no merge-base: no #base trailer" ;; esac

# 5. every mode on the live tree (committed + dirty + untracked), last flag wins
R="$r4"
same c4 --no-guard
same c4 --stat --no-guard
same c4 --live --no-guard
same c4 --uncommitted --no-guard
same c4 --untracked --no-guard
same c4 --graph --no-guard
same c4 --graph-data --no-guard
[ "$(shim_out | head -n 1 | awk -F'\t' '{print NF}')" = 4 ] || fail "graph-data rows are 4 TAB fields"
assert_contains "$(shim_out)" "#base	$(git -C "$r4" rev-parse --short main)" "graph-data trails #base"
same c4 --no-guard --commit "$csha"
same c4 --no-guard --commit "$(git -C "$r4" rev-parse crew/c4)"
same c4 --no-guard --commit "$csha" --stat
assert_contains "$(shim_out)" "committed.txt |" "--commit then --stat renders stat (last mode wins)"
same c4 --stat --live --no-guard
assert_contains "$(shim_out)" "uncommitted edit" "--stat --live renders live"
same c4 --live --stat --no-guard
assert_contains "$(shim_out)" "committed.txt |" "--live --stat renders stat"
same c4 --ref main --no-guard
same c4 --no-guard --no-guard --stat

# 6. the graph-data merge: 45 fillers, a parked ref, an epic branch behind, a
#    merge commit, a TAB subject (W2), % and backslash, a same-second tie, a
#    recent ref whose slice overlaps HEAD's window (dedupe)
R="$r9"
git -C "$r9" checkout -q -b side main~3
GIT_COMMITTER_DATE='@1900000100 +0000' GIT_AUTHOR_DATE='@1900000100 +0000' commit "$r9" sidefile.txt "side work" >/dev/null
git -C "$r9" checkout -q main
GIT_COMMITTER_DATE='@1900000101 +0000' GIT_AUTHOR_DATE='@1900000101 +0000' git -C "$r9" merge -q --no-ff -m "merge side" side
printf 'tab\n' >"$r9/tab.txt"; git -C "$r9" add -A
GIT_COMMITTER_DATE='@1900000102 +0000' GIT_AUTHOR_DATE='@1900000102 +0000' git -C "$r9" commit -qm "$(printf 'tab\there subject')"
GIT_COMMITTER_DATE='@1900000103 +0000' GIT_AUTHOR_DATE='@1900000103 +0000' commit "$r9" pct.txt 'pct % and back\slash %x09 %h' >/dev/null
git -C "$r9" checkout -q -b crew/tie-a main
GIT_COMMITTER_DATE='@1900000200 +0000' GIT_AUTHOR_DATE='@1900000200 +0000' commit "$r9" tiea.txt "tie a" >/dev/null
git -C "$r9" checkout -q -b crew/tie-b main
GIT_COMMITTER_DATE='@1900000200 +0000' GIT_AUTHOR_DATE='@1900000200 +0000' commit "$r9" tieb.txt "tie b" >/dev/null
git -C "$r9" checkout -q -b crew/recent main
GIT_COMMITTER_DATE='@1900000300 +0000' GIT_AUTHOR_DATE='@1900000300 +0000' commit "$r9" recent.txt "recent delta" >/dev/null
git -C "$r9" checkout -q main
same c9 --graph-data --no-guard
assert_eq "$(shim_out | grep -c "$(git -C "$r9" rev-parse --short crew/recent)")" 1 "a hash in HEAD's window and in its ref's slice is printed once"
assert_contains "$(shim_out)" "$(printf '\ttab\n')" "W2: a TAB in the subject is cut at the TAB in the merged path"
assert_contains "$(shim_out)" 'pct % and back\slash %x09 %h' "% and backslash in a subject pass through"
assert_contains "$(shim_out)" "$(git -C "$r9" rev-parse --short main~2^1) $(git -C "$r9" rev-parse --short main~2^2)" "a merge commit carries both parents"
same c9 --graph-data --ref main --no-guard
assert_contains "$(shim_out)" "$(printf 'tab\there subject')" "W2: the --ref path keeps the subject whole"
same c9 --graph-data --ref epic-integration --no-guard
same c9 --graph-data --ref crew/recent --no-guard
same c9 --graph-data --ref crew/tie-b --no-guard
same c9 --graph --no-guard
same c9 --graph --ref crew/parked --no-guard
same c9 --no-guard
same c9 --stat --no-guard
git -C "$r9" checkout -q --detach
same c9 --graph-data --no-guard
same c9 --graph --no-guard
same c9 --no-guard
git -C "$r9" checkout -q main
re="$TMP/empty"; git init -q -b main "$re"; mk_meta ce "$re"; R="$re"
same ce --no-guard
assert_eq "$LAST_RC" 128 "an empty repo: git's own 128"
assert_contains "$(shim_err)" "fatal:" "an empty repo: git's own line"
same ce --stat --no-guard
same ce --live --no-guard
same ce --uncommitted --no-guard
same ce --untracked --no-guard
same ce --graph --no-guard
same ce --graph-data --no-guard
same ce --graph-data --ref main --no-guard
same ce --no-guard --commit abcd
# A ref naming an object the repo does not have: the first log of the merged
# path fails (nothing reached the merge), git's status ends the run.
rb="$TMP/broken-ref"; git init -q -b main "$rb"; git_id "$rb"
commit "$rb" file.txt genesis >/dev/null
printf '%s\n' 0123456789abcdef0123456789abcdef01234567 >"$rb/.git/refs/heads/broken"
mk_meta cb "$rb"; R="$rb"
same cb --graph-data --no-guard
assert_eq "$LAST_RC" 128 "a broken ref: the merged path ends with git's 128"
assert_eq "$(shim_out)" "" "a broken ref: no rows reached the merge"
same cb --graph --no-guard
same cb --no-guard

# 7. untracked names: a space, a newline, a leading dash, UTF-8, an unreadable
#    file, a binary, an ignored file, a worktree that is a subdirectory
ru="$TMP/untracked-names"; git init -q -b main "$ru"; git_id "$ru"
commit "$ru" file.txt genesis >/dev/null
printf 'spaced\n' >"$ru/with space.txt"
printf 'newline\n' >"$ru/$(printf 'nl\nx.txt')"
printf 'dash\n' >"$ru/-dash.txt"
printf 'utf8\n' >"$ru/$(printf 'caf\303\251.txt')"
printf '\0\1\2bin\n' >"$ru/blob.bin"
printf 'ignored.txt\n' >"$ru/.gitignore"; printf 'hidden\n' >"$ru/ignored.txt"
mkdir -p "$ru/sub"; printf 'inner\n' >"$ru/sub/inner.txt"
mk_meta cu "$ru"; R="$ru"
same cu --untracked --no-guard
assert_contains "$(shim_out)" "+++ b/with space.txt" "a name with a space"
assert_contains "$(shim_out)" '+++ "b/nl\nx.txt"' "a name with a newline, quoted by git"
assert_contains "$(shim_out)" "+++ b/-dash.txt" "a name with a leading dash"
assert_contains "$(shim_out)" '+++ "b/caf\303\251.txt"' "a UTF-8 name, octal-quoted by git (core.quotePath)"
assert_contains "$(shim_out)" "Binary files /dev/null and b/blob.bin differ" "a binary"
case "$(shim_out)" in *"b/ignored.txt"*) fail "an ignored file is excluded" ;; esac
same cu --live --no-guard
same cu --untracked --tree "$ru/sub" --no-guard
assert_eq "$(shim_out | grep '^+++ ')" "+++ b/inner.txt" "a subdirectory worktree lists its own files, relative"
if [ "$(id -u)" != 0 ]; then
  printf 'locked\n' >"$ru/locked.txt"; chmod 000 "$ru/locked.txt"
  same cu --untracked --no-guard
  assert_eq "$LAST_RC" 0 "an unreadable untracked file: the run goes on"
  assert_contains "$(shim_err)" "locked.txt" "an unreadable untracked file: git's own error names it"
  chmod 644 "$ru/locked.txt"; rm -f "$ru/locked.txt"
fi
# A name that is not UTF-8 cannot exist on APFS (the filesystem refuses the
# byte); where it can, the names reach git untouched through xargs -0.
if printf 'raw\n' 2>/dev/null >"$ru/$(printf 'bad\351.txt')"; then
  same cu --untracked --no-guard
  assert_contains "$(shim_out)" '+++ "b/bad\351.txt"' "a non-UTF-8 name renders as git renders it"
fi

# 8. the epic fence: meta project=proj, ledger rows, branch records
r8="$TMP/epic-fence"; git init -q -b main "$r8"; git_id "$r8"
gen8="$(commit "$r8" file.txt genesis)"
git -C "$r8" checkout -q -b epic/e1
commit "$r8" epicwork.txt "epic work" >/dev/null
git -C "$r8" update-ref refs/remotes/origin/epic/e1 HEAD
commit "$r8" epicmore.txt "epic local more" >/dev/null
git -C "$r8" branch feat/f1
git -C "$r8" checkout -q -b crew/e1-s1
commit "$r8" story.txt "story one" >/dev/null
git -C "$r8" checkout -q main
printf 'project_dir=%s\nworktree=%s\nproject=proj\n' "$r8" "$r8" >"$AC_HOME/state/e1-s1.meta"
printf 'project_dir=%s\nworktree=%s\nproject=proj\n' "$r8" "$r8" >"$AC_HOME/state/e1-s1-x.meta"
printf 'project_dir=%s\nworktree=%s\nproject=\n' "$r8" "$r8" >"$AC_HOME/state/noproj.meta"
LEDGER="$AC_HOME/records/backlog.md"; rm -rf "$LEDGER"; R="$r8"
same e1-s1 --stat --no-guard
assert_contains "$(shim_out)" "epicwork.txt" "no ledger: the default base renders the epic's own work as the story's"
mkdir -p "$LEDGER"
same e1-s1 --stat --no-guard
assert_contains "$(shim_out)" "epicwork.txt" "a ledger that is a directory is no ledger (rc 1), never rc 2"
rm -rf "$LEDGER"
printf -- '- [ ] e1-s1 - story; epic:e1 (repo: proj)\n' >"$LEDGER"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$LEDGER"
  for m in "" --stat --live --uncommitted --untracked --graph --graph-data "--commit $gen8"; do
    # shellcheck disable=SC2086
    same e1-s1 $m --no-guard
    assert_eq "$LAST_RC" 1 "an unreadable ledger refuses in mode '$m'"
    assert_eq "$(shim_err)" "ERROR: cannot read the ledger to resolve the epic-branch fence for e1-s1" "an unreadable ledger: the refusal in mode '$m'"
    assert_eq "$(shim_out)" "" "an unreadable ledger: nothing rendered in mode '$m'"
  done
  same e1-s1 --stat --tree "$r8" --no-guard
  assert_eq "$LAST_RC" 1 "--tree still reads the meta's project and refuses"
  same noproj --stat --no-guard
  assert_eq "$LAST_RC" 0 "an empty project= is no fence"
  chmod 644 "$LEDGER"
fi
mkdir -p "$AC_HOME/data/e1" "$AC_HOME/data/f1"
printf 'proj epic/e1 push=deferred\n' >"$AC_HOME/data/e1/branches"
same e1-s1 --stat --no-guard
assert_eq "$(shim_out | grep -c 'txt')" 1 "push=deferred: the LOCAL epic branch is the base (only the story)"
assert_contains "$(shim_out)" "story.txt" "push=deferred: the story's own file"
printf 'proj epic/e1\n' >"$AC_HOME/data/e1/branches"
same e1-s1 --stat --no-guard
assert_contains "$(shim_out)" "epicmore.txt" "origin carries the epic branch: origin's tip is the base (the local lag renders)"
case "$(shim_out)" in *epicwork.txt*) fail "origin's epic tip must not render the landed epic work" ;; esac
git -C "$r8" update-ref -d refs/remotes/origin/epic/e1
same e1-s1 --stat --no-guard
assert_eq "$(shim_out | grep -c 'txt')" 1 "only a local epic branch: it is the base"
printf '# retired 2026-01-01T00:00:00Z\nproj epic/e1\n' >"$AC_HOME/data/e1/branches"
same e1-s1 --stat --no-guard
assert_contains "$(shim_out)" "epicwork.txt" "a retired record is no fence: the default base"
printf 'other epic/e1\n' >"$AC_HOME/data/e1/branches"
same e1-s1 --stat --no-guard
assert_contains "$(shim_out)" "epicwork.txt" "a record naming another repo is no fence"
printf -- '- [ ] e1-s1 - story; feature:f1 (repo: proj)\n' >"$LEDGER"
printf 'proj feat/f1 push=deferred\n' >"$AC_HOME/data/f1/branches"
same e1-s1 --stat --no-guard
assert_eq "$(shim_out | grep -c 'txt')" 1 "a feature: token fences on the feature branch"
printf -- '- [ ] e1-s1 - story; epic:e1 (repo: proj)\n' >"$LEDGER"
printf 'proj epic/e1\n' >"$AC_HOME/data/e1/branches"
same e1-s1-x --stat --no-guard
same e1-s1-x --graph-data --no-guard
assert_contains "$(shim_out)" "#base	$(git -C "$r8" rev-parse --short "$gen8")" "a sub-task id resolves by prefix; its #base is the epic's merge-base with HEAD"
printf -- '- [ ] e1-s1 - prose\0junk epic:e1 (repo: proj)\n' >"$LEDGER"
same e1-s1 --stat --no-guard
assert_contains "$(shim_out)" "epicwork.txt" "a NUL in the row cuts the record before its token: no fence"
rm -f "$LEDGER" "$AC_HOME/state/e1-s1.meta" "$AC_HOME/state/e1-s1-x.meta" "$AC_HOME/state/noproj.meta"; rm -rf "$AC_HOME/data/e1" "$AC_HOME/data/f1"

# 9. staged ids: the family grammar decides the crew branch
R="$r1"
for sid in c1-ship c1-r2 c1-spec-r2; do mk_meta "$sid" "$r1"; done
same c1-ship --no-guard
assert_eq "$(shim_out)" "" "c1-ship without data/c1/ship/ is its own family: crew/c1-ship is absent, HEAD diffs empty"
mkdir -p "$AC_HOME/data/c1/ship"
same c1-ship --no-guard
assert_contains "$(shim_out)" "crewdelta.txt" "c1-ship with data/c1/ship/ is family c1: crew/c1"
same c1-r2 --no-guard
assert_contains "$(shim_out)" "crewdelta.txt" "a bare revision is unconditional"
same c1-spec-r2 --no-guard
assert_eq "$(shim_out)" "" "c1-spec-r2 without data/c1/spec/ resolves to c1-spec: no such branch"
mkdir -p "$AC_HOME/data/c1/spec"
same c1-spec-r2 --no-guard
assert_contains "$(shim_out)" "crewdelta.txt" "c1-spec-r2 with data/c1/spec/ is family c1"
rm -rf "$AC_HOME/data/c1"; rm -f "$AC_HOME/state/c1-ship.meta" "$AC_HOME/state/c1-r2.meta" "$AC_HOME/state/c1-spec-r2.meta"

# 10. --tree: a named worktree with and without a meta, a plain dir, a relative
#     path from inside the repo, a path with a space
R="$r5b"
mk_meta c5 "$r5a"
same c5 --live --tree "$r5b" --no-guard
same c5 --tree "$r5b" --no-guard
rm -f "$AC_HOME/state/c5.meta"
same c5 --live --tree "$r5b" --no-guard
assert_contains "$(shim_out)" "second-tree.txt" "--tree renders without a meta"
mkdir -p "$TMP/plain"
same c5 --tree "$TMP/plain" --no-guard
assert_eq "$(shim_err)" "ERROR: not a git worktree: $TMP/plain" "a plain dir is refused"
RD_CWD="$r5b" same c5 --tree . --no-guard
assert_contains "$(shim_out)" "second-tree.txt" "a relative --tree resolves against the caller's cwd"
RD_CWD="$r5b" same c5 --tree sub/.. --no-guard
cp -R "$r5b" "$TMP/sp ace"
same c5 --live --tree "$TMP/sp ace" --no-guard
assert_contains "$(shim_out)" "second-tree.txt" "a worktree path with a space"
if [ "$(id -u)" != 0 ]; then
  mk_meta c5 "$r5a"; chmod 000 "$AC_HOME/state/c5.meta"
  same c5 --tree "$r5b" --no-guard
  assert_eq "$LAST_RC" 1 "--tree with an unreadable meta: the project read dies, exit 1"
  assert_eq "$(shim_err)" "WARN: cannot read meta file $AC_HOME/state/c5.meta" "--tree with an unreadable meta: the WARN alone"
  chmod 644 "$AC_HOME/state/c5.meta"; rm -f "$AC_HOME/state/c5.meta"
fi

# 11. homeless: two ERROR lines without --tree; with --tree the refusal and a
#     rendered diff, exit 0 (W3, kept); a home cd cannot enter
R="$r1"
HOMELESS=1 same c1 --no-guard
assert_eq "$LAST_RC" 1 "homeless: exit 1"
assert_eq "$(shim_err)" "$NOHOME_LINE
ERROR: no crewmate meta for c1" "homeless: the refusal, then the entry's own line (the ac_task_meta swallow)"
HOMELESS=1 same c1
assert_eq "$(shim_err_last)" "ERROR: no crewmate meta for c1" "homeless: the guard says nothing"
HOMELESS=1 same c1 --tree "$r1" --no-guard
assert_eq "$LAST_RC" 0 "W3: homeless --tree renders, exit 0"
assert_eq "$(shim_err)" "$NOHOME_LINE" "W3: the refusal is printed once"
assert_contains "$(shim_out)" "crewdelta.txt" "W3: and the diff follows"
HOMELESS=1 same c1-spec-r2 --tree "$r1" --no-guard
assert_eq "$(shim_err)" "$NOHOME_LINE
$NOHOME_LINE" "W3: a staged id prints the refusal again from the data-dir test"
HOMELESS=1 same c1 --graph-data --tree "$r1" --no-guard
# Named divergence (HOME RESOLUTION ruling): the original fails inside `cd`
# with the shell's own line; the port names the variable. Exit and stdout agree.
AC_HOME_ROW="$TMP/nohome" ERR=own same c1 --no-guard
assert_eq "$LAST_RC" 1 "an unenterable home: exit 1"
assert_eq "$(shim_out)" "" "an unenterable home: nothing rendered"
assert_contains "$(cat "$TMP/o.err")" "No such file or directory" "an unenterable home: the original's cd noise (shell-own stderr)"
assert_eq "$(shim_err)" "ERROR: AC_HOME is not a readable directory: $TMP/nohome
ERROR: no crewmate meta for c1" "an unenterable home: the port names the variable, then the same refusal"
assert_eq "$(tail -n 1 "$TMP/o.err")" "$(shim_err_last)" "an unenterable home: the entry's own last line agrees"

# 12. git absent from PATH: the refusal, after the guard's lines
NOGIT="$TMP/nogit"; mkdir -p "$NOGIT"
for d in /usr/bin /bin "$(dirname "$(command -v bun)")"; do
  for f in "$d"/*; do [ -x "$f" ] && [ "$(basename "$f")" != git ] && [ ! -e "$NOGIT/$(basename "$f")" ] && ln -s "$f" "$NOGIT/$(basename "$f")"; done
done
RD_PATH="$NOGIT:$STUBS" same c1 --no-guard
assert_eq "$(shim_err)" "ERROR: required tool not found: git" "no git on PATH"
RD_PATH="$NOGIT:$STUBS" same c1
assert_contains "$(shim_err)" "WATCHER-DOWN" "no git: the guard still rides first"
assert_eq "$(shim_err_last)" "ERROR: required tool not found: git" "no git: then the refusal"
# 13. every git inherits the caller's stdin: an external diff that reads it
#     sees the same bytes on both sides (the bash never redirected git's stdin)
printf '#!/bin/sh\nprintf "ext-diff %%s <" "$1"; cat; printf ">\\n"\n' >"$TMP/xdiff"; chmod +x "$TMP/xdiff"
printf 'from the caller\n' >"$TMP/rd-stdin"
RD_STDIN="$TMP/rd-stdin" GIT_EXTERNAL_DIFF="$TMP/xdiff" same c1 --no-guard
assert_eq "$LAST_RC" 0 "row 13: the external diff ran on both sides"
assert_contains "$(shim_out)" "<from the caller
>" "row 13: the external diff read the caller's stdin"

[ ! -s "$TMP/rdstub.log" ] || fail "a leg row reached a backend stub: $(cat "$TMP/rdstub.log")"

pass
