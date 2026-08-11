#!/usr/bin/env bash
# ac-brainstorm-skill.test.sh - contract checks for the captain-invocable
# brainstorm skill: Agent Skills frontmatter, the ROOMCHIEF venue (ideation
# runs in a clean-context brainstorm roomchief with its room as the durable
# journal, never the chief's loaded session; --direct stays the quick-riff
# escape hatch), the no-side-effect rule while thinking (no spawns, no
# writes outside the room; ledger-guard machine-bars the roomchief - the
# CREWCHIEF alone mints), grounding duty (recall/scenes/learnings + overlap
# first), the verbatim-confirm row minting with settled-dimensions-only
# pins, "no rows" as a valid outcome, the upstream boundary (never starts
# execution), and the split rule (cite sections 5/8/9, never duplicate
# their grammar).

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
assert_contains "$desc" "DEDICATED brainstorm roomchief" "description names the clean-context venue"
assert_contains "$desc" "machine-barred from the ledger" "description states the mint boundary is enforced"
assert_contains "$desc" "--direct" "description names the quick-riff escape hatch"

# --- venue: roomchief, the crewchief opens and mints only ---------------------
assert_contains "$skill" "DEFAULT venue is a dedicated roomchief" "roomchief is the default venue"
assert_contains "$skill" "open it, and mint at close" "the crewchief's two touches are named"
assert_contains "$skill" "IS the adoption of this one promote" \
  "the promote is the captain's act, not chief drift"
assert_contains "$skill" "--roomchief brainstorm-" "the venue rides standard roomchief machinery"
assert_contains "$skill" "--captain-initiated" "the promote records its captain origin"
assert_contains "$skill" "panes.roomchief" "the profile rides the roomchief dispatch ladder"
assert_contains "$skill" "the captain named a harness in the invocation" "an explicit harness is the captain's choice"
assert_contains "$skill" "--pane roomchief --list" "a routed pane rule is judged by the chief in the loop"
assert_contains "$skill" "the rule is the captain's durable word" "a matching rule carries captain authority, not chief taste"
assert_contains "$skill" "the room IS the
   brief" "the charter posts before the promote (the order gate)"
assert_contains "$skill" "ac-ledger-guard.sh" "the ledger bar is machinery, not discipline"

# --- the one hard rule: thinking has no side effects --------------------------
assert_contains "$skill" "spawns
NOTHING and writes NOTHING outside the room journal" "the no-side-effect rule is stated as law"
assert_contains "$skill" "no crewmate" "a crewmate spawn is explicitly inside the ban"
assert_contains "$skill" "conversation and READS" "instruments are conversation and reads only"
assert_contains "$skill" 'scout to answer" becomes a' "an investigation need becomes a row, not a spawn"
assert_contains "$skill" "cannot touch the ledger" "minting is the crewchief's act alone"

# --- grounding duty before proposing ------------------------------------------
assert_contains "$skill" "ac-know.sh recall" "grounding reads repo knowledge first"
assert_contains "$skill" "records/scenes/" "grounding checks the scene store"
assert_contains "$skill" "records/learnings.md" "grounding checks the learnings ledger"
assert_contains "$skill" "ac-ready.sh overlap" "grounding checks live-task overlap"

# --- ending: verbatim confirm, settled-dims-only pins, no-rows valid ----------
assert_contains "$skill" "VERBATIM" "rows are read back verbatim before minting"
assert_contains "$skill" "carrying ONLY the dimensions the captain" "pins carry settled dimensions only"
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
