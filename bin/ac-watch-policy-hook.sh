#!/usr/bin/env bash
# ac-watch-policy-hook.sh - PreToolUse hook (Bash tool): deny broad watcher
# kills before they run.
#
# Wired in .claude/settings.json under hooks.PreToolUse (matcher "Bash");
# reads the hook payload JSON on stdin and inspects .tool_input.command.
# Pure bash + jq, no other runtime.
#
# DENIES (exit 2, reason on stderr) commands that kill watchers by PATTERN
# instead of by pid - the incident this prevents: an over-broad pkill took
# down ANOTHER session's scoped watcher along with the caller's own:
# - pkill/killall whose argument (same pipeline segment) mentions watch
#   (ac-watch, ac-watch.sh, ...);
# - kill fed by pgrep in a command that mentions watch
#   (kill $(pgrep -f ac-watch); p=$(pgrep -f watch); kill $p);
# - kill of a shell variable whose name mentions watch (kill "$WATCH_PID").
# Everything else is ALLOWED (exit 0): plain `kill <pid>` of a single known
# pid is the sanctioned way to stop a watcher you own.
#
# Fails open: non-Bash payloads, missing jq, or an unparseable payload all
# exit 0 - a broken hook must never wedge the harness.
# Exit codes: 0 allow, 2 deny. Files: none.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

tool="$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null || true)"
[ -n "$tool" ] && [ "$tool" != "Bash" ] && exit 0
cmd="$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null || true)"
[ -n "$cmd" ] || exit 0
lc="$(printf '%s' "$cmd" | tr '[:upper:]' '[:lower:]')"

deny() {
  printf 'ac-watch-policy: %s. Kill a watcher by its OWN pid (kill <pid>), never by pattern - a broad match can take down another session'\''s watcher.\n' "$1" >&2
  exit 2
}

# pkill/killall with a watch-mentioning argument in the same segment.
if printf '%s\n' "$lc" | grep -qE '(^|[^[:alnum:]_-])(pkill|killall)[^|;&]*watch'; then
  deny 'denied: pkill/killall pattern targets a watcher'
fi

# kill of pgrep-derived pids in a watch-mentioning command.
if printf '%s\n' "$lc" | grep -q 'kill' \
  && printf '%s\n' "$lc" | grep -q 'pgrep' \
  && printf '%s\n' "$lc" | grep -q 'watch'; then
  deny 'denied: kill of pgrep-derived pids mentioning watch'
fi

# kill of a variable whose name mentions watch.
if printf '%s\n' "$lc" | grep -qE '(^|[^[:alnum:]_-])kill[^|;&]*[$][{"]*[a-z_]*watch'; then
  deny 'denied: kill of a watch-named variable'
fi

exit 0
