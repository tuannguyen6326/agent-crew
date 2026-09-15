#!/usr/bin/env bash
# ac-crew-verify-skill.test.sh - contract checks for the crew-verify skill: Agent
# Skills frontmatter, the one command shape it carries (the same one the brief
# scaffold prints), the foreground rule that keeps the round alive under a
# memory-pressured harness, the verdict reading (verdict, reviewed_ref == HEAD,
# the STALE RECEIPT line), the round-N+1 loop with a machine-built --history,
# the boundary against running it inside crew-ship, and - because the
# crewmate on a direct-pr/local-only task is who runs it - its PRESENCE in
# crewmate seeding.

set -euo pipefail
# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

pkg="crew-verify"
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
case "$name" in *[!a-z0-9-]*|-*|*-) fail "name not a portable slug: $name" ;; esac
[ -n "$desc" ] && [ "${#desc}" -le 1024 ] || fail "description empty or > 1024 chars"

# --- the description routes: when a worker reaches for it ---------------------
assert_contains "$desc" "ac-verify.sh codereview" "description names the facade it drives"
assert_contains "$desc" "direct-pr" "description names the modes whose review it fulfils"
assert_contains "$desc" "solo" "description names the solo session as a caller"
assert_contains "$desc" "/crew-verify" "description names the slash invocation"
assert_contains "$desc" "never inside crew-ship" "description excludes the engine that owns its own round"

# --- the one command shape, the same one the brief scaffold prints -----------
assert_contains "$skill" '--repo "$PWD" --ref HEAD' "the round reviews the exact current ref of this tree"
assert_contains "$skill" '--base "$TARGET_REF"' "the base is the recorded target, set first"
assert_contains "$skill" '--intent' "the intent file is the authority the reviewer judges against"
assert_contains "$skill" '--output' "the durable result path is named on the command"
assert_contains "$skill" '--caller "$AC_CREW_ID"' "a crewmate signs the round with its own id"

# --- FOREGROUND: the round must outlive the harness's memory reaper ----------
assert_contains "$skill" "in the FOREGROUND" "the round runs in the foreground"
assert_contains "$skill" "run_in_background" "the background launch is named as the thing forbidden"
assert_contains "$skill" "low on memory" "the reaper's own words are quoted so the reader recognises the kill"

# --- reading the verdict -------------------------------------------------------
assert_contains "$skill" 'verdict' "the result's verdict is read"
assert_contains "$skill" "reviewed_ref" "the receipt's ref is read"
assert_contains "$skill" "git rev-parse HEAD" "the receipt is bound to HEAD by a bare SHA equality"
assert_contains "$skill" "STALE RECEIPT" "the facade's stale-receipt line is recognised"
assert_contains "$skill" "lock holder pid" "a held lock is settled by ps, never by rm"

# --- the fix loop: round N+1 with a machine-built history --------------------
assert_contains "$skill" "--history" "round 2+ carries the previous round as history"
assert_contains "$skill" "jq -c" "the history is machine-built, never hand-written"
assert_contains "$skill" "resolved_ids" "the ledger shape carries the disposition channel"
assert_contains "$skill" "ANY commit after" "any later commit invalidates the receipt"
assert_contains "$skill" "review.max_rounds" "the round cap is the project's, not the reader's"
assert_contains "$skill" "ask-user" "an ask-user verdict holds and is relayed, never decided"

# --- boundaries ---------------------------------------------------------------
assert_contains "$skill" "Never run this inside" "the crew-ship engine's review step is not doubled"
assert_contains "$skill" "never edits" "the reviewer classifies; the caller fixes"

# --- SEEDED: the crewmate on a direct task runs it ---------------------------
assert_contains "$liblines" "$pkg" "the crewmate that owes the round is seeded this skill"
assert_contains "$liblines" "crew-ship" "...alongside the engine that owns the other route"

# --- instructions only: no scripts/ shipped -----------------------------------
[ ! -d "$dir/scripts" ] || fail "crew-verify ships scripts/ - bin/ac-verify.sh is the runner"

printf 'ok - crew-verify skill contract\n'
