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
#
# A SECOND, SEPARATE SIGNAL rides the same hook for the same reason it can: it
# only ever prints, so it carries no blocking risk. When AC_HOME is ABSENT this
# hook is the only ac- surface left that can say so - the other three go inert
# at the same statement, and the trace that would record their silence is
# written under the home they cannot resolve. The arm below owns that signal and
# its discriminator; the reminder above is untouched by it, and a homeless
# session is deliberately NOT handed that reminder (the script it names dies on
# the same predicate).
set -u

# THE SOLO ARM COMES BEFORE EVERY GATE. Every check below exists to keep the
# nudge quiet in the right rooms (owned homes, unresolvable homes) - but a
# SOLO session is the one reader whose orientation must survive ALL of them:
# it opens beside a LIVE chief (whose session-lock is exactly what the
# lock-silence gate keys on), and it needs no home resolution to be told what
# it is. Measured on the first live run: the orientation sat below the gates,
# the lock silenced it, and the session introduced itself as the chief.
if [ "${AC_SOLO:-}" = 1 ]; then
  printf 'agent-crew SOLO session (AC_SOLO=1): you are NOT the crewchief - the chief-law identity block does not bind you (AGENTS.md section 1 names this exception; the SOLO SESSION block in section 5 is your contract). You pair-code with the captain DIRECTLY: run `bin/ac-session-start.sh` once (read-only under AC_SOLO - no lock, no drain), then code one slice at a time via `bin/ac-self-task.sh start <id> <project>`, landing per the repo mode with the captain approving in chat. The CREWMATE layer binds your work, and your leased worktree already carries it: self-task start seeds the merged layer like a crew spawn does (--harness routes it to the instruction file your harness loads - .claude/CLAUDE.md by default, AGENTS.md for codex/opencode/pi/cursor), so begin each slice by reading the seeded crewmate instruction file inside that worktree - the FULL merge (container baseline, fleet-learned, fleet, any domain layer) - and discover the seeded skills there too; the seed reaches the tree, never this session, so that read is yours each slice. Only the crewmate mechanics (brief, ac-done, markers, the handback report format - never print a Lessons section in chat, it dies with the session: a genuinely new method lesson goes to bin/ac-learn.sh note, a verified repo fact to bin/ac-know.sh add, anything else ends with the answer) do not apply. The chief session owns wakes, watchers, gates and crew - never touch them from here, and never delegate to a crewmate (the captain wants crew on something: hand the order to the chief with bin/ac-remote.sh order --text-file <draft>, it queues the chief'"'"'s durable remote-order wake and the chief'"'"'s replies land at state/remote-inbox/<rid>.replies.md); your own harness-native subagents ARE fine - you are worker-shaped, like a crewmate keeping subagents in its worktree. A subagent that EDITS your leased worktree is pointed, in its prompt, at the seeded crewmate instruction file inside that worktree before it edits - the seeded crewmate layer reaches a subagent only through your prompt, since instruction files and hooks load by the session, never by the tree being touched - writes go one at a time per worktree, and you read the full diff and run the tests yourself before committing.\n'
  # A slice left in flight by an earlier session is this session's to land
  # or discard; best-effort, the orientation above never waits on it.
  if . "$(dirname "$0")/ac-lib.sh" 2>/dev/null; then ac_self_tasks_in_flight 2>/dev/null || true; fi
  exit 0
fi
# THE ONE STATE NO ac- HOOK CAN OTHERWISE REPORT. With AC_HOME absent, ac_home
# refuses by design and all four claude hooks - the turn-end guard, the watcher
# auto-arm, the prompt recall and this nudge - swallow that refusal into exit 0
# before doing anything; the trace that would have shown the silence is written
# under the home it cannot resolve, so it cannot record its own absence. A
# drydock crewchief ran three days like that: 822 hook firings, 160 supervision
# verdicts, every one swallowed, and the ONE loud detector left
# (bin/ac-session-start.sh) dies on this same predicate - reminder and detector
# fail together.
#
# IT SITS ABOVE THE ac-lib.sh FLOOR, and that is the point: every predicate here
# is an environment read or a git call on the CWD, so the one thing that can
# still speak owes nothing to a library that may itself be missing - and the run
# path below keeps its exact bytes, so a session WITH a home moves not at all.
# Nothing is written, and no home is resolved, named or guessed.
#
# THE DISCRIMINATOR IS THE WHOLE DIFFICULTY. A crewmate is LEGITIMATELY homeless
# (ac-spawn.sh, "A crewmate gets no AC_HOME"), and ac_seed_crew_settings copies
# this settings.json into every crewmate worktree - so a signal keyed on the
# missing home alone would shout at the entire crew. Two independent gates cover
# that direction, because shouting at the crew is the unrecoverable error while
# missing one homeless chief is not:
#   1. THE BADGES A SESSION IS GIVEN INSTEAD OF A HOME. AC_CREW_ID (ac-spawn.sh,
#      the crewmate launch line) and AC_FLEET_NAME (that same line, and
#      ac-pane-agent.sh's ENVPIN, which pins the fleet NAME exactly when the
#      caller had no home to pin) are set nowhere else. AC_SCOPE is deliberately
#      NOT on this list: a roomchief is given AC_HOME *and* AC_SCOPE together
#      (ac-spawn.sh), so a scope with no home is a roomchief that LOST one -
#      ac-relocate.sh resumes one with AC_SCOPE and no AC_HOME, which is this
#      very defect and must be spoken to, not silenced.
#   2. A LINKED WORKTREE is a crewmate checkout - the geometry the sibling hooks
#      use, asked of the CWD here because there is no home to ask about. It is
#      not redundant with gate 1: ac-relocate.sh resumes a crewmate with NO
#      scalars at all, and only the geometry still identifies it. It also covers
#      a captain reading a leased worktree.
#      --path-format=absolute is load-bearing: from a SUBDIRECTORY of a primary
#      checkout the bare form answers an absolute --git-dir against a relative
#      --git-common-dir, which compares unequal and would read as a worktree.
# What is left is a fleet home (not a git checkout at all) or a primary checkout
# hosting a fleet, carrying no crew badge - the shapes that ought to have named a
# home. A captain hacking on the distro checkout lands there too and eats one
# line per session: the price of never again missing the shape that cost three days.
if [ -z "${AC_HOME:-}" ] && [ -z "${AC_CREW_ID:-}" ] && [ -z "${AC_FLEET_NAME:-}" ]; then
  gd="$(git rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  gcd="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  if [ -z "$gd" ] || [ "$gd" = "$gcd" ]; then
    printf 'agent-crew: AC_HOME is not set in this session - every ac- hook here is INERT. ac_home refuses by design (bin/ac-lib.sh: "A fleet home is NAMED, never guessed"), so the turn-end guard, the watcher auto-arm, the prompt recall and this reminder each ask for the home, get that refusal, and exit 0 without a word - and the hook trace that would have recorded the silence lives under the very home they cannot resolve. Nothing supervises this session and nothing says so. It CANNOT be repaired from inside: a hook subprocess is spawned from the environment of the claude process, so an export, or an AC_HOME= prefix on a Bash command, fixes that command and nothing else. RELAUNCH - close this session and reopen it with `ac <fleet>`, or set AC_HOME=<fleet home> in the pane before starting claude. Not running a fleet from here? Ignore this line.\n'
  fi
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
ac_self_tasks_in_flight 2>/dev/null || true
exit 0
