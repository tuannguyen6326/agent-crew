#!/usr/bin/env bash
# ac-diagnostic-reasoning-skill.test.sh - contract checks for the crewchief
# diagnostic-reasoning skill: Agent Skills frontmatter, activation triggers, the
# evidence-only boundary (diagnosis never authorizes a fix), Agent Crew command
# ownership, and the clean-room absence of reference-only names/commands/paths.

set -euo pipefail
# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

pkg="diagnostic-reasoning"
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
assert_contains "$desc" "Load" "description names an activation trigger"
assert_contains "$desc" "root-cause" "description names the diagnostic capability"
assert_contains "$desc" "evidence" "description flags the evidence-only boundary"

# --- safety invariant: diagnosis is NOT authorization to change code ----------
assert_contains "$skill" "A diagnostic report is evidence, not authorization to modify code." "diagnosis != authorization"
assert_contains "$skill" "delegate project inspection to a crewmate" "delegation preserves the prime directive"
assert_contains "$skill" "Implementation begins only under the captain" "implementation needs captain authority"

# --- required reasoning contract ---------------------------------------------
assert_contains "$skill" "masking or exposing condition" "trigger/mask/symptom separation"
assert_contains "$skill" "proven path" "failing-vs-proven comparison"
assert_contains "$skill" "smallest practical counterfactual" "counterfactual"
assert_contains "$skill" "disconfirming evidence" "falsification check"
assert_contains "$skill" "observed facts, supported inference, hypotheses, and unresolved uncertainty" "report distinctions"

# --- non-overlap + command ownership -----------------------------------------
assert_contains "$skill" "does not replace \`crew-qa\`" "non-overlap with crew-qa"
assert_contains "$skill" "script headers" "command mechanics stay in the ac-*.sh headers"

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

printf 'ok - diagnostic-reasoning skill contract\n'
