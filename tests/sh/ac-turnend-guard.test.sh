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

# --- differential: src/turnend-guard.ts against the frozen bash original -----
# DISPUTED: the implementation (tests/fixtures/ac-turnend-guard.sh under bash vs src/turnend-guard.ts through bin/ac-turnend-guard.sh)
# HELD-CONSTANT: each row's home, copied whole for each side (no output names the home's path); the payload; the environment (AC_SCOPE, AC_SOLO, AC_GUARD_GRACE, AC_STOPHOOK_LOG_KEEP; PATH with a date stub frozen at one instant and the helpers' refusing herdr/orca; LC_ALL=C unless a row says otherwise); the test shell as the lock holder's ancestor; stdout, stderr, exit status and each side's home tree after the run compared whole
obin="$(make_oracle_bin ac-turnend-guard)"
cmp -s "$obin/ac-turnend-guard.sh" "$ROOT/tests/fixtures/ac-turnend-guard.sh" \
  || fail "the oracle bin must hold the frozen original"
mkdir -p "$TMP/te-date"
cat >"$TMP/te-date/date" <<'EOF'
#!/bin/sh
case "$*" in *%s*) echo 1800000000 ;; *) echo 2027-01-15T08:00:00Z ;; esac
EOF
chmod +x "$TMP/te-date/date"
te_prep() { :; }
te_world() {  # te_world <name> - a fresh fleet home, printed
  local h="$TMP/te/$1"
  rm -rf "$h"
  mkdir -p "$h/state" "$h/records" "$h/data" "$h/config"
  : >"$h/records/backlog.md"
  printf '%s\n' "$h"
}
te_same() {  # te_same <home> <payload> [VAR=VAL ...] - each side on its own copy of <home>; the port's status in te_rc
  local h="$1" pl="$2" o_rc=0
  shift 2
  rm -rf "$h.o" "$h.n"
  cp -R "$h" "$h.o"
  cp -R "$h" "$h.n"
  te_prep "$h.o"
  te_prep "$h.n"
  te_rc=0
  (printf '%s' "$pl" | env -u AC_SOLO -u AC_SCOPE AC_HOME="$h.o" "$@" PATH="$TMP/te-date:$PATH" LC_ALL="${DIFF_LC:-C}" "$obin/ac-turnend-guard.sh") >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
  (printf '%s' "$pl" | env -u AC_SOLO -u AC_SCOPE AC_HOME="$h.n" "$@" PATH="$TMP/te-date:$PATH" LC_ALL="${DIFF_LC:-C}" "$BIN/ac-turnend-guard.sh") >"$TMP/n.out" 2>"$TMP/n.err" || te_rc=$?
  chmod -R u+rwX "$h.o" "$h.n"
  assert_eq "$te_rc" "$o_rc" "differential exit ($*) in $h"
  # the one line that names a path (an unreadable meta's WARN) names each side's copy
  o_txt="$(cat "$TMP/o.out"; printf x)"; n_txt="$(cat "$TMP/n.out"; printf x)"
  assert_eq "${n_txt//"$h.n"/HOME}" "${o_txt//"$h.o"/HOME}" "differential stdout ($*)"
  o_txt="$(cat "$TMP/o.err"; printf x)"; n_txt="$(cat "$TMP/n.err"; printf x)"
  assert_eq "${n_txt//"$h.n"/HOME}" "${o_txt//"$h.o"/HOME}" "differential stderr ($*)"
  diff -r "$h.o" "$h.n" >"$TMP/te.diff" 2>&1 || fail "differential home trees differ ($*): $(head -n 6 "$TMP/te.diff")"
}
te_verdict() {  # te_verdict <0|2> <home> <payload> [VAR=VAL ...]
  local want="$1"
  shift
  te_same "$@"
  assert_eq "$te_rc" "$want" "turn-end verdict ($*)"
}
te_room() {  # te_room <home> <family> <entry...> - a room holding these entries
  local h="$1" fam="$2" e
  shift 2
  mkdir -p "$h/data/$fam"
  printf '# Room: %s\n\n' "$fam" >"$h/data/$fam/room.md"
  for e in "$@"; do printf -- '- [2027-01-15T07:00:00Z] %s\n' "$e" >>"$h/data/$fam/room.md"; done
}

