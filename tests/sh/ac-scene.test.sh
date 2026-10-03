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

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../../bin/ac-lib.sh
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

# An --into that exists and is not a source refuses before anything moves.
mk taken 'an unrelated scene' 'body taken'
refuses "exists and was not among" bash -c "printf 'x\n' | '$SCENE' merge solo --into taken --summary 'should not happen'"
assert_file "$STORE/solo.md" "a refused --into leaves every source in the store"
assert_no_file "$ARCH/solo.md" "and archives none of them"

# The slug check is ASCII whatever the locale: under en_US.UTF-8 a shell [a-z]
# range interleaves case, so it took B, aB and a Latin letter, and refused Z.
for bad in B aB "$(printf 'caf\303\251')"; do
  refuses "slug must" env LC_ALL=en_US.UTF-8 bash -c "printf 'x\n' | '$SCENE' new '$bad' --summary 'nope'"
done
printf 'x\n' | LC_ALL=en_US.UTF-8 "$SCENE" new zz9 --summary 'the range end' >/dev/null \
  || fail "a z-ended slug is legal under a UTF-8 locale"

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

# The always-loaded layer's stale count rides the same block, string-compared
# (BSD awk has no mktime - the cutoff is computed once by date(1)).
printf '# H\n\n## old-e\n\nb\n\n(learned 2026-01-01)\n\n## new-e\n\nb\n\n(learned %s)\n' "$(date -u +%F)" \
  >"$AC_HOME/CREWMATE-learned.md"
dig3="$("$BIN/ac-session-start.sh" 2>/dev/null || true)"
assert_contains "$dig3" "always-loaded: 2 entries, 1 stale" "the digest counts the always-loaded staleness"
assert_contains "$dig3" "ac-learn.sh stale" "and hands over the verb that shows the detail"
rm -f "$AC_HOME/CREWMATE-learned.md"

