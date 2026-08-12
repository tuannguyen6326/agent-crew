#!/usr/bin/env bash
# ac-archive.test.sh - the manual data/ archive migration: selection (CLOSED
# only), --dry-run, idempotency, the <year> bucket, restore round-trip, and the
# rule that no automatic path may ever call it.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
D="$AC_HOME/data"

room() {
  # room <family> <line>... - write a room with the given entry lines.
  local fam="$1"; shift
  mkdir -p "$D/$fam"
  { printf '# Room: %s\n\n' "$fam"; printf -- '- %s\n' "$@"; } >"$D/$fam/room.md"
}

# closed in 2026 - the ordinary member
room closed26 \
  '[2026-03-04T00:00:00Z] crewchief> ORDER: do the thing' \
  '[2026-03-05T09:00:00Z] crewchief> CLOSED: landed local main @abc1234'
printf 'the brief\n' >"$D/closed26/brief.md"
printf 'the report\n' >"$D/closed26/report.md"
mkdir -p "$D/closed26/spec"
printf 'spec report\n' >"$D/closed26/spec/report.md"

# closed in 2025 - proves the bucket is the family's OWN closing year, never
# the year the migration runs
room closed25 '[2025-11-30T23:59:59Z] crewchief> CLOSED: landed'

# room, but still OPEN - out of scope, must never move
room openfam '[2026-04-01T00:00:00Z] crewchief> GATE: awaiting captain'

# no room at all (bare scout / self-task) - ambiguous, must never move
mkdir -p "$D/noroom"
printf 'a scout report\n' >"$D/noroom/report.md"

# a CLOSED: entry whose timestamp carries no resolvable year - REFUSED, never
# bucketed by a guess
room noyear '[not-a-timestamp] crewchief> CLOSED: landed somehow'

# DEGENERATE input, built in deliberately: a zero-byte room.md. An empty room
# carries no CLOSED: entry, so the family is OPEN and must be skipped - the
# repo-knowledge lesson from ac_room_list_rows is that a fixture set of only
# representative files proves nothing about the empty case.
mkdir -p "$D/emptyroom"
: >"$D/emptyroom/room.md"

# a prose mention of the marker is NOT a closing entry: the selection is pinned
# to the room's `- [<iso>] <actor>> CLOSED:` grammar, never a substring anywhere
room prosefam '[2026-05-01T00:00:00Z] crewchief> we should post CLOSED: when done'

# --- --dry-run moves nothing and names exactly the set ------------------------
out="$("$BIN/ac-archive.sh" archive --dry-run 2>&1)" || true
assert_contains "$out" "closed26" "dry-run names a closed family"
assert_contains "$out" "2026" "dry-run names the year bucket it would use"
assert_contains "$out" "closed25" "dry-run names the second closed family"
case "$out" in *openfam*) fail "dry-run must not select a family whose room is still open" ;; esac
case "$out" in *noroom*) fail "dry-run must not select a dir with no room" ;; esac
assert_file "$D/closed26/room.md" "dry-run moved nothing"
assert_file "$D/closed25/room.md" "dry-run moved nothing (2025 member)"
assert_no_file "$D/archive" "dry-run created no archive tree at all"

# --- the real run -------------------------------------------------------------
run1="$("$BIN/ac-archive.sh" archive 2>&1)" || rc1=$?
assert_eq "${rc1:-0}" "1" "a REFUSED family makes the run exit non-zero, never silently"
assert_contains "$run1" "noyear" "the unresolvable-year family is named"
assert_contains "$run1" "refused" "and it is reported as a refusal, not a skip"

# bucketed by the family's own CLOSED: year
assert_file "$D/archive/2026/closed26/room.md" "closed26 archived under its own closing year"
assert_file "$D/archive/2025/closed25/room.md" "closed25 archived under 2025, not the run year"
assert_no_file "$D/closed26" "the live dir is gone once archived"
assert_no_file "$D/closed25" "the live dir is gone once archived (2025 member)"

