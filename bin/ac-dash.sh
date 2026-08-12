#!/usr/bin/env bash
# ac-dash.sh - the captain dashboard, run in the terminal: fleet header,
# crew states, the rooms
# inbox, backlog counts, and per-project worktree pools.
#
# Usage:
#   ac-dash.sh                # render once
#   ac-dash.sh --watch [<s>]  # redraw every <s> seconds (default 5); ctrl-c to stop
#
# Colors auto-disable when stdout is not a tty or NO_COLOR is set.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-backend.sh"

bin_dir="$(cd "$(dirname "$0")" && pwd -P)"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_H=$'\033[1;36m'; C_G=$'\033[32m'; C_Y=$'\033[33m'; C_R=$'\033[1;31m'
  C_D=$'\033[2m'; C_0=$'\033[0m'
else
  C_H=""; C_G=""; C_Y=""; C_R=""; C_D=""; C_0=""
fi

state_color() {
  # state_color <state-line> - pick a color for a crew state.
  case "$1" in
    *done:*|*resolved:*) printf '%s' "$C_G" ;;
    *blocked:*|*failed:*|*needs-decision:*|gone*) printf '%s' "$C_R" ;;
    *) printf '%s' "$C_Y" ;;
  esac
}

render() {
  printf '%s⚓ %s%s  %scaptain:%s %s  %sbackend:%s %s  %sflow:%s %s\n' \
    "$C_H" "$(basename "$(ac_home)")" "$C_0" \
    "$C_D" "$C_0" "$(ac_captain)" \
    "$C_D" "$C_0" "$(ac_config_read backend herdr)" \
    "$C_D" "$C_0" "$(ac_config_read flow auto)"

  printf '\n%sCREW%s\n' "$C_H" "$C_0"
  local meta id kind project state row found=0 verify_found=0 verify_lines=""
  for meta in "$(ac_state_dir)"/*.meta; do
    [ -e "$meta" ] || continue
    id="$(basename "$meta" .meta)"
    kind="$(ac_meta_get "$meta" kind)"
    project="$(ac_meta_get "$meta" project)"
    state="$("$bin_dir/ac-crew-state.sh" "$id" 2>/dev/null || printf 'unknown')"
    row="$(printf '  %s%-16s%s %-10s %-14s %s%s%s' \
      "$C_0" "$id" "$C_0" "$kind" "$project" "$(state_color "$state")" "$state" "$C_0")"
    if ac_meta_is_verify "$meta"; then
      verify_found=1
      verify_lines="${verify_lines}${row}
"
    else
      found=1
      printf '%s\n' "$row"
    fi
  done
  [ "$found" = 1 ] || printf '  %s(no crewmates in flight)%s\n' "$C_D" "$C_0"

  # Verification agents (ac_meta_is_verify owns the class) get their own
  # heading, rendered only when at least one exists - mirroring
  # ac-fleets.sh:388-390.
  if [ "$verify_found" = 1 ]; then
    printf '\n%sVERIFY (verification agents, not crew)%s\n' "$C_H" "$C_0"
    printf '%s' "$verify_lines"
  fi

  printf '\n%sROOMS (captain inbox)%s\n' "$C_H" "$C_0"
  "$bin_dir/ac-room.sh" list | while IFS= read -r line; do
    case "$line" in
      PENDING-CAPTAIN*) printf '  %s%s%s\n' "$C_R" "$line" "$C_0" ;;
      *) printf '  %s%s%s\n' "$C_D" "$line" "$C_0" ;;
    esac
  done

  printf '\n%sBACKLOG%s' "$C_H" "$C_0"
  local bl
  bl="$(ac_records_dir)/backlog.md"
  if [ -f "$bl" ]; then
    # "done" means real done, not Done-SECTION membership - a [failed]/
    # [abandoned] row is terminal but not done (same-done-miscount-in-three-
    # more-surfaces; two-dashboards lead, ac-dash-crew-heading-swallows-
    # verifiers). Reuses AC_DONELINE_AWK's ac_doneline terminal field, the
    # same position-pinned parser ac-ready.sh's snapshot() uses, never a
    # second marker parser.
    awk "$AC_DONELINE_AWK"'
      /^## In flight/ { s = "f"; next }
      /^## Queued/ { s = "q"; next }
      /^## Done/ { s = "d"; next }
      /^- \[/ && s == "d" {
        ac_doneline($0, o)
        if (o["terminal"] != "failed" && o["terminal"] != "abandoned") d++
        next
      }
      /^- \[/ { if (s == "f") f++; else if (s == "q") q++ }
      END { printf "  in-flight:%d  queued:%d  done:%d\n", f, q, d }
    ' "$bl"
  else
    printf '  %s(no backlog yet)%s\n' "$C_D" "$C_0"
  fi

  printf '\n%sPOOLS%s\n' "$C_H" "$C_0"
  local slots proj leased avail m
  found=0
  for slots in "$(ac_projects_dir)"/*/.crew/slots; do
    [ -d "$slots" ] || continue
    found=1
    proj="$(basename "$(dirname "$(dirname "$slots")")")"
    leased=0; avail=0
    for m in "$slots"/*.meta; do
      [ -f "$m" ] || continue
      if [ "$(ac_meta_get "$m" leased)" = "1" ]; then leased=$((leased + 1)); else avail=$((avail + 1)); fi
    done
    printf '  %-20s leased:%s avail:%s\n' "$proj" "$leased" "$avail"
  done
  [ "$found" = 1 ] || printf '  %s(no worktree pools yet)%s\n' "$C_D" "$C_0"
}

case "${1:-}" in
  --watch)
    interval="${2:-5}"
    trap 'exit 0' INT
    while :; do
      clear
      render
      printf '\n%s(refreshing every %ss - ctrl-c to stop)%s\n' "$C_D" "$interval" "$C_0"
      sleep "$interval"
    done
    ;;
  "")
    render
    ;;
  *) printf 'usage: ac-dash.sh [--watch [<seconds>]]\n' >&2; exit 2 ;;
esac
