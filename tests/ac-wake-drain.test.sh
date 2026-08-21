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

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

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
# invokes its ride-alongs as siblings of $0, so this is how "did the drain
# call them?" is observed. Every other script is the real one.
fakebin="$TMP/fakebin"
mkdir -p "$fakebin"
for f in "$ROOT"/bin/*.sh; do ln -sf "$f" "$fakebin/$(basename "$f")"; done
for s in ac-ready ac-remote; do
  rm -f "$fakebin/$s.sh"
  cat >"$fakebin/$s.sh" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$TMP/$s.calls"
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
printf '{\n "files": 42,\n "changed": 1\n}\n'
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
# sweep exists to avoid): $$ is this very shell, unambiguously alive for the
# whole test.
reset_state
mkdir -p "$state/.wake-spool-draining.$$"
printf '1\treport\tt9\tdone: still draining\n' >"$state/.wake-spool-draining.$$/1.$$.000000"
out="$(drain '')"
case "$out" in *"still draining"*) fail "a LIVE drainer's claim dir must never be stolen by another pass" ;; esac
assert_file "$state/.wake-spool-draining.$$/1.$$.000000" "the live claim dir is left completely alone"
rm -rf "$state/.wake-spool-draining.$$"

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

# Brain ride-along: syncs only a home that already runs the engine (never
# mints a db), fleet drain only, and narrates one summary line.
reset_state
rm -f "$TMP/ac-brain.calls" "$state/brain.sqlite"
drain '' >/dev/null
assert_no_file "$TMP/ac-brain.calls" "no brain.sqlite - the drain never mints an engine"
: >"$state/brain.sqlite"
publish fam1 report fam1-t1 'done: x'
chief_live fam1
drain fam1 >/dev/null
assert_no_file "$TMP/ac-brain.calls" "a scoped drain never runs the fleet's brain sync"
out="$(drain '')"
assert_contains "$(cat "$TMP/ac-brain.calls")" "sync" "the fleet drain syncs the brain"
assert_contains "$out" "brain-sync ok - 42 files, 1 changed" "the drain narrates the sync summary"
rm -f "$state/brain.sqlite"

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
# stand_down_beacon writes on every watcher exit - is genuinely uncovered and
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
# pane, whose scope ac-spawn.sh records on disk (bin/ac-spawn.sh:1374).
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

pass
