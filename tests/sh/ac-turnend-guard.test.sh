#!/usr/bin/env bash
# ac-turnend-guard.test.sh - the "crewmates do not guard" exemption
# (bin/ac-turnend-guard.sh's linked-worktree exit): when AC_HOME is itself a linked git
# worktree, the Stop hook stays inert even carrying state that would
# otherwise block a turn end. tests/sh/ac-watch.test.sh's stale-beacon leg proves the SAME
# fixture (crew meta + no beacon) blocks a plain home in its ~40 invocations
# of this script - none of them ever points AC_HOME at a linked worktree
# (helpers.sh's isolated home is a plain, non-git directory), so this branch
# is otherwise never reached by the suite.

. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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

# A crewdeputy is a chief running its own home: its crew is its own to cover,
# so its session's guard judges that home like any fleet home - crew in flight
# with no beacon blocks, and the verdict is traced.
touch "$AC_HOME/.ac-crewdeputy-home"
rm -f "$trace_log" "$state/.last-watcher-beat"
printf 'kind=ship\n' >"$state/dep-crew.meta"
rc=0; out="$(printf '{}' | "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
assert_eq "$rc" "2" "a crewdeputy home with crew in flight and no beacon blocks its own session's turn end: $out"
assert_file "$trace_log" "...and the verdict is traced"
rm -f "$state/dep-crew.meta" "$AC_HOME/.ac-crewdeputy-home"

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

# --- a live ROOMCHIEF owes the crewchief's fleet coverage --------------------
# The fleet watcher keeps every <family>-chief pane (ac-watch.sh scoping: its
# hand-back must wake the crewchief), so a fleet whose only live meta is a
# roomchief is NOT parked: with no beacon the turn end must block, never tell
# the chief to end the session. The roomchief's own scoped watcher never
# covers its own pane, so its own session owes nothing for it.
rh="$TMP/rc-home"; mkdir -p "$rh/state" "$rh/records" "$rh/config"; : >"$rh/records/backlog.md"
printf 'kind=roomchief\nwindow=crew:famR-chief\n' >"$rh/state/famR-chief.meta"
rc=0; out="$(printf '{}' | AC_HOME="$rh" "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
assert_eq "$rc" "2" "a live roomchief with no fleet watcher blocks the crewchief's turn end: $out"
case "$out" in *PARKED*|*debrief*) fail "a live roomchief is not a parked fleet: $out" ;; esac
rc=0; out="$(printf '{}' | AC_HOME="$rh" AC_SCOPE=famR "$BIN/ac-turnend-guard.sh" 2>&1)" || rc=$?
assert_eq "$rc" "0" "the roomchief's own scoped session owes no coverage for its own pane: $out"

# --- the verdicts, row by row -------------------------------------------------
# Each run works on a fresh copy ($h.n) of the row's home; the environment is
# AC_SCOPE, AC_SOLO, AC_GUARD_GRACE and AC_STOPHOOK_LOG_KEEP as the row gives
# them, a PATH `date` frozen at one instant (epoch 1800000000) ahead of the
# helpers' refusing herdr/orca, LC_ALL=C; the test shell is the lock holder's
# ancestor.
mkdir -p "$TMP/te-date"
cat >"$TMP/te-date/date" <<'EOD'
#!/bin/sh
case "$*" in *%s*) echo 1800000000 ;; *) echo 2027-01-15T08:00:00Z ;; esac
EOD
chmod +x "$TMP/te-date/date"
te_world() {  # te_world <name> - a fresh fleet home, printed
  local h="$TMP/te/$1"
  rm -rf "$h"
  mkdir -p "$h/state" "$h/records" "$h/data" "$h/config"
  : >"$h/records/backlog.md"
  printf '%s\n' "$h"
}
te_verdict() {  # te_verdict <0|2> <home> <payload> [VAR=VAL ...] - one run on <home>.n; sets te_out, te_err
  local want="$1" h="$2" pl="$3" rc=0
  shift 3
  rm -rf "$h.n"
  cp -R "$h" "$h.n"
  (printf '%s' "$pl" | env -u AC_SOLO -u AC_SCOPE AC_HOME="$h.n" "$@" PATH="$TMP/te-date:$PATH" LC_ALL="${TE_LC:-C}" "$BIN/ac-turnend-guard.sh") >"$TMP/n.out" 2>"$TMP/n.err" || rc=$?
  assert_eq "$rc" "$want" "turn-end verdict ($pl $*) in $h"
  te_out="$(cat "$TMP/n.out")"; te_err="$(cat "$TMP/n.err")"
}
te_trace() { cat "$1.n/state/.stop-hooks.log"; }
te_room() {  # te_room <home> <family> <entry...> - a room holding these entries
  local h="$1" fam="$2" e
  shift 2
  mkdir -p "$h/data/$fam"
  printf '# Room: %s\n\n' "$fam" >"$h/data/$fam/room.md"
  for e in "$@"; do printf -- '- [2027-01-15T07:00:00Z] %s\n' "$e" >>"$h/data/$fam/room.md"; done
}
TE_TS="2027-01-15T08:00:00Z hook=turnend-guard"
TE_QUEUED="agent-crew: queued wakes are pending. Run bin/ac-wake-drain.sh and handle them before ending the turn."
TE_ARM="Arm bin/ac-watch.sh as a background task before ending the turn."
te_handback() { printf 'agent-crew: room(s) in HANDBACK - a roomchief reported back and is still waiting: %s. Demote it' "$1"; }

