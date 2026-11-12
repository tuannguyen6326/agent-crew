#!/usr/bin/env bash
# ac-wake-drain.test.sh - scoped wake consumption over the per-record spool:
# cross-scope isolation (the cross-drain fix), the fleet's in-place orphan
# drain of a not-live family's spool (both liveness signals), no-double-drain,
# the R1 fix on the REAL producer (seam), publication collision/ordering pins,
# ride-along gating, the scoped WATCHER-DOWN beacon, and the structural
# no-append invariant.
#
# Deterministic and sleep-free throughout: liveness is a sentinel file behind
# a stub herdr, the R1 interleaving is forced through the TEST-ONLY seam
# inside the real ac_wake_publish (ac-wake-lib.sh), collisions are SEEDED (never
# raced for), and same-stamp ordering is pinned with a stubbed clock.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
state="$AC_HOME/state"

# --- fixtures --------------------------------------------------------------

stub="$TMP/stubbin"
mkdir -p "$stub"
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
# Liveness only: `pane get <p>` succeeds iff the sentinel exists.
if [ "${1:-} ${2:-}" = "pane get" ]; then
  [ -e "$AC_HOME/state/.mock-win-${3:-}" ] || exit 1
fi
# Pane render for the idleness channel: whatever the test seeded for the pane.
if [ "${1:-} ${2:-}" = "pane read" ]; then
  cat "$AC_HOME/state/.mock-tail-${3:-}" 2>/dev/null || true
fi
exit 0
EOF
chmod +x "$stub/herdr"

