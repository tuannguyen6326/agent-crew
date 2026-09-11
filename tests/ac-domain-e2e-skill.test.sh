#!/usr/bin/env bash
# ac-domain-e2e-skill.test.sh - contract checks for the domain-e2e skill: Agent
# Skills frontmatter, the reuse rule that is this route's whole reason to
# exist, the measured disciplines a green depends on (baseline, negative
# control, skip accounting, read-back by the write's own id), the
# shared-environment write contract, the boundary against editing product code,
# and - unlike the captain/chief-facing skills - its PRESENCE in crewmate
# seeding, since a crewmate leased into the suite is who runs it.

set -euo pipefail
# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

pkg="domain-e2e"
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
[ -n "$desc" ] && [ "${#desc}" -le 1024 ] || fail "description empty or > 1024 chars"

# --- the description routes: how a crewmate knows this is its route ----------
assert_contains "$desc" "ac-domain.sh qa-repo" "description names the declaration that selects this route"
assert_contains "$desc" "Not crew-qa" "description distinguishes it from the profile-driven route"
assert_contains "$desc" "mints no attestation" "description states the one thing this route cannot do"

# --- REUSE: the rule the whole route exists to hold --------------------------
assert_contains "$skill" "reused, never re-created" "the suite is reused"
assert_contains "$skill" "Standing up a second suite" "a second suite is named as the thing prevented"

# --- the suite's own docs outrank this skill on mechanics --------------------
assert_contains "$skill" "authoritative for its mechanics" "the repo owns how its stack boots"

# --- extending is part of the slice, not a follow-up -------------------------
assert_contains "$skill" "widens the suite in the SAME slice" "the suite never lags the product"

# --- the measured disciplines a green depends on -----------------------------
assert_contains "$skill" "BASELINE before you read the diff" "baseline precedes the diff read"
assert_contains "$skill" "assemble ALL of them" "a hand-assembled boot keeps every step"
assert_contains "$skill" "NEGATIVE CONTROL" "a cleared red is proven by re-breaking the one thing"
assert_contains "$skill" "Count the skips FIRST" "skips are counted before the pass line is believed"
assert_contains "$skill" "id the WRITE returned" "a read-back binds the write's own id"
assert_contains "$skill" "never what its title says" "a pass is read by what it asserts"

# --- shared-environment writes -----------------------------------------------
assert_contains "$skill" "EXPLICIT authority in the brief" "a shared write needs authority"
assert_contains "$skill" "list in the report exactly what was written" "every write is accounted for"

# --- boundaries ---------------------------------------------------------------
assert_contains "$skill" "Never edit product code" "the suite never fixes the product"
assert_contains "$skill" "never weaken an assertion" "no green bought by weakening"
assert_contains "$skill" "not diagnose in the report what you did not measure" "no guessed cause in a report"

# --- SEEDED, unlike the chief-facing skills ----------------------------------
assert_contains "$liblines" "$pkg" "the crewmate that runs the suite is seeded this skill"
assert_contains "$liblines" "crew-qa" "...alongside the other verification route"

# --- instructions only: no scripts/ shipped -----------------------------------
[ ! -d "$dir/scripts" ] || fail "domain-e2e ships scripts/ - the suite owns its own runner"

printf 'ok - domain-e2e skill contract\n'
