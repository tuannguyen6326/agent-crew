#!/usr/bin/env bash
# ac-pool-health.sh - render the worktree-pool health ride-along for the
# session-start digest (AGENTS.md section 6): per project repo, how many
# .crew/slots pool slots are leasable vs stuck available-dirty (unleasable
# until a chief runs `ac-tree.sh remove --force <path>` - `get` skips a dirty
# slot by design and never resets it silently, and this script never does
# either) vs broken (worktree dir survives, gitdir unreadable - `ac-tree.sh
# list` reports this as its own `broken` state, never silently as `available`,
# because is_dirty is blind on such a tree) vs aged-leased (a durable lease -
# empty owner_pid, ac-tree.sh:417-424 "No owner = durable" - held past
# AGED_LEASE_THRESHOLD_SECS with no reclaim path of its own: acquire_slot,
# prune_pass and remove_slot all skip a leased slot by design, so nothing
# else ever names it). Reads pool state ONLY via `ac-tree.sh list --repo
# <repo>`, never by re-deriving lease/dirty/broken state itself; age is
# computed from the leased_at/owner_pid fields that wire already carries, not
# derived some other way.
#
# The aged-leased signal is SUSPICION, not death: an absent state/<id>.meta
# for the holder proves nothing while the holder may simply not have
# published it yet (ship-review-receipt-deadlocks, bin/ac-verify.sh:299 leases
# at :299, publishes meta only at :957). This script never reclaims, resets
# or expires anything - it only names the slot and the exact `remove
# --include-leased` a chief may choose to run: that command's own
# broken/dirty/unmerged gates (remove_slot, bin/ac-tree.sh:829-855) stay
# armed without --force, so it REFUSES instead of discarding if the slot
# still holds real content - the confirmation the hint asks for, enforced
# rather than merely requested.
#
# Renders NOTHING when every scanned pool is healthy (0 stuck-dirty, 0 broken
# and 0 aged-leased slots total) - same "quiet unless there is a signal" shape
# as the clone-staleness block in ac-session-start.sh. Always exits 0: a
# health hint must never block the digest.
#
# Usage: ac-pool-health.sh [--repo <path>]...
#   --repo <path>  scan exactly this repo instead of discovering project
#                   repos under ac_projects_dir. Repeatable. Test seam only.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

bin_dir="$(cd "$(dirname "$0")" && pwd -P)"

# A lease older than this is reported as SUSPICIOUS, never as dead: 24h is
# well past any single-session direct-flow task this fleet runs (config/flow
# is pinned direct - AGENTS.md section 5 - so no task here is expected to
# span days), while still comfortably covering the longest realistic
# single-run holder (a multi-round review/QA verifier lease), so a
# legitimately long-running holder is not libelled by it.
AGED_LEASE_THRESHOLD_SECS=86400

lease_age_secs() {
  # lease_age_secs <iso> - whole seconds since an ac_iso (%Y-%m-%dT%H:%M:%SZ)
  # timestamp, or empty on a malformed/empty one. macOS `date -j`; no GNU
  # dependency (same seam as ac-learn.sh's learn_age_days).
  local then
  [ -n "$1" ] || return 0
  then="$(date -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" '+%s' 2>/dev/null)" || return 0
  [ -n "$then" ] || return 0
  printf '%s\n' $(( $(ac_now) - then ))
}

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
  leasable=0 total=0 stuck=0 broken=0 aged=0
  slot_lines="" broken_lines="" aged_lines=""
  while IFS=$'\t' read -r n state task wt leased_at owner; do
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
      leased|"leased dirty")
        [ -z "$owner" ] || continue
        age="$(lease_age_secs "$leased_at")"
        [ -n "$age" ] && [ "$age" -ge "$AGED_LEASE_THRESHOLD_SECS" ] || continue
        aged=$((aged + 1))
        aged_lines="${aged_lines}  slot $n  $task  leased $((age / 3600))h ago  $wt
"
        ;;
    esac
  done < <("$bin_dir/ac-tree.sh" list --repo "$repo" 2>/dev/null)

  [ "$stuck" -ge 1 ] || [ "$broken" -ge 1 ] || [ "$aged" -ge 1 ] || continue
  hints=""
  [ "$stuck" -ge 1 ] && hints="${hints}  reclaim each dirty slot: bin/ac-tree.sh remove --force <worktree-path>
"
  [ "$broken" -ge 1 ] && hints="${hints}  reclaim each broken slot: bin/ac-tree.sh remove --force <worktree-path>
"
  [ "$aged" -ge 1 ] && hints="${hints}  reclaim each aged lease (the broken/dirty/unmerged gates stay armed - it refuses instead of discarding if the slot still holds real content): bin/ac-tree.sh remove --include-leased <worktree-path>
"
  block="${block}$(basename "$repo"): $leasable leasable / $total total, $stuck stuck-dirty (unleasable), $broken broken (unleasable), $aged aged-leased (>=$((AGED_LEASE_THRESHOLD_SECS / 3600))h, unconfirmed)
${hints}${slot_lines}${broken_lines}${aged_lines}"
done

if [ -n "$block" ]; then
  printf -- '-- pool (worktree health) --\n'
  printf '%s' "$block"
fi

exit 0