# A bin/ whose ac-ready.sh and ac-remote.sh are sentinel stubs: the drain
# invokes its ride-alongs from the bin/ it was started from, so this is how
# "did the drain call them?" is observed. Every other script is the real one;
# the root beside it links src/, where bin/ac-bun.sh finds the drain's module.
fakebin="$TMP/fake/bin"
mkdir -p "$fakebin"
ln -s "$ROOT/src" "$TMP/fake/src"
for f in "$ROOT"/bin/*.sh; do ln -sf "$f" "$fakebin/$(basename "$f")"; done
for s in ac-ready ac-remote; do
  rm -f "$fakebin/$s.sh"
  cat >"$fakebin/$s.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/$s.calls"
[ ! -f "$TMP/$s.fail" ] || exit "\$(cat "$TMP/$s.fail")"
exit 0
EOF
  chmod +x "$fakebin/$s.sh"
done
# The brain ride-along parses the sync JSON for its one summary line, so its
# stub answers in the engine's shape.
rm -f "$fakebin/ac-brain.sh"
cat >"$fakebin/ac-brain.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/ac-brain.calls"
case "\${1:-}" in
  delta) printf '{"protocol_version":1,"since":"2026-01-01T00:00:00.000Z","pages":[{"path":"data/fam1/room.md"}],"facts":[{"fact":"the widget lock moved to ac-lock.sh"}],"has_more":false}\n' ;;
  *) printf '{\n "files": 42,\n "changed": 1\n}\n' ;;
esac
EOF
chmod +x "$fakebin/ac-brain.sh"
# The remote push ride-along only exists when the transport is configured.
printf '#!/usr/bin/env bash\nexit 0\n' >"$AC_HOME/config/remote-poll"
chmod +x "$AC_HOME/config/remote-poll"

drain() {
  # drain <scope> - one drain pass ('' = the fleet chief's).
  if [ -n "$1" ]; then
    PATH="$stub:$PATH" AC_SCOPE="$1" bash "$fakebin/ac-wake-drain.sh"
  else
    PATH="$stub:$PATH" env -u AC_SCOPE bash "$fakebin/ac-wake-drain.sh"
  fi
}

chief_live() { printf 'window=crew:%s-chief\nbackend=herdr\n' "$1" >"$state/$1-chief.meta"; printf '%s-chief t0\n' "$1" >"$state/.pane-$1-chief"; : >"$state/.mock-win-$1-chief"; }
chief_dead_window() { printf 'window=crew:%s-chief\nbackend=herdr\n' "$1" >"$state/$1-chief.meta"; printf '%s-chief t0\n' "$1" >"$state/.pane-$1-chief"; rm -f "$state/.mock-win-$1-chief"; }
chief_gone() { rm -f "$state/$1-chief.meta" "$state/.mock-win-$1-chief"; }
reset_state() { rm -f "$state"/*-chief.meta "$state"/.mock-win-* "$state"/*.meta; rm -rf "$state"/.wake-spool* "$state"/.wake-tmp.*; seedn=0; }

wake() { printf '%s\treport\t%s\t%s\n' "$(date +%s)" "$1" "$2"; }

seedn=0
seed() {
  # seed <scope> <id> <payload> - one record straight into a scope's spool
  # ('' = the fleet's). The FIXTURE path, for cases about what the drain does
  # with a record; publish() drives the real producer where that is the point.
  local sp="$state/.wake-spool${1:+.$1}"
  mkdir -p "$sp"
  wake "$2" "$3" >"$sp/$(printf '1.1.%06d' "$seedn")"
  seedn=$((seedn + 1))
}

publish() {
  # publish <scope> <kind> <id> <payload> - one record through the REAL
  # ac_wake_publish, called from that process's MAIN shell (the function's
  # subshell contract: $$ is the collision-identity).
  bash -c "set -euo pipefail; . '$ROOT/bin/ac-lib.sh'; . '$ROOT/bin/ac-wake-lib.sh'; ac_wake_publish '$state' '$1' '$2' '$3' '$4'"
}

spool_records() {
  # spool_records <spool-dir> - how many records the spool holds.
  find "$1" -type f 2>/dev/null | wc -l | tr -d ' '
}

# A stubbed clock for the SEEDED collision and same-stamp ordering pins:
# +%s%N is pinned to one constant so destination names are deterministic;
# everything else falls through to the real date.
datestub="$TMP/datestub"
mkdir -p "$datestub"
cat >"$datestub/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "+%s%N" ]; then printf '1700000000123456789\n'; exit 0; fi
exec /bin/date "$@"
EOF
chmod +x "$datestub/date"

# --- 1. cross-scope isolation (the core fix) -------------------------------

# A LIVE family's spool belongs to its roomchief and the fleet must not claim
# its records; a roomchief claims only its own. This is exactly the wake the
# fleet used to steal. Driven through the REAL producer, both directions.
reset_state
publish '' report c1 'done: spooled fleet work'
publish fam1 report fam1-t1 'done: spooled family work'
publish fam2 report fam2-t1 'done: spooled sibling work'
chief_live fam1; chief_live fam2
out="$(drain '')"
assert_contains "$out" "report c1 done: spooled fleet work" "fleet drains its own spool"
case "$out" in *"spooled family work"*) fail "fleet drain stole a LIVE family's spool record" ;; esac
assert_eq "$(spool_records "$state/.wake-spool.fam1")" "1" \
  "a live family's spool records survive the fleet drain"
assert_eq "$(spool_records "$state/.wake-spool")" "0" "the fleet spool was claimed"
[ -d "$state/.wake-spool" ] || fail "the fleet spool container is permanent - a drain never removes it"
out="$(drain fam1)"
assert_contains "$out" "report fam1-t1 done: spooled family work" "roomchief drains its own spool"
case "$out" in *"sibling work"*) fail "roomchief drain stole a sibling's spool record" ;; esac
assert_eq "$(spool_records "$state/.wake-spool.fam2")" "1" "a sibling's records survive a roomchief drain"
[ -d "$state/.wake-spool.fam1" ] || fail "the family spool container is permanent too"

# --- 1b. bounded status context on a drained wake ---------------------------
# A `report` carries its marker in the payload, but `stale`/`ended`/`gone`
# carry little or nothing, and the chief had to go read the task before it
# knew what it was looking at. One indented, bounded, additive line closes it.
reset_state
seed '' s1 ""
printf '2026-07-26T00:00:00Z blocked: needs the captain on the schema choice\n' >"$state/s1.status"
out="$(drain '')"
assert_contains "$out" "  status s1: blocked: needs the captain on the schema choice" \
  "a bare wake is annotated with the task's durable status"
case "$out" in
  "  status"*) fail "the wake line itself must come first, unchanged" ;;
esac

# No duplication: when the payload already says it, the annotation is dropped.
reset_state
seed '' s2 "done: shipped it"
printf '2026-07-26T00:00:00Z done: shipped it\n' >"$state/s2.status"
out="$(drain '')"
assert_contains "$out" "report s2 done: shipped it" "the wake line is unchanged"
case "$out" in *"status s2:"*) fail "a payload that already says it must not be repeated" ;; esac

# Bounded: a long status line is truncated, not streamed into the chief.
reset_state
seed '' s3 ""
{ printf '2026-07-26T00:00:00Z '; for i in $(seq 1 60); do printf 'padpadpad%s ' "$i"; done; printf '\n'; } >"$state/s3.status"
out="$(drain '')"
ctx="$(printf '%s\n' "$out" | grep '^  status s3:' || true)"
[ -n "$ctx" ] || fail "a long status is still annotated"
[ "${#ctx}" -le 180 ] || fail "the context line must stay bounded (got ${#ctx} chars)"
assert_contains "$ctx" "..." "a truncated context says so"

# A task with no status file is simply not annotated - never a failed drain.
reset_state
seed '' s4 ""
out="$(drain '')"
case "$out" in *"status s4:"*) fail "a task with no status must not be annotated" ;; esac

# --- 1c. remote-order wakes get a DEDICATED label: the detector moved out
# of ac-remote.sh's cmd_gc (a pruning verb nobody runs routinely, and its
# old sign could not tell a genuine drain from a lost publish) into THIS
# pass, which every session-start already runs. A remote-order record
# exists in a spool ONLY between ac-remote.sh's publish and the ONE claim
# that follows (ingest_stream never republishes a rid), so this line firing
# at all means the order sat undrained until this exact pass.
reset_state
publish '' remote captain 'remote-order strand1'
out="$(drain '')"
assert_contains "$out" "remote captain remote-order strand1" "the wake line itself stays unchanged and first"
assert_contains "$out" "  status captain: no chief had drained this remote order until now" \
  "A1: a dedicated, unmissable label - not generic noise, not stderr, not a verb to type"
assert_contains "$out" "ac-remote.sh show strand1" "the label points at the exact rid to inspect"

# A4/A3: the SAME rid never fires again once drained - a re-drain of an empty
# spool must not cry wolf about an order that already went through.
out="$(drain '')"
assert_eq "$out" "no queued wakes" "a drained remote order raises no false alarm on the next pass"

# --- 2. orphan fallback drain, BOTH liveness signals ------------------------

# (a) meta archived by teardown -> not live -> the fleet claims its RECORDS in
# place; the container survives, as everywhere else.
reset_state
publish fam1 report fam1-t1 'done: orphaned work'
chief_gone fam1
out="$(drain '')"
assert_contains "$out" "report fam1-t1 done: orphaned work" "fleet drains a chief-archived family's spool"
[ -d "$state/.wake-spool.fam1" ] || fail "the orphan drain claims records, never the container"
assert_eq "$(spool_records "$state/.wake-spool.fam1")" "0" "the orphaned records were claimed"
assert_eq "$(find "$state" -maxdepth 1 -name '.wake-spool-draining.*' | wc -l | tr -d ' ')" "0" \
  "the orphan drain leaves no claim dir behind"

# (b) meta present but the window died -> not live -> drained.
reset_state
publish fam1 report fam1-t1 'done: crashed chief work'
chief_dead_window fam1
assert_contains "$(drain '')" "report fam1-t1 done: crashed chief work" \
  "fleet drains a dead-window chief's spool"
assert_eq "$(spool_records "$state/.wake-spool.fam1")" "0" "the dead-window family's records were claimed"

# (c) meta present AND window alive -> LIVE -> skipped (asserted in 1).

# --- 3. no double-drain (per-record rename) ----------------------------------

# The claim is an atomic rename PER RECORD: of two drainers exactly one
# renames a given record and emits it; the other finds nothing and no-ops.
# (All-or-nothing was the old file primitive's shape, never a stated
# guarantee - truly concurrent drainers split records, each still exactly
# once; sequentially the first takes all, as here.)
reset_state
publish fam1 report fam1-t1 'done: exactly once'
chief_gone fam1
first="$(drain fam1)"    # the roomchief's own drain wins the claims
second="$(drain '')"     # the fleet orphan pass finds an empty spool
assert_contains "$first" "done: exactly once" "the first drainer emits the wake"
case "$second" in *"exactly once"*) fail "the wake was drained twice" ;; esac
assert_contains "$second" "no queued wakes" "the second drainer no-ops"
assert_eq "$(spool_records "$state/.wake-spool.fam1")" "0" "the spool is empty after exactly one drain"

# --- 4. R1 INVERTED: a wake published while a drain is mid-flight is emitted -

# The old pin here asserted the R1 loss as EXPECTED behavior (an fd held
# across the drain, the late write dying in the unlinked inode). Under
# per-record publication that loss class is retired, and the pin is
# REWRITTEN, not deleted: the drain is interposed INSIDE the real
# ac_wake_publish - between its private write and its atomic ln, the exact
# boundary R1 lived on - via the TEST-ONLY seam (ac-wake-lib.sh ac_wake_seam, the
# crash_at house pattern). The interposed drain must not see the in-flight
# record, and the NEXT drain must emit it exactly once. Zero sleeps, zero
# background jobs - and it exercises the code that ships, not a re-enactment.
reset_state
seamhook="$TMP/seam-hook.sh"
cat >"$seamhook" <<EOF
#!/usr/bin/env bash
PATH="$stub:\$PATH" env -u AC_SCOPE bash "$fakebin/ac-wake-drain.sh" >"$TMP/seam-drain.out" 2>&1
EOF
chmod +x "$seamhook"
publish '' report t1 'done: early'
AC_WAKE_SEAM_AT=after-write AC_WAKE_SEAM_RUN="$seamhook" \
  bash -c "set -euo pipefail; . '$ROOT/bin/ac-lib.sh'; . '$ROOT/bin/ac-wake-lib.sh'; ac_wake_publish '$state' '' report t2 'done: late'" \
  || fail "publish must succeed with the seam armed"
mid="$(cat "$TMP/seam-drain.out")"
assert_contains "$mid" "report t1 done: early" "the interposed drain emits the already-published record"
case "$mid" in *"done: late"*) fail "an in-flight (unlinked) record must be invisible to the drain" ;; esac
final="$(drain '')"
assert_contains "$final" "report t2 done: late" "the late record IS emitted by the next drain (R1 retired)"
assert_eq "$(printf '%s\n' "$final" | grep -c 'done: late')" "1" "the late record emits exactly once"
assert_contains "$(drain '')" "no queued wakes" "nothing remains after the late record emits"
assert_eq "$(find "$state" -name '.wake-tmp.*' | wc -l | tr -d ' ')" "0" \
  "a completed publish leaves no temp behind"

# --- 4b. seam inertness (house pattern): unset and unknown labels no-op ------
reset_state
hitlog="$TMP/seam-hits"
rm -f "$hitlog"
inerthook="$TMP/seam-inert-hook.sh"
printf '#!/usr/bin/env bash\nprintf hit >>"%s"\n' "$hitlog" >"$inerthook"
chmod +x "$inerthook"
publish '' report t1 'done: no seam env' || fail "publish must succeed with the seam unset"
AC_WAKE_SEAM_AT=not-a-boundary AC_WAKE_SEAM_RUN="$inerthook" \
  bash -c "set -euo pipefail; . '$ROOT/bin/ac-lib.sh'; . '$ROOT/bin/ac-wake-lib.sh'; ac_wake_publish '$state' '' report t2 'done: unknown label'" \
  || fail "publish must succeed under an unknown seam label"
assert_no_file "$hitlog" "the seam is inert when unset and under an unknown label"
assert_eq "$(spool_records "$state/.wake-spool")" "2" "both publishes landed"

# --- 4c. publication refuses an existing destination (ln, never mv) ----------

# Defect class: silent destination overwrite = a lost record (mv exits 0 and
# replaces; ln refuses with EEXIST). The collision is SEEDED, never raced
# for: with the clock stubbed constant, a pre-seeded record at the publisher's
# own first destination name (a dead pid-reuse predecessor's record - the
# publisher's $$, seq 000000) forces the seq bump. This case also fails on
# any future ln -> mv swap.
reset_state
PATH="$datestub:$PATH" bash -c "
  set -euo pipefail
  . '$ROOT/bin/ac-lib.sh'
  . '$ROOT/bin/ac-wake-lib.sh'
  mkdir -p '$state/.wake-spool'
  printf '1700000000\treport\tt0\tdone: predecessor\n' >\"$state/.wake-spool/1700000000123456789.\$\$.000000\"
  ac_wake_publish '$state' '' report t1 'done: successor'
" || fail "publish must survive a seeded collision"
assert_eq "$(spool_records "$state/.wake-spool")" "2" "collision resolved by a new name, not a replace"
f0="$(find "$state/.wake-spool" -name '*.000000' | head -1)"
f1="$(find "$state/.wake-spool" -name '*.000001' | head -1)"
assert_contains "$(cat "$f0")" "done: predecessor" "the colliding record is NEVER overwritten"
assert_contains "$(cat "$f1")" "done: successor" "the publish stepped past the collision (seq bump)"
out="$(drain '')"
assert_eq "$(printf '%s\n' "$out" | grep -c 'done: ')" "2" "both records drain, exactly once each"

# --- 4d. ordering: a same-stamp burst drains oldest-first --------------------

# THE FIRST PIN of the decided ordering contract (ac-lib.sh): records emit in
# producer-stamp order, same-stamp ties by seq. Defect class: an unpadded seq
# lexically misorders any process emitting more than 9 records under one
# stamp (1 10 11 2 ...). The stubbed clock pins ONE stamp for all 12 records,
# so seq is the only key and the pin is deterministic.
reset_state
PATH="$datestub:$PATH" bash -c "
  set -euo pipefail
  . '$ROOT/bin/ac-lib.sh'
  . '$ROOT/bin/ac-wake-lib.sh'
  i=1
  while [ \$i -le 12 ]; do
    ac_wake_publish '$state' '' report \"\$(printf 't%02d' \"\$i\")\" \"done: n\$(printf '%02d' \"\$i\")\"
    i=\$((i + 1))
  done
" || fail "the 12-record burst must publish"
want="$(printf 'report t%02d done: n%02d\n' 1 1 2 2 3 3 4 4 5 5 6 6 7 7 8 8 9 9 10 10 11 11 12 12)"
got="$(drain '' | grep '^report t' || true)"
assert_eq "$got" "$want" "a same-stamp burst drains in publication order (padded seq)"

# --- 4e. no torn record: one round-trip past the tearing threshold ----------

# Tearing needed two INTERLEAVED write()s into one shared file; a record now
# lives alone in its own private inode, fully written and closed before
# publication, so the obligation reduces to one round-trip - a payload past
# the measured host tearing threshold (1024 B) through the real producer,
# back out whole.
reset_state
bigpad="$(printf '%01400d' 0 | tr '0' 'x')"
big="begin:${bigpad}:end"
publish '' report tbig "done: $big"
assert_contains "$(drain '')" "report tbig done: $big" \
  "a >1024 B record round-trips whole - no torn record at any size"

# --- 4f. ordering across INCREASING stamps: stamp-major, seq a tie-break only

# 4d pins the seq tie-break under ONE stamp; this pins the other half of the
# DECIDED contract: records emit in producer-stamp order and the stamp
# DOMINATES seq. seq is forced to CONTRADICT stamp order (high seq on the
# early stamp, seq zero on the late one), so a seq-major drain fails here.
# The ticking stub hands out strictly increasing stamps, one per publish.
tickclock="$TMP/tickclock"
mkdir -p "$tickclock"
cat >"$tickclock/date" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "+%s%N" ]; then
  n="\$(cat '$TMP/tick.n' 2>/dev/null || printf 0)"
  n=\$((n + 1)); printf '%s\n' "\$n" >'$TMP/tick.n'
  printf '17000000%02d123456789\n' "\$n"; exit 0
fi
exec /bin/date "\$@"
EOF
chmod +x "$tickclock/date"
reset_state
rm -f "$TMP/tick.n"
PATH="$tickclock:$PATH" bash -c "
  set -euo pipefail
  . '$ROOT/bin/ac-lib.sh'
  . '$ROOT/bin/ac-wake-lib.sh'
  _ac_wake_seq=999
  ac_wake_publish '$state' '' report tearly 'done: early stamp, high seq'
  _ac_wake_seq=0
  ac_wake_publish '$state' '' report tlate 'done: late stamp, seq zero'
" || fail "the two-stamp pair must publish"
got="$(drain '' | grep '^report t' || true)"
want="$(printf 'report tearly done: early stamp, high seq\nreport tlate done: late stamp, seq zero\n')"
assert_eq "$got" "$want" "increasing stamps emit stamp-major (seq decides only same-stamp ties)"

# --- 4g. a broken clock fails the publish loudly - never a dotfile record ----

# Defect class: empty `date +%s%N` output built `.<pid>.<seq6>` - a DOTFILE
# invisible to every glob (drain, pending, tally) = a silently, permanently
# lost wake. The stamp is validated (10 leading digits - the seconds field)
# BEFORE any byte exists, so the publish fails loudly and writes nothing.
badclock="$TMP/badclock"
mkdir -p "$badclock"
cat >"$badclock/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "+%s%N" ]; then exit 0; fi   # prints NOTHING, exits 0
exec /bin/date "$@"
EOF
chmod +x "$badclock/date"
reset_state
rc=0
PATH="$badclock:$PATH" bash -c "set -euo pipefail; . '$ROOT/bin/ac-lib.sh'; . '$ROOT/bin/ac-wake-lib.sh'; ac_wake_publish '$state' '' report t1 'done: x'" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "an empty clock output must fail the publish"
cat >"$badclock/date" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "+%s%N" ]; then printf 'not-a-clock\n'; exit 0; fi
exec /bin/date "$@"
EOF
chmod +x "$badclock/date"
rc=0
PATH="$badclock:$PATH" bash -c "set -euo pipefail; . '$ROOT/bin/ac-lib.sh'; . '$ROOT/bin/ac-wake-lib.sh'; ac_wake_publish '$state' '' report t2 'done: y'" 2>/dev/null || rc=$?
[ "$rc" -ne 0 ] || fail "a garbage clock output must fail the publish"
assert_eq "$(find "$state" -name '.wake-tmp.*' | wc -l | tr -d ' ')" "0" \
  "the refused publish wrote nothing (validated before mktemp)"
assert_eq "$(find "$state/.wake-spool" -type f 2>/dev/null | wc -l | tr -d ' ')" "0" \
  "no record - and no DOTFILE record - was published"
assert_contains "$(drain '')" "no queued wakes" "nothing invisible is left behind"

# --- 4h. a record missing its trailing newline never merges with the next ----

# Defect class: `cat | awk` concatenated claim files byte-wise, so a record
# file lacking its trailing newline fused with the following record into ONE
# torn emission. Per-file awk ends the last record at
# each file's EOF.
reset_state
mkdir -p "$state/.wake-spool"
printf '1\treport\tta\tdone: no trailing newline' >"$state/.wake-spool/1.1.000000"
printf '2\treport\ttb\tdone: whole\n' >"$state/.wake-spool/1.1.000001"
out="$(drain '')"
assert_contains "$out" "report ta done: no trailing newline" "the newline-less record emits whole"
assert_contains "$out" "report tb done: whole" "the following record emits separately"
assert_eq "$(printf '%s\n' "$out" | grep -c '^report t')" "2" "two records, two lines - never merged"

# --- 4i. an agent-authored payload carrying a tab/newline stays ONE record ---

# Defect class: the payload is the one record field a producer does not
# control - ac-done.sh passes crewmate argv straight through - so a tab in a
# marker split the `ts\tkind\tid\tpayload` record and the drain's `$2 $3 $4`
# render dropped everything past it: the wake ARRIVED and the chief acted on a
# silently truncated completion line. A newline split it into a second line
# that renders as field-less blanks. Pinned at the producer chokepoint.
reset_state
publish '' report t1 "$(printf 'done: fixed A\tand B\nplus C')"
out="$(drain '')"
assert_contains "$out" "report t1 done: fixed A and B plus C" \
  "a tab/newline payload reaches the chief WHOLE, folded to spaces"
assert_eq "$(printf '%s\n' "$out" | grep -c '^report t1')" "1" \
  "one publish is one record line, whatever the payload holds"

# --- 5b. glob hazards: families named 'draining'/'spool', leaked claim dirs -

# The family filter is prefix-strip + bare-token, never last-dot extraction,
# so a family legitimately named `draining` is a first-class family...
reset_state
publish draining report draining-t1 'done: oddly named'
chief_gone draining
assert_contains "$(drain '')" "report draining-t1 done: oddly named" \
  "a family named 'draining' drains like any other"

# ... and so is a family legitimately named `spool`, while the spool namespace
# itself can never enumerate as a phantom family (family tokens can never be
# blacklisted, only the namespace separates them).
reset_state
publish spool report spool-t2 'done: spooled spool-family work'
chief_gone spool
out="$(drain '')"
assert_contains "$out" "report spool-t2 done: spooled spool-family work" \
  "a family named 'spool': its spool records drain"

# ... while a leaked spool CLAIM dir with a non-pid suffix (never a claim dir
# this drain recognizes - the dead-claim sweep below only touches a
# NUMERIC-suffixed one) is never drained as a family either.
reset_state
mkdir -p "$state/.wake-spool-draining.notapid"
printf '1\treport\tt9\tdone: leaked claim\n' >"$state/.wake-spool-draining.notapid/1.1.000000"
out="$(drain '')"
case "$out" in *"leaked claim"*) fail "a non-pid-suffixed claim dir must not be drained as a family" ;; esac
assert_contains "$out" "no queued wakes" "a non-pid-suffixed claim dir leaves the drain with nothing to do"
assert_file "$state/.wake-spool-draining.notapid/1.1.000000" "a non-pid-suffixed dir is left alone entirely"
rm -rf "$state/.wake-spool-draining.notapid"

# F6 (repo-deep-review): a drainer killed between claim (the mv above) and
# emit strands its records forever - the enumerators deliberately exclude
# claim dirs, so no later drain ever revisits one and the dedup marker has
# already advanced (the wake never re-fires). A drain-start sweep must
# recover a claim dir whose embedded pid is DEAD, returning its record to
# the spool so the ordinary drain that follows picks it up.
reset_state
sh -c 'exit 0' & DEADPID=$!; wait "$DEADPID" 2>/dev/null || true
mkdir -p "$state/.wake-spool-draining.$DEADPID"
printf '1\treport\tt9\tdone: leaked claim\n' >"$state/.wake-spool-draining.$DEADPID/1.$DEADPID.000000"
out="$(drain '')"
assert_contains "$out" "report t9 done: leaked claim" \
  "a dead claimer's stranded record is recovered and drained"
assert_no_file "$state/.wake-spool-draining.$DEADPID" "the dead claim dir is cleaned up after recovery"

# ... but a LIVE drainer's claim dir must NEVER be stolen (the risk this
# sweep exists to avoid): a process that is alive AND still a drainer by its
# command line.
reset_state
bash -c 'exec -a ac-wake-drain.sh sleep 60' & LIVEPID=$!
mkdir -p "$state/.wake-spool-draining.$LIVEPID"
printf '1\treport\tt9\tdone: still draining\n' >"$state/.wake-spool-draining.$LIVEPID/1.$LIVEPID.000000"
out="$(drain '')"
case "$out" in *"still draining"*) fail "a LIVE drainer's claim dir must never be stolen by another pass" ;; esac
assert_file "$state/.wake-spool-draining.$LIVEPID/1.$LIVEPID.000000" "the live claim dir is left completely alone"
kill "$LIVEPID" 2>/dev/null; wait "$LIVEPID" 2>/dev/null || true
rm -rf "$state/.wake-spool-draining.$LIVEPID"

# ... while a pid the OS handed to an unrelated process is no drainer: alive
# is not enough (the reuse ac-lock.sh holder_alive guards the same way), and
# kept, the record would sit stranded until that process happened to exit.
reset_state
sleep 60 & REUSEPID=$!
mkdir -p "$state/.wake-spool-draining.$REUSEPID"
printf '1\treport\tt9\tdone: stranded by reuse\n' >"$state/.wake-spool-draining.$REUSEPID/1.$REUSEPID.000000"
out="$(drain '')"
kill "$REUSEPID" 2>/dev/null; wait "$REUSEPID" 2>/dev/null || true
assert_contains "$out" "report t9 done: stranded by reuse" "a claim dir under a reused pid is recovered"
assert_no_file "$state/.wake-spool-draining.$REUSEPID" "...and cleaned up"

# A drainer that inherits a dead claimer's pid (exec) finds the dir under its
# OWN pid: that is a predecessor's, swept like any dead one - kept, it would
# also collide with this drainer's own claim of the same name.
reset_state
out="$(PATH="$stub:$PATH" env -u AC_SCOPE bash -c '
  d="$1/.wake-spool-draining.$$"; mkdir -p "$d"
  printf "1\treport\tt9\tdone: own-pid predecessor\n" >"$d/1.$$.000000"
  exec bash "$2"' _ "$state" "$fakebin/ac-wake-drain.sh")"
assert_contains "$out" "report t9 done: own-pid predecessor" "a claim dir under the drainer's own pid is a predecessor's"

# A claimer whose command cannot be read is kept, never swept: the lookup
# failing is no proof of a dead drainer (the next drain sweeps it).
reset_state
mkdir -p "$TMP/ps-blind"
printf '#!/usr/bin/env bash\ncase "$*" in *command=*) exit 1 ;; esac\nexec /bin/ps "$@"\n' >"$TMP/ps-blind/ps"
chmod +x "$TMP/ps-blind/ps"
sleep 60 & BLINDPID=$!
mkdir -p "$state/.wake-spool-draining.$BLINDPID"
printf '1\treport\tt9\tdone: unreadable claimer\n' >"$state/.wake-spool-draining.$BLINDPID/1.$BLINDPID.000000"
out="$(PATH="$TMP/ps-blind:$stub:$PATH" env -u AC_SCOPE bash "$fakebin/ac-wake-drain.sh")"
kill "$BLINDPID" 2>/dev/null; wait "$BLINDPID" 2>/dev/null || true
case "$out" in *"unreadable claimer"*) fail "a claimer whose command cannot be read must be kept: $out" ;; esac
assert_file "$state/.wake-spool-draining.$BLINDPID/1.$BLINDPID.000000" "...its record left where it is"
rm -rf "$state/.wake-spool-draining.$BLINDPID"

# ... and recovery routes by the record's OWN id (ac_family_of_id - the same
# derivation in_drain_scope uses, the ONE the system has), never the
# discovering session's scope: a staged sub-id recovered by the FLEET drain
# still lands in ITS family's spool (a live roomchief, or the orphan
# fallback, claims it from there) - never emitted directly by a session that
# does not own it.
reset_state
sh -c 'exit 0' & DEADPID2=$!; wait "$DEADPID2" 2>/dev/null || true
# ac_family_of_id trusts a stage suffix only once its nested brief dir exists
# (family-of-id-suffix-collision) - a real fam1-review task always has one,
# since ac-brief.sh mkdirs it before any crewmate can commit.
mkdir -p "$AC_HOME/data/fam1/review"
mkdir -p "$state/.wake-spool-draining.$DEADPID2"
printf '1\treport\tfam1-review\tdone: recovered family work\n' \
  >"$state/.wake-spool-draining.$DEADPID2/1.$DEADPID2.000000"
chief_live fam1
out="$(drain '')"
case "$out" in *"recovered family work"*) fail "the fleet must not emit a recovered LIVE family's record itself" ;; esac
assert_eq "$(spool_records "$state/.wake-spool.fam1")" "1" \
  "the recovered record lands in fam1's own spool, ready for its live roomchief"
assert_contains "$(drain fam1)" "report fam1-review done: recovered family work" \
  "fam1's own roomchief drains its recovered record"

# ... and by the pane's fleet_scope when its meta records one - the spool its
# own push went to (ac-done.sh publishes into AC_FLEET_SCOPE's), never a
# phantom .wake-spool.<id> no roomchief drains.
reset_state
sh -c 'exit 0' & DEADPID3=$!; wait "$DEADPID3" 2>/dev/null || true
printf 'window=crew:famA-api\nbackend=herdr\nfleet_scope=famA\n' >"$state/famA-api.meta"
mkdir -p "$state/.wake-spool-draining.$DEADPID3"
printf '1\treport\tfamA-api\tdone: api slice landed\n' >"$state/.wake-spool-draining.$DEADPID3/1.$DEADPID3.000000"
chief_live famA
assert_contains "$(drain famA)" "report famA-api done: api slice landed" \
  "a scoped member's recovered record goes back to its roomchief's spool"
[ ! -d "$state/.wake-spool.famA-api" ] || fail "recovery must not mint a phantom per-id spool"

# ... and a claimed record that cannot be read is skipped, not fatal: the
# drain still drains everything else. Skipped under root, which reads it.
if [ "$(id -u)" != 0 ]; then
  reset_state
  sh -c 'exit 0' & DEADPID4=$!; wait "$DEADPID4" 2>/dev/null || true
  mkdir -p "$state/.wake-spool-draining.$DEADPID4"
  printf '1\treport\tt9\tdone: unreadable\n' >"$state/.wake-spool-draining.$DEADPID4/1.$DEADPID4.000000"
  chmod 000 "$state/.wake-spool-draining.$DEADPID4/1.$DEADPID4.000000"
  publish '' report t8 'done: still drained'
  rc=0; out="$(drain '' 2>&1)" || rc=$?
  chmod 644 "$state/.wake-spool-draining.$DEADPID4/1.$DEADPID4.000000"
  assert_eq "$rc" "0" "an unreadable claimed record must not kill the drain: $out"
  assert_contains "$out" "report t8 done: still drained" "...which drains the rest"
  rm -rf "$state/.wake-spool-draining.$DEADPID4"
fi

# --- 6. ride-along gating (both ride-alongs) --------------------------------

# The fleet-wide side effects belong to the fleet chief alone: a roomchief
# drain must not run the epic scheduler or push the fleet's captain-pending
# batch to the remote channel.
reset_state
rm -f "$TMP/ac-ready.calls" "$TMP/ac-remote.calls"
publish fam1 report fam1-t1 'done: x'
chief_live fam1
drain fam1 >/dev/null
assert_no_file "$TMP/ac-ready.calls" "a scoped drain never runs the epic scheduler"
assert_no_file "$TMP/ac-remote.calls" "a scoped drain never pushes the fleet's remote batch"

reset_state
drain '' >/dev/null
assert_file "$TMP/ac-ready.calls" "the fleet drain runs the epic scheduler"
assert_contains "$(cat "$TMP/ac-remote.calls")" "push-pending" "the fleet drain pushes the remote batch"

# A scheduler that could not run prints nothing, and nothing is exactly what
# "no item to start" looks like - the drain has to say which one it was.
reset_state
printf '3\n' >"$TMP/ac-ready.fail"
out="$(drain '')"
rm -f "$TMP/ac-ready.fail"
assert_contains "$out" "WARN   scheduler unavailable: ac-ready.sh exited 3" "a failed scheduler ride-along is named, never silent"

# Brain ride-along: syncs only a home that already runs the engine (never
# mints a db), fleet drain only, and narrates one summary line.
reset_state
rm -f "$TMP/ac-brain.calls" "$state/brain.sqlite"
drain '' >/dev/null
assert_no_file "$TMP/ac-brain.calls" "no brain.sqlite - the drain never mints an engine"
: >"$state/brain.sqlite"
publish fam1 report fam1-t1 'done: x'
chief_live fam1
out="$(drain fam1)"
nsync="$(grep -c '^sync' "$TMP/ac-brain.calls" 2>/dev/null || true)"
assert_eq "${nsync:-0}" "0" "a scoped drain never runs the fleet's brain sync"
# The brain DELTA is every session's own wake read, scoped to the session
# that drains: a roomchief reads its family cursor, the fleet chief reads the
# chief cursor. Machine-made here because a wake read left to each session's
# habit measurably went unread.
assert_contains "$(cat "$TMP/ac-brain.calls")" "delta --agent fam1-chief --session fam1" \
  "a scoped drain reads its own family's brain delta"
assert_contains "$out" "brain-delta: 1 page(s), 1 fact(s)" "the drain narrates the delta counts"
assert_contains "$out" "data/fam1/room.md" "the drain lists the changed page paths"
assert_contains "$out" "the widget lock moved" "the drain lists the new facts"
rm -f "$TMP/ac-brain.calls"
out="$(drain '')"
assert_contains "$(cat "$TMP/ac-brain.calls")" "sync" "the fleet drain syncs the brain"
assert_contains "$out" "brain-sync ok - 42 files, 1 changed" "the drain narrates the sync summary"
assert_contains "$(cat "$TMP/ac-brain.calls")" "delta --agent crewchief --session chief" \
  "the fleet drain reads the chief's brain delta"
rm -f "$state/brain.sqlite" "$TMP/ac-brain.calls"
drain '' >/dev/null
assert_no_file "$TMP/ac-brain.calls" "no brain.sqlite - no delta either"

# --- 7. scoped WATCHER-DOWN beacon ------------------------------------------

# Each session judges the liveness of the watcher that serves IT: a roomchief
# whose own family watcher died must see WATCHER-DOWN even while the fleet
# watcher beats happily.
reset_state
printf 'window=crew:fam1-t1\n' >"$state/fam1-t1.meta"
date +%s >"$state/.last-watcher-beat"
printf '%s\n' "$(( $(date +%s) - 9999 ))" >"$state/.last-watcher-beat.fam1"
assert_contains "$(drain fam1)" "WATCHER-DOWN" "roomchief sees its OWN watcher down despite a fresh fleet beat"
case "$(drain '')" in *WATCHER-DOWN*) fail "fleet must not report down on a fresh fleet beat" ;; esac

# ... and the mirror: a fresh family beat keeps the roomchief quiet even
# while the FLEET watcher is stale.
date +%s >"$state/.last-watcher-beat.fam1"
printf '%s\n' "$(( $(date +%s) - 9999 ))" >"$state/.last-watcher-beat"
case "$(drain fam1)" in *WATCHER-DOWN*) fail "roomchief must not report down on a fresh family beat" ;; esac
assert_contains "$(drain '')" "WATCHER-DOWN" "fleet sees its own stale beat"

# ... and a beat of 0 - an ABSENT beacon, or one holding the `0` that
# watcher's exit cleanup writes on every exit - is genuinely uncovered and
# must STILL fire, but no age is computable from it: `now - 0` printed an
# epoch-sized 56-year age that once read to a chief as a live outage.
# The three no-beat states fire identically and read DIFFERENTLY, because they
# need opposite responses: an absent beacon means nothing ever armed here (you
# have been blind), a 0 means a watcher just heartbeat-exited (routine: drain
# and re-arm), and an empty file is an anomaly in a beacon that is published by
# rename. Unified wording made the COMMON case read like the alarming one.
reset_state
printf 'window=crew:t1\n' >"$state/t1.meta"

rm -f "$state/.last-watcher-beat"
outb="$(drain '')"
assert_contains "$outb" "WATCHER-DOWN" "an absent beacon is still uncovered"
assert_contains "$outb" "no beat on record" "an absent beacon reports no computable age"
assert_contains "$outb" "no beacon" "an absent beacon says nothing ever armed here"
case "$outb" in *"age "*) fail "no age may be computed from an absent beat: $outb" ;; esac

printf '0\n' >"$state/.last-watcher-beat"
outb="$(drain '')"
assert_contains "$outb" "WATCHER-DOWN" "a stood-down beacon (0) is still uncovered"
assert_contains "$outb" "no beat on record" "a stood-down beacon reports no computable age"
assert_contains "$outb" "stood its beacon down" \
  "a stood-down beacon says a watcher EXITED - the routine case, not the blind one"
case "$outb" in *"age "*) fail "no age may be computed from a zero beat: $outb" ;; esac

: >"$state/.last-watcher-beat"
outb="$(drain '')"
assert_contains "$outb" "no beat on record" "an unreadable beat is no beat, not an arithmetic error"
assert_contains "$outb" "unreadable" "... and an empty beacon is neither absent nor stood down"

# ... while a REAL stale beat keeps printing its REAL age, unchanged.
printf '%s\n' "$(( $(date +%s) - 123456 ))" >"$state/.last-watcher-beat"
assert_contains "$(drain '')" "no fresh beat (age 12345" "a real stale beat still prints its real age"

# ... and a zero-padded beat is no ac_now epoch: raw, bash arithmetic reads its
# leading 0 as octal and errors, and forced to base 10 it is a 56-year age.
printf '0009\n' >"$state/.last-watcher-beat"
outb="$(drain '')"
assert_contains "$outb" "WATCHER-DOWN" "a zero-padded beat is still uncovered, not an arithmetic error"
assert_contains "$outb" "the beacon is unreadable" "a zero-padded beat is unreadable, not a usable beat"
case "$outb" in *"age "*) fail "no age may be computed from a zero-padded beat: $outb" ;; esac

# --- 8. structural: no code appends into a wake queue or spool path ----------

# Defect class: a FUTURE producer silently reopening R1 with a bare `>>` (the
# wake producers grew from 2 to 3 once without the architecture noticing).
# Publication is ac_wake_publish - a private tmp plus one atomic ln - never a
# shell append into a shared wake path. Comment lines are exempt; code is not
# (the house no-append pattern, extended to the spool
# and to every script).
for f in "$ROOT"/bin/*.sh; do
  hits="$(grep -nE '>>[^|]*\.wake-(queue|spool)' "$f" | grep -vE '^[0-9]+:[[:space:]]*#' || true)"
  [ -z "$hits" ] || fail "append into a wake store in $(basename "$f") - route it through ac_wake_publish: $hits"
done

# --- 9. unacknowledged completions (the staged-flow blindness hotfix) --------
#
# A wake is one-shot; a finished stage that never produced one (marker deduped
# away, wake published into the wrong scope, no marker printed at all) has to
# be found from durable evidence instead. Every artifact here is seeded with a
# PAST mtime, so an ack stamped at `now` is unambiguously newer - deterministic
# and sleep-free.

past=202601010000

task_meta() {
  # task_meta <id> - a live task: its meta, and a pane keyed by the id itself.
  printf 'window=crew:%s\nbackend=herdr\n' "$1" >"$state/$1.meta"
  printf '%s t0\n' "$1" >"$state/.pane-$1"
}
seed_report() {
  # seed_report <id> <dir-under-data> - a stage report, past-dated.
  mkdir -p "$AC_HOME/data/$2"
  printf 'brief\n' >"$AC_HOME/data/$2/brief.md"
  printf 'report\n' >"$AC_HOME/data/$2/report.md"
  touch -t "$past" "$AC_HOME/data/$2/report.md"
}
seed_quiet_pane() {
  # seed_quiet_pane <id> <tail> - a pane last seen 999s ago, rendering <tail>.
  printf '%s\n' "$(( $(date +%s) - 999 ))" >"$state/.change-$1"
  touch -t "$past" "$state/.change-$1"
  printf '%s\n' "$2" >"$state/.mock-tail-$1"
}
reset_completions() { rm -f "$state"/.ack-* "$state"/.change-* "$state"/.pane-* "$state"/.mock-tail-*; rm -rf "$AC_HOME/data"/*; }

# (1) a report that appeared with NO pane marker is still reported - resolved
# through the nested staged layout (ac_task_dir), never a re-implemented grammar.
reset_state; reset_completions
task_meta famA-spec
seed_report famA-spec famA/spec
out="$(drain '')"
assert_contains "$out" "UNACKNOWLEDGED COMPLETION: famA-spec" "a marker-less report is reported"
assert_contains "$out" "$AC_HOME/data/famA/spec/report.md" "the nested stage report path is named"
assert_contains "$out" "no queued wakes" "the existing wake output is untouched"

# (2) an already-acked report stays silent.
touch "$state/.ack-famA-spec"
case "$(drain '')" in *"famA-spec"*) fail "an acked report must not be reported again" ;; esac

# (3) an idle marker-less pane with no report artifact is reported.
reset_state; reset_completions
task_meta impl1
seed_quiet_pane impl1 'nothing to see here'
assert_contains "$(drain '')" "IDLE-MAY-BE-WAITING-ON-YOU: impl1" "an idle marker-less pane is reported"

# (4) a BUSY pane is not: the harness is still working.
reset_state; reset_completions
task_meta impl2
seed_quiet_pane impl2 'esc to interrupt'
case "$(drain '')" in *impl2*) fail "a busy pane must not be reported" ;; esac

# ... and neither is a pane whose tail already carries a captain marker: the
# watcher's own wake owns that one.
reset_state; reset_completions
task_meta impl3
seed_quiet_pane impl3 'done: stage finished'
case "$(drain '')" in *impl3*) fail "a marker-carrying pane is the watcher's wake, not a completion report" ;; esac

# (4a) ... and neither is a pane whose idle stamp is UNREADABLE - empty, or
# zero-padded (bash arithmetic reads a leading 0 as octal): no evidence of
# idleness, and never an arithmetic error that ends the pass before a later
# task's completion is reported.
reset_state; reset_completions
task_meta idl1; seed_quiet_pane idl1 'nothing to see here'
task_meta zz-spec; seed_report zz-spec zz/spec
for bad in '' 0009; do
  printf '%s' "$bad" >"$state/.change-idl1"
  out="$(drain '')"
  case "$out" in *"IDLE-MAY-BE-WAITING-ON-YOU: idl1"*) fail "an unreadable idle stamp ('$bad') is no evidence of idleness" ;; esac
  assert_contains "$out" "UNACKNOWLEDGED COMPLETION: zz-spec" "an unreadable idle stamp ('$bad') must not end the completion pass"
done

# (4b) ... and neither is a <fam>-chief the WATCHER already declined to wake:
# this fallback re-reads the watcher's own .change-<id> stamp, so without the
# same two suppressions (ac_chief_gate_parked / ac_chief_child_live, ONE
# definition in ac-lib.sh) it resurrects the wake the watcher suppressed - every
# drain, forever. Acking it settles nothing: the chief's own ack output is the
# pane change that makes .change-<id> newer than the stamp again, which is the
# ack TREADMILL that trains a chief to ack reflexively.
# A chief supervising a LIVE family task first - and it reports in PROSE by
# charter, so there is no AC_CAPTAIN_RE marker for the guard above to catch.
reset_state; reset_completions
task_meta scq-chief; seed_quiet_pane scq-chief 'still waiting on scq-t1'
# scq-t1 is a member by its meta fleet_scope ALONE - `-t1` is in no closed
# suffix rule, so its id names no family. That is the shape of an epic STORY
# pane, whose scope ac-spawn.sh records on disk (bin/ac-spawn.sh's fleet_scope meta write).
task_meta scq-t1; printf 'fleet_scope=scq\n' >>"$state/scq-t1.meta"
: >"$state/.mock-win-scq-t1"
case "$(drain '')" in
  *"IDLE-MAY-BE-WAITING-ON-YOU: scq-chief"*) fail "a chief supervising a live family task must earn no idle notice" ;;
esac

# ... and by the CLOSED SUFFIX GRAMMAR (ac_family_of_id), the other of the two
# membership sources.
rm -f "$state/scq-t1.meta" "$state/.mock-win-scq-t1"
# ac_family_of_id trusts a stage suffix only once its nested brief dir exists
# (family-of-id-suffix-collision) - a real scq-spec task always has one, since
# ac-brief.sh mkdirs it before any crewmate can commit.
mkdir -p "$AC_HOME/data/scq/spec"
task_meta scq-spec; : >"$state/.mock-win-scq-spec"
case "$(drain '')" in
  *"IDLE-MAY-BE-WAITING-ON-YOU: scq-chief"*) fail "a stage member of the family is supervision too" ;;
esac

# ... and it FAILS TOWARD NOTIFYING: the family task lands, and the very next
# drain reports the chief. This is what makes the suppression the LIVE predicate
# and not a blanket chief exemption.
rm -f "$state/scq-spec.meta" "$state/.mock-win-scq-spec"
assert_contains "$(drain '')" "IDLE-MAY-BE-WAITING-ON-YOU: scq-chief" \
  "a chief with no live family task is reported as always"

# ... and an UNRELATED family whose id merely STARTS WITH this one is no more
# supervision than no family at all - the second consumer of the same swallow
# the watcher's stale/ended arm proves.
task_meta scq-curate-automation; : >"$state/.mock-win-scq-curate-automation"
assert_contains "$(drain '')" "IDLE-MAY-BE-WAITING-ON-YOU: scq-chief" \
  "a prefix-collision family is not this chief's crew"

# ... and the twin: a chief parked at an unanswered captain GATE, with nothing
# flying for it at all.
reset_state; reset_completions
task_meta pk-chief; seed_quiet_pane pk-chief 'posted the gate, waiting on the captain'
mkdir -p "$AC_HOME/data/pk"
printf '# Room: pk\n\n- [t] crewchief> GATE: spec ready, approve?\n' >"$AC_HOME/data/pk/room.md"
case "$(drain '')" in
  *"IDLE-MAY-BE-WAITING-ON-YOU: pk-chief"*) fail "a chief parked at a captain gate must earn no idle notice" ;;
esac

# ... and that one fails toward notifying too: the captain answers, so the chief
# is idle with nobody to wait on.
printf -- '- [t] crewchief> DECIDED: approved\n' >>"$AC_HOME/data/pk/room.md"
assert_contains "$(drain '')" "IDLE-MAY-BE-WAITING-ON-YOU: pk-chief" \
  "an answered gate leaves the chief genuinely idle"

# (5) scope: a roomchief reports its OWN family's stages and nothing else.
reset_state; reset_completions
task_meta famA-spec; seed_report famA-spec famA/spec
task_meta famB-spec; seed_report famB-spec famB/spec
chief_live famA; chief_live famB
out="$(drain famA)"
assert_contains "$out" "UNACKNOWLEDGED COMPLETION: famA-spec" "a roomchief reports its own family"
case "$out" in *famB-spec*) fail "a roomchief must not report another family's stage" ;; esac
# ... and the fleet drain leaves a LIVE family's ids to that roomchief.
out="$(drain '')"
case "$out" in *famA-spec*|*famB-spec*) fail "the fleet must not report a live family's stages" ;; esac

# (5b) membership is the pair the wake routing uses: the closed suffix grammar
# OR the pane's own fleet_scope. A fan-out sub-task and an epic story belong to
# the roomchief their fleet_scope names - their completions reach it, and the
# fleet leaves them alone while that roomchief lives.
reset_state; reset_completions
chief_live famA
task_meta famA-api; printf 'fleet_scope=famA\n' >>"$state/famA-api.meta"; seed_report famA-api famA/tasks/api
task_meta story1; printf 'fleet_scope=famA\n' >>"$state/story1.meta"; seed_report story1 story1
out="$(drain famA)"
assert_contains "$out" "UNACKNOWLEDGED COMPLETION: famA-api" "a fan-out member's completion reaches its roomchief"
assert_contains "$out" "UNACKNOWLEDGED COMPLETION: story1" "...and so does an epic story's"
out="$(drain '')"
case "$out" in *"famA-api"*|*"story1"*) fail "the fleet must not report a live roomchief's scoped members: $out" ;; esac

# (5c) a roomchief's OWN pane is the fleet's (chief panes are fleet-scoped by
# charter) - even once data/<fam>/chief makes its id read as the family, its
# own drain never reports it to itself.
reset_state; reset_completions
chief_live famA; mkdir -p "$AC_HOME/data/famA/chief"
seed_quiet_pane famA-chief 'reading the room'
case "$(drain famA)" in *"IDLE-MAY-BE-WAITING-ON-YOU: famA-chief"*) fail "a roomchief must not be told about its own pane" ;; esac

# (6) the ack verb is the only writer, and it silences both channels.
reset_state; reset_completions
task_meta famA-spec; seed_report famA-spec famA/spec
task_meta impl1; seed_quiet_pane impl1 'nothing to see here'
PATH="$stub:$PATH" env -u AC_SCOPE bash "$fakebin/ac-wake-drain.sh" ack famA-spec impl1
assert_file "$state/.ack-famA-spec" "ack stamps the report channel"
assert_file "$state/.ack-impl1" "ack stamps the idleness channel"
out="$(drain '')"
case "$out" in *famA-spec*) fail "ack must silence the report line" ;; esac
case "$out" in *impl1*) fail "ack must silence the idle line" ;; esac

# A plain drain NEVER acks - auto-acking would recreate the bug it fixes.
reset_state; reset_completions
task_meta famA-spec; seed_report famA-spec famA/spec
task_meta impl1; seed_quiet_pane impl1 'nothing to see here'
drain '' >/dev/null
assert_no_file "$state/.ack-famA-spec" "the no-arg drain writes no ack stamp"
assert_contains "$(drain '')" "UNACKNOWLEDGED COMPLETION: famA-spec" "an unacked completion re-reports every pass"

# The reported lines must not look like crewmate markers: they are printed
# into a chief's own pane, which a watcher polls.
captain_re="$(bash -c ". '$ROOT/bin/ac-lib.sh'; printf '%s\n' \"\$AC_CAPTAIN_RE\"")"
out="$(drain '')"
while IFS= read -r line; do
  case "$line" in
    "UNACKNOWLEDGED COMPLETION:"*|"IDLE-MAY-BE-WAITING-ON-YOU:"*)
      ! grep -qE "$captain_re" <<<"$line" || fail "a completion line false-wakes a watcher: $line" ;;
  esac
done <<<"$out"

# --- 10. the VERIFICATION-agent class is out of BOTH tallies -----------------
#
# A verification pane agent (ship reviewer, gate judge, qa) writes a
# state/<id>.meta so the watcher can supervise it, but it is not crew: it owes
# the chief no completion report and demands no watcher coverage of its own.
# Both of the drain's meta enumerators must skip it - and neither may change
# for any kind that exists today.
verify_meta() {
  # verify_meta <id> - a live VERIFICATION agent, otherwise identical to task_meta.
  printf 'kind=verify-codereview\nwindow=crew:%s\nbackend=herdr\n' "$1" >"$state/$1.meta"
  printf '%s t0\n' "$1" >"$state/.pane-$1"
}

# (1) report_completions: an idle marker-less VERIFIER is not a completion the
# chief owes an ack for.
reset_state; reset_completions
verify_meta famA-review
seed_quiet_pane famA-review 'nothing to see here'
case "$(drain '')" in *famA-review*) fail "a verifier must not be reported as an unacked completion" ;; esac
# ... and the identical pane under a crewmate kind still IS reported, so the
# skip is the CLASS and not a broken enumerator.
task_meta famA-impl
seed_quiet_pane famA-impl 'nothing to see here'
assert_contains "$(drain '')" "IDLE-MAY-BE-WAITING-ON-YOU: famA-impl" "a crewmate pane is untouched by the class"

# (2) the WATCHER-DOWN tally: a verifier is not "crew in flight", so a home
# holding only verifiers never nags for coverage.
reset_state; reset_completions
verify_meta famA-review
printf '%s\n' "$(( $(date +%s) - 9999 ))" >"$state/.last-watcher-beat"
case "$(drain '')" in *WATCHER-DOWN*) fail "a verifier meta must not count as crew in flight" ;; esac
task_meta famA-impl
assert_contains "$(drain '')" "WATCHER-DOWN" "one real crewmate still raises the alarm"
assert_contains "$(drain '')" "WATCHER-DOWN: 1 crewmate(s)" "and the verifier is not counted in the tally"
reset_state; reset_completions
rm -f "$state/.last-watcher-beat"

# An unknown argument dies with a usage message; the drain itself never runs.
rc=0
PATH="$stub:$PATH" env -u AC_SCOPE bash "$fakebin/ac-wake-drain.sh" bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "an unknown argument must die"

# A SOLO session (AC_SOLO=1) sits beside the chief: a drain from it would
# CONSUME the chief's wake records, which nothing can un-consume.
reset_state
seed '' solo1 "done: shipped"
rc=0; out="$(PATH="$stub:$PATH" AC_SOLO=1 bash "$fakebin/ac-wake-drain.sh" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a solo session's drain must refuse"
assert_contains "$out" "solo" "the refusal names the solo session"
assert_eq "$(spool_records "$state/.wake-spool")" "1" "a refused solo drain leaves the chief's record in the spool"

# --- the CLI contract, row by row ---------------------------------------------
# One side root $H: a home at $H/home and the caller's cwd $H/cwd; a lab bin/
# holding every live script (src/ linked beside it) with ac-ready, ac-remote,
# ac-learn and ac-brain replaced by ONE logging stub (argv and AC_BACKEND,
# answers per sentinel file); a stub dir $H/stub first on PATH - herdr and orca
# logging argv (herdr with HERDR_SESSION) and answering per sentinel file,
# `date +%s` answering $H/stub/clock. Every knob the drain reads is scrubbed,
# then AC_HOME and the row's (HOME in a value is the side root); stdin
# /dev/null; LC_ALL=C unless a row names en_US.UTF-8. stdout and stderr are
# read with the side root spelled HOME and a claim dir's pid PID.
WD_NBIN="$TMP/wdn/bin"
mkdir -p "$WD_NBIN"
cp "$BIN"/*.sh "$WD_NBIN/"
ln -s "$ROOT/src" "$TMP/wdn/src"
for wd_s in ac-ready ac-remote ac-learn ac-brain; do
  cat >"$WD_NBIN/$wd_s.sh" <<'STUB'
#!/bin/sh
n="${0##*/}"
printf '%s %s [AC_BACKEND=%s]\n' "$n" "$*" "${AC_BACKEND-unset}" >>"$STUB_DIR/log"
case "$n $1" in
  "ac-brain.sh sync") [ ! -f "$STUB_DIR/brain-sync" ] || cat "$STUB_DIR/brain-sync" ;;
  "ac-brain.sh delta") [ ! -f "$STUB_DIR/brain-delta" ] || cat "$STUB_DIR/brain-delta" ;;