# 1. idle and parked; the stop_hook_active text; a payload of nothing; a
#    scoped session and a fleet with a READY item are never reminded.
h="$(te_world idle)"
te_verdict 0 "$h" '{}'
assert_contains "$te_out" "PARKED" "1: an idle fleet is reminded"
assert_eq "$te_err" "" "1: ...with nothing on stderr"
assert_eq "$(te_trace "$h")" "$TE_TS verdict=stood-aside reason=clean scope=fleet queued=no inflight=0 age=n/a handback=none" "1: the clean trace line"
te_verdict 0 "$h" ''
assert_contains "$te_out" "PARKED" "1: an empty payload is judged like any"
te_verdict 0 "$h" '{"stop_hook_active":true}'
assert_eq "$te_out$te_err" "" "1: stop_hook_active stands down silent"
assert_no_file "$h.n/state/.stop-hooks.log" "1: ...and untraced"
te_verdict 0 "$h" '{}' AC_SCOPE=famQ
assert_eq "$te_out" "" "1: a scoped session is never reminded"
assert_eq "$(te_trace "$h")" "$TE_TS verdict=stood-aside reason=clean scope=famQ queued=no inflight=0 age=n/a handback=n/a" "1: the scoped trace line"
printf -- '## Queued\n- [ ] t1 - queued work (repo: x)\n' >"$h/records/backlog.md"
te_verdict 0 "$h" '{}'
assert_eq "$te_out" "" "1: a READY item keeps the reminder silent"

# 2. queued wakes: the fleet spool, a family spool for its scope, an orphan family.
h="$(te_world queued)"
mkdir -p "$h/state/.wake-spool"
printf '9\treport\tq1\tdone: x\n' >"$h/state/.wake-spool/1.1.000000"
te_verdict 2 "$h" '{}'
assert_eq "$te_err" "$TE_QUEUED" "2: the fleet spool holds the fleet's turn"
assert_eq "$(te_trace "$h")" "$TE_TS verdict=blocked reason=queued-wakes scope=fleet queued=yes inflight=0 age=n/a handback=none" "2: the blocked trace line"
te_verdict 0 "$h" '{}' AC_SCOPE=famQ
rm -rf "$h/state/.wake-spool"
mkdir -p "$h/state/.wake-spool.famQ"
printf '9\treport\tq2\tdone: x\n' >"$h/state/.wake-spool.famQ/1.1.000000"
te_verdict 2 "$h" '{}' AC_SCOPE=famQ
assert_eq "$te_err" "$TE_QUEUED" "2: a family spool holds its own scope"
te_verdict 2 "$h" '{}'
assert_eq "$te_err" "$TE_QUEUED" "2: an orphan family spool holds the fleet"
te_verdict 0 "$h" '{}' AC_SCOPE=famZ

# 3. the tally and the beacon: crew with no beacon, a fresh, stale, stood-down,
# unreadable and zero-padded beacon, the grace knob, the kinds that never count.
h="$(te_world beacon)"
printf 'kind=ship\n' >"$h/state/c1.meta"
te_verdict 2 "$h" '{}'
assert_eq "$te_err" "agent-crew: 1 crewmate(s) in flight but no beat on record (no beacon - nothing has armed a watcher here). $TE_ARM" "3: crew with no beacon"
printf '1800000000\n' >"$h/state/.last-watcher-beat"
te_verdict 0 "$h" '{}'
assert_eq "$(te_trace "$h")" "$TE_TS verdict=stood-aside reason=clean scope=fleet queued=no inflight=1 age=0s handback=none" "3: a fresh beacon covers the crew"
printf '1799999000\n' >"$h/state/.last-watcher-beat"
te_verdict 2 "$h" '{}'
assert_eq "$te_err" "agent-crew: 1 crewmate(s) in flight but the watcher beacon is stale (1000s). $TE_ARM" "3: a stale beacon"
printf '0\n' >"$h/state/.last-watcher-beat"
te_verdict 2 "$h" '{}'
assert_contains "$te_err" "no beat on record (a watcher stood its beacon down on exit - drain and re-arm)" "3: a stood-down beacon"
for beat in abc 01799999990 ''; do
  printf '%s\n' "$beat" >"$h/state/.last-watcher-beat"
  te_verdict 2 "$h" '{}'
  assert_contains "$te_err" "no beat on record (the beacon is unreadable)" "3: beacon '$beat' is unreadable"
