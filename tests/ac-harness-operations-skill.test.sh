#!/usr/bin/env bash
# ac-harness-operations-skill.test.sh - contract checks for the crewchief
# harness-operations skill: Agent Skills frontmatter, activation triggers, the
# supported-harness-only + read-from-meta + fail-closed invariants, the
# source-of-truth split with bin/ac-spawn.sh and bin/ac-backend.sh, and the
# clean-room absence of reference-only names/commands/paths and unsupported
# runtimes.

set -euo pipefail
# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

pkg="harness-operations"
dir="$ROOT/.agents/skills/$pkg"
skill="$(<"$dir/SKILL.md")"
ref="$(<"$dir/references/harness-facts.md")"
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
assert_contains "$desc" "harness" "description names the harness-operations capability"
assert_contains "$desc" "never guess" "description flags the do-not-guess invariant"

# --- supported harnesses only + herdr-only backend ---------------------------
assert_contains "$skill" "claude" "supported harness: claude"
assert_contains "$skill" "codex" "supported harness: codex"
assert_contains "$skill" "opencode" "supported harness: opencode"
assert_contains "$skill" "herdr session backend remains the only" "herdr is the only backend"

# --- read-from-meta + fail-closed invariants ---------------------------------
assert_contains "$skill" "Read the target harness from the task meta" "read harness from meta"
assert_contains "$skill" "never guess from your own harness" "do not guess from self"
assert_contains "$skill" "fails closed to natural-language steering" "unknown/custom fails closed"
assert_contains "$skill" "Facts for unsupported runtimes must not be imported" "no unsupported-runtime facts"
assert_contains "$skill" "before the adapter is declared supported" "new-harness verification gate"

# --- source-of-truth split ---------------------------------------------------
assert_contains "$skill" "bin/ac-spawn.sh" "spawn owns launch/model/effort/kickoff/names"
assert_contains "$skill" "bin/ac-backend.sh" "backend owns herdr composer/submit/lifecycle"
assert_contains "$skill" "references/harness-facts.md" "extended facts moved to a reference"

# --- reference file: per-harness verified facts, no unsupported runtimes ------
assert_contains "$ref" "claude" "reference covers claude"
assert_contains "$ref" "codex" "reference covers codex"
assert_contains "$ref" "opencode" "reference covers opencode"
assert_contains "$ref" "--resume" "reference records claude resume support"
assert_contains "$ref" "bin/ac-spawn.sh" "reference cites its code provenance"

# --- not seeded to crewmates -------------------------------------------------
assert_not_contains "$liblines" "$pkg" "skill absent from AC_CREW_SKILLS seeding default"

# --- progressive disclosure ceiling ------------------------------------------
lines="$(wc -l <"$dir/SKILL.md")"
[ "$lines" -lt 500 ] || fail "SKILL.md must stay under 500 lines (got $lines)"

# --- clean-room: no reference-only names/commands/dev-home paths, no rejected
#     runtimes (Codex App / Orca / Pi / Grok adapter facts) ---------------------
while IFS= read -r f; do
  bad="$(grep -niE 'fm-|/Users/|/home/|\.stow-notes|Orca|Grok|Codex App' "$f" || true)"
  [ -z "$bad" ] || fail "clean-room/rejected-runtime leak in $f: $bad"
done < <(find "$dir" -type f)

printf 'ok - harness-operations skill contract\n'
