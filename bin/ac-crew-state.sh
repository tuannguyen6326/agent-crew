#!/usr/bin/env bash
# ac-crew-state.sh - one deterministic current-state line for a crewmate.
#
# Usage: ac-crew-state.sh <id>
# Precedence: crew-ship run step > window gone/unobservable > pane busy > last
# status log line > idle. Output is a single line, safe to embed in fleet
# views. `unobservable: ...` means the BACKEND could not be read - the pane's
# liveness is UNKNOWN, never rendered as gone (contract: ac-backend.sh WINDOW
# LIVENESS).

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-backend.sh"

id="${1:-}"
[ -n "$id" ] || ac_die "usage: ac-crew-state.sh <id>"
meta="$(ac_task_meta "$id")"
[ -f "$meta" ] || ac_die "no crewmate meta for $id"
worktree="$(ac_meta_get "$meta" worktree)"
AC_BACKEND="$(ac_task_backend "$id")"; export AC_BACKEND

# 1. An active crew-ship run in the worktree wins.
steps="$worktree/.crew/ship/current/steps.tsv"
if [ -f "$steps" ]; then
  line="$(awk -F'\t' '$2 == "running" || $2 == "fixing" || $2 == "awaiting_approval" { print; exit }' "$steps")"
  if [ -n "$line" ]; then
    printf 'validate:%s\n' "$(tr '\t' ':' <<<"$line")"
    exit 0
  fi
fi

# 2. Window liveness (three-state, contract: ac-backend.sh WINDOW LIVENESS),
#    then busy heuristic on the pane tail.
alive_rc=0
backend_window_alive "$id" || alive_rc=$?
case "$alive_rc" in
  0) ;;
  2) printf 'unobservable: backend could not be read for %s\n' "$(backend_target "$id")"; exit 0 ;;
  *) printf 'gone\n'; exit 0 ;;
esac
tail="$(backend_capture "$id" 40 | sed '/^$/d' | tail -n 25)"
if grep -qE "$AC_BUSY_RE" <<<"$tail"; then
  printf 'busy\n'
  exit 0
fi

# 3. Last recorded status event, else idle. The re-emitted line is prefixed
#    (never merely indented - AC_CAPTAIN_RE's negated class still permits
#    whitespace, so an indent alone keeps matching at line start, contract:
#    F13/AC_CAPTAIN_RE, bin/ac-lib.sh): a crewmate's own captain-marker status
#    line (needs-decision:, blocked:, ...) must not read as a fresh marker
#    from whichever pane calls this - the fleet watcher polls it too.
status_file="$(ac_task_status "$id")"
if [ -s "$status_file" ]; then
  printf 'status| %s\n' "$(tail -n 1 "$status_file" | cut -d' ' -f2-)"
else
  printf 'idle\n'
fi
