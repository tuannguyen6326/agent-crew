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

# Ordinary tools are untouched, and so are the observe-or-stop task verbs:
# they inspect or end work, they never create it.
for t in Bash Read Edit Write Grep TaskList TaskGet TaskOutput TaskStop TaskUpdate TaskCreate; do
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

pass
