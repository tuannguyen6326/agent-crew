#!/usr/bin/env bash
# ac-archive.test.sh - the manual data/ archive migration: selection (CLOSED
# only), --dry-run, idempotency, the <year> bucket, restore round-trip, and the
# rule that no automatic path may ever call it.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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

# --- room prose in any encoding ----------------------------------------------
# A byte that is not UTF-8 (a Latin-1 e acute) aborted the closing-year read
# under a UTF-8 locale and, through set -e, the whole run.
room latinfam "$(printf '[2026-02-01T00:00:00Z] crewchief> caf\351 menu')" \
  '[2026-02-02T00:00:00Z] crewchief> CLOSED: landed'
LC_ALL=en_US.UTF-8 "$BIN/ac-archive.sh" archive >/dev/null 2>&1 || true
assert_file "$D/archive/2026/latinfam/room.md" "a non-UTF-8 byte never aborts the run: the room is archived under its year"

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

# --- differential: src/archive.ts against the frozen bash original -----------
# DISPUTED: the implementation (tests/fixtures/ac-archive.sh under bash vs src/archive.ts through bin/ac-archive.sh)
# HELD-CONSTANT: two homes seeded alike ($OH for the oracle, $NH for the shim), argv, LC_ALL=C on both sides; stdout, stderr (the home path spelled HOME), exit status and `find data | LC_ALL=C sort` of each home compared whole after every run.
# LC_ALL=C because bash 3.2 walks data/*/ (and archive/*/<fam>) in libc collation order under a UTF-8 locale - an outside actor's order, never a contract - while the port walks in byte order, the repo's own `LC_ALL=C sort` idiom; row 9 shows the two apart.
obin="$(make_oracle_bin ac-archive)"
OH="$TMP/oh"; NH="$TMP/nh"
mkdir -p "$OH" "$NH"
both() {  # both <fn> <args...> - run a seeding step with D at each home's data/
  local h; for h in "$OH" "$NH"; do D="$h/data"; "$@"; done
}
wipe() { rm -rf "$D"; }
rawroom() {  # rawroom <family> <printf-format> - a room written as bytes
  mkdir -p "$D/$1"; printf -- "$2" >"$D/$1/room.md"
}
seed_fixture() {  # the file's own fixture set, rebuilt at $D
  room closed26 \
    '[2026-03-04T00:00:00Z] crewchief> ORDER: do the thing' \
    '[2026-03-05T09:00:00Z] crewchief> CLOSED: landed local main @abc1234'
  printf 'the brief\n' >"$D/closed26/brief.md"
  printf 'the report\n' >"$D/closed26/report.md"
  mkdir -p "$D/closed26/spec"
  printf 'spec report\n' >"$D/closed26/spec/report.md"
  room closed25 '[2025-11-30T23:59:59Z] crewchief> CLOSED: landed'
  room openfam '[2026-04-01T00:00:00Z] crewchief> GATE: awaiting captain'
  mkdir -p "$D/noroom"; printf 'a scout report\n' >"$D/noroom/report.md"
  room noyear '[not-a-timestamp] crewchief> CLOSED: landed somehow'
  mkdir -p "$D/emptyroom"; : >"$D/emptyroom/room.md"
  room prosefam '[2026-05-01T00:00:00Z] crewchief> we should post CLOSED: when done'
}
run_oracle() { (cd "$OH" && AC_HOME="$OH" LC_ALL="${1:-C}" "$obin/ac-archive.sh" "${@:2}") >"$TMP/o.raw" 2>"$TMP/o.err"; }
run_shim() { (cd "$NH" && AC_HOME="$NH" LC_ALL="${1:-C}" "$BIN/ac-archive.sh" "${@:2}") >"$TMP/n.raw" 2>"$TMP/n.err"; }
tree() { (cd "$1" && find data 2>/dev/null | LC_ALL=C sort); }
same() {  # same <args...> - oracle on $OH and shim on $NH answer byte-identically and leave the same tree
  local o_rc=0 n_rc=0
  run_oracle C "$@" || o_rc=$?
  run_shim C "$@" || n_rc=$?
  LC_ALL=C sed "s#$OH#HOME#g" "$TMP/o.raw" >"$TMP/o.out"; LC_ALL=C sed "s#$OH#HOME#g" "$TMP/o.err" >"$TMP/o.err2"
  LC_ALL=C sed "s#$NH#HOME#g" "$TMP/n.raw" >"$TMP/n.out"; LC_ALL=C sed "s#$NH#HOME#g" "$TMP/n.err" >"$TMP/n.err2"
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*'"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 4)"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 4)"
  assert_eq "$(tree "$NH")" "$(tree "$OH")" "differential tree for '$*'"
}
shim_out() { cat "$TMP/n.out"; }

