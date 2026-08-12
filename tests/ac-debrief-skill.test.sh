#!/usr/bin/env bash
# ac-debrief-skill.test.sh - contract checks for the reset-time debrief skill.

set -euo pipefail
# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

skill="$(<"$ROOT/.agents/skills/debrief/SKILL.md")"
agents="$(<"$ROOT/AGENTS.md")"
architecture="$(<"$ROOT/docs/architecture.md")"
overview="$(<"$ROOT/docs/overview.html")"

assert_not_contains() {
  case "$1" in
    *"$2"*) fail "${3:-assert_not_contains}: '$2' found" ;;
  esac
}

assert_contains "$skill" 'Landing remains the primary task-level debrief' "landing remains primary"
assert_not_contains "$skill" 'user-invocable:' "Agent Skills frontmatter excludes client-specific user-invocable"
assert_not_contains "$skill" 'metadata:' "debrief uses portable minimal Agent Skills frontmatter"
assert_contains "$skill" 'Inspect each destination immediately before writing it' "inspect before write"
assert_contains "$skill" 'duplicate, superseding, obsolete, or genuinely new' "curation classification"
assert_contains "$skill" 'records/backlog.md' "backlog route"
assert_contains "$skill" 'bin/ac-room.sh post' "room route"
assert_contains "$skill" "Every unresolved captain choice becomes a \`GATE:\` or \`ASK:\`" "durable decision owner"
assert_contains "$skill" 'records/learnings.md' "learning route"
assert_contains "$skill" 'records/captain.md' "captain route"
assert_contains "$skill" 'records/projects.md' "project registry route"
assert_contains "$skill" "never creates, removes, or changes a project's mode as cleanup" "project management exclusion"
assert_contains "$skill" "Project-intrinsic facts go to that project's \`AGENTS.md\` through normal crew delivery" "project knowledge route"
assert_contains "$skill" 'bin/ac-learn.sh tick` exactly once' "one learning tick"
assert_contains "$skill" "never invokes \`bin/ac-learn.sh run\`" "no distill side effect"
assert_contains "$skill" 'Never create, edit, or promote a skill as debrief storage' "no skill storage"
assert_contains "$skill" "Never use \`bin/ac-teardown.sh --force\`" "no force teardown"
assert_contains "$skill" 'SAFE TO RESET' "safe verdict"
assert_contains "$skill" 'NOT SAFE TO RESET' "unsafe verdict"
assert_contains "$skill" 'Resume pointer' "durable continuation pointer"
assert_not_contains "$skill" '.stow-notes.md' "legacy fallback notes file must not leak into Agent Crew debrief"

assert_contains "$agents" '/debrief stays' "AGENTS pointer"
assert_contains "$architecture" "manual \`/debrief\` is the reset-time catch-all" "architecture pointer"
assert_contains "$overview" 'Manual reset-time catch-all' "overview pointer"

printf 'ok - debrief skill contract\n'
