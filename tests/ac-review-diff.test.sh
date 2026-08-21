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

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

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

pass