done
printf '1799999000\n' >"$h/state/.last-watcher-beat"
te_verdict 0 "$h" '{}' AC_GUARD_GRACE=5000
te_verdict 2 "$h" '{}' AC_GUARD_GRACE=10
te_verdict 2 "$h" '{}' AC_GUARD_GRACE=
rm -f "$h/state/c1.meta" "$h/state/.last-watcher-beat"
for kind in self crewdeputy verify-codereview; do
  printf 'kind=%s\n' "$kind" >"$h/state/k1.meta"
  te_verdict 0 "$h" '{}'
done
printf 'kind=roomchief\n' >"$h/state/famR-chief.meta"
te_verdict 2 "$h" '{}'
assert_contains "$te_err" "1 crewmate(s) in flight" "3: a roomchief counts for the fleet session"
te_verdict 0 "$h" '{}' AC_SCOPE=famR
rm -f "$h/state/famR-chief.meta" "$h/state/k1.meta"
printf 'window=crew:x\n' >"$h/state/nokind.meta"
te_verdict 2 "$h" '{}'
assert_contains "$te_err" "1 crewmate(s) in flight" "3: a meta with no kind counts"

# 4. HANDBACK: alone, alongside a queued wake and a stale beacon, cleared by
# each retiring entry, two families in byte order.
h="$(te_world handback)"
te_room "$h" famB 'famB-chief> HANDBACK: landed, please demote'
te_room "$h" famA 'famA-chief> HANDBACK: landed' 'crewchief> HANDBACK-REFUSED: remedy first' 'famA-chief> HANDBACK: again'
te_verdict 2 "$h" '{}'
assert_contains "$te_err" "$(te_handback 'famA famB')" "4: both families, in byte order"
assert_eq "$(te_trace "$h")" "$TE_TS verdict=blocked reason=handback-pending scope=fleet queued=no inflight=0 age=n/a handback=famA famB" "4: the handback trace line"
mkdir -p "$h/state/.wake-spool"
printf '9\treport\thb\tdone: x\n' >"$h/state/.wake-spool/1.1.000000"
te_verdict 2 "$h" '{}'
assert_contains "$te_err" "$TE_QUEUED
$(te_handback 'famA famB')" "4: HANDBACK rides a queued-wake block"
rm -rf "$h/state/.wake-spool"
printf 'kind=ship\n' >"$h/state/c1.meta"
te_verdict 2 "$h" '{}'
assert_contains "$te_err" "$TE_ARM
$(te_handback 'famA famB')" "4: HANDBACK rides a stale-watcher block"
rm -f "$h/state/c1.meta"
te_verdict 0 "$h" '{}' AC_SCOPE=famA
for retire in 'crewchief> HANDBACK-REFUSED: no' 'crewchief> DEMOTED: famB-chief' 'crewchief> CLOSED: done'; do
  te_room "$h" famB 'famB-chief> HANDBACK: landed' "$retire"
  te_verdict 2 "$h" '{}'
  assert_contains "$te_err" "$(te_handback famA)" "4: '$retire' retires famB's hand-back, famA still waits"
done
te_room "$h" famC 'crewchief> GATE: pick one' 'famC-chief> HANDBACK: x' 'crewchief> DEMOTED: famC-chief'
rm -rf "$h/data/famA" "$h/data/famB"
te_verdict 0 "$h" '{}'
assert_eq "$te_out" "" "4: a pending gate keeps the PARKED reminder silent"
te_room "$h" famC 'crewchief> GATE: pick one' 'crewchief> DECIDED: a'
te_verdict 0 "$h" '{}'
assert_contains "$te_out" "PARKED" "4: a decided gate leaves the inbox at 0"

