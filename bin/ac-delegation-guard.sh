#!/usr/bin/env bash
# ac-delegation-guard.sh - PreToolUse hook: refuse harness-native delegation
# from a CHIEF's own checkout.
#
# Wired in .claude/settings.json under hooks.PreToolUse; reads the hook payload
# JSON on stdin and inspects .tool_name. Pure bash + jq, no other runtime.
#
# WHY IT EXISTS. Work created through a harness-native delegation tool has no
# state/<id>.meta. Supervision counts metas, and ac-turnend-guard.sh goes inert
# at zero - so such work is not merely unsupervised: the whole guard stack goes
# structurally inert for the rest of the session, and the work dies with the
# session that made it. That cost is not hypothetical - a fleet running this
# design without the fence lost two workers mid-flight and 73 minutes of
# unnoticed supervision downtime to exactly this. AGENTS.md section 1 already
# forbids it in prose; this is the same rule with an enforcement point.
#
# SHAPE, NOT A LIST. A fixed deny list is fail-open against tools that ship
# later, so the tool NAME is classified by shape: a non-MCP tool whose name is
# exactly `Task`, or contains `Agent` or `Workflow`, creates delegated work.
# Observe-or-stop names (TaskList, TaskGet, TaskOutput, TaskStop, TaskUpdate)
# do NOT match - they inspect or end work, they never create it - and mcp__*
# names are excluded outright: an MCP server's tools are the captain's own
# integrations, not this harness's delegation surface.
#
# SCOPE, three arms: (1) the FLEET HOME - physical cwd == physical AC_HOME. A
# live home is a symlink-based dir, not a git checkout, so the git predicate
# alone left every real fleet's chief session unfenced - measured:
# `git rev-parse` at such a home answers "not a git repository", which fails
# open. A crewmate's cwd is never its fleet's home, so the equality is safe.
# A SOLO session (AC_SOLO=1) is exempt from EVERY arm - see the carve-out at
# the top: worker-shaped like a crewmate, never a chief.
# (2) a genuine PRIMARY checkout (git-dir == git-common-dir, the same
# predicate ac-turnend-guard.sh and ac-sessionstart-nudge.sh use) - a fleet
# hosted on a repo itself. A crewmate's
# leased worktree is a LINKED checkout and is never touched - a crewmate using
# subagents inside its own worktree is a capability it legitimately has, and
# removing it is a different decision than the one this guard makes. This is
# why the guard can live in the repo-tracked settings.json at all: the file is
# shared with every crewmate worktree (ac_seed_crew_settings keeps a
# repo-shipped copy), and only the scope test tells the two apart.
# (3) AC_HOME ABSENT. Arms 1 and 2 both need a home - arm 1 to compare against,
# arm 2 because the fleet home it misses is not a git checkout at all - so a
# chief that LOST its home fell through both and was allowed: a drydock chief
# ran three days like that with the fence down. This arm owns that whole case,
# and no home is resolved, named or guessed for it (bin/ac-lib.sh: "A fleet
# home is NAMED, never guessed"). The discriminator is ac-sessionstart-nudge.sh's,
# reused whole, because it answers exactly this question - which homeless
# session OUGHT to have had a home: the BADGES a session is given INSTEAD of one
# (AC_CREW_ID, AC_FLEET_NAME - set on the crewmate launch line and nowhere else),
# then linked-worktree geometry on the cwd for a crewmate that carries no
# scalars at all. AC_SCOPE is deliberately NOT a badge: a roomchief is given
# AC_HOME *and* AC_SCOPE together, so a scope with no home is a chief that lost
# one - the incident's own shape, and the one this arm must catch.
#
# ESCAPE HATCH: AC_ALLOW_DELEGATION=1 in the environment. Deliberate, and set
# at launch - a chief cannot grant it to itself mid-turn.
#
# Fails open: non-matching payloads, an unparseable payload, a missing
# DEPENDENCY (jq anywhere, git under arm 3), a linked worktree, or a checkout
# git cannot read all exit 0 - a broken guard must never wedge the harness.
# EXACTLY ONE of those is narrower under arm 3, deliberately: a cwd git reads
# as no repo at all is indistinguishable from a live fleet home, the very shape
# arm 3 exists to catch, so homeless it DENIES where a session with a home
# still allows. That is a bounded trade, not a blanket one - the dependency
# fail-open is kept by the explicit git guard in arm 3, so only a genuine
# not-a-repo answer denies.
# What keeps that deny from reaching a session outside any fleet is the WIRING,
# not a predicate here. BOTH entry points gate on the guard being present in
# the tree - .claude/settings.json runs "$CLAUDE_PROJECT_DIR"/bin/<this> and
# .codex/hooks.json runs "$(pwd -P)"/bin/<this>, each behind its own [ -x ] -
# so a tree that does not carry this script never runs it. A fleet home always
# does (its bin/ is symlinked to the distro). Both are pinned by the test file:
# the budget rests on them, so neither may be enumerated alone.
# Exit codes: 0 allow, 2 deny. Files: none.