# --- differential: src/scene.ts against the frozen bash original -------------
# DISPUTED: the implementation (tests/fixtures/ac-scene.sh under bash vs src/scene.ts through bin/ac-scene.sh)
# HELD-CONSTANT: two homes seeded alike ($OH for the oracle, $NH for the shim), argv, stdin ($TMP/in), a PATH-first `date` stub reading the clock file $TMP/clock and a no-op `sleep` stub, LC_ALL=C on both sides (the oracle's mktemp under $TMP); stdout, stderr (the home path spelled HOME), exit status, and the records/ tree with every file's bytes (the lock dir excluded) compared whole after every run.
# LC_ALL=C because bash 3.2 walks scenes/*.md in libc collation order under a UTF-8 locale - an outside actor's order, never a contract - while the port walks in byte order (the repo's own `LC_ALL=C sort` idiom); for names in [a-z0-9-] the two orders agree on this host (row 8 shows it).
# Divergences kept, each named at its row: the usage text (row 2), the oracle's lock dir and body file leaked on a tier refusal (row 13), bash's own arithmetic noise on a hand-edited heat (row 13b), the homeless second line (row 16).
obin="$(make_oracle_bin ac-scene)"
OH="$TMP/oh"; NH="$TMP/nh"
mkdir -p "$OH/config" "$NH/config" "$TMP/stub" "$TMP/otmp"
printf '2026-01-02T03:04:05Z\n' >"$TMP/clock"
cat >"$TMP/stub/date" <<STUB
#!/usr/bin/env bash
case "\$*" in *%s*) echo 1700000000 ;; *) cat "$TMP/clock" ;; esac
STUB
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/stub/sleep"
chmod +x "$TMP/stub/date" "$TMP/stub/sleep"
LOC=C
HELD=0
clock() { printf '%s\n' "$1" >"$TMP/clock"; }
feed() { printf "$@" >"$TMP/in"; }   # feed <printf-args> - the stdin both sides read ('' for none)
run_oracle() { (cd "$OH" && AC_HOME="$OH" TMPDIR="$TMP/otmp" PATH="$TMP/stub:$PATH" LC_ALL="$LOC" "$obin/ac-scene.sh" "$@") <"$TMP/in" >"$TMP/o.raw" 2>"$TMP/o.err"; }
run_shim() { (cd "$NH" && AC_HOME="$NH" PATH="$TMP/stub:$PATH" LC_ALL="$LOC" "$BIN/ac-scene.sh" "$@") <"$TMP/in" >"$TMP/n.raw" 2>"$TMP/n.err"; }
tree() { (cd "$1" && find records ! -path '*/.lock*' 2>/dev/null | LC_ALL=C sort); }
same() {  # same <args...> - oracle on $OH and shim on $NH answer byte-identically and leave the same store
  local o_rc=0 n_rc=0
  run_oracle "$@" || o_rc=$?
  run_shim "$@" || n_rc=$?
  LC_ALL=C sed "s#$OH#HOME#g" "$TMP/o.raw" >"$TMP/o.out"; LC_ALL=C sed "s#$OH#HOME#g" "$TMP/o.err" >"$TMP/o.err2"
  LC_ALL=C sed "s#$NH#HOME#g" "$TMP/n.raw" >"$TMP/n.out"; LC_ALL=C sed "s#$NH#HOME#g" "$TMP/n.err" >"$TMP/n.err2"
  assert_eq "$n_rc" "$o_rc" "differential exit for '$*'"
  cmp -s "$TMP/o.out" "$TMP/n.out" || fail "differential stdout differs for '$*': $(diff "$TMP/o.out" "$TMP/n.out" | head -n 6)"
  cmp -s "$TMP/o.err2" "$TMP/n.err2" || fail "differential stderr differs for '$*': $(diff "$TMP/o.err2" "$TMP/n.err2" | head -n 6)"
  assert_eq "$(tree "$NH")" "$(tree "$OH")" "differential tree for '$*'"
  if [ -d "$OH/records" ]; then
    diff -r -x .lock "$OH/records" "$NH/records" >/dev/null 2>&1 \
      || fail "differential store bytes differ for '$*': $(diff -r -x .lock "$OH/records" "$NH/records" 2>&1 | head -n 6)"
  fi
  [ "$HELD" = 1 ] || assert_no_file "$NH/records/scenes/.lock" "the port leaves no lock behind ('$*')"
}
shim_out() { cat "$TMP/n.out"; }
shim_err() { cat "$TMP/n.err2"; }
both() {  # both <fn> <args...> - a seeding step with D at each home's scene store
  local h; for h in "$OH" "$NH"; do D="$h/records/scenes"; H="$h"; "$@"; done
}
wipe() { rm -rf "$H/records" "$H/config/scene-max"; }
NL="$(printf '\nx')"; NL="${NL%x}"
seed() {  # seed <slug> <line-2> <line-3> [<body>] - a scene written as bytes, line 2 and 3 verbatim
  mkdir -p "$D"; printf '# Scene: %s\n%s\n%s\n\n%s' "$1" "$2" "$3" "${4-body of $1$NL}" >"$D/$1.md"
}
rawscene() { mkdir -p "$D"; printf -- "$2" >"$D/$1.md"; }   # rawscene <slug> <printf-format>
setmax() { printf '%s\n' "$1" >"$H/config/scene-max"; }
T0=2026-01-01T00:00:00Z; T1=2026-01-02T03:04:05Z
oracle_leaked_lock() {  # the original died inside its lock: the dir (dead pid) and its body file stay behind; the port released
  [ -d "$OH/records/scenes/.lock" ] || fail "the original leaks its lock dir on a tier refusal ($1)"
  rm -rf "$OH/records/scenes/.lock"
}

# 1. an empty home: list mints records/ and then exits 1 printing nothing - the
# original's errexit fired on its empty `ls | wc -l` before the `no scenes yet`
# line it meant to print; a wire quirk that changes the result, kept and routed.
both wipe; feed ''
same list
assert_eq "$(cat "$TMP/n.out" "$TMP/n.err2")" "" "list on an absent store: nothing printed"
assert_eq "$(tree "$NH")" "records" "list minted records/ only"
mkdir -p "$OH/records/scenes/scenes-archive" "$NH/records/scenes/scenes-archive"
same list
assert_eq "$(cat "$TMP/n.out" "$TMP/n.err2")" "" "list on an empty store: nothing printed"

