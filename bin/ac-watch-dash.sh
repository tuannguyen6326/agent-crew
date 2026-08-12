#!/usr/bin/env bash
# ac-watch-dash.sh - shared body for the ac-ship-watch/ac-qa-watch live
# dashboards (F28): arg parsing, colors, the step table, findings/log
# rendering, paint, and the idle/refresh main loop. Sourced only - never an
# entry point itself. The two entry-point scripts stay real, directly
# executable ac-ship-watch.sh / ac-qa-watch.sh: a herdr `pane run` string and
# the tests both embed those two names, and each script's own header states
# its role's auto-open/auto-close contract.
#
# A caller sources this (after ac-lib.sh), sets its role config, defines its
# own render_header/render_extra/on_finish/outcome_color, then calls
# ac_watch_dash_main:
#   RUN_BASE          - the run root (<repo>/.crew/ship or .crew/qa)
#   STEP_WIDTH         - status column width for the step table (%-<n>s)
#   FINDINGS_HDR       - the "── findings ──..." separator line for this role
#   LOG_HDR            - the "── log ──..." separator line for this role
#   ACTIVE_STATUSES     - space-separated step statuses counted as ACTIVE
#                        besides running/fixing (ship adds awaiting_approval,
#                        qa adds nothing - the one real per-role behavior
#                        difference the merge must preserve)
#   IDLE_EXTRA_FILES    - extra run-dir files (besides steps.tsv/run.log)
#                        idle_since also watches ("" for none, "cases.tsv"
#                        for qa)
#   NO_RUN_MSG/WAIT_MSG - the --once/live "no run"/"waiting" text
#   idle_limit()        - function returning this role's idle-timeout seconds
# render_extra/on_finish default to no-ops below; a role overrides only what
# it needs (ship overrides on_finish, qa overrides render_extra).


# Colors only on a tty (the herdr pane) - captured output stays plain so
# tests and pipes see stable text. The interactive pane keeps the richer view.
if [ -t 1 ]; then
  c_r=$'\033[0m'; c_b=$'\033[1m'; c_dim=$'\033[2m'
  c_grn=$'\033[32m'; c_cyn=$'\033[36m'; c_yel=$'\033[33m'; c_mag=$'\033[35m'; c_red=$'\033[31m'
else
  c_r=""; c_b=""; c_dim=""; c_grn=""; c_cyn=""; c_yel=""; c_mag=""; c_red=""
fi

IDLE_EXTRA_FILES=""
ACTIVE_STATUSES=""

ac_watch_dash_args() {
  # ac_watch_dash_args "$@" - parse the shared CLI and resolve REPO/SES.
  REPO="$PWD"; SELF=""; INTERVAL=2; ONCE=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --repo) REPO=${2:?}; shift ;;
      --self-pane) SELF=${2:?}; shift ;;
      --interval) INTERVAL=${2:?}; shift ;;
      --once) ONCE=1 ;;
      *) ac_die "unknown arg: $1" ;;
    esac
    shift
  done
  REPO="$(cd "$REPO" && git rev-parse --show-toplevel 2>/dev/null)" || ac_die "not a git repo: $REPO"
  SES="${AC_HERDR_SESSION:-$(ac_config_read herdr-session default)}"
}

self_close() {
  [ -n "$SELF" ] || exit 0
  command -v herdr >/dev/null 2>&1 && herdr --session "$SES" pane close "$SELF" >/dev/null 2>&1
  exit 0
}

render_extra() { :; }
on_finish() { :; }

render_steps() {
  local rd="$1" step status rounds glyph color extra
  while IFS=$'\t' read -r step status rounds; do
    glyph="○"; color="$c_dim"; extra=""
    case "$status" in
      completed) glyph="✓"; color="$c_grn" ;;
      running)   glyph="▶"; color="$c_cyn" ;;
      fixing)    glyph="▶"; color="$c_yel" ;;
      awaiting_approval) glyph="⏸"; color="$c_mag" ;;
      failed)    glyph="✗"; color="$c_red" ;;
      skipped)   glyph="-"; color="$c_dim" ;;
    esac
    [ "${rounds:-0}" -gt 0 ] 2>/dev/null && extra="${c_dim}round $rounds${c_r}"
    printf ' %s%s%s %-10s %s%-*s%s %s\n' \
      "$color" "$glyph" "$c_r" "$step" "$color" "$STEP_WIDTH" "$status" "$c_r" "$extra"
  done <"$rd/steps.tsv"
}

