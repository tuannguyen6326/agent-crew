#!/usr/bin/env bash
# ac-scene.test.sh - the L2 scene store (bin/ac-scene.sh).
#
# Covers, guard class by guard class (the script header owns the contracts):
#   - the composed file shape and the slug/summary/body-cap refusals;
#   - the TIERED CAP: GREEN/AMBER/RED for `new`, and the invariant that
#     `update`/`merge` stay legal at EVERY tier (the pressure must have an exit);
#   - MERGE: heat = sum + 1, every source archived BYTE-IDENTICAL, the oldest
#     `created` inherited, `--into` reusing a source slug, an all-or-nothing
#     source validation, and conservation (archive + store holds every body);
#   - heat as TOUCHES: `show --cite` and `update` each bump it;
#   - the store lock: a held lock makes every writing verb refuse with the
#     store byte-unchanged;
#   - the digest bound: 1 scene vs 50 costs `list` a constant per scene, so a
#     session-start consumer can never be surprised by store size.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../bin/ac-lib.sh
. "$BIN/ac-lib.sh"

make_home
SCENE="$BIN/ac-scene.sh"
STORE="$AC_HOME/records/scenes"
ARCH="$STORE/scenes-archive"

refuses() {
  # refuses <named-part> <cmd...> - the command FAILS and its message NAMES
  # what is wrong. A refusal that does not say what is wrong is a refusal the
  # author cannot act on.
  local want="$1" out
  shift
  out="$("$@" 2>&1)" && fail "expected refusal (wanted '$want'): $*"
  assert_contains "$out" "$want" "refusal names '$want'"
}

mk() {  # mk <slug> <summary> [<body>] - a scene, body defaulted
  printf '%s\n' "${3:-body of $1}" | "$SCENE" new "$1" --summary "$2" >/dev/null
}

# --- the composed file shape -------------------------------------------------

printf 'the watcher skip self-revokes each poll.\n' | "$SCENE" new watcher-protocol \
  --summary 'how the fleet/scoped watcher split hands coverage back' >/dev/null
f="$STORE/watcher-protocol.md"
assert_file "$f" "new creates the scene file"
assert_eq "$(sed -n '1p' "$f")" "# Scene: watcher-protocol" "line 1 is the slug heading"
assert_contains "$(sed -n '2p' "$f")" "heat=1" "a fresh scene starts at heat 1"
assert_contains "$(sed -n '2p' "$f")" "created=" "META carries created"
assert_eq "$(sed -n '3p' "$f")" \
  "summary: how the fleet/scoped watcher split hands coverage back" "line 3 is the index summary"
assert_eq "$(sed -n '4p' "$f")" "" "line 4 is the blank before the body"
assert_eq "$(tail -n +5 "$f")" "the watcher skip self-revokes each poll." "the body is carried verbatim"

# A second scene with the SAME slug never silently replaces the first.
refuses "already exists" bash -c "printf 'x\n' | '$SCENE' new watcher-protocol --summary 'clobber attempt'"
assert_eq "$(tail -n +5 "$f")" "the watcher skip self-revokes each poll." "the refused create left the body untouched"

# --- field validation --------------------------------------------------------

refuses "slug must" bash -c "printf 'x\n' | '$SCENE' new 'Bad Slug' --summary 'nope'"
refuses "slug must" bash -c "printf 'x\n' | '$SCENE' new 'has_underscore' --summary 'nope'"
refuses "single line" bash -c "printf 'x\n' | '$SCENE' new multi --summary 'one
two'"
refuses "cannot appear in --summary" bash -c "printf 'x\n' | '$SCENE' new piped --summary 'a | b'"
refuses "--summary is required" bash -c "printf 'x\n' | '$SCENE' new nosum"
refuses "body is empty" bash -c "printf '' | '$SCENE' new empty --summary 'no body'"

