#!/usr/bin/env bash
# ac-sdlc-skill.test.sh - the artifact templates the sdlc crew skill ships: one
# per artifact of the chain, each named by SKILL.md, carrying the fields the
# chain's readers key on - and the layout reference that defaults every key a
# fleet's sdlc.md may override.

set -euo pipefail
# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

dir="$ROOT/.agents/skills/sdlc"
skill="$(<"$dir/SKILL.md")"

for t in intent spec plan repo-plan test-plan qa-report release-notes; do
  [ -f "$dir/assets/templates/$t.md" ] || fail "template missing: assets/templates/$t.md"
  assert_contains "$skill" "templates/$t.md" "SKILL.md names the $t template"
done
for field in main_repo: repos: based_on: requested_by:; do
  assert_contains "$(<"$dir/assets/templates/intent.md")" "$field" "intent template carries $field"
done
assert_contains "$(<"$dir/assets/templates/qa-report.md")" "source_sha" "qa report template binds the verdict to the source"
assert_contains "$(<"$dir/assets/templates/release-notes.md")" "source_sha" "release notes bind the change to the source the passing round exercised"

# Every layout key a fleet's sdlc.md may override has a default in the layout
# reference SKILL.md routes every path through.
assert_contains "$skill" "references/layout.md" "SKILL.md routes every path through the layout reference"
layout="$(<"$dir/references/layout.md")"
for key in change record slug live snapshot repo_plan intent spec contracts plan test_plan qa_report release_notes requirements tech contracts_live regression incidents; do
  assert_contains "$layout" "| \`$key\` |" "the layout reference defines the $key key"
done

pass
