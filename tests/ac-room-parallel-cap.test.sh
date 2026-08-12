#!/usr/bin/env bash
# ac-room-parallel-cap.test.sh - the roomchief cap: ac-spawn.sh --roomchief
# refuses past config/room-parallel (default 5), counting live <fam>-chief
# metas with kind=roomchief; plus the landing advisory ac-teardown.sh prints
# when demoting a chief frees a slot.
#
# The cap refusal fires before any window or lease work, so nothing here needs
# a live backend (unlike ac-roomchief.test.sh, which drives the spawn itself
# end to end). Its own file because ac-spawn.sh's tests are already split by
# concern (teardown, model/effort).
#
# The fake herdr CLI is armed anyway, because "needs no backend" is not
# "touches no backend": the teardowns below run backend_kill_window over their
# metas, and exactly when the cap REGRESSES the promote runs on into
# backend_window_new - with a real herdr on PATH that would open a live
# harness window on the OPERATOR's server. The fake (tests/helpers.sh) keeps
# every such call file-backed.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_home

chief() { printf 'kind=roomchief\nbackend=herdr\n' >"$AC_HOME/state/$1-chief.meta"; }

room_seed() {
  # room_seed <family> - the ORDER GATE precondition every real promote meets:
  # `--roomchief` takes no brief - the room IS the brief - so ac-spawn refuses a
  # promote into a room holding no entry (tests/ac-roomchief.test.sh owns that
  # gate's own cases). Production posts the order before promoting; these
  # fixtures do the same rather than being exempted from the gate. Promotes that
  # must be refused BEFORE the gate - by a flag rule or by the cap itself - need
  # no seed, and deliberately keep none: their refusal must stay theirs.
  "$BIN/ac-room.sh" post "$1" crewchief "the order for $1, posted before the promote" >/dev/null
}

# -- default cap 5: the sixth promote refuses, naming the flying families -------
for f in fam1 fam2 fam3 fam4 fam5; do chief "$f"; done
out="$("$BIN/ac-spawn.sh" --roomchief fam6 2>&1)" && fail "the sixth promote must refuse"
assert_contains "$out" "room-parallel cap reached: 5/5" "the refusal states the count"
assert_contains "$out" "fam3" "the refusal names the flying families"

# -- under the cap the promote is NOT refused ----------------------------------
# It still dies (no launch template for 'nope'), which is exactly the proof it
# got past the cap check and on to the launch work.
rm -f "$AC_HOME/state/fam5-chief.meta"
room_seed fam6
out="$("$BIN/ac-spawn.sh" --roomchief fam6 --harness nope 2>&1)" || true
case "$out" in *"cap reached"*) fail "4 chiefs are under the cap of 5" ;; esac

# -- only roomchiefs count: a crewdeputy never holds a room slot ----------------
printf 'kind=crewdeputy\nbackend=herdr\n' >"$AC_HOME/state/dep-chief.meta"
out="$("$BIN/ac-spawn.sh" --roomchief fam6 --harness nope 2>&1)" || true
case "$out" in *"cap reached"*) fail "kind=crewdeputy must not count against the room cap" ;; esac
rm -f "$AC_HOME/state/dep-chief.meta"
chief fam5

# -- config/room-parallel overrides the default --------------------------------
printf '2\n' >"$AC_HOME/config/room-parallel"
out="$("$BIN/ac-spawn.sh" --roomchief fam6 2>&1)" && fail "cap 2 must refuse with 5 flying"
assert_contains "$out" "room-parallel cap reached: 5/2" "the knob sets the cap"

# -- a garbage knob clamps to the default; it never refuses on its own ----------
printf 'lots\n' >"$AC_HOME/config/room-parallel"
out="$("$BIN/ac-spawn.sh" --roomchief fam6 2>&1)" && fail "the clamped cap 5 must refuse with 5 flying"
assert_contains "$out" "room-parallel cap reached: 5/5" "a non-numeric knob clamps to the default"
rm -f "$AC_HOME/config/room-parallel"

# -- landing advisory: a demoted chief frees a slot, so teardown surfaces the
#    next queued family - advisory only, it never spawns anything.
cat >"$AC_HOME/records/backlog.md" <<'EOF'
# Backlog

## In flight
- [ ] fam1 - promoted work (repo: proj, since 2026-07-16)

