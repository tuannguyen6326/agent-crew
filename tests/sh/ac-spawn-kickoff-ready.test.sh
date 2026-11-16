#!/usr/bin/env bash
# ac-spawn-kickoff-ready.test.sh - kickoff_wait_input_ready, the composer-ready
# observation ac-spawn.sh's deliver_kickoff now runs between the came-up gate
# and the first thing typed after it (contract: THE COMPOSER-READY OBSERVATION
# in bin/ac-spawn.sh's header). Modeled on the two closest precedents named in
# the brief: tests/sh/ac-pane-agent.test.sh's delay-input-ready/never-input-ready
# fault injection (the sibling arm's own regression shape, reused here via the
# id-scoped `.delay-ready-secs` knob - contract: tests/sh/helpers.sh) and
# tests/sh/ac-spawn-dead-pane.test.sh (the came-up gate's own fault injection,
# same arm, one gate earlier).
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_orca
# Pinned explicitly so this section does not depend on the no-config default.
printf 'orca\n' >"$AC_HOME/config/backend"
export AC_SPAWN_SETTLE=0
make_home
repo="$(make_repo proj)"
# Every orca spawn mints a startup terminal (closed right after) before the
# crew's own, so the crew terminal is always the SECOND tick of the shared
# $FAKE_ORCA/.n counter for that spawn - a knob armed on n+1 would silently
# target a terminal nothing ever reads.
onext() { local n; n="$(cat "$FAKE_ORCA/.n" 2>/dev/null || printf 0)"; printf 'term%s\n' "$((n + 2))"; }

# --- a composer that becomes ready after a short delay: waited for, delivered correctly ---
# Before this gate existed, deliver_kickoff typed the kickoff the instant the
# came-up gate passed - no observation of the composer at all. This pane
# DROPS any text typed before its 2s delay elapses (repo-knowledge, by:
# spawn-cameup-render-readiness: a keystroke sent while the TUI is still
# booting is EATEN), while a bare Enter pressed into that now-empty composer
# still appends a newline to the render - the "unrelated redraw" that fools a
# naive render-diff submit verifier into reporting ACCEPTED even though the
# text never landed. Without the fix this pane's buffer ends up WITHOUT the
# kickoff prompt while the spawn still reports success - the measured defect
# this family exists to kill (RED on the pre-fix tree, verified by hand:
# git-stash the bin/ac-spawn.sh diff and re-run this file - the assertion
# below is what fails). With the fix, kickoff_wait_input_ready holds off
# typing anything until the composer is confirmed ready, so the prompt lands
# only once the drop window has closed. kickoffWaitInputReady (src/spawn.ts)
# proves UP and IDLE off the orca terminal's TITLE alone (harnessUp's
# spinner/✳ match, agentIdle's same two) - make_fake_orca's .delay-ready-secs
# models exactly that, send-drop included.
t="$(onext)"
printf '2\n' >"$FAKE_ORCA/terminals/$t.delay-ready-secs"
"$BIN/ac-brief.sh" ready1 proj --mode local-only >/dev/null
out="$("$BIN/ac-spawn.sh" ready1 "$repo" --harness claude --mode local-only 2>&1)"
assert_contains "$out" "spawned ready1" "a delayed-ready composer still spawns once ready"
assert_contains "$(cat "$(fake_orca_buf ready1)")" \
  "kickoff order at" \
  "the kickoff pointer reaches the transcript once the composer surface is confirmed ready - not before"
"$BIN/ac-teardown.sh" ready1 --force >/dev/null 2>&1
# ready1's own claude kickoff also published an arrival-unverifiable wake (no
# transcript exists under the isolated AC_CLAUDE_TRANSCRIPT_ROOT for it - this
# file is not testing arrival, tests/sh/ac-spawn-kickoff-arrival.test.sh owns
# that contract) - clear it so it cannot pollute the later scenarios' own
# wake-count assertions below.
rm -rf "$AC_HOME/state/.wake-spool"

# --- a composer that never becomes ready: FAILS LOUDLY, nothing typed --------
# The harness is genuinely UP the whole time (backend_harness_up stays 0 - the
# death signal never fires) but its input surface never stabilises, so this is
# the "cannot be CONFIRMED delivered" case the acceptance criteria name: never
# report success, never type blind. AC_KICKOFF_READY_BUDGET keeps the wait
# bounded and the suite fast (real default is 60s).
export AC_KICKOFF_READY_BUDGET=2
t="$(onext)"
printf '9999\n' >"$FAKE_ORCA/terminals/$t.delay-ready-secs"
: >"$FAKE_ORCA/log"
"$BIN/ac-brief.sh" never1 proj --mode local-only >/dev/null
rc=0
err="$("$BIN/ac-spawn.sh" never1 "$repo" --harness claude --mode local-only 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "a composer that never becomes ready must FAIL the spawn, not report success"
assert_contains "$err" "input surface did NOT become ready" "the failure names what never happened"
assert_contains "$err" "REFUSED" "the failure says the spawn is refused"
assert_no_file "$AC_HOME/state/never1.meta" "a refused spawn leaves no task in flight"
assert_contains "$(cat "$AC_HOME/state/never1.status")" "failed:" "the status log records the failure"
case "$(cat "$FAKE_ORCA/log")" in
  *"kickoff order at"*)
    fail "the kickoff pointer must never be typed into a composer that was never confirmed ready" ;;
esac

# --- an UNOBSERVABLE composer (the backend cannot be read at all): warns, proceeds -
# The three probe states are never collapsed (design decision this family is
# bound to): a budget expiring because the backend cannot be READ is not the
# same fact as a budget expiring on a confirmed-alive-but-frozen harness, and
# must not refuse the spawn - that would ground the fleet on a backend hiccup.
export AC_KICKOFF_READY_BUDGET=2
: >"$FAKE_ORCA/.terminal-api-down"
: >"$FAKE_ORCA/log"
"$BIN/ac-brief.sh" blind2 proj --mode local-only >/dev/null
rc=0
err="$("$BIN/ac-spawn.sh" blind2 "$repo" --harness claude --mode local-only 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "0" "an unobservable input-surface probe is not evidence of a frozen composer - the spawn stands"
assert_contains "$err" "input surface became ready" "the readiness gate names what it could not verify"
rm -f "$FAKE_ORCA/.terminal-api-down"
assert_contains "$(cat "$(fake_orca_buf blind2)")" \
  "kickoff order at" "an unobservable probe still delivers the kickoff pointer"
# The fail-open delivery leaves a DURABLE trail, not only stderr WARNs: a
# status stamp the chief can read back, and ONE wake so the chief is TOLD
# instead of discovering an idle agent by accident.
assert_contains "$(cat "$AC_HOME/state/blind2.status")" "warn: kickoff" \
  "an unverified delivery stamps the status log"
grep -rq 'kickoff-unverified' "$AC_HOME/state/.wake-spool" 2>/dev/null \
  || fail "an unverified delivery publishes a kickoff-unverified wake"
assert_eq "$(grep -rl 'kickoff-unverified' "$AC_HOME/state/.wake-spool" 2>/dev/null | wc -l | tr -d ' ')" "1" \
  "exactly ONE wake per spawn, however many probes went unobservable"

pass
