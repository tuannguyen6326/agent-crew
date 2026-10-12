#!/usr/bin/env bash
# ac-project-mode.sh - resolve a project's YOLO flag from records/projects.md
# (`yolo=<on|off>`). The authoritative spec, the registry grammar included, is
# the header of src/project-mode.ts; this entry only starts it through
# bin/ac-bun.sh, so every caller keeps this path. The module is found at
# <this bin/>/../src physically, so a per-home override bin/ needs a sibling
# src/.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
ac_bun_exec src/project-mode.ts "$@"
