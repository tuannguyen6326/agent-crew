#!/usr/bin/env bash
# ac-sdlc-skill.test.sh - the artifact templates the sdlc crew skill ships: one
# per artifact of the chain, each named by SKILL.md, carrying the fields the
# chain's readers key on.

set -euo pipefail
# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

dir="$ROOT/.agents/skills/sdlc"
skill="$(<"$dir/SKILL.md")"

for t in intent spec plan repo-plan test-plan qa-report; do
  [ -f "$dir/assets/templates/$t.md" ] || fail "template missing: assets/templates/$t.md"
  assert_contains "$skill" "templates/$t.md" "SKILL.md names the $t template"
done
for field in main_repo: repos: based_on: requested_by:; do
  assert_contains "$(<"$dir/assets/templates/intent.md")" "$field" "intent template carries $field"
done
assert_contains "$(<"$dir/assets/templates/qa-report.md")" "source_sha" "qa report template binds the verdict to the source"

pass