render_findings() {
  local rd="$1" f fstep counts ccolor shown=0
  for f in "$rd/findings/"*.json; do
    [ -f "$f" ] || continue
    case "$f" in *.meta.json) continue ;; esac
    counts="$(jq -r 'if length == 0 then "" else group_by(.action) | map("\(.[0].action)=\(length)") | join("  ") end' "$f" 2>/dev/null)"
    [ -n "$counts" ] || continue
    [ "$shown" = 0 ] && { printf '\n%s%s%s\n' "$c_dim" "$FINDINGS_HDR" "$c_r"; shown=1; }
    fstep="$(basename "$f" .json)"
    ccolor="$c_dim"
    case "$counts" in *ask-user*) ccolor="$c_mag" ;; *fix*) ccolor="$c_yel" ;; esac
    printf ' findings %-9s %s%s%s\n' "$fstep" "$ccolor" "$counts" "$c_r"
  done
}

render_log() {
  local rd="$1" COLS="$2"
  [ -f "$rd/logs/run.log" ] || return 0
  printf '\n%s%s%s\n' "$c_dim" "$LOG_HDR" "$c_r"
  tail -n 6 "$rd/logs/run.log" | awk -v dim="$c_dim" -v rst="$c_r" -v w="$COLS" '{
    ts = $1; sub(/^[^ ]+ /, "", $0)
    t = ts; sub(/^.*T/, "", t); sub(/Z$/, "", t)
    line = " " dim t rst "  " $0
    if (length(line) > w) line = substr(line, 1, w - 1) "…"
    print line
  }'
}

render() {
  # render <run-dir> - one full frame on stdout.
  local rd="$1" COLS
  COLS="$( (tput cols 2>/dev/null || echo 200) | head -1)"
  render_header "$rd"
  render_steps "$rd"
  render_extra "$rd"
  render_findings "$rd"
  render_log "$rd" "$COLS"
}

idle_since() {
  # newest mtime across the run's live files (steps + log + role extras).
  local rd="$1" m1 m2 m3 f
  m1=$(ac_file_mtime "$rd/steps.tsv") || m1=0
  m2=$(ac_file_mtime "$rd/logs/run.log") || m2=0
  [ "$m2" -gt "$m1" ] && m1="$m2"
  for f in $IDLE_EXTRA_FILES; do
    m3=$(ac_file_mtime "$rd/$f") || m3=0
    [ "$m3" -gt "$m1" ] && m1="$m3"
  done
  printf '%s\n' "$m1"
}

paint() {
  # Flicker-free repaint: overwrite from home, clear each line's tail (\033[K)
  # and whatever remains below (\033[J) - no full-screen clear, no flash.
  printf '\033[H%s\033[J\n' "$(printf '%s\n' "$1" | sed $'s/$/\033[K/')"
}

is_active() {
  local rd="$1" st cond="\$2 == \"running\" || \$2 == \"fixing\""
  for st in $ACTIVE_STATUSES; do
    cond="$cond || \$2 == \"$st\""
  done
  awk -F'\t' "$cond"' { print $1; exit }' "$rd/steps.tsv"
}

ac_watch_dash_main() {
  local waited=0 last_frame="" rd outcome active frame
  if [ "$ONCE" = 0 ]; then
    printf '\033[2J\033[H\033[?25l'
    trap 'printf "\033[?25h"' EXIT
  fi
  while :; do
    if [ -L "$RUN_BASE/current" ]; then
      rd="$RUN_BASE/$(readlink "$RUN_BASE/current")"
      if [ "$ONCE" = 1 ]; then
        render "$rd"
      else
        frame="$(render "$rd")"
        if [ "$frame" != "$last_frame" ]; then paint "$frame"; last_frame="$frame"; fi
      fi
      outcome="$(ac_meta_get "$rd/run.meta" outcome)"
      # A reopened run (finish recorded, then a step re-entered running/fixing
      # under hold-and-fix) is NOT done: close only when no step is active.
      active="$(is_active "$rd")"
      if [ "$outcome" != running ] && [ -z "$active" ]; then
        printf 'run finished: %s\n' "$outcome"
        [ "$ONCE" = 1 ] && exit 0
        on_finish "$rd"
        sleep 5
        self_close
      fi
      if [ "$ONCE" = 1 ]; then exit 0; fi
      if [ $(( $(ac_now) - $(idle_since "$rd") )) -gt "$(idle_limit)" ]; then
        printf '\nrun idle too long - closing watch\n'
        sleep 2
        self_close
      fi
    else
      [ "$ONCE" = 1 ] && { printf '%s\n' "$NO_RUN_MSG"; exit 0; }
      frame="$WAIT_MSG"
      [ "$frame" = "$last_frame" ] || { paint "$frame"; last_frame="$frame"; }
      waited=$((waited + INTERVAL))
      [ "$waited" -gt 300 ] && self_close
    fi
    sleep "$INTERVAL"
  done
}
