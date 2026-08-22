#!/usr/bin/env bash
# ac-review-diff.sh - show a crewmate's change as a diff against the
# authoritative base (merge-base with the default branch).
#
# Usage: ac-review-diff.sh <id> [--stat | --live | --uncommitted | --untracked | --graph]
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
# - --graph: git's own text graph of the branch topology around the tree's
#   tip (no diff) - the CLI view.
# - --graph-data: the same topology machine-readable, one commit per line,
#   newest first: hash<TAB>parents<TAB>refs<TAB>subject. What the dashboard
#   Worktrees tab draws its lane graph from.
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

id="${1:-}"; mode=committed; tree=""; gref=""
[ -n "$id" ] || ac_die "usage: ac-review-diff.sh <id> [--stat | --live | --uncommitted | --untracked] [--tree <worktree>]"
shift
while [ $# -gt 0 ]; do
  case "$1" in
    --stat) mode=stat ;;
    --live) mode=live ;;
    --uncommitted) mode=uncommitted ;;
    --untracked) mode=untracked ;;
    --graph) mode=graph ;;
    --graph-data) mode=graphdata ;;
    --commit)
      shift; commit="${1:-}"; mode=commit
      printf '%s' "$commit" | grep -Eq '^[0-9a-f]{4,40}$' || ac_die "--commit needs a sha"
      ;;
    --tree) shift; tree="${1:-}"; [ -n "$tree" ] || ac_die "--tree needs a path" ;;
    # Focus the graph modes on ONE branch (the dashboard's branch picker).
    --ref)
      shift; gref="${1:-}"
      printf '%s' "$gref" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._/-]*$' || ac_die "--ref needs a branch name"
      ;;
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
  # One commit's own change, bare diff - the dashboard graph's click-through
  # (the graph row already carries the subject; a header would render as a
  # stray file card).
  commit)      git -C "$worktree" show --format='' "$commit" ;;
  # 40 recent commits from the tree's CURRENT position (HEAD, not the resolved
  # crew branch - a tree can sit detached or on another ref, and the graph
  # must show where the checkout actually stands) PLUS every LOCAL branch
  # all of it unlanded work that must be visible in the topology, not only where
  # HEAD stands. Bounded so a deep repo stays fast. graphdata trails a #base
  # marker naming the merge-base the checkout grew from. Each local ref also
  # contributes its OWN slice: an old parked tip falls outside the 40-newest
  # window (measured: crew tips a week behind a busy release).
  graph)
    if [ -n "$gref" ]; then git -C "$worktree" log --graph --oneline --decorate --no-color -n 40 "refs/heads/$gref"
    else git -C "$worktree" log --graph --oneline --decorate --no-color -n 40 HEAD --branches; fi
    ;;
  graphdata)
    # --ref FOCUSES on one branch's own history (the dashboard branch picker).
    if [ -n "$gref" ]; then
      git -C "$worktree" log --format='%h%x09%p%x09%D%x09%s' -n 40 "refs/heads/$gref"
      if gb="$(git -C "$worktree" merge-base "$defref" "refs/heads/$gref" 2>/dev/null)"; then
        printf '#base\t%s\n' "$(git -C "$worktree" rev-parse --short "$gb")"
      fi
      exit 0
    fi
    # An old parked tip falls outside the 40-newest window (measured: crew
    # tips a week behind a busy release), so each crew/* ref contributes its
    # OWN slice (--not HEAD, capped) and the streams merge newest-first,
    # deduped by hash. The leading %ct column exists only to sort and is
    # stripped before the rows leave.
    {
      git -C "$worktree" log --format='%ct%x09%h%x09%p%x09%D%x09%s' -n 40 HEAD --branches
      git -C "$worktree" for-each-ref 'refs/heads' --format='%(refname)' \
        | while IFS= read -r cref; do
            git -C "$worktree" log --format='%ct%x09%h%x09%p%x09%D%x09%s' -n 8 "$cref" --not HEAD
          done
    } | sort -s -t"$(printf '\t')" -k1,1rn \
      | awk -F'\t' 'BEGIN{OFS="\t"} !seen[$2]++ {print $2,$3,$4,$5}'
    if gb="$(git -C "$worktree" merge-base "$defref" HEAD 2>/dev/null)"; then
      printf '#base\t%s\n' "$(git -C "$worktree" rev-parse --short "$gb")"
    fi
    ;;
  *)           git -C "$worktree" diff "$base" "$head" ;;
esac