esac
[ ! -f "$STUB_DIR/$n.kill" ] || kill -TERM $$
[ ! -f "$STUB_DIR/$n.rc" ] || exit "$(cat "$STUB_DIR/$n.rc")"
exit 0
STUB
  chmod +x "$WD_NBIN/$wd_s.sh"
done
H="$TMP/wside"
WT=1700000000
WD_ENV=(); WD_LC=C; WD_HOMELESS=0; WD_WRAP=""; WD_PATH="$PATH"
wd_run() {  # wd_run <prefix> <args...> - one drain on $H, its stdout and stderr in $TMP/<prefix>.raw/.err
  local p="$1" x v; shift
  local a=() e=("LC_ALL=$WD_LC" "PATH=$H/stub:$WD_PATH" "STUB_DIR=$H/stub")
  [ "$WD_HOMELESS" = 1 ] || e+=("AC_HOME=$H/home")
  for x in ${WD_ENV[@]+"${WD_ENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//HOME/$H}"); done
  for x in "$@"; do a+=("${x//HOME/$H}"); done
  rm -f "$H/stub/log"
  local cmd=("$WD_NBIN/ac-wake-drain.sh")
  [ -z "$WD_WRAP" ] || cmd=(bash -c "$WD_WRAP" _ "$H/home/state" "$WD_NBIN/ac-wake-drain.sh")
  (cd "$H/cwd" && env -u AC_HOME -u AC_SCOPE -u AC_SOLO -u AC_BACKEND -u AC_FLEET_STATE -u AC_STALE -u AC_GUARD_GRACE \
    -u AC_BUSY_RE -u AC_CAPTAIN_RE -u AC_HERDR_SESSION -u AC_HERDR_RPC_TIMEOUT -u EPOCHSECONDS -u LANG -u LC_CTYPE \
    "${e[@]}" "${cmd[@]}" ${a[@]+"${a[@]}"}) <"${WD_STDIN:-/dev/null}" >"$TMP/$p.raw" 2>"$TMP/$p.err"
}
wd_norm() { LC_ALL=C sed -e "s#$H#HOME#g" -E -e 's/\.wake-spool-draining\.[0-9]+/.wake-spool-draining.PID/g'; }
WRC=0
wd() {  # wd <args...> - one drain; WRC its exit, wout/werr/wlog what it said and spawned
  WRC=0
  wd_run n "$@" || WRC=$?
  wd_norm <"$TMP/n.raw" >"$TMP/n.out"; wd_norm <"$TMP/n.err" >"$TMP/n.err2"
}
wd_utf8() { WD_LC=en_US.UTF-8; wd "$@"; WD_LC=C; }
wout() { cat "$TMP/n.out"; }
werr() { cat "$TMP/n.err2"; }
wlog() { [ ! -f "$H/stub/log" ] || wd_norm <"$H/stub/log"; }
fresh() {  # a clean side: home, cwd, the PATH stubs, the clock at WT
  rm -rf "$H"; mkdir -p "$H/home/state" "$H/home/data" "$H/home/config" "$H/cwd" "$H/stub"
  printf '%s\n' "$WT" >"$H/stub/clock"
  cat >"$H/stub/date" <<'EOF'
#!/bin/sh
[ "$*" = +%s ] && exec cat "$STUB_DIR/clock"
exec /bin/date "$@"
EOF
  cat >"$H/stub/herdr" <<'EOF'
#!/bin/sh
d="$STUB_DIR"
printf 'herdr %s [%s]\n' "$*" "${HERDR_SESSION:-}" >>"$d/log"
case "$1 $2" in
  "pane get") [ -e "$d/win-$3" ] ;;
  "pane list") [ ! -e "$d/list-fails" ] || exit 1; printf '{"result":{"panes":[]}}\n' ;;
  "status server") printf '{"running":true}\n' ;;
  "pane read") [ -e "$d/tail-$3" ] || exit 1; cat "$d/tail-$3" ;;
  *) exit 2 ;;
