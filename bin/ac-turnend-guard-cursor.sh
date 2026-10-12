#!/usr/bin/env bash
# ac-turnend-guard-cursor.sh - cursor `stop` adapter for the turn-end guard.
#
# Registered in the tracked .cursor/hooks.json. Cursor's stop hook CANNOT
# block: exit 2 there is a silent no-op (measured upstream against the
# cursor-agent 2026.08.11 build's own blocked-response mapper; our live probe
# pending), so this adapter never relies on it - every path exits 0 and the
# ONLY channel is at most one {"followup_message": ...} object on stdout,
# which cursor submits as the next user message. docs/-equivalent guidance
# accepts one bounded follow-up as the blocking alternative - the same
# primitive the opencode session.idle and pi agent_settled adapters use.
#
# LOOP BOUNDING IS DOUBLE, because either bound alone is insufficient: the
# registration's loop_limit is cursor's own ceiling (the only bound that
# survives a broken adapter - past it cursor stops invoking the hook), and
# AC_CURSOR_TURNEND_CEILING here bites BELOW it, so a persistent objection
# goes quiet on our terms instead of dying silently at cursor's ceiling.
# The payload's loop_count is cursor's stop_hook_active analogue: 0 on the
# first stop after a real user message, +1 per follow-up-driven stop.
#
# AC_TURNEND_GUARD_BIN overrides the guard path for tests only. Fails open
# on every missing dependency - a broken hook must never wedge the harness.

set -uo pipefail

payload="$(cat 2>/dev/null || true)"
command -v jq >/dev/null 2>&1 || exit 0

loops="$(jq -r '.loop_count // 0' <<<"$payload" 2>/dev/null || printf '0')"
case "$loops" in *[!0-9]*|'') loops=0 ;; esac
[ "$loops" -lt "${AC_CURSOR_TURNEND_CEILING:-3}" ] || exit 0

guard="${AC_TURNEND_GUARD_BIN:-$(dirname "$0")/ac-turnend-guard.sh}"
[ -x "$guard" ] || exit 0

rc=0
reason="$(printf '%s' "$payload" | "$guard" 2>&1 >/dev/null)" || rc=$?
[ "$rc" = 2 ] || exit 0

jq -n --arg m "TURN WOULD END BLIND - supervision is off. Drain queued wakes and re-arm the watcher (bin/ac-watch.sh, or a bounded --once checkpoint) before ending the turn.

$reason" '{followup_message: $m}'
exit 0