set -uo pipefail

[ "${AC_ALLOW_DELEGATION:-}" = 1 ] && exit 0
# A SOLO session (AC_SOLO=1) is WORKER-shaped, not chief-shaped: it keeps its
# own subagents exactly as a crewmate's worktree does - the slice stays its
# responsibility, its self-task meta keeps the work visible, and the captain
# is watching it live. Same carve-out, either scope arm.
[ "${AC_SOLO:-}" = 1 ] && exit 0
command -v jq >/dev/null 2>&1 || exit 0
payload="$(cat 2>/dev/null || true)"
[ -n "$payload" ] || exit 0

tool="$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null || true)"
[ -n "$tool" ] || exit 0
case "$tool" in mcp__*) exit 0 ;; esac

case "$tool" in
  Task|*Agent*|*Workflow*) : ;;
  *) exit 0 ;;
esac

# Scope, three arms - any one of them is a session the fence covers:
# 1. FLEET HOME: physical cwd == physical AC_HOME. A live fleet home is a
#    symlink-based dir, not a git checkout, so the git predicate below never
#    sees it - yet the chief session (and a solo session, AC_SOLO=1) sits
#    exactly there, and a crewmate's cwd is never its fleet's home.
# 2. PRIMARY CHECKOUT (git-dir == git-common-dir): a fleet hosted on a repo
#    itself. A linked worktree (a crewmate) and an unreadable checkout fail
#    OPEN as before.
# 3. AC_HOME ABSENT: arms 1 and 2 both need a home, so a chief that lost one
#    fell through both. See the SCOPE block above for the discriminator and
#    for the one fail-open this arm deliberately narrows.
here="$(pwd -P 2>/dev/null || true)"
[ -n "$here" ] || exit 0
if [ -z "${AC_HOME:-}" ]; then
  # Arm 3 keyed on the VARIABLE, not on a resolved path: AC_HOME set but
  # unresolvable must keep the old arms' exact behavior, so only a genuinely
  # absent home reaches here.
  #
  # git is a DEPENDENCY here, not just a probe, because this arm reads a deny
  # out of an EMPTY answer. Unguarded, "git is missing or too old for
  # --path-format=absolute" is indistinguishable from "not a repo" and would
  # deny a crewmate - turning the broken-dependency fail-open into a
  # fail-closed. Guarded like jq above, for the same reason.
  command -v git >/dev/null 2>&1 || exit 0
  gd="$(git -C "$here" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  gcd="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$gd" ] && [ "$gd" != "$gcd" ] && exit 0   # linked worktree: a crewmate
  # GEOMETRY OUTRANKS THE BADGES, and only here. A primary checkout denied
  # before this arm existed and still does, whatever the environment says: a
  # badge is an ordinary exported string, and no worker is ever AT a primary
  # checkout (a crewmate and a verification pane both lease a LINKED worktree),
  # so letting one stand the fence down there would buy nothing and cost a
  # silent re-opening of this very cell. On a cwd that is not a repo at all -
  # the fleet-home shape - the badges are the whole discriminator.
  if [ -z "$gd" ]; then
    [ -z "${AC_CREW_ID:-}" ] || exit 0
    [ -z "${AC_FLEET_NAME:-}" ] || exit 0
  fi
else
  home_p="$(cd "$AC_HOME" 2>/dev/null && pwd -P || true)"
  if [ -z "$home_p" ] || [ "$here" != "$home_p" ]; then
    gd="$(git -C "$here" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
    gcd="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
    [ -n "$gd" ] && [ -n "$gcd" ] || exit 0
    [ "$gd" = "$gcd" ] || exit 0   # linked worktree: a crewmate, not a chief
  fi
fi

printf 'ac-delegation-guard: %s creates work with no state/<id>.meta, which leaves the whole supervision stack inert and dies with this session. Delegate through bin/ac-spawn.sh instead (AGENTS.md section 1). Deliberate override: launch with AC_ALLOW_DELEGATION=1.\n' "$tool" >&2
exit 2