esac
EOF
  cat >"$H/stub/orca" <<'EOF'
#!/bin/sh
d="$STUB_DIR"
printf 'orca %s\n' "$*" >>"$d/log"
case "$1 $2" in
  "terminal show") [ -e "$d/win-$4" ] && c=true || c=false; printf '{"ok":true,"result":{"terminal":{"connected":%s}}}\n' "$c" ;;
  "terminal read") [ -e "$d/tail-$4" ] || exit 1; jq -Rs '{ok:true,result:{terminal:{tail:(split("\n")[:-1])}}}' <"$d/tail-$4" ;;
  *) printf '{"ok":true}\n' ;;
esac
EOF
  chmod +x "$H/stub/date" "$H/stub/herdr" "$H/stub/orca"
}
rec() { mkdir -p "$H/home/state/.wake-spool${1:+.$1}"; printf "$3" >"$H/home/state/.wake-spool${1:+.$1}/$2"; }  # rec <family|''> <name> <printf format>
claim() { mkdir -p "$H/home/state/.wake-spool-draining.$1"; printf "$3" >"$H/home/state/.wake-spool-draining.$1/$2"; }  # claim <suffix> <name> <format>
m() { printf "$2" >"$H/home/state/$1.meta"; }  # m <id> <printf format>
pane() { printf '%s t\n' "${2:-p$1}" >"$H/home/state/.pane-$1"; }  # pane <id> [<handle>]
win() { : >"$H/stub/win-$1"; }
ptail() { printf "$2" >"$H/stub/tail-$1"; }  # ptail <handle> <printf format>
chief() {  # chief <fam> [<backend>] - a promoted roomchief meta and its pane handle (live only with win p<fam>-chief)
  m "$1-chief" "kind=roomchief\nbackend=${2:-herdr}\n"; pane "$1-chief"
}
chg() { printf "$2" >"$H/home/state/.change-$1"; touch -t 202301010000 "$H/home/state/.change-$1"; }  # chg <id> <printf format>
idle() { m "$1" 'kind=implement\nbackend=herdr\n'; pane "$1"; win "p$1"; chg "$1" "$((WT - 999))\n"; ptail "p$1" "${2:-quiet here}\n"; }
report() {  # report <id> <dir under data> - a past-dated stage report
  mkdir -p "$H/home/data/$2"; printf 'b\n' >"$H/home/data/$2/brief.md"; printf 'r\n' >"$H/home/data/$2/report.md"
  touch -t 202301010000 "$H/home/data/$2/report.md"
}
cfg() { printf '%s\n' "$2" >"$H/home/config/$1"; }
beat() { printf '%s\n' "$1" >"$H/home/state/.last-watcher-beat${2:+.$2}"; }
st() { printf "$2" >"$H/home/state/$1.status"; }  # st <id> <printf format>
WD_E1=$'\303\251'
usage_all="ERROR: usage: ac-wake-drain.sh | ac-wake-drain.sh ack <id> [<id>...]"
solo_refusal="ERROR: a solo session (AC_SOLO=1) never drains or acks wakes - they belong to the chief session (solo-session skill)"