# 1. idle and parked; the stop_hook_active text; a payload of nothing.
h="$(te_world idle)"
te_verdict 0 "$h" '{}'
assert_contains "$(cat "$TMP/n.out")" "PARKED" "an idle fleet is reminded on both sides"
te_verdict 0 "$h" ''
te_verdict 0 "$h" '{"stop_hook_active":true}'
te_verdict 0 "$h" '{"stop_hook_active": true}'
te_verdict 0 "$h" '{}' AC_SCOPE=famQ
printf -- '- [ ] t1 - queued work (repo: x)\n' >"$h/records/backlog.md"
te_verdict 0 "$h" '{}'

# 2. queued wakes: the fleet spool, a family spool for its scope, an orphan family.
h="$(te_world queued)"
mkdir -p "$h/state/.wake-spool"
printf '9\treport\tq1\tdone: x\n' >"$h/state/.wake-spool/1.1.000000"
te_verdict 2 "$h" '{}'
te_verdict 0 "$h" '{}' AC_SCOPE=famQ
rm -rf "$h/state/.wake-spool"
mkdir -p "$h/state/.wake-spool.famQ"
printf '9\treport\tq2\tdone: x\n' >"$h/state/.wake-spool.famQ/1.1.000000"
te_verdict 2 "$h" '{}' AC_SCOPE=famQ
te_verdict 2 "$h" '{}'
te_verdict 0 "$h" '{}' AC_SCOPE=famZ

# 3. the tally and the beacon: crew with no beacon, a fresh, stale, stood-down,
# unreadable and zero-padded beacon, the grace knob, the kinds that never count.
h="$(te_world beacon)"
printf 'kind=ship\n' >"$h/state/c1.meta"
te_verdict 2 "$h" '{}'
for beat in 1800000000 1799999000 0 abc 01799999990 ''; do
  printf '%s\n' "$beat" >"$h/state/.last-watcher-beat"
  te_same "$h" '{}'
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
te_verdict 0 "$h" '{}' AC_SCOPE=famR
rm -f "$h/state/famR-chief.meta" "$h/state/k1.meta"
printf 'window=crew:x\n' >"$h/state/nokind.meta"
te_verdict 2 "$h" '{}'
# an unreadable crew meta counts, its WARN on the block's stderr (AT PARITY)
if [ "$(id -u)" != 0 ]; then
  te_prep() { chmod 000 "$1/state/nokind.meta"; }
  te_verdict 2 "$h" '{}'
  te_prep() { :; }
fi

# 4. HANDBACK: alongside a queued wake and a stale beacon, alone, cleared by each
# retiring entry, two families in byte order, a room set that cannot be read.
h="$(te_world handback)"
te_room "$h" famB 'famB-chief> HANDBACK: landed, please demote'
te_room "$h" famA 'famA-chief> HANDBACK: landed' 'crewchief> HANDBACK-REFUSED: remedy first' 'famA-chief> HANDBACK: again'
te_verdict 2 "$h" '{}'
assert_contains "$(cat "$TMP/n.err")" "waiting: famA famB." "both families, in byte order"
mkdir -p "$h/state/.wake-spool"
printf '9\treport\thb\tdone: x\n' >"$h/state/.wake-spool/1.1.000000"
te_verdict 2 "$h" '{}'
rm -rf "$h/state/.wake-spool"
printf 'kind=ship\n' >"$h/state/c1.meta"
te_verdict 2 "$h" '{}'
rm -f "$h/state/c1.meta"
te_verdict 0 "$h" '{}' AC_SCOPE=famA
for retire in 'crewchief> HANDBACK-REFUSED: no' 'crewchief> DEMOTED: famB-chief' 'crewchief> CLOSED: done'; do
  te_room "$h" famB 'famB-chief> HANDBACK: landed' "$retire"
  te_same "$h" '{}'