# The body cap: one byte over is refused, and the refusal says why a cap exists.
big="$TMP/big-body"
# awk, not `yes | head`: `yes` takes SIGPIPE when head closes, and under
# pipefail that 141 kills the suite before the assertion it was building.
awk 'BEGIN { for (i = 0; i < 20000; i++) print "x" }' >"$big"   # ~40KB, past the 16384 cap
refuses "cap" "$SCENE" new toobig --summary 'over the cap' --file "$big"
[ -e "$STORE/toobig.md" ] && fail "a refused body must write nothing"

# --- heat is TOUCHES: cite and update both bump ------------------------------

"$SCENE" show watcher-protocol --cite >/dev/null
assert_contains "$(sed -n '2p' "$f")" "heat=2" "show --cite bumps heat (a read IS the touch)"
"$SCENE" show watcher-protocol >/dev/null
assert_contains "$(sed -n '2p' "$f")" "heat=2" "a plain show does NOT bump - only --cite records the read"
printf 'revised body.\n' | "$SCENE" update watcher-protocol >/dev/null
assert_contains "$(sed -n '2p' "$f")" "heat=3" "update bumps heat"
assert_eq "$(tail -n +5 "$f")" "revised body." "update replaces the body"
assert_eq "$(sed -n '3p' "$f")" \
  "summary: how the fleet/scoped watcher split hands coverage back" \
  "update without --summary keeps the existing index line"
printf 'again.\n' | "$SCENE" update watcher-protocol --summary 'a narrower summary' >/dev/null
assert_eq "$(sed -n '3p' "$f")" "summary: a narrower summary" "update --summary replaces the index line"

# `created` is STABLE across updates - it dates the topic, not the last edit.
created_before="$(sed -n '2p' "$f" | tr ' ' '\n' | sed -n 's/^created=//p')"
printf 'third.\n' | "$SCENE" update watcher-protocol >/dev/null
assert_eq "$(sed -n '2p' "$f" | tr ' ' '\n' | sed -n 's/^created=//p')" "$created_before" \
  "created survives every update"

refuses "no scene" bash -c "printf 'x\n' | '$SCENE' update never-made"

# --- MERGE: heat arithmetic, verbatim archive, conservation ------------------

rm -rf "$STORE"
mk fifo-gates 'what a fifo hold gate can and cannot bound' 'gate body A'
mk lock-idiom 'the mkdir-lock stale-owner recovery' 'lock body B'
"$SCENE" show fifo-gates --cite >/dev/null        # fifo-gates -> heat 2
"$SCENE" show fifo-gates --cite >/dev/null        # fifo-gates -> heat 3
before_a="$(cat "$STORE/fifo-gates.md")"
before_b="$(cat "$STORE/lock-idiom.md")"

printf 'the consolidated body.\n' | "$SCENE" merge fifo-gates lock-idiom \
  --into test-fixtures --summary 'fixture-side blocking primitives' >/dev/null
assert_file "$STORE/test-fixtures.md" "merge writes the --into scene"
assert_contains "$(sed -n '2p' "$STORE/test-fixtures.md")" "heat=5" \
  "merge heat = sum of every source (3+1) + 1 - the survivor inherits the topic's whole usage history"
assert_no_file "$STORE/fifo-gates.md" "a merged source leaves the live store"
assert_no_file "$STORE/lock-idiom.md" "every merged source leaves the live store"
assert_eq "$(cat "$ARCH/fifo-gates.md")" "$before_a" "the source is archived BYTE-IDENTICAL"
assert_eq "$(cat "$ARCH/lock-idiom.md")" "$before_b" "every source is archived byte-identical"
# Conservation: nothing a merge consumed is unreachable afterwards.
assert_contains "$(cat "$ARCH"/*.md)" "gate body A" "the first merged body survives in the archive"
assert_contains "$(cat "$ARCH"/*.md)" "lock body B" "the second merged body survives in the archive"

# --into MAY be one of the sources (fold b into a) - the common shape.
rm -rf "$STORE"
mk keep-me 'the surviving topic' 'body keep'
mk fold-me 'the folded topic' 'body fold'
printf 'folded together.\n' | "$SCENE" merge keep-me fold-me --into keep-me \
  --summary 'the surviving topic, widened' >/dev/null
