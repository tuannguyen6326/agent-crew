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
#   - a home whose session lock is held LIVE - session-start already ran here
#     (mine), or another session owns the home and this one is read-only.
# Any unowned home gets the nudge, a crewdeputy home included: the `ac
# <deputy>` launcher opens a plain chief session there with NO kickoff to
# order session-start, and a SPAWNED deputy either holds a live lock by the
# time it reads context or eats one redundant reminder line - harmless.
set -u

# THE SOLO ARM COMES BEFORE EVERY GATE. Every check below exists to keep the
# nudge quiet in the right rooms (owned homes, unresolvable homes) - but a
# SOLO session is the one reader whose orientation must survive ALL of them:
# it opens beside a LIVE chief (whose session-lock is exactly what the
# lock-silence gate keys on), and it needs no home resolution to be told what
# it is. Measured on the first live run: the orientation sat below the gates,
# the lock silenced it, and the session introduced itself as the chief.
if [ "${AC_SOLO:-}" = 1 ]; then
  printf 'agent-crew SOLO session (AC_SOLO=1): you are NOT the crewchief - the chief-law identity block does not bind you (AGENTS.md section 1 names this exception; the SOLO SESSION block in section 5 is your contract). You pair-code with the captain DIRECTLY: run `bin/ac-session-start.sh` once (read-only under AC_SOLO - no lock, no drain), then code one slice at a time via `bin/ac-self-task.sh start <id> <project>`, landing per the repo mode with the captain approving in chat. The CREWMATE layer binds your work, and your leased worktree already carries it: self-task start seeds the merged layer like a crew spawn does (--harness routes it to the instruction file your harness loads - .claude/CLAUDE.md by default, AGENTS.md for codex/opencode/pi/cursor), so begin each slice by reading the seeded crewmate instruction file inside that worktree - the FULL merge (container baseline, fleet-learned, fleet, any domain layer) - and discover the seeded skills there too; the seed reaches the tree, never this session, so that read is yours each slice. Only the crewmate mechanics (brief, ac-done, markers) do not apply. The chief session owns wakes, watchers, gates and crew - never touch them from here, and never delegate to a crewmate; your own harness-native subagents ARE fine - you are worker-shaped, like a crewmate keeping subagents in its worktree. A subagent that EDITS your leased worktree is pointed, in its prompt, at the seeded crewmate instruction file inside that worktree before it edits - the seeded crewmate layer reaches a subagent only through your prompt, since instruction files and hooks load by the session, never by the tree being touched - writes go one at a time per worktree, and you read the full diff and run the tests yourself before committing.\n'
  exit 0
fi
. "$(dirname "$0")/ac-lib.sh" 2>/dev/null || exit 0

home="$(ac_home 2>/dev/null)" || exit 0

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
