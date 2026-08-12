#!/usr/bin/env bash
# ac-promote.sh - promote a scout task to a ship task IN PLACE.
#
# Usage: ac-promote.sh <id> [--mode <crew-ship|direct-pr|local-only>]
#
# A scout steered mid-flight into writing code on crew/<id> stops being a
# report-only task. Promoting rewrites state/<id>.meta (each key via the
# atomic per-key rewrite): kind=scout flips to kind=ship, and mode= is set
# from --mode when given, else from the project registry default
# (ac-project-mode.sh). From then on the FULL ship teardown protection
# applies: ac-teardown.sh demands landed proof for crew/<id> (contained in
# the default branch, a remote branch, or a merged PR) plus a clean
# worktree, instead of only a report.md.
#
# If the crewmate's window is still alive, a short ship-contract notice is
# sent to its pane via ac-send.sh: it now delivers a project change on
# crew/<id>, delivery per the recorded mode. A gone window is not an error -
# the promotion is recorded either way and says so.
#
# Exit codes: 0 promoted; 1 on usage error, unknown task, or a task whose
# kind is not scout.
# Files touched: state/<id>.meta (kind=, mode=), state/<id>.status (append).

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

bin_dir="$(cd "$(dirname "$0")" && pwd -P)"

id="${1:-}"
[ -n "$id" ] || ac_die "usage: ac-promote.sh <id> [--mode <crew-ship|direct-pr|local-only>]"
shift

mode_flag=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)
      mode_flag="${2:-}"
      [ -n "$mode_flag" ] || ac_die "missing value for --mode"
      shift 2 ;;
    *) ac_die "unknown argument: $1" ;;
  esac
done

meta="$(ac_task_meta "$id")"
[ -f "$meta" ] || ac_die "no crewmate meta for $id"

kind="$(ac_meta_get "$meta" kind)"
[ "$kind" = scout ] || ac_die "task $id is kind=${kind:-unset}, not scout (only scouts promote)"

# Delivery mode: --mode wins, else the project registry default.
if [ -n "$mode_flag" ]; then
  case "$mode_flag" in
    crew-ship|direct-pr|local-only) mode="$mode_flag" ;;
    *) ac_die "invalid --mode: $mode_flag (want crew-ship|direct-pr|local-only)" ;;
  esac
else
  project="$(ac_meta_get "$meta" project)"
  mode_line="$("$bin_dir/ac-project-mode.sh" "$project")"
  mode="${mode_line#mode=}"; mode="${mode%% *}"
fi

ac_meta_set "$meta" kind ship
ac_meta_set "$meta" mode "$mode"
ac_status_append "$id" "promoted: scout -> ship (mode=$mode)"

printf 'promoted %s: kind scout -> ship, mode=%s (ship teardown protection now applies)\n' \
  "$id" "$mode"

# Tell the live crewmate its contract changed (ac-send.sh fail-closes when
# the window is gone; a recorded promotion without a notice is still valid).
notice="NOTICE: this task was promoted to SHIP - deliver the project change on crew/$id; delivery per mode=$mode. A report alone no longer lands it."
if "$bin_dir/ac-send.sh" "$id" "$notice" >/dev/null 2>&1; then
  printf 'notified crewmate %s of the ship contract\n' "$id"
else
  printf 'crewmate window not reachable; promotion recorded in meta only\n'
fi