# 1. the fixture set: dry-run, the real run, the idempotent re-run (noyear refuses every time)
both wipe; both seed_fixture
same archive --dry-run
assert_eq "$(shim_out)" "would archive  closed25 -> archive/2025/closed25
would archive  closed26 -> archive/2026/closed26
refused  noyear - CLOSED: entry carries no resolvable year
would archive 2 family(ies); refused 1" "dry-run: exact line shapes, byte order, the trailer counts dry-run candidates"
same archive
assert_eq "$(tail -n 1 "$TMP/n.out")" "archived 2 family(ies); refused 1" "the real trailer"
same archive
assert_eq "$(shim_out)" "refused  noyear - CLOSED: entry carries no resolvable year
archived 0 family(ies); refused 1" "a re-run refuses noyear again and archives nothing"

# 2. no refusal: exit 0
both wipe
both room closed26 '[2026-03-05T09:00:00Z] crewchief> CLOSED: landed'
both room closed25 '[2025-11-30T23:59:59Z] crewchief> CLOSED: landed'
same archive
assert_eq "$(shim_out)" "archived  closed25 -> archive/2025/closed25
archived  closed26 -> archive/2026/closed26
archived 2 family(ies); refused 0" "a clean run"

# 3. data/ absent (minted as a side effect, dry run or not) and data/ empty
both wipe
same archive --dry-run
assert_eq "$(tree "$NH")" "data" "a bare home gains data/ even on a dry run"
same archive
mkdir_data() { mkdir -p "$D"; }
both wipe; both mkdir_data
same archive
assert_eq "$(shim_out)" "archived 0 family(ies); refused 0" "an empty data/ archives nothing, exit 0"

# 4. the destination already exists: refused with the absolute path, exit 1
both wipe
both room closed26 '[2026-03-05T09:00:00Z] crewchief> CLOSED: landed'
mk_dest() { mkdir -p "$D/archive/2026/closed26"; }
both mk_dest
same archive --dry-run
assert_eq "$(shim_out)" "refused  closed26 - HOME/data/archive/2026/closed26 already exists
would archive 0 family(ies); refused 1" "an occupied destination refuses, dry run included"
same archive

# 5. two CLOSED lines in different years: the last wins
both wipe
both room lastwins '[2024-01-01T00:00:00Z] crewchief> CLOSED: first' '[2026-01-01T00:00:00Z] crewchief> CLOSED: again'
both room firstlast '[2026-01-01T00:00:00Z] crewchief> CLOSED: first' '[2024-01-01T00:00:00Z] crewchief> CLOSED: again'
same archive --dry-run
same archive
assert_eq "$(shim_out)" "archived  firstlast -> archive/2024/firstlast
archived  lastwins -> archive/2026/lastwins
archived 2 family(ies); refused 0" "the year of the LAST closing entry"

# 6. the marker off its grammar position: `[x]` with no actor, an actor holding `>`
both wipe
both room ticked '[x] CLOSED: tick' '[2026-01-01T00:00:00Z] a> b CLOSED: hidden'
both room halfmark '[x] done> CLOSED: tick' '[2026-01-01T00:00:00Z] crewchief> nothing'
same archive
assert_eq "$(shim_out)" "refused  halfmark - CLOSED: entry carries no resolvable year
archived 0 family(ies); refused 1" "ticked is skipped (no entry matches); halfmark matches the marker but no line carries a year"

# 7. a non-UTF-8 byte on the CLOSED line itself
both wipe
both rawroom e9fam '- [2026-02-02T00:00:00Z] caf\351> CLOSED: landed\n'
same archive
assert_eq "$(shim_out)" "archived  e9fam -> archive/2026/e9fam
archived 1 family(ies); refused 0" "under LC_ALL=C both archive it"
# The ONE result divergence, named: under a UTF-8 locale BSD grep's `[^>]*`
# cannot match the invalid byte, so the original SKIPS the family (reads it as
# still open); the port matches bytes (room prose is bytes - closed_year's own
# rule) and archives it under any locale. A fail-path artifact of the external
# tool, not reproduced.
both wipe
both rawroom e9fam '- [2026-02-02T00:00:00Z] caf\351> CLOSED: landed\n'
o_rc=0; run_oracle en_US.UTF-8 archive || o_rc=$?
n_rc=0; run_shim en_US.UTF-8 archive || n_rc=$?
assert_eq "$o_rc $n_rc" "0 0" "UTF-8 locale, the e9 room: both exit 0"
assert_eq "$(cat "$TMP/o.raw")" "archived 0 family(ies); refused 0" "the original under a UTF-8 locale skips the room whose CLOSED line carries an invalid byte"
assert_eq "$(cat "$TMP/n.raw")" "archived  e9fam -> archive/2026/e9fam
archived 1 family(ies); refused 0" "the port archives it: bytes, whatever the locale"
assert_file "$NH/data/archive/2026/e9fam/room.md" "the port moved it"
assert_file "$OH/data/e9fam/room.md" "the original left it"

