#!/usr/bin/env bash
# ac-delegation-guard.test.sh - the PreToolUse fence that keeps a chief from
# creating work outside the fleet: shape classification, primary-vs-linked
# scope, the escape hatch, and fail-open on every missing dependency.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

guard="$BIN/ac-delegation-guard.sh"

# hook <dir> <tool-name> [env-assignment] -> exit code of the guard run there
hook() {
  local dir="$1" tool="$2" rc=0
  ( cd "$dir" && printf '{"tool_name":"%s","tool_input":{}}' "$tool" | "$guard" >/dev/null 2>&1 ) || rc=$?
  printf '%s\n' "$rc"
}

primary="$(make_repo delegation)"

# --- shape classification, in a PRIMARY checkout (a chief's own) -------------
# Delegation-shaped names are refused: `Task` exactly, anything carrying Agent
# or Workflow. The list is not fixed, so a tool that ships later is still
# caught by its shape.
for t in Task Agent Workflow AgentTool WorkflowRunner SubAgent; do
  assert_eq "$(hook "$primary" "$t")" "2" "$t must be refused in a primary checkout"
done

# Ordinary tools are untouched. So are the Task-prefixed observe-or-stop
# verbs, but not by exemption - TaskList/TaskGet/TaskOutput/TaskStop/
# TaskUpdate/TaskCreate never shape-match at all (not exactly `Task`, no
# `Agent`/`Workflow` substring), an accident of spelling. ListAgents DOES
# shape-match (it contains `Agent`) and passes by a different mechanism: the
# exact-name allowlist ahead of the shape test.
for t in Bash Read Edit Write Grep TaskList TaskGet TaskOutput TaskStop TaskUpdate TaskCreate ListAgents; do
  assert_eq "$(hook "$primary" "$t")" "0" "$t must be allowed"
done

# MCP tools are the captain's own integrations, never this harness's
# delegation surface - excluded by prefix even when the name would match.
assert_eq "$(hook "$primary" "mcp__thing__Agent")" "0" "an mcp__ name is never classified"

# --- scope: a crewmate's leased worktree is NOT fenced -----------------------
# The guard lives in the repo-tracked settings.json, which every crewmate
# worktree inherits, so the scope test is the only thing telling them apart.
# A crewmate using subagents inside its own worktree is a capability it has.
linked="$("$BIN/ac-tree.sh" get --repo "$primary" --id dg1 --holder crew:dg1 2>/dev/null)"
assert_eq "$(hook "$linked" Task)" "0" "a linked worktree (crewmate) is never fenced"
assert_eq "$(hook "$primary" Task)" "2" "the primary checkout still is"

