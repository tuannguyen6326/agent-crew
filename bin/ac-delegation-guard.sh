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
# SCOPE, two arms: (1) the FLEET HOME - physical cwd == physical AC_HOME. A
# live home is a symlink-based dir, not a git checkout, so the git predicate
# alone left every real fleet's chief session unfenced - measured:
# `git rev-parse` at such a home answers "not a git repository", which fails
# open. A crewmate's cwd is never its fleet's home, so the equality is safe.
# A SOLO session (AC_SOLO=1) is exempt from BOTH arms - see the carve-out at
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
#
# ESCAPE HATCH: AC_ALLOW_DELEGATION=1 in the environment. Deliberate, and set
# at launch - a chief cannot grant it to itself mid-turn.
#
# Fails open: non-matching payloads, missing jq, an unparseable payload, or a
# checkout git cannot read all exit 0 - a broken guard must never wedge the
# harness. Exit codes: 0 allow, 2 deny. Files: none.

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

# Scope, two arms - either one is a session the fence covers:
# 1. FLEET HOME: physical cwd == physical AC_HOME. A live fleet home is a
#    symlink-based dir, not a git checkout, so the git predicate below never
#    sees it - yet the chief session (and a solo session, AC_SOLO=1) sits
#    exactly there, and a crewmate's cwd is never its fleet's home.
# 2. PRIMARY CHECKOUT (git-dir == git-common-dir): a fleet hosted on a repo
#    itself. A linked worktree (a crewmate) and an unreadable checkout fail
#    OPEN as before.
here="$(pwd -P 2>/dev/null || true)"
[ -n "$here" ] || exit 0
home_p=""
[ -z "${AC_HOME:-}" ] || home_p="$(cd "$AC_HOME" 2>/dev/null && pwd -P || true)"
if [ -z "$home_p" ] || [ "$here" != "$home_p" ]; then
  gd="$(git -C "$here" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)"
  gcd="$(git -C "$here" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)"
  [ -n "$gd" ] && [ -n "$gcd" ] || exit 0
  [ "$gd" = "$gcd" ] || exit 0   # linked worktree: a crewmate, not a chief
fi

printf 'ac-delegation-guard: %s creates work with no state/<id>.meta, which leaves the whole supervision stack inert and dies with this session. Delegate through bin/ac-spawn.sh instead (AGENTS.md section 1). Deliberate override: launch with AC_ALLOW_DELEGATION=1.\n' "$tool" >&2
exit 2