# 8. a CRLF room
both wipe
both rawroom crlf '- [2026-03-05T09:00:00Z] crewchief> CLOSED: x\r\n'
same archive
assert_eq "$(shim_out)" "archived  crlf -> archive/2026/crlf
archived 1 family(ies); refused 0" "CR is kept on the line and the marker still matches"

# 9. ordering across mixed-case, punctuated and numeric names
both wipe
for f in b-fam B_fam bfam a.fam A-fam 10 9; do
  both room "$f" '[2026-01-01T00:00:00Z] crewchief> CLOSED: x'
done
same archive --dry-run
assert_eq "$(shim_out)" "would archive  10 -> archive/2026/10
would archive  9 -> archive/2026/9
would archive  A-fam -> archive/2026/A-fam
would archive  B_fam -> archive/2026/B_fam
would archive  a.fam -> archive/2026/a.fam
would archive  b-fam -> archive/2026/b-fam
would archive  bfam -> archive/2026/bfam
would archive 7 family(ies); refused 0" "byte order"
# Named divergence: under en_US.UTF-8 the original's glob follows libc
# collation (case-folded, punctuation-insensitive: a.fam lands before B_fam),
# the same set of lines in another order; the port's order is the locale's
# business nowhere.
run_oracle en_US.UTF-8 archive --dry-run
assert_eq "$(LC_ALL=C sort "$TMP/o.raw")" "$(LC_ALL=C sort "$TMP/n.out")" "UTF-8 locale: the original names the same set"
run_shim en_US.UTF-8 archive --dry-run
assert_eq "$(cat "$TMP/n.raw")" "$(shim_out)" "the port's order does not move with the locale"
same archive

# 10. restore: dry run, the move, not archived, a live dir in the way, the arg checks
both wipe; both seed_fixture
same archive
same restore closed26 --dry-run
assert_eq "$(shim_out)" "would restore  closed26 <- archive/2026/closed26" "restore dry-run line"
same restore closed26
assert_eq "$(shim_out)" "restored  closed26" "restore line"
same restore closed26
assert_eq "$(cat "$TMP/n.err2")" "ERROR: restore: closed26 is not archived" "a second restore refuses"
same archive
mk_live() { mkdir -p "$D/closed26"; }
both mk_live
same restore closed26
assert_eq "$(cat "$TMP/n.err2")" "ERROR: restore: HOME/data/closed26 already exists - move it aside first" "a live dir in the way refuses"
rm_live() { rmdir "$D/closed26"; }
both rm_live
same restore 'bad/name'
assert_eq "$(cat "$TMP/n.err2")" "ERROR: family must be [a-zA-Z0-9_-]: bad/name" "charset refusal"
same restore 'café'
same restore
assert_eq "$(cat "$TMP/n.err2")" "ERROR: usage: ac-archive.sh restore <family> [--dry-run]" "no family: usage"
same restore x --bogus
same restore 'bad/name' --bogus
assert_eq "$(cat "$TMP/n.err2")" "ERROR: usage: ac-archive.sh restore <family> [--dry-run]" "the arg-shape check precedes the charset check"

# 11. a family archived under two years: the first year in byte order is restored, the other stays
both wipe
two_years() {
  mkdir -p "$D/archive/2025/dup" "$D/archive/2026/dup"
  printf 'from 2025\n' >"$D/archive/2025/dup/room.md"
  printf 'from 2026\n' >"$D/archive/2026/dup/room.md"
}
both two_years
same restore dup --dry-run
assert_eq "$(shim_out)" "would restore  dup <- archive/2025/dup" "the first year dir"
same restore dup
assert_eq "$(cat "$NH/data/dup/room.md")" "from 2025" "2025's copy came back"
assert_file "$NH/data/archive/2026/dup/room.md" "2026's copy stays archived"
assert_no_file "$NH/data/archive/2025" "the emptied year dir is removed"

# 12. the year dir keeps a sibling: rmdir fails silently, output unchanged
both wipe
siblings() {
  mkdir -p "$D/archive/2026/one" "$D/archive/2026/two"
  printf 'one\n' >"$D/archive/2026/one/room.md"; printf 'two\n' >"$D/archive/2026/two/room.md"
}
both siblings
same restore one
assert_eq "$(shim_out)" "restored  one" "no rmdir noise"
assert_file "$NH/data/archive/2026/two/room.md" "the sibling stays"

