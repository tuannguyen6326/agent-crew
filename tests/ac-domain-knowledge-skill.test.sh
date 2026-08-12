#!/usr/bin/env bash
# ac-domain-knowledge-skill.test.sh - contract checks for the captain-invocable
# domain-knowledge skill: Agent Skills frontmatter, the one-idempotent-flow
# design constraint (no onboard/update mode fork), the verbs it cites
# (list/new/validate) and the exact symlink depth it prescribes, the
# unmodified-ac-domain.sh boundary, and its absence from crewmate seeding.

set -euo pipefail
# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

pkg="domain-knowledge"
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

# --- description states captain invocation, crewchief scope, activation -------
assert_contains "$desc" "/domain-knowledge <name> [project]" "description states the captain invocation form"
assert_contains "$desc" "crewchief's own unscoped session" "description states it runs in the crewchief session"
assert_contains "$desc" "Load when the captain says" "description names activation triggers"

# --- the one hard design constraint: no mode fork ------------------------------
assert_contains "$skill" "ONE idempotent flow" "onboard and update are one flow, not two modes"
assert_contains "$skill" "no onboard mode and no update mode" "no mode fork stated explicitly"

# --- cites the verbs it actually uses: list, new, validate --------------------
assert_contains "$skill" "bin/ac-domain.sh list" "cites the resolve-check verb"
assert_contains "$skill" "bin/ac-domain.sh new " "cites the create verb"
assert_contains "$skill" "bin/ac-domain.sh validate" "cites the closing-gate verb"
assert_contains "$skill" "Close every run on \`validate\`" "validate is mandated as the closing gate"

# --- exact symlink depth, copied from cmd_new ---------------------------------
assert_contains "$skill" "../../../projects/<p>       <pkg>/projects/<p>" "clone symlink at the exact depth"
assert_contains "$skill" "../../../projects/<p>.yaml  <pkg>/projects/<p>.yaml" "yaml symlink at the exact depth"

# --- (b) scope change moves both surfaces in one action -----------------------
assert_contains "$skill" "BOTH surfaces" "scope change moves symlinks and heading together"

# --- boundary: never modify bin/ac-domain.sh ----------------------------------
assert_contains "$skill" "Do not modify \`bin/ac-domain.sh\`" "boundary against reopening ac-domain.sh"
assert_contains "$skill" "needs-decision:" "unsatisfiable acceptance escalates instead of expanding scope"

# --- instructions only: no scripts/ shipped ------------------------------------
[ ! -d "$dir/scripts" ] || fail "domain-knowledge ships scripts/ - it must call ac-domain.sh, never re-implement it"

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

printf 'ok - domain-knowledge skill contract\n'
