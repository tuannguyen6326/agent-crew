#!/usr/bin/env bash
# ac-home-seed.test.sh - crewdeputy home provisioning: structure, config
# inheritance, project clones with origin re-pointing, registry lines,
# duplicate/missing-project refusals.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

# Parent fleet: one project clone, some config, fleet CREWMATE.md.
repo="$(make_repo alpha)"
git -C "$repo" remote add origin https://example.test/alpha.git
git clone --quiet "$repo" "$AC_HOME/projects/alpha"
git -C "$AC_HOME/projects/alpha" remote set-url origin https://example.test/alpha.git
printf 'herdr\n' >"$AC_HOME/config/backend"
printf 'codex\n' >"$AC_HOME/config/crew-harness"
printf 'lab\n' >"$AC_HOME/config/herdr-session"
printf 'wPARENT\n' >"$AC_HOME/config/herdr-workspace"
printf 'FLEET RULES\n' >"$AC_HOME/CREWMATE.md"
printf '# Projects\n\n- alpha [direct-pr] - a project (added 2026-07-13)\n' >"$AC_HOME/records/projects.md"

home="$("$BIN/ac-home-seed.sh" mate1 --projects alpha 2>/dev/null)"
assert_eq "$home" "$AC_HOME/crewdeputies/mate1" "prints the home path"
for d in state data config projects; do
  [ -d "$home/$d" ] || fail "missing $d/ in seeded home"
done
assert_eq "$(cat "$home/config/backend")" "herdr" "backend inherited"
assert_eq "$(cat "$home/config/crew-harness")" "codex" "crew-harness inherited"
assert_eq "$(cat "$home/config/herdr-session")" "lab" "herdr-session inherited (the herdr server session is shared)"
assert_no_file "$home/config/herdr-workspace" "herdr-workspace NOT inherited - a workspace id is fleet-specific, the crewdeputy owns its own group"
assert_eq "$(cat "$home/CREWMATE.md")" "FLEET RULES" "CREWMATE.md inherited"
assert_file "$home/.ac-crewdeputy-home" "crewdeputy marker for the turn-end guard"
[ -d "$home/projects/alpha/.git" ] || fail "project not cloned into home"
assert_eq "$(git -C "$home/projects/alpha" remote get-url origin)" "https://example.test/alpha.git" "origin re-pointed to real remote"
assert_contains "$(cat "$home/records/projects.md")" "- alpha [direct-pr]" "registry line carried over"
# Registered with the parent in the v2 routing-table grammar: the line its own
# parser accepts, carrying a charter placeholder and an EMPTY scope - seeding
# cannot know the scope, and a scopeless entry is never routable.
rec="$(bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; ac_deputy_parse '$AC_HOME/records/crewdeputies.md'" \
  | awk -F'\t' '$2 == "mate1"')"
assert_eq "$(printf '%s\n' "$rec" | cut -f1)" "VALID" "the seeded line parses as VALID"
assert_eq "$(printf '%s\n' "$rec" | cut -f3)" "$home" "the seeded line records the home"
assert_eq "$(printf '%s\n' "$rec" | cut -f5)" "" "the seeded line has NO scope - not routable until the chief fills it in"
assert_eq "$(printf '%s\n' "$rec" | cut -f6)" "alpha" "the seeded line carries the clone list"
[ -n "$(printf '%s\n' "$rec" | cut -f4)" ] || fail "the seeded line needs a charter placeholder to be well-formed"
# The parent had no records/captain.md when mate1 was seeded, so mate1 gets
# none - a crewdeputy without recorded style starts clean, like a fresh fleet.
assert_no_file "$home/records/captain.md" "no captain.md seeded when the parent has none"

# Captain style IS seed-copied when the parent records it: the crewdeputy's
# captain-facing prose should match the fleet voice from turn one.
printf 'CAPTAIN: TN. Style: terse, no hedging.\n' >"$AC_HOME/records/captain.md"
caphome="$("$BIN/ac-home-seed.sh" mate-cap --no-projects 2>/dev/null)"
assert_eq "$(cat "$caphome/records/captain.md")" "CAPTAIN: TN. Style: terse, no hedging." \
  "parent captain.md seed-copied into the crewdeputy"

# Seeding SAYS the line is not routable yet - a silently scopeless deputy would
# just never be picked at intake, with nothing on screen explaining why.
err="$("$BIN/ac-home-seed.sh" mate-scope --no-projects 2>&1 >/dev/null)"
assert_contains "$err" "scope:" "seeding names the field the chief must fill in"
assert_eq "$(bash -c "set -euo pipefail; . '$BIN/ac-lib.sh'; ac_deputy_parse '$AC_HOME/records/crewdeputies.md'" \
  | awk -F'\t' '$2 == "mate-scope" { print $6 }')" "none" "a clone-less deputy records projects: none"

# Refusals: duplicate home, unknown project, no explicit projects decision.
assert_fails "$BIN/ac-home-seed.sh" mate1 --no-projects
assert_fails "$BIN/ac-home-seed.sh" mate2 --projects nosuch
assert_fails "$BIN/ac-home-seed.sh" mate2

# --no-projects seeds an empty-projects home.
"$BIN/ac-home-seed.sh" mate3 --no-projects >/dev/null 2>&1
[ -d "$AC_HOME/crewdeputies/mate3/projects" ] || fail "mate3 projects dir missing"

# Mint-side grammar is [a-z0-9-] - a deputy name IS an ac-spawn id (spawned
# afterwards with `ac-spawn.sh <name> --crewdeputy`), so the same tightened
# charset as ac-brief.sh/ac-spawn.sh applies here: underscore and uppercase
# must die immediately, naming [a-z0-9-], with no home directory created.
err="$("$BIN/ac-home-seed.sh" my_deputy --no-projects 2>&1 || true)"
assert_contains "$err" "name must be [a-z0-9-]" "underscore name refused, naming the tightened charset"
assert_no_file "$AC_HOME/crewdeputies/my_deputy" "no home created for a refused name"
err="$("$BIN/ac-home-seed.sh" MyDeputy --no-projects 2>&1 || true)"
assert_contains "$err" "name must be [a-z0-9-]" "uppercase name refused, naming the tightened charset"
assert_no_file "$AC_HOME/crewdeputies/MyDeputy" "no home created for a refused name"

# A valid lowercase-hyphen name still seeds (no regression in the happy path).
"$BIN/ac-home-seed.sh" mate-four --no-projects >/dev/null 2>&1
[ -d "$AC_HOME/crewdeputies/mate-four" ] || fail "mate-four home missing"

pass
