#!/usr/bin/env bash
# ac-watch-policy-cursor.sh - cursor beforeShellExecution adapter for the
# watch policy.
#
# Registered in the tracked .cursor/hooks.json. Cursor's native shell-hook
# payload carries the command as `.command` - not the claude hook shape the
# guard scripts read - so piping it through raw leaves the guard inert (it
# exits 0 for any payload without tool_name "Bash"). This adapter
# synthesizes the claude shape, exactly as the opencode plugin and pi
# extension do in-process, and hands it to bin/ac-watch-policy-hook.sh; the
# exit code passes through (cursor blocks on exit 2, the convention the
# guard already speaks). Fails open on every missing dependency.

set -uo pipefail

payload="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0
cmd="$(jq -r '.command // empty' <<<"$payload" 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0
jq -cn --arg c "$cmd" '{tool_name: "Bash", tool_input: {command: $c}}' \
  | "$(dirname "$0")/ac-watch-policy-hook.sh"
