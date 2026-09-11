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

# --- RC-5 (revised for crewdomain-token): domain rows ARE fleet rows ----------
# The old blind spot - rows moved into a domain ledger that ac-ready.sh never
# read - has no substrate: a domain-assigned row stays in the ONE fleet
# ledger, stamped, so the reminder's ordinary ready probe sees it with zero
# domain-aware code.
#
# BOTH directions are asserted: a reminder that never fires is as broken as one
# that fires wrongly, and only the pair pins the ready probe as the reason.
make_home
: >"$AC_HOME/records/backlog.md"

# Baseline - genuinely parked, so the reminder MUST fire. Without this leg the
# next assertion would pass against a guard that had simply gone silent.
out="$(printf '{}' | "$BIN/ac-turnend-guard.sh")" || fail "the parked reminder must never block"
assert_contains "$out" "/debrief" "an empty fleet with no domain work is still reminded"

# One QUEUED row in a crewdomain backlog, everything else identical -> SILENT.
mkdir -p "$AC_HOME/crewdomains/payments/records"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n- [ ] pay-fix - assigned, not yet promoted; domain:payments (repo: alpha)\n\n## Done\n' \
  >"$AC_HOME/records/backlog.md"
assert_eq "$(printf '{}' | "$BIN/ac-turnend-guard.sh")" "" \
  "RC-5: queued crewdomain work keeps the reminder silent - the chief must not park on top of it"

# A row that is NOT queued does not hold the session open: an in-flight row has
# a live crewmate the in-flight predicate already sees, and a done row is
# history. Only the QUEUED count is the reminder's input.
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n\n- [x] pay-fix - landed (merged 2026-08-02); domain:payments\n' \
  >"$AC_HOME/records/backlog.md"
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

# A SOLO session (AC_SOLO=1) owes no supervision: the chief drains, arms and
# answers hand-backs - blocking a solo turn on the fleet's obligations would
# nag the one session that must not discharge them.
hb_room hbsolo
mkdir -p "$state/.wake-spool"
printf '9\treport\thbs-live\tdone: x\n' >"$state/.wake-spool/1.1.000001"
rc=0; out="$(printf '{}' | AC_SOLO=1 "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
assert_eq "$rc" "0" "a solo session is never blocked on the chief's obligations"
assert_eq "$out" "" "...and silently: the obligations are not its news"
rm -rf "$state/.wake-spool" "$AC_HOME/data/hbsolo"
# Its one turn-end concern is its own slice: uncommitted changes in a self
# task's worktree get a captain-facing NOTICE (systemMessage), never a block;
# a clean worktree stays silent.
solo_repo="$(make_repo solorepo)"
printf 'kind=self\nproject=solorepo\nworktree=%s\n' "$solo_repo" >"$state/sl1.meta"
rc=0; out="$(printf '{}' | AC_SOLO=1 "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
assert_eq "$rc" "0" "a clean solo slice ends its turn freely"
assert_eq "$out" "" "...and silently"
printf 'wip\n' >>"$solo_repo/file.txt"
rc=0; out="$(printf '{}' | AC_SOLO=1 "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
assert_eq "$rc" "0" "a dirty solo slice is a notice, never a block"
assert_contains "$(jq -r '.systemMessage' <<<"$out")" "sl1" "the notice names the dirty slice"
rm -f "$state/sl1.meta"

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

# --- TRACE: state/.stop-hooks.log (stop-hooks-had-zero-effect-and-leave-no-trace) ---
# Every reachable verdict leaves ONE durable, file-only line: A1-A5 and R1-R4
# from the row that added this.

trace_log="$AC_HOME/state/.stop-hooks.log"
last_trace() { tail -n 1 "$trace_log" 2>/dev/null; }
trace_lines() { wc -l <"$trace_log" 2>/dev/null | tr -d ' '; }

make_home
: >"$AC_HOME/records/backlog.md"

# A1 (stand-aside) + R4 ("the stand-aside outcomes... are the most valuable
# lines in the file, not the least"): a clean, otherwise-idle turn end still
# writes a line.
rm -f "$trace_log"
out="$(printf '{}' | "$BIN/ac-turnend-guard.sh")" || fail "the parked reminder must never block"
assert_contains "$out" "/debrief" "sanity: still the parked reminder"
assert_eq "$(trace_lines)" "1" "a clean turn end writes exactly one trace line"
assert_contains "$(last_trace)" "hook=turnend-guard" "the line names the hook"
assert_contains "$(last_trace)" "verdict=stood-aside" "a clean turn end traces stood-aside"
assert_contains "$(last_trace)" "reason=clean" "...with its reason"