# 1. the gate: the backend first, then the home, then solo, then argv; a
#    refused solo run leaves the chief's record and mints state/ alone.
fresh
wd bogus; assert_eq "$WRC:$(werr)" "1:$usage_all" "row 1: an unknown verb"
wd ack; assert_eq "$WRC:$(werr)" "1:ERROR: usage: ac-wake-drain.sh ack <id> [<id>...]" "row 1: ack with no id"
wd ack a '' ../x
assert_eq "$WRC" 1 "row 1: the failing touch ends the run"
assert_file "$H/home/state/.ack-a" "row 1: the stamps before the failing one are written"
assert_file "$H/home/state/.ack-" "row 1: an empty id stamps as spelled"
wd ack $'e\n\n'; assert_eq "$WRC" 0 "row 1: an id's trailing LFs are dropped"
assert_file "$H/home/state/.ack-e" "row 1: ...and it stamps .ack-e"
rec '' 1.1.000000 '1\treport\tz1\tdone: x\n'
WD_ENV=(AC_SOLO=1)
wd ack s1; assert_eq "$WRC:$(werr)" "1:$solo_refusal" "row 1: solo refuses ack"
assert_no_file "$H/home/state/.ack-s1" "row 1: a refused solo ack stamps nothing"
wd bogus; assert_eq "$WRC:$(werr)" "1:$solo_refusal" "row 1: solo refuses before the arguments are read"
WD_ENV=()
assert_file "$H/home/state/.wake-spool/1.1.000000" "row 1: a refused solo run leaves the record"
WD_ENV=(AC_SOLO=0); wd; assert_contains "$(wout)" "report z1 done: x" "row 1: AC_SOLO=0 drains"
rec '' 1.1.000000 '1\treport\tz2\tdone: y\n'
WD_ENV=("AC_SOLO= 1"); wd; assert_contains "$(wout)" "report z2 done: y" "row 1: AC_SOLO=' 1' drains"; WD_ENV=()
wd '' extra; assert_eq "$WRC:$(wout)" "0:no queued wakes" "row 1: an empty first argument is the drain"
rm -rf "$H/home/state"
WD_HOMELESS=1; WD_ENV=(AC_SOLO=1); wd; WD_ENV=(); WD_HOMELESS=0
assert_eq "$WRC" 1 "row 1: homeless exits 1"
assert_contains "$(werr)" "ERROR: AC_HOME is not set" "row 1: homeless refuses before solo"
cfg backend tmux
WD_ENV=(AC_SOLO=1); wd; WD_ENV=()
assert_eq "$WRC:$(werr)" "1:ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" "row 1: config/backend before solo"
rm -f "$H/home/config/backend"
WD_ENV=(AC_BACKEND=Herdr AC_SOLO=1); WD_HOMELESS=1; wd; WD_HOMELESS=0; WD_ENV=()
assert_eq "$WRC" 1 "row 1: an unsupported AC_BACKEND exits 1"
assert_contains "$(werr)" "unsupported backend 'Herdr'" "row 1: the backend before the home and solo"
WD_ENV=(AC_HOME=HOME/nowhere); wd; WD_ENV=()
assert_eq "$WRC:$(werr)" "1:ERROR: AC_HOME is not a readable directory: HOME/nowhere" "row 1: an AC_HOME cd cannot enter"

