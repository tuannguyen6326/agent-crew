#!/usr/bin/env bash
# ac-project-mode.sh - resolve a project's delivery mode from records/projects.md.
#
# Usage: ac-project-mode.sh <project-name>
# Output: `mode=<crew-ship|direct-pr|local-only> yolo=<on|off>`
#
# records/projects.md line format (one project per line):
#   - <name> [<mode>] - <one-line description> (added <date>)
# The [<mode>] bracket is optional and defaults to `crew-ship` (full
# pipeline via the crew-ship skill -> PR -> captain merge). `+yolo` inside
# the bracket lets the orchestrator self-approve routine decisions,
# e.g. [crew-ship +yolo].

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

name="${1:-}"
[ -n "$name" ] || ac_die "usage: ac-project-mode.sh <project-name>"

bracket="$(ac_project_mode "$name")"
yolo="off"
case "$bracket" in *"+yolo"*) yolo="on" ;; esac
mode="$(sed 's/+yolo//; s/^ *//; s/ *$//' <<<"$bracket")"
[ -n "$mode" ] || mode="crew-ship"
case "$mode" in
  crew-ship|direct-pr|local-only) ;;
  *) ac_die "unknown mode '$mode' for project $name (want crew-ship|direct-pr|local-only)" ;;
esac

printf 'mode=%s yolo=%s\n' "$mode" "$yolo"
