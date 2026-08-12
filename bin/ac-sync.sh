#!/usr/bin/env bash
# ac-sync.sh - keep project clones fresh: fetch, fast-forward the checked-out
# default branch, and prune local branches whose upstream is gone.
#
# Usage:
#   ac-sync.sh [<project>]
#     <project> is a name under projects/ or a path to (inside) a repo;
#     with no argument every git repo under projects/ is swept.
#
# Per project:
# - `git fetch origin --prune`, time-bounded (AC_SYNC_TIMEOUT env >
#   config/sync-timeout > 60 seconds): a fetch still running at the deadline
#   is killed and the project reported `FAILED <project>: fetch timed out` -
#   a hung remote never hangs the sweep, the next project still runs.
# - Clean clone, on the default branch, strictly behind origin -> the branch
#   is fast-forwarded: `synced <project>: <branch> <old>..<new>`.
# - Nothing to pull (or no origin remote at all) -> `fresh <project>`.
# - Cannot act - checked out off the default branch, dirty tree, or diverged
#   from origin -> `STUCK <project>: <why> (N commits behind)`; the working
#   tree is NEVER touched in those states. UNTRACKED files never count as
#   dirty (caches like .crew/ or .codegraph/ must not block the sweep); when
#   a fast-forward would overwrite one, git itself refuses and that surfaces
#   as `STUCK <project>: fast-forward failed`.
# - Local branches whose upstream tracking branch is GONE are deleted, unless
#   still needed: checked out in some worktree, or `crew/<task>` for a pool
#   lease (read-only scan of <repo>/.crew/slots/*.meta with leased=1; even a
#   dead-owner lease keeps its branch - reclaiming leases is the pool's job).
#   Reported as `pruned <project>: branch <b>` / `kept <project>: branch <b>`.
#
# Exit codes: 0 every project synced/fresh; 1 any project STUCK or FAILED
# (ride-alongs surface a non-zero sweep); 2 usage.
#
# Deliberately NOT an ac-tree verb: the pool owns worktree leases (ac-tree.sh
# is the authoritative spec of the slot records), ac-sync owns MAIN-CLONE
# freshness and only ever reads those records.

set -euo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ac-lib.sh"

usage() {
  awk 'NR>1{if(!/^#/)exit; print}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

sync_timeout() {
  # Fetch deadline in seconds: AC_SYNC_TIMEOUT env > config/sync-timeout > 60.
  local t
  t="${AC_SYNC_TIMEOUT:-$(ac_config_read sync-timeout 60)}"
  case "$t" in
    '' | *[!0-9]*) t=60 ;;
  esac
  printf '%s\n' "$t"
}

fetch_bounded() {
  # fetch_bounded <repo> <secs> - `git fetch origin --prune` with a watchdog:
  # the fetch is killed once <secs> elapse (TERM, short grace, KILL).
  # Returns the fetch's own status, or 124 on timeout.
  local repo="$1" secs="$2" pid start
  git -C "$repo" -c http.lowSpeedLimit=1 -c "http.lowSpeedTime=$secs" \
    fetch origin --prune --quiet >/dev/null 2>&1 &
  pid=$!
  start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$secs" ]; then
      kill "$pid" 2>/dev/null || true
      sleep 0.5
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.2
  done
  wait "$pid"
}

needed_branches() {
  # needed_branches <repo> - one branch name per line that must survive
  # pruning: every branch checked out in some worktree of the repo, plus
  # crew/<task> for every pool lease (slot meta leased=1 with a task id).
  local repo="$1" meta task
  git -C "$repo" worktree list --porcelain 2>/dev/null \
    | awk '/^branch / { sub("refs/heads/", "", $2); print $2 }'
  for meta in "$repo"/.crew/slots/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(ac_meta_get "$meta" leased)" = "1" ] || continue
    task="$(ac_meta_get "$meta" task)"
    [ -n "$task" ] && printf 'crew/%s\n' "$task"
  done
  return 0
}