done
te_room "$h" famB 'famB-chief> HANDBACK: landed'
mkdir -p "$h/data/zz/room.md"
te_verdict 0 "$h" '{}'
rm -rf "$h/data/zz"
te_room "$h" famC 'crewchief> GATE: pick one' 'famC-chief> HANDBACK: x' 'crewchief> DEMOTED: famC-chief'
rm -rf "$h/data/famA" "$h/data/famB"
te_verdict 0 "$h" '{}'
te_room "$h" famC 'crewchief> GATE: pick one' 'crewchief> DECIDED: a'
te_verdict 0 "$h" '{}'

# 5. standing coverage: the lock held by the test shell (an ancestor of both
# sides), remote-poll executable or not, a fresh beacon.
h="$(te_world standing)"
printf 'pid=%s\nsince=now\n' "$$" >"$h/state/.session-lock"
printf '#!/bin/sh\nexit 0\n' >"$h/config/remote-poll"
chmod +x "$h/config/remote-poll"
te_verdict 2 "$h" '{}'
printf '1800000000\n' >"$h/state/.last-watcher-beat"
te_verdict 0 "$h" '{}'
rm -f "$h/state/.last-watcher-beat"
chmod -x "$h/config/remote-poll"
te_verdict 0 "$h" '{}'
chmod +x "$h/config/remote-poll"
te_verdict 0 "$h" '{}' AC_SCOPE=famS

# 6. the read-only lock: a live foreign holder, a dead one, kill -0's own
# grammar for 0, -1 and +<pid> (AT PARITY), a word that is no pid.
h="$(te_world lock)"
printf 'kind=ship\n' >"$h/state/c1.meta"
hold_open telockhold; telockpid=$HOLD_PID
printf 'pid=%s\nsince=now\n' "$telockpid" >"$h/state/.session-lock"
te_verdict 0 "$h" '{}'
te_verdict 2 "$h" '{}' AC_SCOPE=famL
hold_close telockhold "$telockpid"
te_verdict 2 "$h" '{}'
for p in 0 -1 "+$$" abc ''; do
  printf 'pid=%s\n' "$p" >"$h/state/.session-lock"
  te_same "$h" '{}'
done
printf 'since=now\npid=%s\npid=1\n' "$$" >"$h/state/.session-lock"
te_verdict 2 "$h" '{}'

# 7. the landing receipt: mirror off, the first run seeding the baseline, a new
# Done id with a room, the same id stamped, one with no room.
h="$(te_world landing)"
printf -- '- [x] old1 - landed\n' >"$h/records/backlog.md"
te_room "$h" new1 'new1> TRIAGE: x'
te_verdict 0 "$h" '{}'
printf 'on\n' >"$h/config/remote-mirror"
te_verdict 0 "$h" '{}'
printf -- '- [x] old1 - landed\n' >"$h/state/.landing-seen"
printf -- '- [x] old1 - landed\n- [x] new1 - landed (merged 2027-01-15)\n- [x] noroom - landed\n' >"$h/records/backlog.md"
te_verdict 2 "$h" '{}'
printf 'new1=2027-01-15\n' >"$h/state/.landing-receipt-stamp"
te_verdict 0 "$h" '{}'
printf 'chief\n' >"$h/config/remote-mirror"
rm -f "$h/state/.landing-receipt-stamp"
te_verdict 2 "$h" '{}'
te_verdict 0 "$h" '{}' AC_SCOPE=new1
printf 'off\n' >"$h/config/remote-mirror"
te_verdict 0 "$h" '{}'

# 8. the trace trim; the inert shapes (a linked worktree, a home inside a git
# checkout's subdirectory - AT PARITY).
h="$(te_world trim)"
for i in 1 2 3 4 5; do printf 'old %s\n' "$i" >>"$h/state/.stop-hooks.log"; done
te_same "$h" '{}' AC_STOPHOOK_LOG_KEEP=2
te_same "$h" '{}' AC_STOPHOOK_LOG_KEEP=010
trrepo="$(make_repo terepo)"
git -C "$trrepo" worktree add -q -b tewt "$TMP/tewt"
mkdir -p "$TMP/tewt/state" "$trrepo/homes/h/state"
printf 'kind=ship\n' >"$TMP/tewt/state/c1.meta"
printf 'kind=ship\n' >"$trrepo/homes/h/state/c1.meta"
for hh in "$TMP/tewt" "$trrepo/homes/h"; do
  o_rc=0; (printf '{}' | AC_HOME="$hh" LC_ALL=C "$obin/ac-turnend-guard.sh") >"$TMP/o.out" 2>&1 || o_rc=$?
  n_rc=0; (printf '{}' | AC_HOME="$hh" LC_ALL=C "$BIN/ac-turnend-guard.sh") >"$TMP/n.out" 2>&1 || n_rc=$?
  assert_eq "$o_rc $n_rc" "0 0" "an inert home allows on both sides: $hh"
  assert_eq "$(cat "$TMP/o.out" "$TMP/n.out")" "" "an inert home says nothing: $hh"
  assert_no_file "$hh/state/.stop-hooks.log" "an inert home is never traced: $hh"