# 5. standing coverage: the lock held by the test shell (an ancestor of the
# guard), remote-poll executable or not, a fresh beacon.
h="$(te_world standing)"
printf 'pid=%s\nsince=now\n' "$$" >"$h/state/.session-lock"
printf '#!/bin/sh\nexit 0\n' >"$h/config/remote-poll"
chmod +x "$h/config/remote-poll"
te_verdict 2 "$h" '{}'
assert_eq "$te_err" "agent-crew: remote orders are wired but nothing is polling - arm bin/ac-watch.sh as a background task (it stays up when idle)." "5: the standing-coverage block"
printf '1800000000\n' >"$h/state/.last-watcher-beat"
te_verdict 0 "$h" '{}'
rm -f "$h/state/.last-watcher-beat"
chmod -x "$h/config/remote-poll"
te_verdict 0 "$h" '{}'
chmod +x "$h/config/remote-poll"
te_verdict 0 "$h" '{}' AC_SCOPE=famS

# 6. the read-only lock: a live foreign holder, a dead one, a word that is no
# pid, the first pid= line read.
h="$(te_world lock)"
printf 'kind=ship\n' >"$h/state/c1.meta"
hold_open telockhold; telockpid=$HOLD_PID
printf 'pid=%s\nsince=now\n' "$telockpid" >"$h/state/.session-lock"
te_verdict 0 "$h" '{}'
assert_eq "$(te_trace "$h")" "$TE_TS verdict=stood-aside reason=read-only-lock scope=fleet queued=n/a inflight=n/a age=n/a handback=n/a" "6: a read-only session stands aside"
te_verdict 2 "$h" '{}' AC_SCOPE=famL
hold_close telockhold "$telockpid"
te_verdict 2 "$h" '{}'
for p in abc ''; do
  printf 'pid=%s\n' "$p" >"$h/state/.session-lock"
  te_verdict 2 "$h" '{}'
done
printf 'since=now\npid=%s\npid=1\n' "$$" >"$h/state/.session-lock"
te_verdict 2 "$h" '{}'

# 7. the landing receipt: mirror off, the first run seeding the baseline, a new
# Done id with a room, the same id stamped, one with no room.
h="$(te_world landing)"
printf -- '- [x] old1 - landed\n' >"$h/records/backlog.md"
te_room "$h" new1 'new1> TRIAGE: x'
te_verdict 0 "$h" '{}'
assert_no_file "$h.n/state/.landing-seen" "7: mirror off seeds no baseline"
printf 'on\n' >"$h/config/remote-mirror"
te_verdict 0 "$h" '{}'
assert_eq "$(cat "$h.n/state/.landing-seen")" "old1" "7: the first run seeds the baseline silently"
printf 'old1\n' >"$h/state/.landing-seen"
printf -- '- [x] old1 - landed\n- [x] new1 - landed (merged 2027-01-15)\n- [x] noroom - landed\n' >"$h/records/backlog.md"
te_verdict 2 "$h" '{}'
assert_eq "$te_err" "agent-crew: a task landed (backlog Done) but its Slack done-report may be unposted for: new1. Post it then stamp it (bin/ac-remote.sh done-stamp <family>) - this repeats every turn end until it is stamped." "7: the new Done id with a room is owed, the one with none is not"
assert_eq "$(cat "$h.n/state/.landing-seen")" "old1" "7: the baseline never grows"
printf 'new1=2027-01-15\n' >"$h/state/.landing-receipt-stamp"
te_verdict 0 "$h" '{}'
printf 'chief\n' >"$h/config/remote-mirror"
rm -f "$h/state/.landing-receipt-stamp"
te_verdict 2 "$h" '{}'
te_verdict 0 "$h" '{}' AC_SCOPE=new1
printf 'off\n' >"$h/config/remote-mirror"
te_verdict 0 "$h" '{}'

# 8. the trace trim: past twice the keep, the log keeps its last <keep> lines.
h="$(te_world trim)"
for i in 1 2 3 4 5; do printf 'old %s\n' "$i" >>"$h/state/.stop-hooks.log"; done
te_verdict 0 "$h" '{}' AC_STOPHOOK_LOG_KEEP=2
assert_eq "$(te_trace "$h")" "old 5
$TE_TS verdict=stood-aside reason=clean scope=fleet queued=no inflight=0 age=n/a handback=none" "8: six lines past a keep of 2 leave the last two"
assert_eq "$(ls -A "$h.n/state")" ".stop-hooks.log" "8: the trim leaves no temp"

