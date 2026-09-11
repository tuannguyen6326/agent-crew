#!/usr/bin/env bash
# ac-spawn-kickoff-arrival.test.sh - deliver_kickoff's ARRIVAL check (contract:
# kickoff-prompt delivery in bin/ac-spawn.sh's header; the measured incident
# this family exists to kill - a truncated kickoff still reported SUCCESS
# because backend_send_line/backend_submit_verified only prove a SUBMIT, never
# that the text which ARRIVED equals the text sent). Wires the shared
# ac_arrival_wait/ac_claude_last_typed_turn primitives (tests/ac-arrival.test.sh
# owns their own contract) into kickoff_arrival_check, reusing the EXISTING
# kickoff_unverified fail-open channel (tests/ac-spawn-kickoff-ready.test.sh
# owns that channel's own shape) - never a second mechanism, never a refusal.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
export AC_SPAWN_SETTLE=0
export AC_SEND_SETTLE=0
export AC_KICKOFF_READY_BUDGET=5
: >"$FAKE_HERDR/.pane-idle-by-default"
make_home
repo="$(make_repo proj)"

# A claude stub so `command -v` passes; the fake herdr never executes the
# launch line - it lands verbatim, unexecuted, in the pane buffer.
mkdir -p "$TMP/stub"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$TMP/stub/claude"
chmod +x "$TMP/stub/claude"
export PATH="$TMP/stub:$PATH"

TROOT="$(mktemp -d)"
export AC_CLAUDE_TRANSCRIPT_ROOT="$TROOT"
mkdir -p "$TROOT/proj"

mk_turn() {
  # mk_turn <session-id> <content> - one typed-human-turn transcript file,
  # the shape verified against a live transcript (contract: tests/ac-arrival.test.sh).
  printf '{"type":"user","promptSource":"typed","origin":{"kind":"human"},"message":{"role":"user","content":%s}}\n' \
    "$(printf '%s' "$2" | jq -Rs .)" >"$TROOT/proj/$1.jsonl"
}

pointer_text() {
  # pointer_text <id> - the exact kickoff-pointer line deliver_kickoff types
  # (bin/ac-spawn.sh FILE-DELIVERED KICKOFF), so a fixture can pre-seed a
  # transcript that matches (or deliberately does not).
  printf 'Read and follow your kickoff order at %s/data/%s/kickoff.md NOW - it is this session'"'"'s contract. Start by reading that file in full.' \
    "$AC_HOME" "$1"
}

# --- A4: healthy claude path, arrival CONFIRMED - no regression -------------
# The transcript already carries the pointer BEFORE the spawn runs (this is
# what a real claude session does once the composer accepts it) - the probe's
# very first read matches, so this also proves the healthy path costs no
# meaningful extra wait (AC_SEND_SETTLE=0 makes any retry free in-suite, but
# the first-read-confirms shape is what keeps it free in production too).
sid_ok="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
printf 'claude --session-id %s --permission-mode auto\n' "$sid_ok" >"$AC_HOME/config/launch-claude"
"$BIN/ac-brief.sh" ok1 proj --mode local-only >/dev/null
mk_turn "$sid_ok" "$(pointer_text ok1)"
out="$("$BIN/ac-spawn.sh" ok1 "$repo" --harness claude --mode local-only 2>&1)"
assert_contains "$out" "spawned ok1" "a confirmed arrival still reports the ordinary spawn success"
case "$(cat "$AC_HOME/state/ok1.status" 2>/dev/null)" in
  *"warn: kickoff"*) fail "a CONFIRMED arrival must not warn - that is the no-regression bar (A4)" ;;
esac
grep -rq 'kickoff-unverified' "$AC_HOME/state/.wake-spool" 2>/dev/null \
  && fail "a CONFIRMED arrival must publish no kickoff-unverified wake"
"$BIN/ac-teardown.sh" ok1 --force >/dev/null 2>&1

# --- A1: capable harness, arrival REFUTED - no longer a silent `spawned` ----
# The transcript exists and is readable, but its last typed turn is WRONG
# (the pane received something else) - fail-OPEN stays (the spawn still
# succeeds, per the deliberate design this family must not re-litigate), but
# it is no longer SILENT: the chief is told on the same durable channel as
# every other fail-open point here.
sid_bad="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
printf 'claude --session-id %s --permission-mode auto\n' "$sid_bad" >"$AC_HOME/config/launch-claude"
"$BIN/ac-brief.sh" bad1 proj --mode local-only >/dev/null
mk_turn "$sid_bad" "garbled: only the tail of what was actually sent landed here"
out="$("$BIN/ac-spawn.sh" bad1 "$repo" --harness claude --mode local-only 2>&1)"
assert_contains "$out" "spawned bad1" \
  "a REFUTED arrival still spawns - refusing here would ground the fleet (deliberate, OUT of scope)"
assert_contains "$(cat "$AC_HOME/state/bad1.status")" "warn: kickoff" \
  "THE REGRESSION THIS CLOSES: a wrong arrival must stamp the status log, never ack silently"
grep -rq 'kickoff-unverified' "$AC_HOME/state/.wake-spool" 2>/dev/null \
  || fail "a REFUTED arrival must publish a kickoff-unverified wake, exactly like every other fail-open point"
"$BIN/ac-teardown.sh" bad1 --force >/dev/null 2>&1

# --- A2: no per-harness capability - told, not silently acked, not refused -
# codex writes no transcript this fleet can read; a custom launch-codex
# template's TUI is unknown either way (same suppression the startup-dialog
# sequence already applies - bin/ac-spawn.sh header).
printf 'echo crew __ID__ reading __BRIEF__; sleep 300\n' >"$AC_HOME/config/launch-codex"
"$BIN/ac-brief.sh" nocap1 proj --mode local-only >/dev/null
out="$("$BIN/ac-spawn.sh" nocap1 "$repo" --harness codex --mode local-only 2>&1)"
assert_contains "$out" "spawned nocap1" \
  "a harness with no arrival capability still spawns - never a refusal, never a silent ack"
assert_contains "$(cat "$AC_HOME/state/nocap1.status")" "warn: kickoff" \
  "A2: a capability-less harness's kickoff is durably marked arrival-unverifiable"
assert_contains "$(cat "$AC_HOME/state/nocap1.status")" "arrival unverifiable" \
  "the reason names WHAT could not be established, not just that something failed"
grep -rq 'kickoff-unverified' "$AC_HOME/state/.wake-spool" 2>/dev/null \
  || fail "a capability-less harness's kickoff must publish a kickoff-unverified wake"

pass
