#!/usr/bin/env bash
# ac-standing-jobs.sh - render the standing-jobs digest block for the
# session-start digest: reports each DECLARED job's state from
# records/standing-jobs.md, with the exact re-create action.
#
# CronCreate is SESSION-ONLY: the job lives in harness session memory, is
# never written to disk, and dies with the session (the CronCreate tool's own session-only contract). There is
# therefore no on-disk signal this script can read to tell whether a
# declared job is actually alive THIS session - so it never claims
# PRESENT/MISSING. It reports the DECLARED state (on/off) plus the exact
# re-create action, and tells the chief to run CronList to confirm actual
# liveness. A digest line that claimed a job was live when it cannot know
# that would be a worse defect than the invisible-cron failure this exists
# to surface.
#
# records/standing-jobs.md is the machine-readable source of truth for a
# job's current declared state - a fleet's captain.md should CITE it rather
# than duplicate cadence/on-off/re-create text, which would drift.
#
# Line format (one job per line):
#   - <id> [on|off] cadence:<cadence> recreate:<exact re-create action>
# Mirrors the records/projects.md bracket grammar (ac_project_mode).
#
# Usage: ac-standing-jobs.sh [--ids]
#
# --ids prints one declared id per line, in file order, and nothing else - no
# header, no grading. It exists so the OTHER reader of this grammar
# (bin/ac-rig.sh's standing_jobs class) never re-derives the id itself: the
# grammar has exactly one parser, in the file AGENTS.md section 2 names as its
# owner, which is what section 13's one-contract-one-file rule requires. Same
# shape as bin/ac-pool-health.sh reading pool state only through `ac-tree.sh
# list` instead of re-deriving it. Both modes walk the SAME loop and the same
# line selection, so there is no second copy to drift.
#
# Always prints its "-- standing jobs --" header, unlike the pool-health
# ride-along which stays silent when healthy: a standing job with no
# declaration on disk is exactly the invisible-cron failure this exists to
# surface, so silence here would recreate the defect it fixes.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

mode=digest
case "${1:-}" in
  --ids) mode=ids ;;
  '') : ;;
  *) ac_die "usage: ac-standing-jobs.sh [--ids]" ;;
esac

[ "$mode" = ids ] || printf -- '-- standing jobs --\n'

f="$(ac_records_dir)/standing-jobs.md"
if [ ! -s "$f" ]; then
  [ "$mode" = ids ] || printf '(no standing-jobs declaration - records/standing-jobs.md)\n'
  exit 0
fi
# --ids ONLY: an unreadable file would otherwise print nothing and still exit
# 0, and its consumer cannot tell that empty set from "no jobs declared" - it
# would report every declared job as missing. The digest path keeps its own
# behaviour untouched: it renders prose a human reads, and the shell's own
# redirect error is already visible there.
if [ "$mode" = ids ] && [ ! -r "$f" ]; then
  ac_die "records/standing-jobs.md is not readable - refusing to report an empty id set"
fi

found=0
while IFS= read -r line; do
  case "$line" in
    "- "*"["*"]"*) : ;;
    *) continue ;;
  esac
  found=1
  id="$(sed -n 's/^- \([^ ]*\) .*/\1/p' <<<"$line")"
  if [ "$mode" = ids ]; then
    [ -n "$id" ] && printf '%s\n' "$id"
    continue
  fi
  state="$(sed -n 's/^- [^[]*\[\([^]]*\)\].*/\1/p' <<<"$line")"
  cadence="$(sed -n 's/.*cadence:\(.*\) recreate:.*/\1/p' <<<"$line")"
  recreate="$(sed -n 's/.*recreate:\(.*\)$/\1/p' <<<"$line")"
  [ -n "$id" ] || continue
  case "$state" in
    on)
      printf '%s: declared ON (cadence: %s) - runtime liveness unverifiable from disk (CronCreate is session-only); run CronList to confirm, re-create if missing: %s\n' \
        "$id" "$cadence" "$recreate"
      ;;
    off)
      printf '%s: declared OFF - do not re-create (%s)\n' "$id" "$recreate"
      ;;
    *)
      printf '%s: unknown declared state [%s] in records/standing-jobs.md - fix the line\n' "$id" "$state"
      ;;
  esac
done <"$f"

[ "$mode" = ids ] || [ "$found" -eq 1 ] || printf '(records/standing-jobs.md has no declared job lines)\n'

exit 0