assert_file "$STORE/keep-me.md" "--into may reuse a source slug"
assert_contains "$(sed -n '2p' "$STORE/keep-me.md")" "heat=3" "1+1+1 when --into is itself a source"
assert_file "$ARCH/keep-me.md" "the reused slug's PRIOR content is still archived, not overwritten in place"
assert_no_file "$STORE/fold-me.md" "the folded source is gone from the live store"

# All-or-nothing: one bad source moves NOTHING.
rm -rf "$STORE"
mk solo 'the only scene' 'body solo'
refuses "does not exist" bash -c "printf 'x\n' | '$SCENE' merge solo ghost --into merged --summary 'should not happen'"
assert_file "$STORE/solo.md" "a merge naming a missing source archives nothing"
assert_no_file "$STORE/merged.md" "and writes no --into"

refuses "at least one source" bash -c "printf 'x\n' | '$SCENE' merge --into x --summary 'no sources'"

# --- THE TIERED CAP ----------------------------------------------------------
# The cap is on the FILE COUNT and it gates `new` only. GREEN below max-1,
# AMBER at max-1 (one slot left is not a slot), RED at max - and update/merge
# stay legal at every tier, or the pressure has no exit.

rm -rf "$STORE"
printf '4\n' >"$AC_HOME/config/scene-max"
mk s1 'first' 'b1'
mk s2 'second' 'b2'
# count 2, max 4 -> GREEN
printf 'b3\n' | "$SCENE" new s3 --summary 'third' >/dev/null || fail "GREEN tier must allow new"
# count 3 == max-1 -> AMBER
out="$(printf 'b4\n' | "$SCENE" new s4 --summary 'fourth' 2>&1)" && fail "AMBER tier must refuse new"
assert_contains "$out" "one slot from the cap" "the AMBER refusal names the tier"
assert_contains "$out" "3/4" "the AMBER refusal states count/max"
assert_no_file "$STORE/s4.md" "a tier-refused new writes nothing"
# update/merge remain legal at AMBER
printf 'b1 revised\n' | "$SCENE" update s1 >/dev/null || fail "AMBER must still allow update"
printf 'merged\n' | "$SCENE" merge s2 s3 --into s2 --summary 'second, widened' >/dev/null \
  || fail "AMBER must still allow merge - it is the exit the cap exists to force"
assert_eq "$(scene_n() { ls "$STORE"/*.md 2>/dev/null | wc -l | tr -d ' '; }; scene_n)" "2" \
  "the merge freed a slot"

# RED is reached the way it actually happens: AMBER structurally PREVENTS `new`
# from ever spending the last slot, so a store cannot walk itself to the cap -
# it arrives there when the captain LOWERS config/scene-max over a store that
# already holds that many, or when scenes were minted under a larger cap.
printf 'b3\n' | "$SCENE" new s3 --summary 'third again' >/dev/null
"$SCENE" show s3 --cite >/dev/null   # s3 hotter than s1, so the coldest list is deterministic
printf '3\n' >"$AC_HOME/config/scene-max"
red="$(printf 'b5\n' | "$SCENE" new s5 --summary 'fifth' 2>&1)" && fail "RED tier must refuse new"
assert_contains "$red" "FULL at the cap" "the RED refusal names the tier"
assert_contains "$red" "3/3" "the RED refusal states count/max"
assert_contains "$red" "ac-scene.sh merge" "the RED refusal hands over the exact merge command shape"
assert_contains "$red" "heat" "the RED refusal names candidates BY heat, not by name order"
# The exit stays open at RED: merge is how a full store is worked down.
printf 'worked down\n' | "$SCENE" merge s1 s2 --into s1 --summary 'consolidated' >/dev/null \
  || fail "RED must still allow merge - a cap with no exit is a wedge"
rm -f "$AC_HOME/config/scene-max"

