#!/usr/bin/env bash
# ac-turnend-guard.test.sh - the "crewmates do not guard" exemption
# (bin/ac-turnend-guard.sh:100-102): when AC_HOME is itself a linked git
# worktree, the Stop hook stays inert even carrying state that would
# otherwise block a turn end. tests/ac-watch.test.sh:39-44 proves the SAME
# fixture (crew meta + no beacon) blocks a plain home in its ~40 invocations
# of this script - none of them ever points AC_HOME at a linked worktree
# (helpers.sh's isolated home is a plain, non-git directory), so this branch
# is otherwise never reached by the suite.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

repo="$(make_repo twguardrepo)"
wt="$TMP/twguardwt"
git -C "$repo" worktree add -q -b twguardwt "$wt"
mkdir -p "$wt/state"
printf 'window=crew:t9\n' >"$wt/state/t9.meta"

rc=0
out="$(printf '{}' | AC_HOME="$wt" "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
assert_eq "$rc" "0" "a linked worktree must stay inert even with crew in flight and no watcher beacon: $out"

# --- RC-5: the PARKED reminder sees crewdomain queued rows -------------------
# The reminder gates on ac-ready.sh, which reads the FLEET backlog only. A fleet
# holding rows ASSIGNED into a crewdomain but not yet promoted therefore read as
# "nothing READY - safe to park", and the guard told the chief to END the
# session on top of queued work. Every other domain-unaware consumer merely
# fails to SHOW something; this one's failure is an ACTION, which is why it is
# fixed rather than named in the residual list.
#
# BOTH directions are asserted: a reminder that never fires is as broken as one
# that fires wrongly, and only the pair pins the tally as the reason.
make_home
: >"$AC_HOME/records/backlog.md"

# Baseline - genuinely parked, so the reminder MUST fire. Without this leg the
# next assertion would pass against a guard that had simply gone silent.
out="$(printf '{}' | "$BIN/ac-turnend-guard.sh")" || fail "the parked reminder must never block"
assert_contains "$out" "/debrief" "an empty fleet with no domain work is still reminded"

# One QUEUED row in a crewdomain backlog, everything else identical -> SILENT.
mkdir -p "$AC_HOME/crewdomains/payments/records"
printf '# Backlog: payments\n\n## In flight\n\n## Queued\n\n- [ ] pay-fix - assigned, not yet promoted; assigned:crewchief (repo: alpha)\n\n## Done\n' \
  >"$AC_HOME/crewdomains/payments/records/backlog.md"
assert_eq "$(printf '{}' | "$BIN/ac-turnend-guard.sh")" "" \
  "RC-5: queued crewdomain work keeps the reminder silent - the chief must not park on top of it"

# A row that is NOT queued does not hold the session open: an in-flight row has
# a live crewmate the in-flight predicate already sees, and a done row is
# history. Only the QUEUED count is the reminder's input.
printf '# Backlog: payments\n\n## In flight\n\n## Queued\n\n## Done\n\n- [x] pay-fix - landed; assigned:crewchief (merged 2026-08-02)\n' \
  >"$AC_HOME/crewdomains/payments/records/backlog.md"
out="$(printf '{}' | "$BIN/ac-turnend-guard.sh")" || fail "the reminder must never block"
assert_contains "$out" "/debrief" "RC-5: a drained crewdomain parks exactly as today"

# --- HANDBACK BACKSTOP: a busy turn end must not mask a pending hand-back ----
# handback-backstop-unreachable: HANDBACK is PERSISTENT while queued wakes, the
# standing-coverage remote-poll gap, and a stale watcher beacon are TRANSIENT -
# so each of those earlier exit-2 sites must carry the HANDBACK line too, or a
# busy fleet (a wake queued at nearly every turn end, or a beacon continuously
# stale) never reaches the otherwise-clean tail and a room can sit in HANDBACK
# indefinitely with nothing objecting. Not theoretical: a real family posted
# HANDBACK with both its PRs merged and sat unclaimed while the chief kept
# receiving queued-wakes/arm-the-watcher lines - the captain caught it, not
# the guard. One deterministic scenario per earlier block covered.
make_home
state="$AC_HOME/state"

hb_room() {
  # hb_room <family> - a room whose last entry is an unresolved HANDBACK:.
  local f="$AC_HOME/data/$1/room.md"
  mkdir -p "$(dirname "$f")"
  printf '# Room: %s\n\n- [%s] %s-chief> HANDBACK: landed, please demote and close\n' \
    "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >"$f"
}

# (1) queued wake + HANDBACK, at once.
hb_room hbqfam
mkdir -p "$state/.wake-spool"
printf '9\treport\thb-live\tdone: x\n' >"$state/.wake-spool/1.1.000000"
rc=0; out="$(printf '{}' | "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
assert_eq "$rc" "2" "a queued wake still blocks the turn end"
assert_contains "$out" "queued wakes" "the queued-wake reason still fires"
assert_contains "$out" "hbqfam" "the HANDBACK line rides alongside a queued wake instead of queueing behind it"
rm -rf "$state/.wake-spool" "$AC_HOME/data/hbqfam"

# (2) stale watcher beacon with crew in flight + HANDBACK, at once.
hb_room hbwfam
printf 'kind=ship\n' >"$state/hbw-live.meta"
rm -f "$state/.last-watcher-beat"
rc=0; out="$(printf '{}' | "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
assert_eq "$rc" "2" "a stale watcher beacon with crew in flight still blocks"
assert_contains "$out" "Arm bin/ac-watch.sh" "the stale-watcher reason still fires"
assert_contains "$out" "hbwfam" "the HANDBACK line rides alongside the stale-watcher block too"
rm -f "$state/hbw-live.meta"; rm -rf "$AC_HOME/data/hbwfam"

# (3) standing-coverage (idle fleet, remote-poll wired, no beacon) + HANDBACK.
hb_room hbsfam
hook="$AC_HOME/config/remote-poll"
printf '#!/bin/sh\nexit 0\n' >"$hook"
chmod +x "$hook"
printf 'pid=%s\nsince=now\n' "$$" >"$state/.session-lock"
rc=0; out="$(printf '{}' | "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
assert_eq "$rc" "2" "standing coverage still blocks the idle lock-holder"
assert_contains "$out" "nothing is polling" "the standing-coverage reason still fires"
assert_contains "$out" "hbsfam" "the HANDBACK line rides alongside standing-coverage too"
rm -f "$hook" "$state/.session-lock"; rm -rf "$AC_HOME/data/hbsfam"

pass
