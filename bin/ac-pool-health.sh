#!/usr/bin/env bash
# ac-pool-health.sh - render the worktree-pool health ride-along for the
# session-start digest (AGENTS.md section 6): per project repo, how many
# .crew/slots pool slots are leasable vs stuck available-dirty (unleasable
# until a chief runs `ac-tree.sh remove --force <path>` - `get` skips a dirty
# slot by design and never resets it silently, and this script never does
# either) vs broken (worktree dir survives, gitdir unreadable - `ac-tree.sh
# list` reports this as its own `broken` state, never silently as `available`,
# because is_dirty is blind on such a tree). Reads pool state ONLY via
# `ac-tree.sh list --repo <repo>`, never by re-deriving lease/dirty/broken
# state itself.
#
# Renders NOTHING when every scanned pool is healthy (0 stuck-dirty and 0
# broken slots total) - same "quiet unless there is a signal" shape as the
# clone-staleness block in ac-session-start.sh. Always exits 0: a health hint
# must never block the digest.
#
# Usage: ac-pool-health.sh [--repo <path>]...
#   --repo <path>  scan exactly this repo instead of discovering project
#                   repos under ac_projects_dir. Repeatable. Test seam only.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

bin_dir="$(cd "$(dirname "$0")" && pwd -P)"

repos=()
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repos+=("$2"); shift 2 ;;
    *) ac_die "ac-pool-health.sh: unknown argument $1" ;;
  esac
done

if [ "${#repos[@]}" -eq 0 ]; then
  for p in "$(ac_projects_dir)"/*/; do
    [ -d "$p" ] || continue
    git -C "$p" rev-parse --git-dir >/dev/null 2>&1 || continue
    [ -d "$p/.crew/slots" ] || continue
    repos+=("$p")
  done
fi

block=""
for repo in "${repos[@]:-}"; do
  [ -n "$repo" ] || continue
  leasable=0 total=0 stuck=0 broken=0
  slot_lines="" broken_lines=""
  while IFS=$'\t' read -r n state task wt; do
    [ -n "$n" ] || continue
    total=$((total + 1))
    case "$state" in
      available) leasable=$((leasable + 1)) ;;
      "available dirty")
        stuck=$((stuck + 1))
        slot_lines="${slot_lines}  slot $n  $task  $wt
"
        ;;
      broken)
        broken=$((broken + 1))
        broken_lines="${broken_lines}  slot $n  $task  $wt
"
        ;;
    esac
  done < <("$bin_dir/ac-tree.sh" list --repo "$repo" 2>/dev/null)

  [ "$stuck" -ge 1 ] || [ "$broken" -ge 1 ] || continue
  hints=""
  [ "$stuck" -ge 1 ] && hints="${hints}  reclaim each dirty slot: bin/ac-tree.sh remove --force <worktree-path>
"
  [ "$broken" -ge 1 ] && hints="${hints}  reclaim each broken slot: bin/ac-tree.sh remove --force <worktree-path>
"
  block="${block}$(basename "$repo"): $leasable leasable / $total total, $stuck stuck-dirty (unleasable), $broken broken (unleasable)
${hints}${slot_lines}${broken_lines}"
done

if [ -n "$block" ]; then
  printf -- '-- pool (worktree health) --\n'
  printf '%s' "$block"
fi

exit 0