# 2. usage and the unknown verb. The ONE divergence here, by program rule: the
# original printed its header's Usage block; the port prints the whole header
# of src/scene.ts, the spec that replaced it. Exit 1 either way, stderr empty.
same bogus
assert_eq "$(shim_err)" "ERROR: unknown verb: bogus" "unknown verb"
usage_diverges() {
  local o_rc=0 n_rc=0
  run_oracle "$@" || o_rc=$?
  run_shim "$@" || n_rc=$?
  assert_eq "$n_rc $o_rc" "1 1" "usage exits 1 on both sides ('$*')"
  assert_eq "$(cat "$TMP/o.err" "$TMP/n.err")" "" "usage says nothing on stderr ('$*')"
  assert_eq "$(cat "$TMP/o.raw")" "$(sed -n '/^# Usage:/,/^#$/p' "$ROOT/tests/fixtures/ac-scene.sh" | sed 's/^# \{0,1\}//')" "the original prints its Usage block ('$*')"
  assert_eq "$(cat "$TMP/n.raw")" "$(awk '/^\/\//{sub(/^\/\/ ?/,""); print; next} {exit}' "$ROOT/src/scene.ts")" "the port prints the src/scene.ts header ('$*')"
  assert_contains "$(cat "$TMP/n.raw")" "ac-scene.sh merge  <src>... --into <slug> --summary <line> [--file <path>]" "the header carries the Usage lines ('$*')"
}
usage_diverges
usage_diverges -h
usage_diverges --help
usage_diverges ''

# 3. new: the receipt and the composed bytes - trailing LFs collapse to one
feed 'a\nb\n\n\n'
same new alpha --summary first
assert_eq "$(shim_out)" "created HOME/records/scenes/alpha.md (heat 1)" "the create receipt"
assert_eq "$(cat "$NH/records/scenes/alpha.md")" "# Scene: alpha
META: created=$T1 updated=$T1 heat=1
summary: first

a
b" "the composed file"
assert_eq "$(tail -c 2 "$NH/records/scenes/alpha.md" | od -An -c | tr -d ' ')" 'b\n' "exactly one trailing LF"

# 4. the same slug again: refused, the file untouched
cp "$NH/records/scenes/alpha.md" "$TMP/alpha.before"
feed 'x\n'
same new alpha --summary again
assert_eq "$(shim_err)" "ERROR: scene 'alpha' already exists - use \`update\` (a new scene never silently replaces one)" "already exists"
cmp -s "$TMP/alpha.before" "$NH/records/scenes/alpha.md" || fail "a refused create left the file untouched"

# 4b. a path already at the temp name - a symlink back to alpha - is never
# written through: alpha, the symlink and the listing agree with the original,
# whose `$f.tmp.$$` never met it
plant() { ln -s alpha.md "$D/planted.md.tmp"; }
both plant
feed 'planted body\n'
same new planted --summary p
assert_eq "$(shim_out)" "created HOME/records/scenes/planted.md (heat 1)" "the create receipt past a planted temp path"
cmp -s "$TMP/alpha.before" "$NH/records/scenes/alpha.md" || fail "the planted symlink's target is untouched"
assert_eq "$(readlink "$NH/records/scenes/planted.md.tmp")" "alpha.md" "the planted symlink is left as it was"
[ ! -L "$NH/records/scenes/planted.md" ] || fail "the scene must be a regular file, never the planted symlink"
rm "$OH/records/scenes/planted.md.tmp" "$NH/records/scenes/planted.md.tmp"

# 5. flag, slug and summary refusals, in the original's check order
refused_as() {  # refused_as <stderr-line> <args...> - both refuse identically, the shim with this line
  same "${@:2}"
  assert_eq "$(shim_err)" "$1" "refusal for '${*:2}'"
}
feed 'x\n'
refused_as "ERROR: scene rejected: slug must match [a-z0-9][a-z0-9-]* (got: 'Bad-Slug')" new 'Bad-Slug' --summary s
refused_as "ERROR: scene rejected: slug must start with [a-z0-9] (got: '-x')" new -x --summary s
refused_as "ERROR: scene rejected: no slug given" new '' --summary s
refused_as "ERROR: scene rejected: no slug given" new
refused_as "ERROR: unknown flag: x" new --summary x                      # a flag-looking first word IS the slug
refused_as "ERROR: scene rejected: '|' cannot appear in --summary (it is the field separator of the records it sits beside)" new ok --summary 'a|b'
refused_as "ERROR: scene rejected: --summary must be a single line (no newline or carriage return)" new ok --summary 'a
b'
refused_as "ERROR: scene rejected: --summary must be a single line (no newline or carriage return)" new ok --summary "$(printf 'a\rb')"
refused_as "ERROR: --summary needs a value" new ok --summary
refused_as "ERROR: --file needs a value" new ok --summary s --file
refused_as "ERROR: scene rejected: --summary is required and must be non-empty" new ok --summary ''
refused_as "ERROR: scene rejected: --summary is required and must be non-empty" new ok
refused_as "ERROR: unknown flag: --bogus" new ok --summary x --bogus
refused_as "ERROR: unknown flag: --bogus" new 'Bad-Slug' --summary x --bogus   # flags are parsed before the slug
refused_as "ERROR: scene rejected: --summary is required and must be non-empty" update alpha --summary ''
refused_as "ERROR: unknown flag: -x" merge -x --into z --summary s
refused_as "ERROR: --into needs a value" merge alpha --into
refused_as "ERROR: unknown flag: --bogus" show alpha --bogus
refused_as "ERROR: scene rejected: no slug given" show
refused_as "ERROR: no scene 'nosuch' (ac-scene.sh list shows the store)" show nosuch
refused_as "ERROR: no scene 'nosuch' to update - \`new\` creates one" update nosuch

