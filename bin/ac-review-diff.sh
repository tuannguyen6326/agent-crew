#!/usr/bin/env bash
# ac-review-diff.sh - show a crewmate's change as a diff against the
# authoritative base (merge-base with the default branch).
#
# Usage: ac-review-diff.sh <id> [--stat]

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

id="${1:-}"; stat=0
[ -n "$id" ] || ac_die "usage: ac-review-diff.sh <id> [--stat]"
[ "${2:-}" = "--stat" ] && stat=1
meta="$(ac_task_meta "$id")"
[ -f "$meta" ] || ac_die "no crewmate meta for $id"
worktree="$(ac_meta_get "$meta" worktree)"
[ -d "$worktree" ] || ac_die "worktree gone: $worktree"

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
base="$(git -C "$worktree" merge-base "$defref" "$head")"

if [ "$stat" = 1 ]; then
  git -C "$worktree" diff --stat "$base" "$head"
else
  git -C "$worktree" diff "$base" "$head"
fi