prune_gone_branches() {
  # prune_gone_branches <repo> <name> - delete local branches whose upstream
  # tracking branch is gone, keeping any branch a worktree or pool lease
  # still needs. Only refs are touched, never the working tree.
  local repo="$1" name="$2" gone needed b
  gone="$(git -C "$repo" for-each-ref \
    --format='%(refname:short) %(upstream:track)' refs/heads \
    | awk '$2 == "[gone]" { print $1 }')"
  [ -n "$gone" ] || return 0
  needed="$(needed_branches "$repo")"
  while IFS= read -r b; do
    [ -n "$b" ] || continue
    if printf '%s\n' "$needed" | grep -qxF "$b"; then
      printf 'kept %s: branch %s (upstream gone, still in use)\n' "$name" "$b"
      continue
    fi
    if git -C "$repo" branch -D "$b" >/dev/null 2>&1; then
      printf 'pruned %s: branch %s (upstream gone)\n' "$name" "$b"
    else
      printf 'kept %s: branch %s (upstream gone, delete refused)\n' "$name" "$b"
    fi
  done <<<"$gone"
}

sync_project() {
  # sync_project <repo> - one project's sweep: bounded fetch, ff-advance or
  # a quantified STUCK line, then gone-upstream branch pruning.
  # Returns 0 when synced/fresh, 1 when STUCK or the fetch FAILED.
  local repo="$1" name branch cur behind ahead old new frc=0 rc=0
  name="$(basename "$repo")"

  if ! git -C "$repo" remote get-url origin >/dev/null 2>&1; then
    printf 'fresh %s (no origin)\n' "$name"
    return 0
  fi
  fetch_bounded "$repo" "$(sync_timeout)" || frc=$?
  if [ "$frc" = 124 ]; then
    printf 'FAILED %s: fetch timed out after %ss\n' "$name" "$(sync_timeout)"
    return 1
  elif [ "$frc" != 0 ]; then
    printf 'FAILED %s: fetch origin failed (exit %s)\n' "$name" "$frc"
    return 1
  fi

  branch="$(ac_default_branch "$repo")"
  cur="$(git -C "$repo" symbolic-ref --quiet --short HEAD || true)"
  behind="$(git -C "$repo" rev-list --count \
    "refs/heads/$branch..refs/remotes/origin/$branch" 2>/dev/null || printf 0)"
  ahead="$(git -C "$repo" rev-list --count \
    "refs/remotes/origin/$branch..refs/heads/$branch" 2>/dev/null || printf 0)"

  if [ "$behind" = 0 ]; then
    printf 'fresh %s\n' "$name"
  elif [ "$cur" != "$branch" ]; then
    printf 'STUCK %s: checked out %s, not %s (%s commits behind)\n' \
      "$name" "${cur:-detached HEAD}" "$branch" "$behind"
    rc=1
  elif [ -n "$(git -C "$repo" status --porcelain 2>/dev/null | grep -v '^??' || true)" ]; then
    printf 'STUCK %s: dirty tree (%s commits behind)\n' "$name" "$behind"
    rc=1
  elif [ "$ahead" != 0 ]; then
    printf 'STUCK %s: diverged, ahead %s (%s commits behind)\n' \
      "$name" "$ahead" "$behind"
    rc=1
  else
    old="$(git -C "$repo" rev-parse --short HEAD)"
    if git -C "$repo" merge --ff-only --quiet "origin/$branch" >/dev/null 2>&1; then
      new="$(git -C "$repo" rev-parse --short HEAD)"
      printf 'synced %s: %s %s..%s\n' "$name" "$branch" "$old" "$new"
    else
      printf 'STUCK %s: fast-forward failed (%s commits behind)\n' "$name" "$behind"
      rc=1
    fi
  fi

  prune_gone_branches "$repo" "$name"
  return "$rc"
}

main() {
  local target="${1:-}" bad=0 found=0 pdir d repo
  case "$target" in
    -*) usage ;;
  esac
  [ $# -le 1 ] || usage
  if [ -n "$target" ]; then
    repo="$(ac_project_dir "$target")" || ac_die "no such project: $target"
    sync_project "$repo" || bad=1
  else
    pdir="$(ac_projects_dir)"
    for d in "$pdir"/*/; do
      [ -d "$d" ] || continue
      found=1
      if ! git -C "$d" rev-parse --git-dir >/dev/null 2>&1; then
        ac_warn "skip $(basename "$d"): not a git repository"
        continue
      fi
      sync_project "$(cd "$d" && pwd -P)" || bad=1
    done
    [ "$found" = 1 ] || ac_warn "no projects under $pdir"
  fi
  exit "$bad"
}

main "$@"
