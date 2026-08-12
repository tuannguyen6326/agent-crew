#!/usr/bin/env bash
# ac-stuck-crewmate-recovery-skill.test.sh - contract checks for the crewchief
# stuck-crewmate-recovery skill: Agent Skills frontmatter, activation triggers,
# the recovery-preserves-work invariants (never force-teardown, never discard
# dirty work), Agent Crew primitive ownership, and the clean-room absence of
# reference-only names/commands/paths.

set -euo pipefail
# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

pkg="stuck-crewmate-recovery"
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
assert_contains "$desc" "Load after" "description names an activation trigger"
assert_contains "$desc" "stalled" "description names the recovery capability"
assert_contains "$desc" "force-teardown" "description flags the force-teardown boundary"

# --- safety invariants: preserve work ----------------------------------------
assert_contains "$skill" "Never use \`bin/ac-teardown.sh --force\` as recovery." "no force teardown"
assert_contains "$skill" "Never destroy a dirty or unlanded worktree" "no discard of dirty work"
assert_contains "$skill" "Never retype the same instruction" "no blind retype after submit ambiguity"
assert_contains "$skill" "Never send ordinary text into a pane blocked on an interactive dialog" "no text into a blocked pane"

# --- evidence ladder uses existing primitives --------------------------------
assert_contains "$skill" "bin/ac-wake-drain.sh" "drains wakes first"
assert_contains "$skill" "bin/ac-peek.sh" "reads the bounded transcript"
assert_contains "$skill" "bin/ac-crew-state.sh" "reads deterministic state"
assert_contains "$skill" "bin/ac-send.sh" "one corrective steer"
assert_contains "$skill" "--resume-from" "resume preserves the recorded session"
assert_contains "$skill" "\`harness-operations\`" "verified harness action defers to harness-operations"

# --- not-stuck classes + durable outcome -------------------------------------
assert_contains "$skill" "healthy idle CrewDeputy" "not-stuck: idle crewdeputy"
assert_contains "$skill" "blocked interactive prompt" "not-stuck: blocked prompt"
assert_contains "$skill" "point back to the original work" "replacement identity points back"
assert_contains "$skill" "roomchief routing" "preserve roomchief routing ownership"
assert_contains "$skill" "covers ordinary crewmate recovery only" "persistent crewdeputy recovery is out of scope"

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

printf 'ok - stuck-crewmate-recovery skill contract\n'
