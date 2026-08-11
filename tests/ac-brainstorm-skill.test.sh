#!/usr/bin/env bash
# ac-brainstorm-skill.test.sh - contract checks for the captain-invocable
# brainstorm skill: Agent Skills frontmatter, the no-side-effect rule (thinking
# spawns and writes nothing - a cheap scout included), grounding duty
# (recall/scenes/learnings + overlap BEFORE proposing), the verbatim-confirm
# row minting with settled-dimensions-only pins, "no rows" as a valid outcome,
# the upstream boundary (never starts execution), and the split rule (cite
# sections 5/8/9, never duplicate their grammar).

set -euo pipefail
# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

pkg="brainstorm"
dir="$ROOT/.agents/skills/$pkg"
skill="$(<"$dir/SKILL.md")"

assert_not_contains() { case "$1" in *"$2"*) fail "${3:-assert_not_contains}: '$2' found" ;; esac; }

# --- frontmatter: name + description only, spec-compliant ---------------------
front="$(awk 'NR==1&&$0=="---"{f=1;next} f&&$0=="---"{exit} f{print}' "$dir/SKILL.md")"
keys="$(printf '%s\n' "$front" | grep -oE '^[A-Za-z0-9_-]+:' | sort -u | tr '\n' ' ')"
assert_eq "$keys" "description: name: " "frontmatter carries exactly name + description"
name="$(printf '%s\n' "$front" | sed -n 's/^name:[[:space:]]*//p')"
desc="$(printf '%s\n' "$front" | sed -n 's/^description:[[:space:]]*//p')"
assert_eq "$name" "$pkg" "name == package dir"
case "$name" in *[!a-z0-9-]*|-*|*-) fail "name not a portable slug: $name" ;; esac
[ -n "$desc" ] && [ "${#desc}" -le 1024 ] || fail "description empty or > 1024 chars"

# --- description states capability AND activation triggers --------------------
assert_contains "$desc" "/brainstorm" "description names the slash trigger"
assert_contains "$desc" "not yet an order" "description names the exploratory-conversation trigger"
assert_contains "$desc" "no crewmate" "description states the no-spawn posture"

# --- the one hard rule: thinking has no side effects --------------------------
assert_contains "$skill" "spawn NOTHING and write NOTHING" "the no-side-effect rule is stated as law"
assert_contains "$skill" "no scout" "a cheap scout is explicitly inside the ban"
assert_contains "$skill" "conversation
and READS" "instruments are conversation and reads only"
assert_contains "$skill" "needs a scout to answer" "an investigation need becomes a row, not a spawn"

# --- grounding duty before proposing ------------------------------------------
assert_contains "$skill" "ac-know.sh recall" "grounding reads repo knowledge first"
assert_contains "$skill" "records/scenes/" "grounding checks the scene store"
assert_contains "$skill" "records/learnings.md" "grounding checks the learnings ledger"
assert_contains "$skill" "ac-ready.sh overlap" "grounding checks live-task overlap"

# --- ending: verbatim confirm, settled-dims-only pins, no-rows valid ----------
assert_contains "$skill" "VERBATIM" "rows are read back verbatim before minting"
assert_contains "$skill" "ONLY the dimensions the captain actually settled" "pins carry settled dimensions only"
assert_contains "$skill" "src:cap" "the captain's confirmation is the order-source token"
assert_contains "$skill" "escalation gate never re-asks" "a pin minted here is pre-consent"
assert_contains "$skill" '"No rows" is a fully valid ending' "an empty outcome is legitimate"
assert_contains "$skill" "deliberately NOT" "the not-minted list is part of the outcome"

# --- upstream boundary + split rule -------------------------------------------
assert_contains "$skill" "never starts execution" "brainstorm is upstream of every execution flow"
assert_contains "$skill" "duplicates nothing" "grammar/gate/triage stay cited, not copied"
# the split rule bites: the skill must not carry its own copy of the closed
# contract vocabulary (that lives in section 9 / ac_contract_lint alone)
assert_not_contains "$skill" "src|flow|mode|rev|qa|promote" "no duplicated token vocabulary"

# --- catalog registration ------------------------------------------------------
assert_contains "$(<"$ROOT/AGENTS.md")" '`brainstorm` - captain-invocable ideation' "AGENTS.md section 12 lists the skill"
assert_contains "$(<"$ROOT/docs/architecture.md")" '`brainstorm` (captain ideation' "architecture.md lists the skill"

pass
