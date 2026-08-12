#!/usr/bin/env bash
# ac-peek.sh - bounded tail of a crewmate's pane.
#
# Usage: ac-peek.sh <id> [<lines>]   (default 40 lines)

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-backend.sh"
[ ! -x "$(dirname "$0")/ac-guard.sh" ] || "$(dirname "$0")/ac-guard.sh" || true  # warn-only advisory

id="${1:-}"; lines="${2:-40}"
[ -n "$id" ] || ac_die "usage: ac-peek.sh <id> [<lines>]"
[ -f "$(ac_task_meta "$id")" ] || ac_die "no crewmate meta for $id"
AC_BACKEND="$(ac_task_backend "$id")"; export AC_BACKEND
# Three-state liveness (contract: ac-backend.sh WINDOW LIVENESS): both refusals
# exit 1 as before, but they name DIFFERENT facts - a pane that is gone stays
# gone, while a backend nobody can read is no evidence the crewmate died.
alive_rc=0
backend_window_alive "$id" || alive_rc=$?
case "$alive_rc" in
  0) ;;
  2) ac_die "the BACKEND could not be read for $id - the pane's liveness is UNKNOWN and no work is lost; check the backend itself (herdr status server), then peek again" ;;
  *) ac_die "window gone for $id" ;;
esac
# Prefixed, never merely indented: AC_CAPTAIN_RE's negated class still
# permits whitespace, so an indent alone keeps a marker matching at line
# start (contract: F13/AC_CAPTAIN_RE, bin/ac-lib.sh). A crewmate's own
# captain-marker line, reprinted verbatim, must not read as a fresh marker
# from whichever pane is running this - the fleet watcher polls it too.
backend_capture "$id" "$lines" | sed '/^$/d' | tail -n "$lines" | sed 's/^/peek| /'