# 6. --file: the cap is measured on the stripped bytes; a missing file; '' means stdin
awk 'BEGIN { for (i = 0; i < 16384; i++) printf "x" }' >"$TMP/b16384"
awk 'BEGIN { for (i = 0; i < 16385; i++) printf "x" }' >"$TMP/b16385"
awk 'BEGIN { for (i = 0; i < 16384; i++) printf "x"; printf "\n\n\n" }' >"$TMP/b16384lf"
feed ''
same new cap-ok --summary s --file "$TMP/b16384"
assert_eq "$(tail -n +5 "$NH/records/scenes/cap-ok.md" | wc -c | tr -d ' ')" "16385" "16384 body bytes land, plus the one LF"
refused_as "ERROR: scene rejected: the scene body exceeds its 16384-byte cap - split it into two scenes, or consolidate harder (a cap keeps a recall budget meaningful)" new cap-over --summary s --file "$TMP/b16385"
assert_no_file "$NH/records/scenes/cap-over.md" "a refused body writes nothing"
same new cap-lf --summary s --file "$TMP/b16384lf"
cmp -s <(tail -n +5 "$NH/records/scenes/cap-lf.md") <(tail -n +5 "$NH/records/scenes/cap-ok.md") || fail "trailing LFs are stripped before the cap is measured"
refused_as "ERROR: --file does not exist: $TMP/nonexistent" new nofile --summary s --file "$TMP/nonexistent"
refused_as "ERROR: --file does not exist: $TMP" new nofile --summary s --file "$TMP"
feed 'from stdin\n'
same new emptyfile --summary s --file ''
assert_eq "$(tail -n +5 "$NH/records/scenes/emptyfile.md")" "from stdin" "--file '' reads stdin, as the original's -n test did"

# 7. stdin bodies: only newlines, a NUL, no trailing LF, three, CRLF, a non-UTF-8 byte
feed '\n\n'
refused_as "ERROR: scene rejected: the scene body is empty (a scene with no body is a summary, not a scene)" new e --summary s
feed ''
refused_as "ERROR: scene rejected: the scene body is empty (a scene with no body is a summary, not a scene)" new e --summary s
feed 'a\0b\n'
same new nul --summary s
assert_eq "$(tail -n +5 "$NH/records/scenes/nul.md" | od -An -c | tr -d ' ')" 'ab\n' "the NUL is dropped, as command substitution dropped it"
feed 'x'
same new nolf --summary s
assert_eq "$(tail -n +5 "$NH/records/scenes/nolf.md" | od -An -c | tr -d ' ')" 'x\n' "no trailing LF gains one"
feed 'x\n\n\n'
same new threelf --summary s
assert_eq "$(tail -n +5 "$NH/records/scenes/threelf.md" | od -An -c | tr -d ' ')" 'x\n' "three trailing LFs collapse to one"
feed 'a\r\nb\r\n'
same new crlf --summary s
assert_eq "$(tail -n +5 "$NH/records/scenes/crlf.md" | od -An -c | tr -d ' ')" 'a\r\nb\r\n' "CR survives; only the LF is stripped and restored"
feed 'caf\351\200\n'
same new bytes --summary s
assert_eq "$(tail -n +5 "$NH/records/scenes/bytes.md" | od -An -c | tr -d ' ')" 'caf351200\n' "non-UTF-8 bytes pass through"
feed 'x\n'
same new "$(printf 'caf\303\251')" --summary s
assert_eq "$(shim_err)" "$(printf "ERROR: scene rejected: slug must match [a-z0-9][a-z0-9-]* (got: 'caf\303\251')")" "a UTF-8 slug is refused with its own bytes echoed"

