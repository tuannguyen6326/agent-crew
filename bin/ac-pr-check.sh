#!/usr/bin/env bash
# ac-pr-check.sh - record a crewmate's PR and its head SHA on the task meta.
#
# Usage: ac-pr-check.sh <id> <github-pr-url>
# Records pr= (the captain-facing PR link) and pr_head= (the PR's head SHA at
# record time) on the task meta. Informational only: nothing currently reads
# either field back - teardown's landed check gates on pr_merged=1, set
# separately by ac-pr-merge.sh.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
ac_require gh

id="${1:-}"; url="${2:-}"
[ -n "$id" ] && [ -n "$url" ] || ac_die "usage: ac-pr-check.sh <id> <pr-url>"
meta="$(ac_task_meta "$id")"
[ -f "$meta" ] || ac_die "no crewmate meta for $id"
case "$url" in
  https://github.com/*/*/pull/[0-9]*) ;;
  *) ac_die "not a full GitHub PR URL: $url" ;;
esac

head="$(gh pr view "$url" --json headRefOid --jq .headRefOid)"
state="$(gh pr view "$url" --json state --jq .state)"
ac_meta_set "$meta" pr "$url"
ac_meta_set "$meta" pr_head "$head"
ac_status_append "$id" "PR ready: $url ($state)"
printf 'recorded pr=%s pr_head=%s state=%s\n' "$url" "$head" "$state"
