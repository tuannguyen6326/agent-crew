#!/usr/bin/env bash
# ac-project-management-skill.test.sh - contract checks for the crewchief
# project-management skill: Agent Skills frontmatter, activation triggers, the
# destructive-removal boundary (captain-confirmed after preflight), registry and
# prime-directive ownership, and the clean-room absence of reference-only
# names/commands/paths.

set -euo pipefail
# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

pkg="project-management"
dir="$ROOT/.agents/skills/$pkg"
skill="$(<"$dir/SKILL.md")"
liblines="$(grep -n 'AC_CREW_SKILLS=' "$ROOT/bin/ac-lib.sh")"

assert_not_contains() { case "$1" in *"$2"*) fail "${3:-assert_not_contains}: '$2' found" ;; esac; }

# --- frontmatter: name + description only, no non-spec key --------------------
front="$(awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f{print}' "$dir/SKILL.md")"
keys="$(printf '%s\n' "$front" | grep -oE '^[A-Za-z0-9_-]+:' | sort -u | tr '\n' ' ')"
assert_eq "$keys" "description: name: " "frontmatter carries exactly name + description"
name="$(printf '%s\n' "$front" | sed -n 's/^name:[[:space:]]*//p')"
desc="$(printf '%s\n' "$front" | sed -n 's/^description:[[:space:]]*//p')"
assert_eq "$name" "$pkg" "name == package dir"
case "$name" in *[!a-z0-9-]*|-*|*-) fail "name not a portable slug: $name" ;; esac
[ "${#name}" -le 64 ] || fail "name > 64 chars"
[ -n "$desc" ] && [ "${#desc}" -le 1024 ] || fail "description empty or > 1024 chars"

# --- description states BOTH capability AND activation triggers ---------------
assert_contains "$desc" "Load before" "description names an activation trigger"
assert_contains "$desc" "lifecycle" "description names the project-lifecycle capability"
assert_contains "$desc" "captain confirmation" "description flags the destructive-removal boundary"

# --- safety invariant: removal is captain-confirmed after preflight -----------
assert_contains "$skill" "explicit captain confirmation" "removal requires captain confirmation"
assert_contains "$skill" "unpushed commits" "removal preflight inspects unpushed commits"
assert_contains "$skill" "open or unmerged pull requests" "removal preflight inspects PRs"
assert_contains "$skill" "unguarded recursive deletion" "no unguarded rm as a removal path"

# --- registry + prime-directive ownership ------------------------------------
assert_contains "$skill" "records/projects.md" "registry file owner"
assert_contains "$skill" "bin/ac-project-mode.sh" "registry parser owner"
assert_contains "$skill" "projects/<name>" "clone destination"
assert_contains "$skill" "read-only over \`projects/\`" "prime directive preserved"
assert_contains "$skill" "The registry carries NO delivery mode" "the registry answers +yolo only - mode is per-task"
assert_contains "$skill" "never write one into \`records/projects.md\`" "a task's mode never lands in the registry"
assert_contains "$skill" "Visibility defaults to private" "remote-create consent default"

# --- scope boundary + debrief exclusion --------------------------------------
assert_contains "$skill" "per-task delivery-mode triage" "does not own task-level mode triage"
assert_contains "$skill" "not this skill's lifecycle judgment" "crewdeputy home clones are out of scope"
assert_contains "$skill" "never performs project creation, removal, or \`+yolo\` mutation" "debrief never mutates the registry as cleanup"

# --- not seeded to crewmates -------------------------------------------------
assert_not_contains "$liblines" "$pkg" "skill absent from AC_CREW_SKILLS seeding default"

# --- progressive disclosure ceiling ------------------------------------------
lines="$(wc -l <"$dir/SKILL.md")"
[ "$lines" -lt 500 ] || fail "SKILL.md must stay under 500 lines (got $lines)"

# --- clean-room: no reference-only names/commands/dev-home paths --------------
while IFS= read -r f; do
  bad="$(grep -niE 'fm-|/Users/|/home/|\.stow-notes|Orca|Grok' "$f" || true)"
  [ -z "$bad" ] || fail "clean-room leak in $f: $bad"
done < <(find "$dir" -type f)

printf 'ok - project-management skill contract\n'
