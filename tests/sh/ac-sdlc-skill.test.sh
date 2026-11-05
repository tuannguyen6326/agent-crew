#!/usr/bin/env bash
# ac-sdlc-skill.test.sh - contract checks for the sdlc crew skill: Agent Skills
# frontmatter, the description that routes a flow:sdlc crewmate to it, the
# artifact templates it ships, the commit order it binds the execution
# crewmate to (plan before code, one commit per accepted artifact, the snapshot
# never rewritten), the contract it defers to, and its PRESENCE in crewmate
# seeding - a crewmate on an sdlc change is who reads it.

set -euo pipefail
# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

pkg="sdlc"
dir="$ROOT/.agents/skills/$pkg"
[ -f "$dir/SKILL.md" ] || fail "package $pkg is missing its SKILL.md"
skill="$(<"$dir/SKILL.md")"
liblines="$(grep -n 'AC_CREW_SKILLS=' "$ROOT/bin/ac-lib.sh")"

# --- frontmatter: name + description only, no non-spec key --------------------
front="$(awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f{print}' "$dir/SKILL.md")"
keys="$(printf '%s\n' "$front" | grep -oE '^[A-Za-z0-9_-]+:' | sort -u | tr '\n' ' ')"
assert_eq "$keys" "description: name: " "frontmatter carries exactly name + description"
name="$(printf '%s\n' "$front" | sed -n 's/^name:[[:space:]]*//p')"
desc="$(printf '%s\n' "$front" | sed -n 's/^description:[[:space:]]*//p')"
assert_eq "$name" "$pkg" "name == package dir"
[ -n "$desc" ] && [ "${#desc}" -le 1024 ] || fail "description empty or > 1024 chars"

# --- the description routes: when a crewmate reaches for it -------------------
assert_contains "$desc" "Flow: sdlc" "description names the brief line that selects it"
assert_contains "$desc" "/sdlc" "description names the slash invocation"

# --- the templates it ships, one per artifact of the chain --------------------
for t in intent spec plan repo-plan test-plan qa-report; do
  [ -f "$dir/assets/templates/$t.md" ] || fail "template missing: assets/templates/$t.md"
  assert_contains "$skill" "templates/$t.md" "SKILL.md names the $t template"
done
assert_contains "$(<"$dir/assets/templates/intent.md")" "main_repo:" "intent template names the main repository"
assert_contains "$(<"$dir/assets/templates/intent.md")" "repos:" "intent template lists the participating repositories"
assert_contains "$(<"$dir/assets/templates/intent.md")" "based_on:" "intent template carries the lineage field"
assert_contains "$(<"$dir/assets/templates/intent.md")" "requested_by:" "intent template names a role, never a person"
case "$(<"$dir/assets/templates/intent.md")" in *"own words"*) fail "intent template must not ask for a quotation" ;; esac
assert_contains "$skill" "never quotes the captain" "an artifact states facts, never the captain's words"
assert_contains "$skill" "no local fact" "an artifact carries no local path or fleet detail"
assert_contains "$skill" "grep -rnE '/Users/|/home/|ac-homes" "the local-fact check is a command, not prose"
assert_contains "$skill" "before the first commit" "execution re-runs the check before the chain commit"
assert_contains "$(<"$dir/assets/templates/plan.md")" "Deploy order" "main plan template carries the deploy order"
assert_contains "$(<"$dir/assets/templates/plan.md")" "Rollback" "main plan template carries the rollback path"
assert_contains "$(<"$dir/assets/templates/qa-report.md")" "source_sha" "qa report template binds the verdict to the source"

# --- the contract it defers to and the paths it binds -------------------------
assert_contains "$skill" "docs/sdlc-flow.md" "the flow spec is named as the contract owner"
assert_contains "$skill" "docs/features/<feature>/changes/<change>/" "the snapshot path shape is stated"
assert_contains "$skill" ".claude/skills/sdlc/" "a repo-shipped override is named"

# --- the commit order the execution crewmate follows --------------------------
assert_contains "$skill" "before any code" "plan lands before code"
assert_contains "$skill" "one commit per artifact" "each accepted artifact is its own commit"
assert_contains "$skill" "same commit" "a plan departure updates the plan in the same commit"
assert_contains "$skill" "never rewritten" "the snapshot is immutable after landing"
assert_contains "$skill" "qa-report.md" "the QA report closes the chain"

# --- seeding: a crewmate on an sdlc change reads it in its worktree -----------
assert_contains "$liblines" "$pkg" "skill present in AC_CREW_SKILLS seeding default"

pass
