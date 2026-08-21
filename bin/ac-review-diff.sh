#!/usr/bin/env bash
# ac-review-diff.sh - show a crewmate's change as a diff against the
# authoritative base (merge-base with the default branch).
#
# Usage: ac-review-diff.sh <id> [--stat | --live | --uncommitted | --untracked]
#                               [--tree <worktree>]
#
# Modes (default = committed-only, base -> branch tip: the chief/roomchief
# delivered-change review):
# - --live: base -> WORKING TREE (uncommitted tracked edits included,
#   untracked files appended as new-file diffs) - the mid-task view, where
#   most of a crewmate's change has not been committed yet.
# - --uncommitted: HEAD -> working tree, tracked files only.
# - --untracked: untracked files only, each as a new-file diff.
# The three SCM groups a dashboard file list wants are the default,
# --uncommitted, and --untracked - --live is their union for a single read.
#
# --tree <path> diffs that worktree instead of the meta's: the ac-tree pool is
# the truth of leased trees (a multi-repo task holds several; a pool lease can
# outlive its task meta). The id still names the crew branch; no meta is
# required. Pool MEMBERSHIP gating belongs to the dashboard's /api/diff - the
# CLI trusts its operator like every other bin/ script.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
[ ! -x "$(dirname "$0")/ac-guard.sh" ] || "$(dirname "$0")/ac-guard.sh" || true  # warn-only advisory
ac_require git

diff_base_ref() {
  # diff_base_ref <repo> - the default-branch ref to diff a crew branch against,
  # LOCAL-ONLY-AWARE. ac_default_ref is origin-wins, but a local-only fleet never
  # pushes its default branch, so origin/<default> sits frozen behind the real
  # LOCAL default and every already-landed commit renders as fresh diff. Mirror
  # teardown's head_landed (ac-teardown.sh): trust the LOCAL default branch when
  # origin/<default> is absent or STRICTLY behind it; keep origin-wins for
  # push-mode (crew-ship/direct-pr), where landings live on origin and it is
  # fresh (equal, ahead, or diverged). The origin-behind-local topology check
  # distinguishes the two worlds, so the task's delivery mode is never consulted.
  local repo="$1" branch
  branch="$(ac_default_branch "$repo")"
  if ! git -C "$repo" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
    printf '%s\n' "$branch"; return                 # no origin ref -> local default
  fi
  if git -C "$repo" merge-base --is-ancestor "origin/$branch" "$branch" 2>/dev/null \
     && ! git -C "$repo" merge-base --is-ancestor "$branch" "origin/$branch" 2>/dev/null; then
    printf '%s\n' "$branch"                         # origin strictly behind local -> local
  else
    printf 'origin/%s\n' "$branch"                  # origin fresh -> origin-wins
  fi
}

id="${1:-}"; mode=committed; tree=""
[ -n "$id" ] || ac_die "usage: ac-review-diff.sh <id> [--stat | --live | --uncommitted | --untracked] [--tree <worktree>]"
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --stat) mode=stat ;;
    --live) mode=live ;;
    --uncommitted) mode=uncommitted ;;
    --untracked) mode=untracked ;;
    --tree) shift; tree="${1:-}"; [ -n "$tree" ] || ac_die "--tree needs a path" ;;
    *) ac_die "unknown argument: $1" ;;
  esac
  shift
done
meta="$(ac_task_meta "$id")"
if [ -n "$tree" ]; then
  worktree="$tree"
  git -C "$worktree" rev-parse --git-dir >/dev/null 2>&1 || ac_die "not a git worktree: $tree"
else
  [ -f "$meta" ] || ac_die "no crewmate meta for $id"
  worktree="$(ac_meta_get "$meta" worktree)"
  [ -d "$worktree" ] || ac_die "worktree gone: $worktree"
fi

branch="$(ac_crew_branch "$id")"
head="$branch"
git -C "$worktree" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null || head="HEAD"
defref="$(diff_base_ref "$worktree")"
# Epic stories diff against the EPIC branch (epic-branch-mech): the default
# merge-base would render every sibling story's commits as this story's diff.
proj_name="$(ac_meta_get "$meta" project)"
if [ -n "$proj_name" ] && eb="$(ac_epic_base_for "$id" "$proj_name" 2>/dev/null)"; then
  ebb="${eb%% *}"
  if git -C "$worktree" rev-parse --verify --quiet "refs/heads/$ebb" >/dev/null; then
    defref="$ebb"
  elif git -C "$worktree" rev-parse --verify --quiet "refs/remotes/origin/$ebb" >/dev/null; then
    defref="origin/$ebb"
  fi
fi
# A tree pinned to REWRITTEN default-branch history shares no ancestor with
# defref (measured: a pool lease taken before a commit-tree scrub). No base ->
# fall back to the tree's own head: the committed view reads empty and the
# working-tree views still work, instead of a hard errexit death.
if ! base="$(git -C "$worktree" merge-base "$defref" "$head" 2>/dev/null)"; then
  base="$head"
fi

# Untracked files as new-file diffs: read-only by design - `git add -N` would
# mutate the crewmate's index. --no-index exits 1 on any difference. Relative
# paths on purpose: -C already stands in the worktree, and an absolute
# argument would become the rendered a/-b/ header path.
untracked_diffs() {
  git -C "$worktree" ls-files --others --exclude-standard -z \
    | while IFS= read -r -d '' f; do
        git -C "$worktree" diff --no-index -- /dev/null "$f" || true
      done
}

case "$mode" in
  stat)        git -C "$worktree" diff --stat "$base" "$head" ;;
  live)        git -C "$worktree" diff "$base"; untracked_diffs ;;
  uncommitted) git -C "$worktree" diff ;;
  untracked)   untracked_diffs ;;
  *)           git -C "$worktree" diff "$base" "$head" ;;
esac