# R1: the trace write must never reach stdout - the JSON above must still be
# valid, parseable systemMessage JSON with nothing extra appended to it.
printf '%s' "$out" | jq -e '.systemMessage' >/dev/null \
  || fail "R1: stdout must still be valid JSON after adding the trace"

# A1 (blocked) via queued wakes, DISTINGUISHABLE from the stand-aside above.
rm -f "$trace_log"
mkdir -p "$state/.wake-spool"
printf '9\treport\ttw-live\tdone: x\n' >"$state/.wake-spool/1.1.000000"
rc=0; out="$(printf '{}' | "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
assert_eq "$rc" "2" "sanity: queued wakes still block"
assert_eq "$(trace_lines)" "1" "a queued-wake block writes exactly one trace line"
assert_contains "$(last_trace)" "verdict=blocked" "a queued-wake block traces blocked"
assert_contains "$(last_trace)" "reason=queued-wakes" "...distinguishably from a stand-aside"
assert_contains "$(last_trace)" "queued=yes" "R2: the ALREADY-COMPUTED queued flag rides the line as a boolean"

# R1: stderr on this same block must be UNCHANGED by the trace - the exact
# block-reason text the model reads verbatim.
err="$(printf '{}' | "$BIN/ac-turnend-guard.sh" 2>&1 1>/dev/null)" || true
assert_eq "$err" "agent-crew: queued wakes are pending. Run bin/ac-wake-drain.sh and handle them before ending the turn." \
  "R1: stderr on a block must be exactly the guard's own message, nothing from the trace"
rm -rf "$state/.wake-spool"

# R3: the handback field distinguishes NOT OBSERVED (n/a) from OBSERVED EMPTY
# (none) from OBSERVED NON-EMPTY (the family list) - the exact lesson
# kickoff-ack-verifies-submission-not-arrival landed (6d3a029): "not observed"
# must never look like "observed negative".
rm -f "$trace_log"
hb_room trhbfam
rc=0; out="$(printf '{}' | "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
assert_eq "$rc" "2" "a room in HANDBACK on an otherwise-clean turn end still blocks"
assert_contains "$(last_trace)" "verdict=blocked" "...and traces the block"
assert_contains "$(last_trace)" "reason=handback-pending" "...distinguishably from every other block reason"
assert_contains "$(last_trace)" "handback=trhbfam" "R3: an OBSERVED non-empty handback set names the family"
rm -rf "$AC_HOME/data/trhbfam"

# ...OBSERVED EMPTY (fleet session, no rooms in handback at all) -> "none",
# never blank and never omitted.
rm -f "$trace_log"
out="$(printf '{}' | "$BIN/ac-turnend-guard.sh")" || fail "the parked reminder must never block"
assert_contains "$(last_trace)" "handback=none" "R3: an OBSERVED but empty handback set prints 'none', never blank or omitted"

# ...NOT OBSERVED (the read-only-lock exemption fires before handback is ever
# computed) -> "n/a", never conflated with "none". A live FOREIGN pid holds
# the lock - hold_open/hold_close (helpers.sh) stand in for it with no sleep
# and no polling.
rm -f "$trace_log"
hold_open trlockhold; trlockpid=$HOLD_PID
printf 'pid=%s\nsince=now\n' "$trlockpid" >"$state/.session-lock"
printf '{}' | "$BIN/ac-turnend-guard.sh" >/dev/null 2>&1 || true
hold_close trlockhold "$trlockpid"
assert_contains "$(last_trace)" "verdict=stood-aside" "R4: the read-only-lock exemption is a stand-aside verdict that MUST be traced"
assert_contains "$(last_trace)" "reason=read-only-lock" "...distinguishably"
assert_contains "$(last_trace)" "handback=n/a" "R3: NOT observed on this early-exit path - never 'none'"
assert_contains "$(last_trace)" "queued=n/a" "...and neither is queued, on this same early-exit path"
rm -f "$state/.session-lock"

