#!/usr/bin/env bash
# ac-project-mode.sh - resolve a project's YOLO flag from records/projects.md.
#
# Usage: ac-project-mode.sh <project-name>
# Output: `yolo=<on|off>`
#
# records/projects.md line format (one project per line):
#   - <name> [+yolo] - <one-line description> (added <date>)
# `+yolo` lets the orchestrator self-approve routine decisions for that
# project. DELIVERY MODE IS NOT ANSWERED HERE (mode is per-task,
# fixed policy: recorded as the backlog row's contract token `mode:<m>`
# and resolved by ac-brief.sh - pin > --mode flag > refuse, never a registry
# default). A legacy `[<mode>]` bracket on a registry line is tolerated and
# IGNORED so old registries keep resolving yolo without a migration.
set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

name="${1:-}"
[ -n "$name" ] || ac_die "usage: ac-project-mode.sh <project-name>"

bracket="$(ac_project_mode "$name")"
yolo="off"
case "$bracket" in *"+yolo"*) yolo="on" ;; esac

printf 'yolo=%s\n' "$yolo"