# 2. an empty home: `no queued wakes`, config/ minted; the remote push only
#    with an executable remote-poll; a scoped drain runs no ride-along.
fresh; rm -rf "$H/home/config"
wd; assert_eq "$WRC:$(wout)" "0:no queued wakes" "row 2: empty"
[ -d "$H/home/config" ] || fail "row 2: config/ is minted"
WD_ENV=(AC_SCOPE=fam2); wd; assert_eq "$(wlog)" "" "row 2: a scoped drain runs no ride-along"; WD_ENV=()
printf '#!/bin/sh\n' >"$H/home/config/remote-poll"
wd; case "$(wlog)" in *push-pending*) fail "row 2: a remote-poll that is not executable pushes nothing" ;; esac
# state/ is minted by a spawned `mkdir -p`: a regular file there fails it, and
# the drain goes on with that path.
fresh; rm -rf "$H/home/state"; : >"$H/home/state"
wd; assert_eq "$WRC:$(wout)" "0:no queued wakes" "row 2: a file at state/ drains nothing, exit 0"
[ -n "$(werr)" ] || fail "row 2: the failed mkdir says so"
wd ack x; assert_eq "$WRC" 1 "row 2: an ack under a file at state/ is touch's failure"

# 3. the rendering: spaces around the fields dropped, inner runs kept,
#    per-file records, a two-line record, backslashes and bytes, the remote
#    label with and without its prefix, a blank record, a spaced kind.
fresh
rec '' 1.1.000001 '1\treport\tr1\t  done: trailing and  inner  spaces  \n'
rec '' 1.1.000002 '1\treport\tr2\t\n'
rec '' 1.1.000005 '1\treport\tr5\tno LF'
rec '' 1.1.000006 '1\treport\tr6\tline one\n2\tstale\tr6b\tline two\n'
rec '' 1.1.000007 '1\treport\tr7\tback\\\\slash \\n\n'
rec '' 1.1.000008 '1\treport\tr8\tbyte \351 and \303\251\n'
rec '' 1.1.000009 '1\tremote\tcaptain\tremote-order rid9\n'
rec '' 1.1.000010 '1\tremote\tcaptain\tno prefix\n'
rec '' 1.1.000011 '\n'
rec '' 1.1.000012 '1\t  spaced kind\tr12\tx\n'
wd
assert_eq "$WRC:$(wout)" "0:report r1 done: trailing and  inner  spaces
report r2$(printf ' ')
report r5 no LF
report r6 line one
stale r6b line two
report r7 back\\\\slash \\n
report r8 byte $(printf '\351') and $WD_E1
remote captain remote-order rid9
  status captain: no chief had drained this remote order until now - ac-remote.sh show rid9