## Queued
- [ ] waiting - blocked work (repo: proj) blocked-by: fam1 - needs fam1 first
- [ ] nextup - ordinary queued work (repo: proj)
EOF
# A pane handle so teardown's kill path can resolve the tab (the fake herdr
# no-ops the close; the ac-promote.test.sh idiom).
printf 'p10 t10\n' >"$AC_HOME/state/.pane-fam1-chief"
out="$("$BIN/ac-teardown.sh" fam1-chief 2>&1)"
assert_contains "$out" "teardown fam1-chief complete" "the teardown still reports its own outcome"
assert_contains "$out" "next queued family: nextup" "a freed chief slot surfaces the next queued family"
case "$out" in *waiting*) fail "a family whose blocker is still in flight is not the next one" ;; esac
assert_no_file "$AC_HOME/state/nextup-chief.meta" "the advisory never spawns - the crewchief stays the scheduler"

# -- the advisory is scoped to chiefs: no other teardown frees a room slot ------
repo="$(make_repo proj)"
printf 'kind=ship\nbackend=herdr\nworktree=%s\nproject_dir=%s\n' "$repo" "$repo" >"$AC_HOME/state/plain.meta"
printf 'p11 t11\n' >"$AC_HOME/state/.pane-plain"
out="$("$BIN/ac-teardown.sh" plain 2>&1)"
case "$out" in *"chief slot is free"*) fail "tearing down a crewmate frees no chief slot" ;; esac

# ==== origin field + cap-gate flags (--captain-initiated / --over-cap) =========
# The cap counts only chief-initiated (non-exempt) chiefs; --captain-initiated
# is exempt and never counts; --over-cap sanctions ONE extra chief past the cap
# without ever writing config. Success cases run the spawn to completion, so
# they need the fake launch template + immediate kickoff (the ac-roomchief.test.sh
# idiom); the fake herdr is already armed above.
export AC_SPAWN_SETTLE=0
# Every pane here clears the composer-ready observation (bin/ac-spawn.sh
# kickoff_wait_input_ready) immediately - this suite is not testing that gate
# (tests/ac-spawn-kickoff-ready.test.sh owns it), it just needs the spawns
# below to complete without a real harness's boot delay.
: >"$FAKE_HERDR/.pane-idle-by-default"
export AC_KICKOFF_READY_BUDGET=5
printf 'echo roomchief __ID__\n' >"$AC_HOME/config/launch-fake"
# A chief() variant that stamps initiated_by= - the cheapest way to seed an
# exempt (captain) vs counted (chief) chief. The plain chief() above stamps NO
# initiated_by, and its metas still COUNT (the fail-closed default proved by the
# top-of-file assertions).
chief_ib() { printf 'kind=roomchief\nbackend=herdr\ninitiated_by=%s\n' "$2" >"$AC_HOME/state/$1-chief.meta"; }

