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

pass