remote captain no prefix
  status captain: no chief had drained this remote order until now - ac-remote.sh show no prefix
$(printf '  ')
spaced kind r12 x" "row 3: every record rendered, in name order"
# the status context: annotated, deduped, bounded (characters under UTF-8,
# bytes under C), a symlink, no space, empty, a blank last line, an LF-less
# one, a directory, bytes kept.
wd_long="$(printf 'x%.0s' $(seq 1 160))"
wd_e160="$(printf "$WD_E1%.0s" $(seq 1 160))"
wd_status() {
  st a1 '2026-01-01T00:00:00Z blocked: on the schema\n'; rec '' 1.1.000001 '1\tstale\ta1\t\n'
  st a2 '2026-01-01T00:00:00Z done: shipped it\n'; rec '' 1.1.000002 '1\treport\ta2\tdone: shipped it\n'
  st a3 "t ${wd_long}\n"; rec '' 1.1.000003 '1\tstale\ta3\t\n'
  st a4 "t ${wd_long}y\n"; rec '' 1.1.000004 '1\tstale\ta4\t\n'
  st a5 "t ${wd_e160}\n"; rec '' 1.1.000005 '1\tstale\ta5\t\n'
  st a6 "t ${wd_e160}$WD_E1\n"; rec '' 1.1.000006 '1\tstale\ta6\t\n'
  st real7 't linked status\n'; ln -s real7.status "$H/home/state/a7.status"; rec '' 1.1.000007 '1\tstale\ta7\t\n'
  st a8 'nospace\n'; rec '' 1.1.000008 '1\tstale\ta8\t\n'
  st a9 ''; rec '' 1.1.000009 '1\tstale\ta9\t\n'
  st a10 'x first\n\n'; rec '' 1.1.000010 '1\tstale\ta10\t\n'
  st a11 'x older\nx no LF at the end'; rec '' 1.1.000011 '1\tstale\ta11\t\n'
  mkdir -p "$H/home/state/a12.status"; rec '' 1.1.000012 '1\tstale\ta12\t\n'
  st a13 'x \351 byte\r\n'; rec '' 1.1.000013 '1\tstale\ta13\t\n'
}
fresh; wd_status; wd
assert_eq "$(wout | LC_ALL=C grep '^  status')" "  status a1: blocked: on the schema
  status a3: $wd_long
  status a4: $(printf 'x%.0s' $(seq 1 157))...
  status a5: $(printf '%s' "$wd_e160" | head -c 157)...
  status a6: $(printf '%s' "$wd_e160" | head -c 157)...
  status a11: no LF at the end
  status a13: $(printf '\351 byte\r')" "row 3: the status lines under C - 160 bytes kept, past that 157 and ..."
fresh; wd_status; wd_utf8
assert_contains "$(wout)" "  status a5: $wd_e160
" "row 3: 160 characters stay whole under UTF-8"
assert_contains "$(wout)" "  status a6: $(printf "$WD_E1%.0s" $(seq 1 157))...
" "row 3: past 160 characters, 157 and ... under UTF-8"
if [ "$(id -u)" != 0 ]; then
  fresh; st u1 'x unreadable\n'; chmod 000 "$H/home/state/u1.status"; rec '' 1.1.000001 '1\tstale\tu1\t\n'
  wd; case "$(wout)" in *"status u1"*) fail "row 3: an unreadable status is not annotated" ;; esac
  chmod 644 "$H/home/state/u1.status"
fi

# 4. scope: the fleet drains orphans (no chief meta, a dead window, a meta
#    backend it refuses) and leaves a live family (herdr or orca), each probe
#    on config/herdr-session.
fresh
cfg herdr-session s1
rec '' 1.1.000001 '1\treport\tf1\tdone: fleet\n'
rec famL 1.1.000001 '1\treport\tfamL-t1\tdone: live family\n'; chief famL; win pfamL-chief
rec famD 1.1.000001 '1\treport\tfamD-t1\tdone: dead window\n'; chief famD
rec famA 1.1.000001 '1\treport\tfamA-t1\tdone: archived chief\n'
rec famO 1.1.000001 '1\treport\tfamO-t1\tdone: orca chief\n'; chief famO orca; win pfamO-chief
rec famB 1.1.000001 '1\treport\tfamB-t1\tdone: a refused meta backend\n'; chief famB tmux; win pfamB-chief
wd
assert_eq "$WRC:$(wout | grep '^report')" "0:report f1 done: fleet
report famA-t1 done: archived chief
report famB-t1 done: a refused meta backend
report famD-t1 done: dead window" "row 4: the fleet's own, then each orphan family in byte order"
assert_contains "$(wlog)" "herdr pane get pfamD-chief --session s1 [s1]" "row 4: the probe on the configured session"
assert_contains "$(wlog)" "orca terminal show --terminal pfamO-chief" "row 4: an orca chief is probed through orca"

# 5. orphan order: byte order, under C and under UTF-8 alike.
wd_order() { for f in afam Bfam Cfam; do rec "$f" 1.1.000001 "1\treport\t$f-t1\tdone: $f\n"; done; }
wd_bytes="report Bfam-t1 done: Bfam
report Cfam-t1 done: Cfam
report afam-t1 done: afam"
fresh; wd_order; wd
assert_eq "$(wout | grep '^report')" "$wd_bytes" "row 5: byte order"
fresh; wd_order; wd_utf8
assert_eq "$(wout | grep '^report')" "$wd_bytes" "row 5: byte order under UTF-8 too"

# 6. the dead-claim sweep: a chief's record goes to the fleet spool; the last
#    `.wake-spool-draining.` tag decides the suffix; a non-pid or empty
#    suffix is no claim dir.
fresh
sh -c 'exit 0' & WD_DEAD=$!; wait "$WD_DEAD" 2>/dev/null || true
claim "$WD_DEAD" "1.$WD_DEAD.000001" '1\treport\tc-chief\tdone: a chief record\n'
claim notapid 1.1.000001 '1\treport\tn1\tdone: not a pid\n'
claim "x.wake-spool-draining.$WD_DEAD" 1.1.000001 '1\treport\tn2\tdone: the last tag decides\n'
claim "" 1.1.000001 '1\treport\tn3\tdone: an empty suffix\n'
wd
assert_contains "$(wout)" "report c-chief done: a chief record" "row 6: a chief's recovered record drains on the fleet pass"
assert_contains "$(wout)" "report n2 done: the last tag decides" "row 6: the suffix after the last tag is the pid"
case "$(wout)" in *n1*|*n3*) fail "row 6: a non-pid or empty suffix is never swept: $(wout)" ;; esac
assert_file "$H/home/state/.wake-spool-draining.notapid/1.1.000001" "row 6: a non-pid suffix is left alone"
assert_file "$H/home/state/.wake-spool-draining./1.1.000001" "row 6: an empty suffix is left alone"
[ ! -e "$H/home/state/.wake-spool-draining.$WD_DEAD" ] || fail "row 6: the dead claim dir is removed"
# a live claimer running this module (`bun ... /src/wake-drain.ts`) is a
# drainer: its claim is kept.
bash -c "exec -a 'bun --no-env-file $TMP/held/src/wake-drain.ts /cwd' sleep 60" & WD_TS=$!
fresh
claim "$WD_TS" 1.1.000001 '1\treport\tl4\tdone: held by a TS drainer\n'
wd
kill "$WD_TS" 2>/dev/null; wait "$WD_TS" 2>/dev/null || true
assert_eq "$(head -n 1 "$TMP/n.out")" "no queued wakes" "row 6: a live TS drainer's claim is kept"
assert_file "$H/home/state/.wake-spool-draining.$WD_TS/1.1.000001" "row 6: the record stays in the live claim"

# 7. a dot entry and an empty family spool drain nothing; neither does a file
#    at the fleet spool's path.
fresh
rec '' .hidden '1\treport\tdot\tdone: x\n'; mkdir -p "$H/home/state/.wake-spool.famE"
wd; assert_eq "$(head -n 1 "$TMP/n.out")" "no queued wakes" "row 7: a dot entry and an empty spool"
assert_file "$H/home/state/.wake-spool/.hidden" "row 7: a dot entry is never claimed"
rm -rf "$H/home/state/.wake-spool"; : >"$H/home/state/.wake-spool"
wd; assert_eq "$WRC:$(head -n 1 "$TMP/n.out")" "0:no queued wakes" "row 7: a file at the fleet spool's path"

# 8. completions: the report line, an ambiguous task dir and a verifier stay
#    silent, a self task is reported.
fresh
m famA-spec 'kind=spec\n'; report famA-spec famA/spec
m amb 'kind=x\n'; report amb amb; report amb amb/implement
m ver1 'kind=verify-codereview\n'; report ver1 ver1
m self1 'kind=self\n'; report self1 self1
wd
assert_eq "$(wout | grep '^UNACK')" "UNACKNOWLEDGED COMPLETION: famA-spec has a report at HOME/home/data/famA/spec/report.md (silence it: bin/ac-wake-drain.sh ack famA-spec)
UNACKNOWLEDGED COMPLETION: self1 has a report at HOME/home/data/self1/report.md (silence it: bin/ac-wake-drain.sh ack self1)" "row 8: the report lines"