# --- FIX (review-round-1, finding 1): a SCOPED session's handback field -----
# handback_owed is FLEET session only BY DESIGN (its own opening guard: "[ -z
# "$scope" ] || return 0"), so for a scoped session it returns 0 having
# printed NOTHING - hb_seen becomes set-but-empty for a reason that is NOT
# "observed, nothing owed". That must render n/a, never "none", even while a
# DIFFERENT family genuinely sits in HANDBACK - "none" there is the log
# actively answering the diagnostic question WRONG, the exact incident this
# row exists to kill.
rm -f "$trace_log"
hb_room hbscopedfam
mkdir -p "$state/.wake-spool.famY"
printf '9\treport\thbsy-live\tdone: x\n' >"$state/.wake-spool.famY/1.1.000000"
rc=0; out="$(printf '{}' | AC_SCOPE=famY "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
assert_eq "$rc" "2" "sanity: a scoped session with its own queued wake still blocks"
assert_contains "$(last_trace)" "scope=famY" "the line names the scoped session"
assert_contains "$(last_trace)" "handback=n/a" \
  "FIX: a scoped session's handback is n/a - handback_owed never checked ANY room for it, not even hbscopedfam, which really is in HANDBACK"
case "$(last_trace)" in *"handback=none"*) fail "a scoped session must never report handback=none - that claims a check that never ran" ;; esac
rm -rf "$state/.wake-spool.famY" "$AC_HOME/data/hbscopedfam"

# --- FIX (review-round-1, finding 2): the age field with no beacon ----------
# ac_watcher_beat_read (ac-wake-lib.sh) reports beat=0 for every no-beat state
# ON PURPOSE - the guard's own fire condition needs now-0 to compare against
# AC_GUARD_GRACE (A4: that computation must not change) - but its own header
# warns explicitly against ever PRINTING that figure as an age: "now - 0 is a
# 56-year figure that a chief reads as a live outage". beat_note is non-empty
# in exactly that state; the trace must say n/a, never the raw number.
rm -f "$trace_log" "$state/.last-watcher-beat"
printf 'kind=ship\n' >"$state/tw-nobeacon.meta"
rc=0; out="$(printf '{}' | "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
assert_eq "$rc" "2" "sanity: crew in flight with no beacon still blocks (stale-watcher)"
assert_contains "$(last_trace)" "age=n/a" \
  "FIX: no beacon on record renders an honest n/a, never a bogus multi-decade figure"
case "$(last_trace)" in
  *"age="[0-9][0-9][0-9][0-9][0-9][0-9][0-9]*)
    fail "the trace must never carry a raw now-0 epoch figure: $(last_trace)" ;;
esac
rm -f "$state/tw-nobeacon.meta"

# R4: the structurally-inert exits are NEVER traced.
rm -f "$trace_log"
printf '{"stop_hook_active":true}' | "$BIN/ac-turnend-guard.sh" >/dev/null 2>&1 || true
assert_no_file "$trace_log" "R4: stop_hook_active must never write a trace line"

repo2="$(make_repo trtracerepo)"
wt2="$TMP/trtracewt"
git -C "$repo2" worktree add -q -b trtracewt "$wt2"
mkdir -p "$wt2/state"
printf 'window=crew:tw9\n' >"$wt2/state/tw9.meta"
printf '{}' | AC_HOME="$wt2" "$BIN/ac-turnend-guard.sh" >/dev/null 2>&1 || true
assert_no_file "$wt2/state/.stop-hooks.log" "R4: a linked worktree (crewmate) must never write a trace line"

touch "$AC_HOME/.ac-crewdeputy-home"
rm -f "$trace_log"
printf '{}' | "$BIN/ac-turnend-guard.sh" >/dev/null 2>&1 || true
assert_no_file "$trace_log" "R4: a crewdeputy home must never write a trace line"
rm -f "$AC_HOME/.ac-crewdeputy-home"

# A5: fail-open. A read-only state dir must never change the guard's own
# verdict, message, or exit status - the trace write silently does nothing.
rm -f "$trace_log"
mkdir -p "$state/.wake-spool"
printf '9\treport\ttw-live\tdone: x\n' >"$state/.wake-spool/1.1.000000"
chmod 555 "$state"
rc=0; out="$(printf '{}' | "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
chmod 755 "$state"
assert_eq "$rc" "2" "A5: a read-only state dir must not change the guard's own verdict"
assert_contains "$out" "queued wakes" "...or its message"
rm -rf "$state/.wake-spool"

pass