# 8. list: exact rows in byte order, a hand-edited META missing updated= and
# an empty heat=, a scene with no summary: line
both wipe
mk3() {
  seed a-1 "META: created=$T0 updated=$T1 heat=4" "summary: first"
  seed a1 "META: created=$T0 heat=" "summary: second"
  seed aa "META: created=$T0 updated=$T0 heat=1" "no summary here"
}
both mk3; feed ''
same list
assert_eq "$(shim_out)" "scenes: 3/30 in HOME/records/scenes
  a-1  heat=4  updated=$T1  first
  a1  heat=0  updated=  second
  aa  heat=1  updated=$T0  " "exact rows: two spaces between columns, heat 0 and empty updated/summary for malformed heads"
# Under a UTF-8 locale the original's glob keeps this order for [a-z0-9-] names
# (probed: hyphen before digit before letter, as in C); the port's order never
# moves with the locale.
LOC=en_US.UTF-8; run_oracle list; LOC=C
assert_eq "$(LC_ALL=C sed "s#$OH#HOME#g" "$TMP/o.raw")" "$(shim_out)" "UTF-8 locale: the original lists in the same order"
both setmax abc
same list
assert_eq "$(sed -n 1p "$TMP/n.out")" "scenes: 3/abc in HOME/records/scenes" "list prints the raw config value, unvalidated"
mkdir -p "$OH/records/scenes/scenes-archive" "$NH/records/scenes/scenes-archive"
same list
assert_eq "$(sed -n 1p "$TMP/n.out")" "scenes: 3/abc in HOME/records/scenes" "the archive dir is not a scene"

