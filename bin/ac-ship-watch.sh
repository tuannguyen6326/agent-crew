#!/usr/bin/env bash
# ac-ship-watch.sh - live dashboard for a crew-ship run: one screen per
# refresh showing the run header, the step table with
# the ACTIVE step marked, fix rounds, per-step findings summaries, and the
# tail of the run log. Read-only.
#
#   ac-ship-watch.sh [--repo DIR] [--self-pane ID] [--interval SECS] [--once]
#
# Auto-open/auto-close contract: ac-ship.sh start
# opens this in a herdr tab (label ac-ship-watch) and records the pane in
# <run>/watch.pane; the watch SELF-CLOSES its pane when the run finishes
# (outcome != running, after a short linger) or when the run goes idle for
# AC_SHIP_WATCH_IDLE secs (default 1800) - and ac-ship.sh finish also closes
# it belt-and-suspenders. Without --self-pane it just exits instead of
# closing anything (foreground use).
# Session: AC_HERDR_SESSION > config/herdr-session > default.
# The rendering/loop body shared with ac-qa-watch.sh lives in
# ac-watch-dash.sh (F28); this file owns only the crew-ship-specific shape.
set -u
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-watch-dash.sh"

ac_watch_dash_args "$@"
RUN_BASE="$REPO/.crew/ship"
STEP_WIDTH=18
ACTIVE_STATUSES="awaiting_approval"
FINDINGS_HDR="── findings ─────────────────────"
LOG_HDR="── log ──────────────────────────"
NO_RUN_MSG="no active crew-ship run in $REPO"
WAIT_MSG="waiting for a crew-ship run in $REPO ..."
idle_limit() { printf '%s' "${AC_SHIP_WATCH_IDLE:-1800}"; }

outcome_color() {
  case "$1" in
    running) printf '%s' "$c_cyn" ;;
    checks-passed|passed) printf '%s' "$c_grn" ;;
    failed) printf '%s' "$c_red" ;;
    *) printf '%s' "$c_dim" ;;
  esac
}

render_header() {
  local rd="$1" id intent branch outcome
  id="$(basename "$rd")"
  intent="$(ac_meta_get "$rd/run.meta" intent)"
  branch="$(ac_meta_get "$rd/run.meta" branch)"
  outcome="$(ac_meta_get "$rd/run.meta" outcome)"
  printf '%sac-ship%s %s%s%s  %srun %s%s  [%s%s%s]\n' \
    "$c_b" "$c_r" "$c_cyn" "$branch" "$c_r" "$c_dim" "$id" "$c_r" \
    "$(outcome_color "$outcome")" "$outcome" "$c_r"
  printf '%sintent:%s %.110s\n\n' "$c_dim" "$c_r" "$intent"
}

on_finish() {
  # Belt-and-suspenders: retire a reviewer pane the (earlier) finish
  # missed - a reopened run's last review round outlives that finish.
  local rd="$1"
  if [ -f "$rd/review.pane" ] && command -v herdr >/dev/null 2>&1; then
    herdr --session "$SES" pane close "$(cat "$rd/review.pane")" >/dev/null 2>&1
    rm -f "$rd/review.pane"
  fi
}

ac_watch_dash_main
