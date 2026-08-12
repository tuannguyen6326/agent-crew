#!/usr/bin/env bash
# ac-sessionstart-nudge.sh - one-line "run session-start" reminder (Claude Code
# SessionStart hook). Wired in .claude/settings.json for source startup|resume|
# clear. CLAUDE.md section 3 says the crewchief must run bin/ac-session-start.sh
# first, every session; nothing native caught a session that forgot - the
# turn-end guard enforces the WATCHER, not the digest. This prints the reminder
# into the fresh session's context.
#
# ALWAYS exits 0. A SessionStart hook that exits non-zero BLOCKS session init,
# so every path - success, silence, or any broken dependency - exits 0. It only
# ever prints; it changes nothing.
#
# Self-scoped, because this hook can reach sessions that must NOT be nudged. It
# governs the agent-crew repo (where the `ac` launcher `cd`s every crewchief),
# but when agent-crew hosts a fleet ON ITSELF, ac_seed_crew_settings copies this
# same settings.json into each crewmate's linked worktree. So it stays SILENT
# on, mirroring ac-turnend-guard's own scope checks:
#   - a linked worktree (git-dir != git-common-dir) - a crewmate follows a
#     brief and never runs session-start;
#   - a crewdeputy home (.ac-crewdeputy-home) - spawned with a kickoff that
#     already tells it to run session-start;
#   - a home whose session lock is held LIVE - session-start already ran here
#     (mine), or another session owns the home and this one is read-only.
# Only a genuine, unowned primary home gets the nudge.
set -u
. "$(dirname "$0")/ac-lib.sh" 2>/dev/null || exit 0

home="$(ac_home 2>/dev/null)" || exit 0

# Crewdeputy home: its spawn kickoff already says to run session-start.
[ -e "$home/.ac-crewdeputy-home" ] && exit 0

# Linked worktree = a crewmate checkout (the self-hosting footgun): silent.
gd="$(git -C "$home" rev-parse --git-dir 2>/dev/null || true)"
gcd="$(git -C "$home" rev-parse --git-common-dir 2>/dev/null || true)"
[ -n "$gd" ] && [ "$gd" != "$gcd" ] && exit 0

# A live session lock means session-start already ran here, or another session
# owns this home - either way, do not nudge. `stale` (dead holder) and
# `unlocked` both fall through to the nudge: a fresh session should run it.
case "$("$(dirname "$0")/ac-lock.sh" status 2>/dev/null)" in
  held*) exit 0 ;;
esac

# shellcheck disable=SC2016  # the backticked path is literal reminder text, not a command
printf 'agent-crew: run `bin/ac-session-start.sh` now, once, before taking orders - it drains wakes, shows the fleet/backlog, and arms supervision. Skip only if you already ran it this session.\n'
exit 0