# 9. show: plain stdout is the file; --cite bumps and prints the bumped file
both wipe
mk1() { seed alpha "META: created=$T0 updated=$T0 heat=1" "summary: one" "line five
line six
"; }
both mk1; feed ''
same show alpha
cmp -s "$TMP/n.raw" "$NH/records/scenes/alpha.md" || fail "plain show prints the file bytes"
assert_contains "$(sed -n 2p "$NH/records/scenes/alpha.md")" "heat=1" "plain show does not bump"
clock 2026-03-03T00:00:00Z
same show alpha --cite
same show alpha --cite
cmp -s "$TMP/n.raw" "$NH/records/scenes/alpha.md" || fail "show --cite prints the file after the bump"
assert_eq "$(sed -n 2p "$NH/records/scenes/alpha.md")" "META: created=$T0 updated=2026-03-03T00:00:00Z heat=3" "two cites: heat 3, updated moves, created stays"
assert_eq "$(tail -n +5 "$NH/records/scenes/alpha.md")" "line five
line six" "the body is carried verbatim through the bump"
clock "$T1"
# A hand-written one-line scene gains the four-line head on --cite: heat 1,
# created now, an empty summary, and nothing after the blank line.
oneliner() { rawscene one '# just a line'; }
both oneliner
same show one --cite
assert_eq "$(cat "$NH/records/scenes/one.md" | od -An -c | tr -d ' \n')" "$(printf '# Scene: one\nMETA: created=%s updated=%s heat=1\nsummary: \n\n' "$T1" "$T1" | od -An -c | tr -d ' \n')" "a one-line scene cited: the head, an empty body"
# A scene whose line 2 is not META: heat reads 0, created reads now.
nometa() { rawscene nometa 'first\nsecond\nthird\nfourth\nfifth\n'; }
both nometa
same show nometa --cite
assert_eq "$(sed -n '2p;5p' "$NH/records/scenes/nometa.md")" "META: created=$T1 updated=$T1 heat=1
fifth" "no META: heat 0+1, created now; tail -n +5 keeps line five"

# 10. merge: heat sum + 1, created from the OLDER source, sources archived byte-identical
both wipe
mk2() {
  seed alpha "META: created=$T1 updated=$T1 heat=1" "summary: a" "body a
"
  seed beta "META: created=$T0 updated=$T1 heat=4" "summary: b" "body b
"
}
both mk2
cp "$NH/records/scenes/alpha.md" "$TMP/alpha.orig"; cp "$NH/records/scenes/beta.md" "$TMP/beta.orig"
feed 'm\n'
same merge beta alpha --into gamma --summary s
assert_eq "$(shim_out)" "merged beta alpha into HOME/records/scenes/gamma.md (heat 6); sources archived verbatim in HOME/records/scenes/scenes-archive" "the merge receipt: one space per source"
assert_eq "$(sed -n 2p "$NH/records/scenes/gamma.md")" "META: created=$T0 updated=$T1 heat=6" "heat 1+4+1, created = the byte-minimum of the sources"
assert_eq "$(tail -n +5 "$NH/records/scenes/gamma.md")" "m" "the merged body"
cmp -s "$TMP/alpha.orig" "$NH/records/scenes/scenes-archive/alpha.md" || fail "alpha archived byte-identical"
cmp -s "$TMP/beta.orig" "$NH/records/scenes/scenes-archive/beta.md" || fail "beta archived byte-identical"
assert_no_file "$NH/records/scenes/alpha.md" "alpha left the live store"
assert_no_file "$NH/records/scenes/beta.md" "beta left the live store"

# 11. the archive already holds a copy of a source: overwritten; --into reusing a source slug
both wipe; both mk2
oldarch() { mkdir -p "$D/scenes-archive"; printf 'an older archive\n' >"$D/scenes-archive/alpha.md"; }
both oldarch
same merge alpha beta --into alpha --summary s
assert_eq "$(sed -n 2p "$NH/records/scenes/alpha.md")" "META: created=$T0 updated=$T1 heat=6" "--into as a source: its heat counted once, created from the older source"
cmp -s "$TMP/alpha.orig" "$NH/records/scenes/scenes-archive/alpha.md" || fail "the older archive copy is overwritten by the source's bytes"
assert_no_file "$NH/records/scenes/beta.md" "beta left the live store"
# A source missing its META created=: created falls back to the one that has it.
both wipe
nocreated() {
  seed a "META: updated=$T1 heat=2" "summary: a"
  seed b "META: created=$T1 updated=$T1 heat=" "summary: b"
}
both nocreated
same merge a b --into c --summary s
assert_eq "$(sed -n 2p "$NH/records/scenes/c.md")" "META: created=$T1 updated=$T1 heat=3" "2+0+1; an empty created= loses to a real one"
same merge c --into d --summary s
assert_eq "$(sed -n 2p "$NH/records/scenes/d.md")" "META: created=$T1 updated=$T1 heat=4" "one source: its heat + 1"

# 12. merge refusals, the store untouched
both wipe; both mk2
before="$(tree "$NH")"
refused_as "ERROR: merge source 'ghost' does not exist - nothing moved" merge alpha ghost --into z --summary s
refused_as "ERROR: scene rejected: merge needs at least one source scene (merge <src>... --into <slug>)" merge --into z --summary s
refused_as "ERROR: --into 'beta' exists and was not among the merged sources - name it as a source, or pick a fresh slug - nothing moved" merge alpha --into beta --summary s
refused_as "ERROR: scene rejected: slug must match [a-z0-9][a-z0-9-]* (got: 'Z')" merge alpha --into Z --summary s
refused_as "ERROR: scene rejected: slug must match [a-z0-9][a-z0-9-]* (got: 'A')" merge A --into z --summary s
refused_as "ERROR: scene rejected: no slug given" merge alpha --summary s
assert_eq "$(tree "$NH")" "$before" "every refused merge moved nothing"

# 13. the tiered cap. scene-max=4 with three scenes: AMBER names the coldest in
# heat-then-updated order with the heat tie broken by the older updated=; at
# scene-max=3 RED adds the merge shape; update and merge stay legal at both.
both wipe
mktier() {
  seed s1 "META: created=$T0 updated=$T1 heat=1" "summary: one"
  seed s2 "META: created=$T0 updated=$T1 heat=3" "summary: two"
  seed s3 "META: created=$T0 updated=$T0 heat=1" "summary: three"
}
both mktier; both setmax 4
feed 'b4\n'
same new s4 --summary four
assert_eq "$(shim_err)" "ERROR: scene store is one slot from the cap (3/4, config/scene-max) - update an existing scene or merge two, rather than spending the last slot. Coldest first:
  s3 (heat 1, updated $T0)
  s1 (heat 1, updated $T1)
  s2 (heat 3, updated $T1)" "AMBER: the tier, count/max and the coldest three"
oracle_leaked_lock AMBER
assert_no_file "$NH/records/scenes/s4.md" "a tier-refused new writes nothing"
both setmax 3
same new s4 --summary four
assert_eq "$(shim_err)" "ERROR: scene store is FULL at the cap (3/3, config/scene-max) - merge before adding. Coldest first:
  s3 (heat 1, updated $T0)
  s1 (heat 1, updated $T1)
  s2 (heat 3, updated $T1)
  ac-scene.sh merge <slug-a> <slug-b> --into <slug-a> --summary '<line>' --file <body>" "RED: the tier, the coldest three, the merge shape"
oracle_leaked_lock RED
feed 'revised\n'
same update s1
assert_eq "$(shim_out)" "updated HOME/records/scenes/s1.md (heat 2)" "update is legal at RED"
same merge s1 s2 --into s1 --summary merged
assert_eq "$(shim_out)" "merged s1 s2 into HOME/records/scenes/s1.md (heat 6); sources archived verbatim in HOME/records/scenes/scenes-archive" "merge is legal at RED: 2+3+1"
# The coldest list with heat= empty and updated= absent: `IFS=TAB read` in the
# original collapses the empty field, so the slug lands in the updated column
# and the slug column is empty - a wire quirk that changes the result, kept.
both wipe
mkcold() {
  seed s1 "META: created=$T0 updated=$T1 heat=1" "summary: one"
  seed s2 "META: created=$T0 heat=" "summary: two"
  seed s3 "META: created=$T0 updated=$T0 heat=1" "summary: three"
}
both mkcold; both setmax 3
feed 'b4\n'
same new s4 --summary four
assert_eq "$(sed -n '2,4p' "$TMP/n.err2")" "   (heat 0, updated s2)
  s3 (heat 1, updated $T0)
  s1 (heat 1, updated $T1)" "RED coldest: heat absent reads 0 and sorts first; its empty updated column collapses under the original's read"
oracle_leaked_lock RED-collapse

# 13b. a hand-edited heat the shell could not add to: both exit 1 and write
# nothing. Named divergence: the original died in bash's own arithmetic noise
# (`value too great for base`, `unbound variable`) with its lock leaked; the
# port names the line and releases.
both wipe
badheat() {
  seed h1 "META: created=$T0 updated=$T0 heat=1x" "summary: one"
  seed h2 "META: created=$T0 updated=$T0 heat=abc" "summary: two"
}
both badheat
for slug in h1 h2; do
  feed 'x\n'
  o_rc=0; run_oracle update "$slug" || o_rc=$?
  n_rc=0; run_shim update "$slug" || n_rc=$?
  assert_eq "$n_rc $o_rc" "1 1" "heat not a count ($slug): both exit 1"
  assert_contains "$(cat "$TMP/o.err")" "line 245" "the original's refusal is bash arithmetic noise ($slug)"
  assert_eq "$(cat "$TMP/n.err")" "ERROR: scene '$slug' carries a META heat that is not a count (heat=$(sed -n '2s/.*heat=//p' "$NH/records/scenes/$slug.md")) - fix line 2 by hand, nothing written" "the port names it ($slug)"
  assert_eq "$(tree "$NH")" "$(tree "$OH")" "heat not a count ($slug): the store is unchanged"
  diff -r -x .lock "$OH/records" "$NH/records" >/dev/null || fail "heat not a count ($slug): the file is unchanged"
  oracle_leaked_lock "heat $slug"
  assert_no_file "$NH/records/scenes/.lock" "the port released ($slug)"
done
o_rc=0; run_oracle show h1 --cite || o_rc=$?
n_rc=0; run_shim show h1 --cite || n_rc=$?
assert_eq "$n_rc $o_rc" "1 1" "heat not a count: --cite exits 1 on both sides"
assert_eq "$(cat "$TMP/n.err")" "ERROR: scene 'h1' carries a META heat that is not a count (heat=1x) - fix line 2 by hand, nothing written" "the same refusal rides --cite"
assert_eq "$(cat "$TMP/o.raw" "$TMP/n.raw")" "" "a refused cite prints no file"
oracle_leaked_lock "heat cite"

# 14. scene-max not a count, 0 and 1
both wipe; both setmax abc; feed 'x\n'
refused_as "ERROR: config/scene-max must be a count (got: 'abc')" new a --summary x
oracle_leaked_lock scene-max-abc
same list
assert_eq "$(cat "$TMP/n.out" "$TMP/n.err2")" "" "list on an empty store under a bad cap: the same silent exit 1"
both setmax 0
same new a --summary x
assert_eq "$(shim_err)" "ERROR: scene store is FULL at the cap (0/0, config/scene-max) - merge before adding. Coldest first:

  ac-scene.sh merge <slug-a> <slug-b> --into <slug-a> --summary '<line>' --file <body>" "max 0: FULL with an empty coldest list"
oracle_leaked_lock max-0
both setmax 1
same new a --summary x
assert_eq "$(cat "$TMP/n.err2" | od -An -c | tr -d ' \n')" "$(printf "ERROR: scene store is one slot from the cap (0/1, config/scene-max) - update an existing scene or merge two, rather than spending the last slot. Coldest first:\n\n" | od -An -c | tr -d ' \n')" "max 1: AMBER at zero, the empty list leaves a blank line"
oracle_leaked_lock max-1
both setmax 2
same new a --summary x
assert_eq "$(shim_out)" "created HOME/records/scenes/a.md (heat 1)" "max 2: GREEN at zero"

# 15. the store lock held by a LIVE pid: every writing verb refuses within the
# stubbed 30 s, files unchanged; held by a DEAD pid: reclaimed at once
both wipe; both mk1
holdlock() { mkdir -p "$D/.lock"; printf '%s\n' "$$" >"$D/.lock/pid"; }
both holdlock
HELD=1
for verb in "new b --summary x" "update alpha" "show alpha --cite"; do
  feed 'x\n'
  SECONDS=0
  # shellcheck disable=SC2086  # the verb string is a deliberate argv split
  same $verb
  [ "$SECONDS" -lt 5 ] || fail "the stubbed sleep must make the 30 s lock wait instant on both sides ($verb): ${SECONDS}s"
  assert_eq "$(shim_err)" "ERROR: scene store lock HOME/records/scenes/.lock could not be acquired within 30s - nothing written" "held lock refuses: $verb"
done
HELD=0
assert_eq "$(sed -n 2p "$NH/records/scenes/alpha.md")" "META: created=$T0 updated=$T0 heat=1" "a refused cite bumped nothing"
assert_no_file "$NH/records/scenes/b.md" "a refused new minted nothing"
rm -rf "$OH/records/scenes/.lock" "$NH/records/scenes/.lock"
deadpid="$(sh -c 'echo $$')"
deadlock() { mkdir -p "$D/.lock"; printf '%s\n' "$deadpid" >"$D/.lock/pid"; }
both deadlock
same show alpha --cite
assert_eq "$(sed -n 2p "$NH/records/scenes/alpha.md")" "META: created=$T0 updated=$T1 heat=2" "a dead holder's lock is reclaimed and the cite lands"

# 16. homeless: exit 1, the same first stderr line. Named divergence: the
# original's `show` prints a second line (`no scene`) because the die fired
# inside a $(scene_dir) substitution; the port dies once, at the first home touch.
feed 'x\n'
for args in "list" "new a --summary x" "show a" "update a"; do
  # shellcheck disable=SC2086
  o_rc=0; (AC_HOME= PATH="$TMP/stub:$PATH" LC_ALL=C "$obin/ac-scene.sh" $args) <"$TMP/in" >/dev/null 2>"$TMP/o.err" || o_rc=$?
  # shellcheck disable=SC2086
  n_rc=0; (AC_HOME= PATH="$TMP/stub:$PATH" LC_ALL=C "$BIN/ac-scene.sh" $args) <"$TMP/in" >/dev/null 2>"$TMP/n.err" || n_rc=$?
  assert_eq "$n_rc $o_rc" "1 1" "homeless '$args': both refuse"
  assert_eq "$(head -n 1 "$TMP/n.err")" "$(head -n 1 "$TMP/o.err")" "homeless '$args': the same refusal line"
  assert_contains "$(head -n 1 "$TMP/n.err")" "ERROR: AC_HOME is not set" "homeless '$args': the refusal names the variable"
  assert_eq "$(wc -l <"$TMP/n.err" | tr -d ' ')" "1" "homeless '$args': the port says it once"
done
# A bad slug is refused before the home is touched, homeless or not.
o_rc=0; (AC_HOME= "$obin/ac-scene.sh" new 'B' --summary x) <"$TMP/in" >/dev/null 2>"$TMP/o.err" || o_rc=$?
n_rc=0; (AC_HOME= "$BIN/ac-scene.sh" new 'B' --summary x) <"$TMP/in" >/dev/null 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc $o_rc" "1 1" "homeless, bad slug: both refuse"
cmp -s "$TMP/o.err" "$TMP/n.err" || fail "homeless, bad slug: the slug refusal comes first on both sides"

# 17. the ASCII slug check under a UTF-8 locale
both wipe; LOC=en_US.UTF-8; feed 'x\n'
refused_as "$(printf "ERROR: scene rejected: slug must match [a-z0-9][a-z0-9-]* (got: 'caf\303\251')")" new "$(printf 'caf\303\251')" --summary s
refused_as "ERROR: scene rejected: slug must match [a-z0-9][a-z0-9-]* (got: 'B')" new B --summary s
same new zz9 --summary s
assert_eq "$(shim_out)" "created HOME/records/scenes/zz9.md (heat 1)" "a z-ended slug is legal under a UTF-8 locale"
LOC=C

pass