# the WHOLE task dir travels, not just the room
assert_file "$D/archive/2026/closed26/brief.md" "the brief travels with the family"
assert_file "$D/archive/2026/closed26/report.md" "the report travels with the family"
assert_file "$D/archive/2026/closed26/spec/report.md" "nested stage dirs travel too"

# out-of-scope dirs are untouched
assert_file "$D/openfam/room.md" "an OPEN family is never moved"
assert_file "$D/noroom/report.md" "a dir with no room is never moved"
assert_file "$D/noyear/room.md" "a REFUSED family stays exactly where it was"
assert_file "$D/emptyroom/room.md" "a zero-byte room.md is an OPEN family, never archived"
assert_file "$D/prosefam/room.md" "a prose mention of the marker never closes a family"

# --- idempotency: a second run changes nothing and says so --------------------
before="$(find "$D" | sort)"
run2="$("$BIN/ac-archive.sh" archive 2>&1)" || true
after="$(find "$D" | sort)"
assert_eq "$after" "$before" "a second run changes nothing on disk"
assert_contains "$run2" "archived 0" "a second run reports it archived nothing"

# --- restore: reversible, and a round trip is byte-identical ------------------
sum_before="$(cd "$D/archive/2026/closed26" && find . -type f | sort | xargs shasum)"
"$BIN/ac-archive.sh" restore closed26 >/dev/null
assert_file "$D/closed26/room.md" "restore puts the family back at its live path"
assert_no_file "$D/archive/2026/closed26" "restore leaves nothing behind in the archive"
sum_after="$(cd "$D/closed26" && find . -type f | sort | xargs shasum)"
assert_eq "$sum_after" "$sum_before" "the archive -> restore round trip is byte-identical"

# restore --dry-run moves nothing
"$BIN/ac-archive.sh" archive >/dev/null 2>&1 || true
assert_file "$D/archive/2026/closed26/room.md" "re-archived for the dry-run check"
rout="$("$BIN/ac-archive.sh" restore closed26 --dry-run 2>&1)"
assert_contains "$rout" "closed26" "restore --dry-run names what it would move"
assert_file "$D/archive/2026/closed26/room.md" "restore --dry-run moved nothing"

# restore refuses to clobber a live dir of the same name
mkdir -p "$D/closed26"
assert_fails_with "already exists" -- "$BIN/ac-archive.sh" restore closed26
assert_file "$D/archive/2026/closed26/room.md" "a refused restore left the archive intact"
rmdir "$D/closed26"

# restore refuses a family that is not archived
assert_fails_with "not archived" -- "$BIN/ac-archive.sh" restore nosuchfam

# --- archive/ is never mistaken for a task family ----------------------------
# It has no room.md of its own, and the selection walks data/<fam>/room.md only,
# so a re-run can never nest data/archive/<year>/archive/.
"$BIN/ac-archive.sh" archive >/dev/null 2>&1 || true
assert_no_file "$D/archive/2026/archive" "the archive root is never archived into itself"

# --- the migration has NO caller on any automatic path -----------------------
# The whole point of splitting code from the move: a migration that can fire by
# itself defeats the split. The predicate is EXECUTION, not mention - a comment
# or doc line naming the script is the cross-reference AGENTS.md section 13 asks
# for, while a line that RUNS it is the defect. Comment lines are stripped
# first, then any surviving mention outside the script itself is a caller.
callers="$(grep -rn 'ac-archive\.sh' "$ROOT/bin" "$ROOT/.agents" "$ROOT/docs" 2>/dev/null \
  | grep -v '^[^:]*/ac-archive\.sh:' \
  | grep -vE '^[^:]*:[0-9]+:[[:space:]]*(#|\*|//|\|)' || true)"
assert_eq "$callers" "" "no script, skill or doc RUNS the migration - it is manual-only"

pass
