#!/usr/bin/env bash
# ac-qa-watch.sh - live dashboard for a qa run (the ac-ship-watch role,
# adapted to the qa pipeline): one screen per refresh showing the run header,
# the step table with the ACTIVE step marked, the CASE LEDGER (pass/fail/
# unverifiable + per-tier and recent rows), per-step findings summaries, and
# the tail of the run log. Read-only.
#
#   ac-qa-watch.sh [--repo DIR] [--self-pane ID] [--interval SECS] [--once]
#
# Auto-open/auto-close contract (mirrors ac-ship-watch): ac-qa.sh start opens
# this in a herdr tab (label ac-qa-watch) and records the pane in
# <run>/watch.pane; the watch SELF-CLOSES its pane when the run finishes
# (outcome != running, after a short linger) or when the run goes idle for
# AC_QA_WATCH_IDLE secs (default 1800) - and ac-qa.sh finish also closes it
# belt-and-suspenders. Without --self-pane it just exits (foreground use).
# Session: AC_HERDR_SESSION > config/herdr-session > default.
# The rendering/loop body shared with ac-ship-watch.sh lives in
# ac-watch-dash.sh (F28); this file owns only the qa-specific shape.
set -u
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-watch-dash.sh"

ac_watch_dash_args "$@"
RUN_BASE="$REPO/.crew/qa"
STEP_WIDTH=12
IDLE_EXTRA_FILES="cases.tsv"
FINDINGS_HDR="── findings ──"
LOG_HDR="── log ──"
NO_RUN_MSG="no active qa run in $REPO"
WAIT_MSG="waiting for a qa run in $REPO ..."
idle_limit() { printf '%s' "${AC_QA_WATCH_IDLE:-1800}"; }

outcome_color() {
  case "$1" in
    running) printf '%s' "$c_cyn" ;;
    passed) printf '%s' "$c_grn" ;;
    failed) printf '%s' "$c_red" ;;
    unverifiable) printf '%s' "$c_yel" ;;
    *) printf '%s' "$c_dim" ;;
  esac
}

render_header() {
  local rd="$1" id target task outcome
  id="$(basename "$rd")"
  target="$(ac_meta_get "$rd/run.meta" target)"
  task="$(ac_meta_get "$rd/run.meta" task)"
  outcome="$(ac_meta_get "$rd/run.meta" outcome)"
  printf '%sac-qa%s %s%s%s  %srun %s%s  [%s%s%s]\n' \
    "$c_b" "$c_r" "$c_cyn" "$task" "$c_r" "$c_dim" "$id" "$c_r" \
    "$(outcome_color "$outcome")" "$outcome" "$c_r"
  printf '%starget:%s %.110s\n\n' "$c_dim" "$c_r" "$target"
}

render_extra() {
  local rd="$1"
  [ -s "$rd/cases.tsv" ] || return 0
  local p f u
  p="$(awk -F'\t' '$3=="pass"' "$rd/cases.tsv" | wc -l | tr -d ' ')"
  f="$(awk -F'\t' '$3=="fail"' "$rd/cases.tsv" | wc -l | tr -d ' ')"
  u="$(awk -F'\t' '$3=="unverifiable"' "$rd/cases.tsv" | wc -l | tr -d ' ')"
  printf '\n%s── cases ─%s %s%s pass%s  %s%s fail%s  %s%s unverifiable%s\n' \
    "$c_dim" "$c_r" "$c_grn" "$p" "$c_r" "$c_red" "$f" "$c_r" "$c_yel" "$u" "$c_r"
  tail -n 8 "$rd/cases.tsv" | awk -F'\t' \
    -v g="$c_grn" -v rd_="$c_red" -v y="$c_yel" -v d="$c_dim" -v rst="$c_r" '{
    col = (($3=="pass") ? g : ($3=="fail") ? rd_ : y)
    gl  = (($3=="pass") ? "✓" : ($3=="fail") ? "✗" : "?")
    printf "   %s%s%s %-22s %s%-4s%s %-13s %s%s%s\n", col, gl, rst, $1, d, $2, rst, $3, d, ($6=="-"?"":"grade "$6), rst
  }'
}

ac_watch_dash_main