rm -f "$AC_HOME/state"/*-chief.meta            # known-empty chief population
printf '1\n' >"$AC_HOME/config/room-parallel"  # a single slot makes the gate crisp

# 1. chief-initiated at cap, no flag -> refuse (fail-closed, normal message).
chief c-a
out="$("$BIN/ac-spawn.sh" --roomchief c-b --harness fake 2>&1)" && fail "a plain chief-initiated promote at cap must refuse"
assert_contains "$out" "room-parallel cap reached: 1/1" "the refusal states the count"

# 2. --over-cap "" (empty) at cap -> dies with the rule-only sanction message.
out="$("$BIN/ac-spawn.sh" --roomchief c-b --harness fake --over-cap "" 2>&1)" && fail "an empty over-cap sanction at cap must die"
assert_contains "$out" "sanction" "empty over-cap dies naming the required captain sanction"
case "$out" in *"cap reached"*) fail "the empty-sanction death is the rule message, not the plain refuse" ;; esac

# 3. --over-cap "<reason>" at cap -> promotes; room gains the sanction receipt;
#    config/room-parallel is BYTE-IDENTICAL across the spawn.
room_seed c-b
cp "$AC_HOME/config/room-parallel" "$TMP/rp.before"
out="$("$BIN/ac-spawn.sh" --roomchief c-b --harness fake --over-cap "captain TN said go" 2>&1)" || fail "a sanctioned over-cap promote must succeed: $out"
assert_contains "$out" "spawned c-b-chief" "the over-cap promote spawns"
room="$(cat "$AC_HOME/data/c-b/room.md")"
assert_contains "$room" "DECIDED:" "over-cap posts a DECIDED receipt"
assert_contains "$room" "+1 past room-parallel=1" "the receipt states it is one past the cap"
assert_contains "$room" "captain TN said go" "the receipt carries the captain sanction"
cmp -s "$TMP/rp.before" "$AC_HOME/config/room-parallel" || fail "config/room-parallel must be byte-identical across an over-cap promote"

# 4. --captain-initiated "<ref>" at cap -> promotes with NO reason; meta has
#    initiated_by=captain; room gains the captain-initiated receipt.
rm -f "$AC_HOME/state"/*-chief.meta
chief c-a                                        # the counted slot is full again
room_seed c-c
out="$("$BIN/ac-spawn.sh" --roomchief c-c --harness fake --captain-initiated "order 2026-07-19" 2>&1)" || fail "a captain-initiated promote must succeed even at cap: $out"
assert_contains "$out" "spawned c-c-chief" "the captain-initiated promote spawns at cap"
assert_eq "$(awk -F= '$1=="initiated_by"{print $2}' "$AC_HOME/state/c-c-chief.meta")" "captain" "the meta records initiated_by=captain"
room="$(cat "$AC_HOME/data/c-c/room.md")"
assert_contains "$room" "DECIDED:" "captain-initiated posts a DECIDED receipt"
assert_contains "$room" "order 2026-07-19" "the receipt carries the order ref"
assert_contains "$room" "does NOT count" "the receipt states it does not count toward the cap"

# 5. the cap counts only non-exempt chiefs.
#    (a) the single slot holds only an exempt captain-initiated chief -> a
#        chief-initiated promote still fits.
rm -f "$AC_HOME/state"/*-chief.meta
chief_ib c-x captain
room_seed c-d
out="$("$BIN/ac-spawn.sh" --roomchief c-d --harness fake 2>&1)" || fail "an exempt chief must not consume the slot: $out"
assert_contains "$out" "spawned c-d-chief" "a chief-initiated promote fits past an exempt chief"
#    (b) the single slot holds a counted chief-initiated chief -> the next
#        chief-initiated promote refuses.
rm -f "$AC_HOME/state"/*-chief.meta
chief_ib c-x chief
out="$("$BIN/ac-spawn.sh" --roomchief c-e --harness fake 2>&1)" && fail "a counted chief fills the slot: the next must refuse"
assert_contains "$out" "room-parallel cap reached: 1/1" "a counted chief fills the cap"

# 6. --captain-initiated + --over-cap together -> dies (mutually exclusive).
rm -f "$AC_HOME/state"/*-chief.meta
out="$("$BIN/ac-spawn.sh" --roomchief c-f --harness fake --captain-initiated "ref" --over-cap "reason" 2>&1)" && fail "the two cap-gate flags are mutually exclusive"
assert_contains "$out" "mutually exclusive" "both flags die with the mutual-exclusion rule"

# ==== initiated_by=system: the STANDING-ORDER exempt class =====================
# The third origin - a promote the fleet made on a standing captain rule, with
# no human deciding it now. Exempt exactly like captain, but the meta and the
# receipt say WHICH justification the room rode, which is the whole reason it is
# a third value rather than a borrow of =captain.

# 7. --system-initiated "<ref>" at a full cap promotes; the meta records
#    initiated_by=system; the receipt names the STANDING order.
rm -f "$AC_HOME/state"/*-chief.meta
chief c-a                                        # the counted slot is full again
room_seed c-g
out="$("$BIN/ac-spawn.sh" --roomchief c-g --harness fake --system-initiated "records/captain.md standing rule 2026-07-21" 2>&1)" || fail "a system-initiated promote must succeed even at cap: $out"
assert_contains "$out" "spawned c-g-chief" "the system-initiated promote spawns at cap"
assert_eq "$(awk -F= '$1=="initiated_by"{print $2}' "$AC_HOME/state/c-g-chief.meta")" "system" "the meta records initiated_by=system"
room="$(cat "$AC_HOME/data/c-g/room.md")"
assert_contains "$room" "DECIDED:" "system-initiated posts a DECIDED receipt"
assert_contains "$room" "standing order: records/captain.md standing rule 2026-07-21" "the receipt names the standing order it carries out"
assert_contains "$room" "does NOT count" "the receipt states it does not count toward the cap"

# 8. an empty ref dies naming the requirement (the --captain-initiated idiom).
out="$("$BIN/ac-spawn.sh" --roomchief c-h --harness fake --system-initiated "" 2>&1)" && fail "an empty system-initiated ref must die"
assert_contains "$out" "non-empty order ref" "empty --system-initiated dies naming the requirement"

# 9. the cap counts only non-exempt chiefs, and the exempt token match is EXACT.
#    (a) a system chief does not consume the single slot.
rm -f "$AC_HOME/state"/*-chief.meta
chief_ib c-x system
room_seed c-i
out="$("$BIN/ac-spawn.sh" --roomchief c-i --harness fake 2>&1)" || fail "an initiated_by=system chief must not consume the slot: $out"
assert_contains "$out" "spawned c-i-chief" "a chief-initiated promote fits past a system chief"
#    (b) a NEAR-MISS is not the token: it still COUNTS. A near-miss that opened
#        a slot is exactly the failure the exactness exists to prevent.
for near in systemic System " system"; do
  rm -f "$AC_HOME/state"/*-chief.meta
  chief_ib c-x "$near"
  out="$("$BIN/ac-spawn.sh" --roomchief c-j --harness fake 2>&1)" && fail "initiated_by='$near' is not the exempt token: it must still count"
  assert_contains "$out" "room-parallel cap reached: 1/1" "initiated_by='$near' still counts toward the cap"
done

# 10. the exclusion is three-way: --system-initiated pairs with neither sibling.
rm -f "$AC_HOME/state"/*-chief.meta
out="$("$BIN/ac-spawn.sh" --roomchief c-k --harness fake --system-initiated "ref" --captain-initiated "ref" 2>&1)" && fail "--system-initiated and --captain-initiated are mutually exclusive"
assert_contains "$out" "mutually exclusive" "system+captain die with the mutual-exclusion rule"
out="$("$BIN/ac-spawn.sh" --roomchief c-k --harness fake --system-initiated "ref" --over-cap "reason" 2>&1)" && fail "--system-initiated and --over-cap are mutually exclusive"
assert_contains "$out" "mutually exclusive" "system+over-cap die with the mutual-exclusion rule"

# 11. roomchief-only, like its siblings: a crew spawn passing it is a mistake.
out="$("$BIN/ac-spawn.sh" someid someproj --system-initiated "ref" 2>&1)" && fail "--system-initiated requires --roomchief"
assert_contains "$out" "require --roomchief" "the flag is refused without --roomchief"

# 12. the POST-META tail is BOOKKEEPING, not the promote. Once the meta is
#     written the chief is addressable and teardown owns it, so a failing
#     status / PROMOTED: / DECIDED: write WARNS by name and the spawn still
#     exits 0. That is what fixes the meaning of the exit status for an
#     AUTOMATIC caller: ac-learn.sh autoroom retries on non-zero and says so out
#     loud, and a tail failure reported as a failed promote would strand a real
#     room behind a "the next checkpoint retries" message that never comes true.
#     The broken write is the STATUS append, not the room: the ORDER GATE now
#     refuses a promote whose room holds no readable entry, so a room.md that is
#     a DIRECTORY - the state this case used to stage - can no longer BE a
#     promote-time state, and staging it would prove the gate rather than the
#     tail. A .status path that is a DIRECTORY breaks its append the same way,
#     deterministically for ANY uid (a chmod would not, since the suite may run
#     as root), and is the FIRST item in the same tail.
rm -f "$AC_HOME/state"/*-chief.meta
room_seed c-l
mkdir -p "$AC_HOME/state/c-l-chief.status"
set +e
out="$("$BIN/ac-spawn.sh" --roomchief c-l --harness fake --system-initiated "standing ref" 2>&1)"
rc=$?
set -e
assert_eq "$rc" "0" "a post-meta bookkeeping failure never fails the promote"
assert_file "$AC_HOME/state/c-l-chief.meta" "the meta is present: the promote HAPPENED and is not retryable"
assert_contains "$out" "spawned c-l-chief" "the spawn still reports its own outcome"
assert_contains "$out" "status line could not be appended" "the lost bookkeeping write is named in the warning, never silently dropped"

# 13. the FINAL outcome print is part of that bookkeeping tail too. A CLOSED
#     stdout makes it fail LAST - after the meta is durable - so an unguarded
#     print would return non-zero WITH the chief present, and the automatic
#     caller would again promise a retry the meta suppresses. Closing stdout
#     (>&-) is the reviewer's own probe.
rm -f "$AC_HOME/state"/*-chief.meta
rm -rf "$AC_HOME/data/c-m"
room_seed c-m
set +e
"$BIN/ac-spawn.sh" --roomchief c-m --harness fake --system-initiated "standing ref" >&- 2>"$TMP/cm.err"
rc=$?
set -e
assert_eq "$rc" "0" "a closed stdout on the final outcome print never fails an already-durable promote"
assert_file "$AC_HOME/state/c-m-chief.meta" "the meta is durable even though the final print could not be written"
assert_contains "$(cat "$TMP/cm.err")" "outcome line could not be printed" "the lost outcome line is warned on stderr, not swallowed as a failure"

#     BOTH channels gone (>&- 2>&-) is the harder leg: the warning has nowhere to
#     go either, so ac_warn ALSO fails - and only the trailing `|| true` keeps
#     that from tripping set -e after the meta is durable. No channel is left to
#     assert on, so the proof is that it still exits 0 with the meta present.
rm -f "$AC_HOME/state"/*-chief.meta
rm -rf "$AC_HOME/data/c-n"
room_seed c-n
set +e
"$BIN/ac-spawn.sh" --roomchief c-n --harness fake --system-initiated "standing ref" >&- 2>&-
rc=$?
set -e
assert_eq "$rc" "0" "both stdout AND stderr closed: an already-durable promote still exits 0 (the tail is truly total)"
assert_file "$AC_HOME/state/c-n-chief.meta" "both channels closed: the meta is durable and no failure is reported"

# 13b. F22 (repo-deep-review): the cap must count an IN-FLIGHT promote that
#      has claimed its id (state/.meta-claims/<fam>-chief/) but has not yet
#      written its meta - the gap a slow deliver_kickoff (AC_SPAWN_SETTLE)
#      opens between two concurrent promotes. Deterministically simulated by
#      seeding the claim directly rather than racing it.
rm -f "$AC_HOME/state"/*-chief.meta
printf '1\n' >"$AC_HOME/config/room-parallel"
mkdir -p "$AC_HOME/state/.meta-claims/claiming-chief"
printf '%s\n' "$$" >"$AC_HOME/state/.meta-claims/claiming-chief/pid"
out="$("$BIN/ac-spawn.sh" --roomchief c-o --harness fake 2>&1)" && fail "an in-flight (claimed, not-yet-metaed) promote must count toward the cap"
assert_contains "$out" "room-parallel cap reached: 1/1" "the in-flight claim is counted"
assert_contains "$out" "claiming" "the refusal names the in-flight family"
rm -rf "$AC_HOME/state/.meta-claims/claiming-chief"

# ... but a STALE claim (dead owner, past the grace window) must NOT count -
# it is an abandoned pre-meta window, not a live promote.
mkdir -p "$AC_HOME/state/.meta-claims/stale-chief"
sh -c 'exit 0' & DEADCLAIM=$!; wait "$DEADCLAIM" 2>/dev/null || true
printf '%s\n' "$DEADCLAIM" >"$AC_HOME/state/.meta-claims/stale-chief/pid"
touch -t 202601010000 "$AC_HOME/state/.meta-claims/stale-chief"
room_seed c-p
out="$("$BIN/ac-spawn.sh" --roomchief c-p --harness fake 2>&1)" || fail "a stale claim must not block the promote: $out"
assert_contains "$out" "spawned c-p-chief" "a dead-owner claim past the grace window is not counted"
rm -rf "$AC_HOME/state/.meta-claims/stale-chief" "$AC_HOME/state"/*-chief.meta
rm -f "$AC_HOME/config/room-parallel"

# 14. AC-13: the header is the AUTHORITATIVE contract for the cap and its exempt
#     classes - a behaviour change that leaves it stale is incomplete.
hdr="$(sed -n '1,140p' "$BIN/ac-spawn.sh")"
assert_contains "$hdr" "--system-initiated" "the header documents the new flag"
assert_contains "$hdr" "initiated_by=system" "the header documents the new origin value"
assert_contains "$hdr" "post-meta bookkeeping tail" "the header documents what a --roomchief exit status means"
assert_contains "$hdr" "THE ORDER GATE" "the header documents the empty-room refusal"

pass