# 9. SOLO: no self task, a clean one, a dirty one (the systemMessage JSON).
h="$(te_world solo)"
solorepo="$(make_repo tesolo)"
te_verdict 0 "$h" '{}' AC_SOLO=1
assert_eq "$te_out$te_err" "" "9: no self task is silence"
printf 'kind=self\nproject=tesolo\nworktree=%s\n' "$solorepo" >"$h/state/sl1.meta"
te_verdict 0 "$h" '{}' AC_SOLO=1
assert_eq "$te_out$te_err" "" "9: a clean slice is silence"
printf 'wip\n' >>"$solorepo/file.txt"
printf 'kind=self\nworktree=/nonexistent-te\n' >"$h/state/sl2.meta"
mkdir -p "$h/state/.wake-spool"
printf '9\treport\tso\tdone: x\n' >"$h/state/.wake-spool/1.1.000000"
te_verdict 0 "$h" '{}' AC_SOLO=1
assert_eq "$(jq -r .systemMessage <<<"$te_out")" "solo: uncommitted changes in slice sl1 - the session's end strands them; commit, land (bin/ac-teardown.sh <id>) or leave them on purpose" "9: the dirty slice is named, the one with no worktree is not"
assert_eq "$te_err" "" "9: a solo session is never blocked on a queued wake"
assert_no_file "$h.n/state/.stop-hooks.log" "9: the SOLO arm is untraced"

# 10. no bun on PATH: the shim allows at once, saying so in one stderr line; a
# module that cannot load is the same no-op, never a held stop.
h="$(te_world named)"
mkdir -p "$h/state/.wake-spool"
printf '9\treport\tnb\tdone: x\n' >"$h/state/.wake-spool/1.1.000000"
mkdir -p "$TMP/te-nobun"
for t in bash env cat dirname jq git sed awk head tail ps date mkdir mv wc tr grep basename; do ln -sf "$(command -v "$t")" "$TMP/te-nobun/$t"; done
n_rc=0; (printf '{}' | AC_HOME="$h" PATH="$TMP/te-nobun" LC_ALL=C "$BIN/ac-turnend-guard.sh") >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc:$(cat "$TMP/n.out")" "0:" "10: without bun the shim allows, nothing on stdout"
assert_eq "$(cat "$TMP/n.err")" "ac-turnend-guard.sh: bun is not on PATH - this hook did nothing" "10: ...saying so in one stderr line"
te_lf="$TMP/te-loadfail"
mkdir -p "$te_lf/bin" "$te_lf/src"
cp "$BIN/ac-bun.sh" "$BIN/ac-turnend-guard.sh" "$te_lf/bin/"
printf 'throw new Error("turn-end guard cannot load");\n' >"$te_lf/src/turnend-guard.ts"
n_rc=0; (printf '{}' | AC_HOME="$h" LC_ALL=C "$te_lf/bin/ac-turnend-guard.sh") >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc:$(cat "$TMP/n.out")" "0:" "10: a module that cannot load never holds the stop"
assert_contains "$(cat "$TMP/n.err")" "ac-turnend-guard.sh: src/turnend-guard.ts exited 1 - this hook did nothing" "10: ...and the shim says it did nothing"

# 11. a keep knob the arithmetic cannot read only skips the trim: the fleet is
# judged as with any keep.
h="$(te_world keep)"
te_verdict 0 "$h" '{}' AC_STOPHOOK_LOG_KEEP=2x
assert_contains "$te_out" "PARKED" "11: an idle fleet is still judged parked"
assert_eq "$te_err" "" "11: ...with nothing on stderr"
mkdir -p "$h/state/.wake-spool"
printf '9\treport\tkp\tdone: x\n' >"$h/state/.wake-spool/1.1.000000"
te_verdict 2 "$h" '{}' AC_STOPHOOK_LOG_KEEP=2x
assert_eq "$te_err" "$TE_QUEUED" "11: a queued-wake block keeps its exit 2"

# 12. the rooms are named in byte order whatever the locale; a story's room at
# data/<epic>/<story>/ (the dir marked .family, src/brief.ts's header owns the
# layout) is judged and named by the story, never its epic.
h="$(te_world order)"
te_room "$h" famb 'famb-chief> HANDBACK: x'
te_room "$h" famC 'famC-chief> HANDBACK: x'
TE_LC=en_US.UTF-8 te_verdict 2 "$h" '{}'
assert_contains "$te_err" "$(te_handback 'famC famb')" "12: byte order under a UTF-8 locale"
h="$(te_world nested)"
mkdir -p "$h/data/ep/story"
: >"$h/data/ep/story/.family"
printf '# Room: story\n\n- [2027-01-15T07:00:00Z] story-chief> HANDBACK: landed\n' >"$h/data/ep/story/room.md"
te_verdict 2 "$h" '{}'
assert_contains "$te_err" "$(te_handback story)" "12: a nested story room holds the stop under its own name"

pass