# --- the store lock ----------------------------------------------------------
# Held by THIS process, which is alive, so ac_lock_stale never reclaims it. The
# no-op `sleep` on PATH lets ac_lock_acquire spin its whole timeout instantly
# rather than paying 30 real seconds - the AC-9.6 idiom, nothing else varied.
rm -rf "$STORE"
mk locked 'a scene to guard' 'guarded body'
mkdir -p "$TMP/fastbin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/fastbin/sleep"
chmod +x "$TMP/fastbin/sleep"
before_locked="$(cat "$STORE/locked.md")"
mkdir -p "$STORE/.lock" && printf '%s\n' "$$" >"$STORE/.lock/pid"
for verb in "new other --summary x" "update locked" "show locked --cite"; do
  # shellcheck disable=SC2086  # the verb string is a deliberate argv split
  if printf 'x\n' | PATH="$TMP/fastbin:$PATH" "$SCENE" $verb >/dev/null 2>&1; then
    ac_lock_release "$STORE/.lock"
    fail "a writing verb must refuse while the store lock is held: $verb"
  fi
done
ac_lock_release "$STORE/.lock"
assert_eq "$(cat "$STORE/locked.md")" "$before_locked" "every refused verb left the scene byte-unchanged"
assert_no_file "$STORE/other.md" "and minted nothing"

# --- digest bound ------------------------------------------------------------
# `list` is what a session-start line reads. 1 scene vs 50 must cost a constant
# PER SCENE (one line each) - never a body read - so the digest can never be
# surprised by store size (the AC20 idiom, applied to this store).
rm -rf "$STORE"
printf '99\n' >"$AC_HOME/config/scene-max"
mk one 'the only one' 'body'
one_lines="$("$SCENE" list | wc -l | tr -d ' ')"
i=2; while [ "$i" -le 50 ]; do mk "s$i" "summary $i" "body $i"; i=$((i + 1)); done
fifty_lines="$("$SCENE" list | wc -l | tr -d ' ')"
assert_eq "$one_lines" "2" "one scene lists as one header + one row"
assert_eq "$fifty_lines" "51" "50 scenes list as one header + 50 rows - one line each, no body read"
rm -f "$AC_HOME/config/scene-max"

# --- the session-start digest reads STAMPS, never re-derives -----------------
# The bound that makes the block honest: `ac-know.sh verify` is an 8-second git
# walk over a real record (measured), so the digest may never call it. It reads
# the stamp that run left, says NEVER VERIFIED when there is none, and both
# shapes cost a constant per record.
rm -rf "$STORE"
mkdir -p "$AC_HOME/records/repo-knowledge"
printf -- '- fact one | src: cmd:true | at: abc 2026-08-01 | by: fam\n' \
  >"$AC_HOME/records/repo-knowledge/proj.md"
dig="$("$BIN/ac-session-start.sh" 2>/dev/null || true)"
assert_contains "$dig" "NEVER verified" "an unverified record is NAMED as such, not silently counted"
assert_contains "$dig" "ac-know.sh verify" "and the digest hands over the exact command"

printf 'record=proj.md\nfresh=39\nsuspect=415\nhead=1b7bb96c11e663ec3eebb4f46ac9abaee559e057\nran=2026-08-09T10:00:00Z\n' \
  >"$AC_HOME/state/.know-verify-proj.meta"
mk hot-topic 'the topic this fleet keeps reaching for' 'body'
"$SCENE" show hot-topic --cite >/dev/null
mk cold-topic 'a topic nobody opened' 'body'
dig2="$("$BIN/ac-session-start.sh" 2>/dev/null || true)"
assert_contains "$dig2" "39 fresh / 415 suspect" "a stamped record reports its graded counts"
assert_contains "$dig2" "@1b7bb96c1" "and the HEAD it was graded against, so a moved tree is visible"
assert_contains "$dig2" "scenes: 2/30" "the scene store reports count against its cap"
assert_contains "$dig2" "hottest: hot-topic" "and names the hottest scene by heat, not by name order"
rm -f "$AC_HOME/state/.know-verify-proj.meta" "$AC_HOME/records/repo-knowledge/proj.md"

pass