done

# 9. SOLO: no self task, a clean one, a dirty one (the systemMessage JSON).
h="$(te_world solo)"
solorepo="$(make_repo tesolo)"
te_verdict 0 "$h" '{}' AC_SOLO=1
printf 'kind=self\nproject=tesolo\nworktree=%s\n' "$solorepo" >"$h/state/sl1.meta"
te_verdict 0 "$h" '{}' AC_SOLO=1
printf 'wip\n' >>"$solorepo/file.txt"
te_verdict 0 "$h" '{}' AC_SOLO=1
assert_contains "$(cat "$TMP/n.out")" "slice sl1 - the session" "the dirty slice is named"
printf 'kind=self\nworktree=/nonexistent-te\n' >"$h/state/sl2.meta"
te_verdict 0 "$h" '{}' AC_SOLO=1

# --- named divergences: each row asserts both sides ---------------------------
h="$(te_world named)"
mkdir -p "$h/state/.wake-spool"
printf '9\treport\tnb\tdone: x\n' >"$h/state/.wake-spool/1.1.000000"
# BUN: no bun on PATH - the shim allows at once and says nothing; the original
# (bash, jq and its libs) held the stop.
mkdir -p "$TMP/te-nobun"
for t in bash env cat dirname jq git sed awk head tail ps date mkdir mv wc tr grep basename; do ln -sf "$(command -v "$t")" "$TMP/te-nobun/$t"; done
o_rc=0; (printf '{}' | AC_HOME="$h" PATH="$TMP/te-nobun" LC_ALL=C "$obin/ac-turnend-guard.sh") >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; (printf '{}' | AC_HOME="$h" PATH="$TMP/te-nobun" LC_ALL=C "$BIN/ac-turnend-guard.sh") >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$o_rc $n_rc" "2 0" "BUN: the original holds the stop with no bun on PATH, the shim allows"
assert_contains "$(cat "$TMP/o.err")" "queued wakes are pending" "BUN: the original's reason"
assert_eq "$(cat "$TMP/n.out" "$TMP/n.err")" "" "BUN: the shim says nothing"
# BUN: a module that cannot load is the shim's no-op, never a held stop.
te_lf="$TMP/te-loadfail"
mkdir -p "$te_lf/bin" "$te_lf/src"
cp "$BIN/ac-bun.sh" "$BIN/ac-turnend-guard.sh" "$te_lf/bin/"
printf 'throw new Error("turn-end guard cannot load");\n' >"$te_lf/src/turnend-guard.ts"
n_rc=0; (printf '{}' | AC_HOME="$h" LC_ALL=C "$te_lf/bin/ac-turnend-guard.sh") >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$n_rc" "0" "BUN: a module that cannot load never holds the stop"
assert_eq "$(cat "$TMP/n.out")" "" "BUN: a module that cannot load prints nothing on stdout"
assert_contains "$(cat "$TMP/n.err")" "turn-end guard cannot load" "BUN: the load failure is bun's own diagnosis"
# STATUS FOLD: a keep knob naming a variable ended the original under set -u
# with a status of its own after its reason line; neither side holds the stop.
o_rc=0; (printf '{}' | AC_HOME="$h" AC_STOPHOOK_LOG_KEEP=nokeep PATH="$TMP/te-date:$PATH" LC_ALL=C "$obin/ac-turnend-guard.sh") >/dev/null 2>&1 || o_rc=$?
n_rc=0; (printf '{}' | AC_HOME="$h" AC_STOPHOOK_LOG_KEEP=nokeep PATH="$TMP/te-date:$PATH" LC_ALL=C "$BIN/ac-turnend-guard.sh") >/dev/null 2>&1 || n_rc=$?
[ "$o_rc" != 2 ] || fail "AT PARITY: the original never held the stop with an identifier keep"
assert_eq "$n_rc" "0" "STATUS FOLD: the shim answers 0"
rm -rf "$h/state/.wake-spool"
# KEEP ARITHMETIC: a keep knob `$(( ))` cannot read made the original abandon
# each whole top-level statement around a trace, so an idle fleet fell through
# to the stale-watcher line with 0 crew in flight; the port skips the trim.
h="$(te_world keep)"
o_rc=0; (printf '{}' | AC_HOME="$h" AC_STOPHOOK_LOG_KEEP=2x PATH="$TMP/te-date:$PATH" LC_ALL=C "$obin/ac-turnend-guard.sh") >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; (printf '{}' | AC_HOME="$h" AC_STOPHOOK_LOG_KEEP=2x PATH="$TMP/te-date:$PATH" LC_ALL=C "$BIN/ac-turnend-guard.sh") >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$o_rc $n_rc" "0 0" "KEEP ARITHMETIC: neither side holds the stop"
assert_contains "$(cat "$TMP/o.err")" "0 crewmate(s) in flight" "KEEP ARITHMETIC: the original fell through to the stale-watcher line"
assert_contains "$(cat "$TMP/n.out")" "PARKED" "KEEP ARITHMETIC: the port judges the idle fleet as parked"
assert_eq "$(cat "$TMP/n.err")" "" "KEEP ARITHMETIC: the port says nothing on stderr"
# SHELL-OWN STDERR: a grace that is no integer - both judge the beacon fresh;
# only the original prints `[`'s own line.
printf 'kind=ship\n' >"$h/state/c1.meta"
o_rc=0; (printf '{}' | AC_HOME="$h" AC_GUARD_GRACE=abc PATH="$TMP/te-date:$PATH" LC_ALL=C "$obin/ac-turnend-guard.sh") >"$TMP/o.out" 2>"$TMP/o.err" || o_rc=$?
n_rc=0; (printf '{}' | AC_HOME="$h" AC_GUARD_GRACE=abc PATH="$TMP/te-date:$PATH" LC_ALL=C "$BIN/ac-turnend-guard.sh") >"$TMP/n.out" 2>"$TMP/n.err" || n_rc=$?
assert_eq "$o_rc $n_rc" "0 0" "SHELL-OWN: a grace that is no integer never holds the stop"
assert_contains "$(cat "$TMP/o.err")" "integer expression expected" "SHELL-OWN: the original's line is the shell's"
assert_eq "$(cat "$TMP/n.err")" "" "SHELL-OWN: the port adds none"
rm -f "$h/state/c1.meta"
# ORDER: the rooms are named in byte order; the original's glob followed the
# locale's collation, so under UTF-8 `famb` precedes `famC` there.
h="$(te_world order)"
te_room "$h" famb 'famb-chief> HANDBACK: x'
te_room "$h" famC 'famC-chief> HANDBACK: x'
o_rc=0; (printf '{}' | AC_HOME="$h" PATH="$TMP/te-date:$PATH" LC_ALL=en_US.UTF-8 "$obin/ac-turnend-guard.sh") >/dev/null 2>"$TMP/o.err" || o_rc=$?
n_rc=0; (printf '{}' | AC_HOME="$h" PATH="$TMP/te-date:$PATH" LC_ALL=en_US.UTF-8 "$BIN/ac-turnend-guard.sh") >/dev/null 2>"$TMP/n.err" || n_rc=$?
assert_eq "$o_rc $n_rc" "2 2" "ORDER: both hold the stop"
assert_contains "$(cat "$TMP/o.err")" "waiting: famb famC." "ORDER: the original collates under UTF-8"
assert_contains "$(cat "$TMP/n.err")" "waiting: famC famb." "ORDER: the port reads byte order"

pass