# 13. bad archive arg; no verb and an unknown verb print the header, exit 2
same archive --bogus
assert_eq "$(cat "$TMP/n.err2")" "ERROR: usage: ac-archive.sh archive [--dry-run]" "archive usage"
# Named divergence: the usage header is each implementation's OWN spec header -
# the shim's header is a pointer, so the port prints src/archive.ts's.
for verb in "" frobnicate; do
  o_rc=0; run_oracle C $verb || o_rc=$?
  n_rc=0; run_shim C $verb || n_rc=$?
  assert_eq "$o_rc $n_rc" "2 2" "no verb / unknown verb '$verb': both exit 2"
  assert_eq "$(cat "$TMP/o.err" "$TMP/n.err")" "" "the header goes to stdout only"
  assert_eq "$(cat "$TMP/o.raw")" "$(awk 'NR>1{if(!/^#/)exit; print}' "$ROOT/tests/fixtures/ac-archive.sh" | sed 's/^# \{0,1\}//')" "the original prints its bash header"
  assert_eq "$(cat "$TMP/n.raw")" "$(awk '{if(!/^\/\//)exit; print}' "$ROOT/src/archive.ts" | sed 's/^\/\/ \{0,1\}//')" "the port prints the src/archive.ts spec header"
done
assert_contains "$(cat "$TMP/n.raw")" "ac-archive.sh archive [--dry-run]" "the spec header carries the usage"

# 14. homeless: the same refusal; an unreadable home: the same status, the shell's own line is not reproduced
for args in "archive" "restore x"; do
  o_rc=0; (cd "$TMP" && AC_HOME= "$obin/ac-archive.sh" $args) >"$TMP/o.raw" 2>"$TMP/o.err" || o_rc=$?
  n_rc=0; (cd "$TMP" && AC_HOME= "$BIN/ac-archive.sh" $args) >"$TMP/n.raw" 2>"$TMP/n.err" || n_rc=$?
  assert_eq "$o_rc $n_rc" "1 1" "homeless '$args': both refuse"
  assert_eq "$(cat "$TMP/n.err")" "$(cat "$TMP/o.err")" "homeless '$args': the same refusal"
  assert_contains "$(cat "$TMP/n.err")" "ERROR: AC_HOME is not set" "homeless '$args': names the variable"
  o_rc=0; (cd "$TMP" && AC_HOME=/nonexistent/ac-archive "$obin/ac-archive.sh" $args) >/dev/null 2>"$TMP/o.err" || o_rc=$?
  n_rc=0; (cd "$TMP" && AC_HOME=/nonexistent/ac-archive "$BIN/ac-archive.sh" $args) >/dev/null 2>"$TMP/n.err" || n_rc=$?
  assert_eq "$o_rc $n_rc" "1 1" "unreadable home '$args': both exit 1"
  assert_contains "$(cat "$TMP/o.err")" "No such file or directory" "unreadable home: the original fails in cd (shell-own stderr)"
  assert_eq "$(cat "$TMP/n.err")" "ERROR: AC_HOME is not a readable directory: /nonexistent/ac-archive" "unreadable home: the port names the variable"
done
# the arg checks run before the home is touched
o_rc=0; (AC_HOME= "$obin/ac-archive.sh" archive --bogus) 2>"$TMP/o.err" || o_rc=$?
n_rc=0; (AC_HOME= "$BIN/ac-archive.sh" archive --bogus) 2>"$TMP/n.err" || n_rc=$?
assert_eq "$o_rc $n_rc" "1 1" "homeless usage error: both exit 1"
assert_eq "$(cat "$TMP/n.err")" "$(cat "$TMP/o.err")" "homeless: usage is checked before the home"
assert_eq "$(cat "$TMP/n.err")" "ERROR: usage: ac-archive.sh archive [--dry-run]" "homeless: the usage line"

# 15. a live family that is a symlink to a dir: the LINK moves, there and back
both wipe
linkfam() {
  mkdir -p "$D.real/lnkfam" "$D"
  printf -- '- [2026-01-01T00:00:00Z] crewchief> CLOSED: x\n' >"$D.real/lnkfam/room.md"
  ln -s "$D.real/lnkfam" "$D/lnkfam"
}
both linkfam
same archive
assert_eq "$(shim_out)" "archived  lnkfam -> archive/2026/lnkfam
archived 1 family(ies); refused 0" "a symlinked family is archived"
[ -L "$NH/data/archive/2026/lnkfam" ] || fail "the port moved the link itself, not its target"
[ -L "$OH/data/archive/2026/lnkfam" ] || fail "mv moved the link itself, not its target"
assert_file "$NH/data.real/lnkfam/room.md" "the target stayed put"
same restore lnkfam
[ -L "$NH/data/lnkfam" ] || fail "restore moved the link back"

pass