# 9. idleness: quiet, busy (ASCII and UTF-8 busy text), a captain marker,
#    stamps that are no number, a stamp of now; the AC_STALE threshold; the
#    clock; the chief suppressions; the orca capture; stdin.
fresh
idle i1
idle i2 'esc to interrupt'
idle i3 $'Working\342\200\246 on it'
idle i4 'done: finished'
idle i5; chg i5 ''
idle i6; chg i6 '0009\n'
idle i8; chg i8 "$WT\n"
wd
assert_eq "$(wout | grep '^IDLE')" "IDLE-MAY-BE-WAITING-ON-YOU: i1 quiet for 999s with no marker (peek: bin/ac-peek.sh i1; silence it: bin/ac-wake-drain.sh ack i1)" "row 9: only the quiet pane is idle"
WD_ENV=(AC_STALE=+1000); wd; case "$(wout)" in *IDLE*) fail "row 9: 999s is under an AC_STALE of 1000" ;; esac
WD_ENV=(AC_STALE=0999); wd; assert_contains "$(wout)" "YOU: i1 quiet for 999s" "row 9: AC_STALE is decimal and inclusive"
WD_ENV=(EPOCHSECONDS=1700000500); wd; assert_contains "$(wout)" "YOU: i1 quiet for 1499s" "row 9: EPOCHSECONDS is the clock"
WD_ENV=(EPOCHSECONDS=1700000000+1); wd; WD_ENV=()
assert_contains "$(wout)" "IDLE-MAY-BE-WAITING-ON-YOU: i1 quiet for 1000s" "row 9: an expression clock is evaluated"
# the chief suppressions: a prefix family and a verifier are no members, and
# an unreadable member meta warns.
fresh
idle px-chief; m px-curate-x 'kind=x\n'; pane px-curate-x; win ppx-curate-x
m vf-x 'kind=verify-qa\nfleet_scope=px\n'; pane vf-x; win pvf-x
idle pk-chief; mkdir -p "$H/home/data/pk"; printf '# Room: pk\n\n- [t] crewchief> GATE: approve?\n' >"$H/home/data/pk/room.md"
idle sf-chief; m story1 'fleet_scope=sf\n'; pane story1; win pstory1
wd
assert_contains "$(wout)" "IDLE-MAY-BE-WAITING-ON-YOU: px-chief" "row 9: a prefix family and a verifier are no members"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$H/home/data/pk/room.md" "$H/home/state/story1.meta"
  wd
  chmod 644 "$H/home/data/pk/room.md" "$H/home/state/story1.meta"
  assert_contains "$(werr)" "WARN: cannot read meta file HOME/home/state/story1.meta" "row 9: an unreadable member meta warns"
  assert_contains "$(wout)" "IDLE-MAY-BE-WAITING-ON-YOU: pk-chief" "row 9: an unreadable room is no parked gate"
fi
# an orca task, a capture that fails.
fresh
idle h0; rm -f "$H/stub/tail-ph0"
idle o1; m o1 'backend=orca\n'; pane o1 ho1; win ho1; ptail ho1 'orca quiet\n'
wd
assert_contains "$(wlog)" "orca terminal read --terminal ho1 --limit 40 --screen --json" "row 9: the orca capture's argv"
assert_eq "$(wout | grep '^IDLE' | cut -d' ' -f2)" "o1" "row 9: the orca pane is idle, the uncapturable one skipped"
fresh; rec '' 1.1.000001 '1\treport\tq1\tdone: consumed\n'; idle b13 'bad \351 byte'; wd
assert_contains "$(wout)" "IDLE-MAY-BE-WAITING-ON-YOU: b13" "row 9: under C an invalid byte in the capture reads"
# stdin by position: a herdr that logs what its stdin holds, the drain's
# stdin a line. The completion scope's roomchief probe and chiefChildLive's
# member probes run with stdin /dev/null - the caller's stdin passed to them
# is orca's alone.
wd_stdin() {
  cat >"$H/stub/herdr" <<'EOF'
#!/bin/sh
d="$STUB_DIR"
printf 'herdr %s stdin=[%s]\n' "$*" "$(cat)" >>"$d/log"
case "$1 $2" in
  "pane get") [ -e "$d/win-$3" ] ;;
  "pane list") printf '{"result":{"panes":[]}}\n' ;;
  "pane read") [ -e "$d/tail-$3" ] || exit 1; cat "$d/tail-$3" ;;
  *) exit 2 ;;
esac
EOF
  m w6-api 'fleet_scope=w6\n'; report w6-api w6/tasks/api; chief w6
  idle sv-chief; mkdir -p "$H/home/data/sv/spec"; m sv-spec 'kind=spec\n'; pane sv-spec; win psv-spec
}
fresh; wd_stdin
printf 'caller-stdin\n' >"$TMP/wd-stdin"
WD_STDIN="$TMP/wd-stdin"; wd; WD_STDIN=""
assert_contains "$(wout)" "UNACKNOWLEDGED COMPLETION: w6-api" "row 9 (stdin): the completion scope probed the chief"
case "$(wout)" in *"YOU: sv-chief"*) fail "row 9 (stdin): a live member keeps its chief quiet" ;; esac
assert_eq "$(wlog | /usr/bin/grep -c 'stdin=\[\]$')" "$(wlog | /usr/bin/grep -c '^herdr ')" "row 9 (stdin): no herdr call read the caller's stdin"
assert_contains "$(wlog)" "herdr pane get pw6-chief stdin=[]" "row 9 (stdin): ...the completion scope's"
assert_contains "$(wlog)" "herdr pane get psv-spec stdin=[]" "row 9 (stdin): ...chiefChildLive's"

# 10. WATCHER-DOWN: the in-flight set (verifier and self out, a chief and a
#     directory named x.meta in), AC_GUARD_GRACE, an expression clock.
fresh
m t1 'kind=x\n'; m v1 'kind=verify-x\n'; m s1 'kind=self\n'; chief cf; mkdir -p "$H/home/state/d.meta"
beat "$((WT - 1000))"
wd
assert_contains "$(wout)" "WATCHER-DOWN: 3 crewmate(s) in flight but no fresh beat (age 1000s). Arm bin/ac-watch.sh as a background task now." "row 10: the tally and the line"
WD_ENV=(AC_GUARD_GRACE=+2000); wd; case "$(wout)" in *WATCHER-DOWN*) fail "row 10: an age under AC_GUARD_GRACE is covered" ;; esac
WD_ENV=(EPOCHSECONDS=1700000000+1); wd; WD_ENV=()
assert_contains "$(wout)" "no fresh beat (age 1001s)" "row 10: an expression clock is evaluated"

# 11. the scheduler killed (128+n); autoroom failing.
fresh
touch "$H/stub/ac-ready.sh.kill"; wd
assert_contains "$(wout)" "WARN   scheduler unavailable: ac-ready.sh exited 143 - run it to see why" "row 11: a signal is 128+n"
rm -f "$H/stub/ac-ready.sh.kill"; printf '5\n' >"$H/stub/ac-learn.sh.rc"
wd; assert_eq "$WRC" 0 "row 11: autoroom's failure never ends the drain"
assert_contains "$(wlog)" "ac-learn.sh autoroom" "row 11: ...which did run it"

# 12. the brain: a failing sync says nothing; the delta's rendering through
#     jq (8 pages, 5 facts cut at 160, has_more); a first wake, an error, not
#     JSON, an empty object; no jq on PATH.
fresh; touch "$H/home/state/brain.sqlite"
printf '2\n' >"$H/stub/ac-brain.sh.rc"; wd; rm -f "$H/stub/ac-brain.sh.rc"
assert_eq "$WRC" 0 "row 12: a failing brain exits 0"
case "$(wout)" in *brain-*) fail "row 12: a failing sync or delta prints nothing: $(wout)" ;; esac
wd_pages="$(for i in 1 2 3 4 5 6 7 8 9; do printf '{"path":"p%s"},' "$i"; done)"
wd_f170="$(printf 'f%.0s' $(seq 1 170))"
printf '%s\n' "{\"since\":\"s\",\"pages\":[${wd_pages}{\"slug\":\"sl\"},{}],\"facts\":[{\"fact\":\"$wd_f170\"},{},{\"fact\":\"b\"},{\"fact\":\"c\"},{\"fact\":\"d\"},{\"fact\":\"e\"}],\"has_more\":true}" >"$H/stub/brain-delta"
wd
assert_eq "$(wout | sed -n '/^brain-delta/,$p')" "brain-delta: 11 page(s), 6 fact(s) since s (more pending - the next drain continues)
- p1
- p2
- p3
- p4
- p5
- p6
- p7
- p8
- fact: $(printf 'f%.0s' $(seq 1 160))
$(printf -- '- fact: ')
- fact: b
- fact: c
- fact: d" "row 12: the delta's rendering"
assert_contains "$(wlog)" "ac-brain.sh delta --agent crewchief --session chief --compact" "row 12: the chief's cursor"
printf '{"first_wake":true}\n' >"$H/stub/brain-delta"; wd
assert_contains "$(wout)" "brain-delta: cursor registered for crewchief (first wake)" "row 12: a first wake"
for wd_delta in '{"error":"x"}' 'not json'; do
  printf '%s\n' "$wd_delta" >"$H/stub/brain-delta"; wd
  case "$(wout)" in *brain-delta*) fail "row 12: '$wd_delta' renders nothing: $(wout)" ;; esac
done
printf '{}\n' >"$H/stub/brain-delta"; wd
assert_contains "$(wout)" "brain-delta: 0 page(s), 0 fact(s) since ?" "row 12: an empty delta"
WD_NOJQ="$TMP/nojq"; mkdir -p "$WD_NOJQ"
for f in /usr/bin/* /bin/*; do case "${f##*/}" in jq) ;; *) ln -sf "$f" "$WD_NOJQ/" ;; esac; done
WD_PATH="$WD_NOJQ:$(dirname "$(command -v bun)")"; wd; WD_PATH="$PATH"
case "$(wlog)" in *delta*) fail "row 12: no jq, no delta call" ;; esac

# 13. concurrency: one drain HELD inside its claim (its emit awk has read the
#     records and waits on a gate), a second drain beside it: the second keeps
#     the live claimer's records, and every record emits once.
WD_GATE="$TMP/wd-gate"; mkfifo "$WD_GATE" "$WD_GATE.in"
mkdir -p "$TMP/wd-hold"
cat >"$TMP/wd-hold/awk" <<EOF
#!/bin/sh
case "\$*" in
  *'printf "%s %s %s'*) [ -e "\$STUB_DIR/hold" ] || exec /usr/bin/awk "\$@"
    rm -f "\$STUB_DIR/hold"; o="\$(/usr/bin/awk "\$@"; printf x)"
    printf '\n' >"$WD_GATE.in"; read -r _ <>"$WD_GATE"; printf '%s' "\${o%x}" ;;
  *) exec /usr/bin/awk "\$@" ;;
esac
EOF
chmod +x "$TMP/wd-hold/awk"
fresh; rec '' 1.1.000001 '1\treport\th1\tdone: once\n'; rec '' 1.1.000002 '1\treport\th2\tdone: twice?\n'; : >"$H/stub/hold"
WD_PATH="$TMP/wd-hold:$PATH"
wd_run h1 & wd_held=$!
read -r -t 60 _ <>"$WD_GATE.in" || fail "row 13: the held drain never reached its gate"
wd_run h2 || true
exec 9<>"$WD_GATE"; printf '\n' >&9; wait "$wd_held" || true; exec 9>&-
WD_PATH="$PATH"
assert_eq "$(cat "$TMP/h1.raw" "$TMP/h2.raw" | grep -c '^report h')" "2" "row 13: two drains emit each record once"
assert_contains "$(cat "$TMP/h2.raw")" "no queued wakes" "row 13: the second keeps the live drainer's claim"

# 14. THE CLOSED READER: stdout a pipe whose reader is gone ends the drain at
#     the write, 141, the record kept in its claim; the next drain's sweep
#     emits it.
fresh
rec fam 1.1.000001 '1\treport\tfam-r1\tdone: unread\n'
WD_ENV=(AC_SCOPE=fam)
WD_WRAP='exec python3 -c "import os, signal, sys
r, w = os.pipe(); os.close(r); os.dup2(w, 1); os.close(w)
signal.signal(signal.SIGPIPE, signal.SIG_DFL)
os.execv(sys.argv[1], sys.argv[1:])" "$2"'
wd; WD_WRAP=""
assert_eq "$WRC:$(werr)" "141:" "row 14: exit 141, nothing said"
assert_eq "$(cat "$H"/home/state/.wake-spool-draining.*/1.1.000001)" "$(printf '1\treport\tfam-r1\tdone: unread')" "row 14: the record is kept in its claim"
wd
assert_eq "$(wout)" "report fam-r1 done: unread" "row 14: the next drain emits the kept record"
WD_ENV=()

pass