# --- scope: a FLEET HOME cwd is fenced too -----------------------------------
# A live fleet home is a symlink-based dir, not a git checkout, so the
# primary-checkout predicate never sees it - yet the chief session (and a solo
# session, AC_SOLO=1) sits exactly there. The guard closes it by the one thing
# a crewmate never has: physical cwd == physical AC_HOME.
mkdir -p "$AC_HOME"
assert_eq "$(hook "$AC_HOME" Task)" "2" "a chief session at a non-git fleet home is fenced"
# A SOLO session is worker-shaped: it keeps its own subagents exactly as a
# crewmate's worktree does - the slice stays its responsibility, and the
# captain is watching it live.
rc=0
( cd "$AC_HOME" && printf '{"tool_name":"Task"}' | AC_SOLO=1 "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "a solo session keeps its own subagents, like a crewmate"
rc=0
( cd "$primary" && printf '{"tool_name":"Task"}' | AC_SOLO=1 "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "the solo carve-out holds on a repo-hosted fleet too"
assert_eq "$(hook "$AC_HOME" Read)" "0" "ordinary tools stay untouched at the home"
rc=0
( cd "$AC_HOME" && printf '{"tool_name":"Task"}' | AC_ALLOW_DELEGATION=1 "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "the deliberate override works at the home too"

# --- scope: a chief whose session LOST its AC_HOME ---------------------------
# The home arm has nothing to compare against when AC_HOME is absent, and a
# live fleet home is not a git checkout at all - so the fence dropped for every
# homeless chief (a drydock chief ran three days like that). The discriminator
# is ac-sessionstart-nudge.sh's: the badges a session is given INSTEAD of a
# home, then linked-worktree geometry on the cwd.

# homeless_hook <dir> <tool> [VAR=VAL ...] -> exit code, run with AC_HOME REMOVED
homeless_hook() {
  local dir="$1" tool="$2" rc=0
  shift 2
  ( cd "$dir" && printf '{"tool_name":"%s"}' "$tool" \
    | env -u AC_HOME "$@" "$guard" >/dev/null 2>&1 ) || rc=$?
  printf '%s\n' "$rc"
}

assert_eq "$(homeless_hook "$AC_HOME" Task)" "2" \
  "a homeless chief at a fleet home is fenced"
assert_eq "$(homeless_hook "$primary" Task)" "2" \
  "a homeless chief on a repo-hosted fleet is fenced"
# The incident's own shape: ac-relocate.sh resumes a roomchief with AC_SCOPE
# and no AC_HOME, so a scope with no home is a chief that LOST one - never a
# badge, and never a reason to stand down.
assert_eq "$(homeless_hook "$AC_HOME" Task AC_SCOPE=fam)" "2" \
  "AC_SCOPE is not a crew badge"
assert_eq "$(homeless_hook "$AC_HOME" Read)" "0" \
  "ordinary tools stay untouched at a homeless home"
assert_eq "$(homeless_hook "$AC_HOME" Task AC_ALLOW_DELEGATION=1)" "0" \
  "the deliberate override works homeless too"

# C3, the three classes that are homeless BY DESIGN - each must stay at 0.
# 1. a crewmate, by either gate on its own: the badge it is launched with, and
#    the worktree geometry that still identifies it when ac-relocate.sh resumes
#    it with no scalars at all.
assert_eq "$(homeless_hook "$linked" Task AC_CREW_ID=dg1)" "0" \
  "a crewmate is never fenced - badge and geometry"
assert_eq "$(homeless_hook "$linked" Task)" "0" \
  "geometry alone still identifies a crewmate"
assert_eq "$(homeless_hook "$AC_HOME" Task AC_CREW_ID=dg1)" "0" \
  "the crew badge alone stands the fence down"
assert_eq "$(homeless_hook "$AC_HOME" Task AC_FLEET_NAME=drydock)" "0" \
  "so does the pinned fleet name"
# 2. a solo session - worker-shaped, carved out above every arm.
assert_eq "$(homeless_hook "$AC_HOME" Task AC_SOLO=1)" "0" \
  "a solo session keeps its own subagents when homeless too"
# 3. a session outside any fleet: see the reach block at the end of this file -
#    the wiring, not a predicate here, is what keeps it out.

# GEOMETRY OUTRANKS THE BADGES on a real checkout. A badge is an ordinary
# exported string and no worker is ever AT a primary checkout - both lease a
# LINKED worktree - so honouring one there would re-open this very cell while
# buying nothing. The primary denied before arm 3 existed and still does.
assert_eq "$(homeless_hook "$primary" Task AC_FLEET_NAME=drydock)" "2" \
  "a badge never stands the fence down at a primary checkout"
assert_eq "$(homeless_hook "$primary" Task AC_CREW_ID=dg1)" "2" \
  "nor does the crew badge"

# git is a DEPENDENCY of arm 3, not just a probe: the arm reads a deny out of an
# EMPTY answer, so an absent (or pre-2.31, no --path-format) git would be
# indistinguishable from "not a repo" and would fence a crewmate. C4 keeps the
# broken-dependency fail-open, so arm 3 guards git exactly as the script guards
# jq. One variable, everything else held constant.
stubdir="$TMP/nogit"; mkdir -p "$stubdir"
# Everything the guard's own interpreter and body need, and nothing more - git
# is the single variable this leg removes.
for c in bash env cat jq; do
  ln -sf "$(command -v "$c")" "$stubdir/$c"
done
command -v git >/dev/null || fail "no git on PATH: this leg cannot vary it"
rc=0
( cd "$linked" && printf '{"tool_name":"Task"}' \
  | env -u AC_HOME -u AC_CREW_ID -u AC_FLEET_NAME PATH="$stubdir" "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "a missing git fails OPEN in arm 3, never onto a crewmate"
rc=0
( cd "$AC_HOME" && printf '{"tool_name":"Task"}' \
  | env -u AC_HOME PATH="$stubdir" "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "and at a fleet home too - a broken dependency never denies"

# --- the escape hatch, and fail-open ----------------------------------------
rc=0
( cd "$primary" && printf '{"tool_name":"Task"}' \
  | AC_ALLOW_DELEGATION=1 "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "AC_ALLOW_DELEGATION=1 is the deliberate override"

# Fail-open, every way: empty payload, unparseable payload, no tool_name, and
# a directory git cannot read as a repo. A broken guard must never wedge the
# harness, so none of these may refuse.
rc=0; ( cd "$primary" && printf '' | "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "an empty payload fails open"
rc=0; ( cd "$primary" && printf 'not json' | "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "an unparseable payload fails open"
rc=0; ( cd "$primary" && printf '{"tool_input":{}}' | "$guard" >/dev/null 2>&1 ) || rc=$?
assert_eq "$rc" "0" "a payload with no tool_name fails open"
nonrepo="$(mktemp -d)"
assert_eq "$(hook "$nonrepo" Task)" "0" "a non-repo cwd fails open"
rm -rf "$nonrepo"

# --- reach: the wiring is what keeps an outside session out ------------------
# The homeless arm denies a NON-GIT cwd, because that is the shape a live fleet
# home has. What holds C3's third class (a session outside any fleet) at 0 is
# therefore not a predicate in this script - it is the hook wiring, which only
# ever runs the guard from a tree that carries it. Pinned here because the
# homeless arm's false-positive budget rests on exactly this.
# BOTH entry points, never one: enumerating a single wiring would let the other
# lose its [ -x ] gate with nothing red.
wiring="$(jq -r '.hooks.PreToolUse[].hooks[].command
                 | select(contains("ac-delegation-guard"))' \
          "$ROOT/.claude/settings.json")"
assert_contains "$wiring" 'CLAUDE_PROJECT_DIR' \
  "the claude guard is only ever reached through the project dir"
assert_contains "$wiring" '[ -x "$h" ] || exit 0' \
  "a tree that does not carry the guard never runs it (claude)"
codex="$(jq -r '.. | objects | .command? // empty
                | select(type=="string") | select(contains("ac-delegation-guard"))' \
         "$ROOT/.codex/hooks.json")"
assert_contains "$codex" 'pwd -P' \
  "the codex guard is reached through the cwd"
assert_contains "$codex" '[ -x "$root/bin/ac-delegation-guard.sh" ] || exit 0' \
  "a tree that does not carry the guard never runs it (codex)"

pass
