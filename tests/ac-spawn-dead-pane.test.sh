#!/usr/bin/env bash
# ac-spawn-dead-pane.test.sh - the harness-came-up gate ac-spawn.sh runs
# BETWEEN the launch line and the kickoff prompt (contract: the kickoff-prompt
# delivery block in bin/ac-spawn.sh, the probe itself in bin/ac-backend.sh).
# Three panes, three verdicts: a live harness is delivered to exactly as before,
# a pane that fell back to a bare shell refuses the spawn LOUDLY with no kickoff
# typed into it, and a pane that could not be READ keeps today's delivery under
# a warning (an unreadable probe is not evidence of a dead harness).
# The gate runs TWICE - the same probe again AFTER the prompt - so the fourth
# pane here is the one it exists for: alive at the gate, DEAD on the kickoff.
# And because codex dies on the kickoff by ANSWERING its startup trust dialog
# with it, the last cases assert what is typed at a codex pane first: the bare
# Enter goes to a BUILT-IN codex launch only, and it goes BEFORE the gate, so
# the gate covers its aftermath too.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
# Deliver the kickoff prompt immediately (default 8s) so the suite stays fast.
export AC_SPAWN_SETTLE=0
# Every pane here is a stand-in for a REAL harness that settles to idle almost
# immediately (repo-knowledge, by: spawn-cameup-render-readiness) - this suite
# is not testing the composer-ready observation itself (tests/ac-spawn-
# kickoff-ready.test.sh owns that), so seed every pane ready from birth and
# keep the budget small: still enough for the ~2-3 tick convergence the
# observation genuinely needs (three one-second reads of a stable render),
# tiny enough that an unobservable-forever pane (the "blind1" case below)
# warns-and-proceeds in seconds rather than the real 60s default.
: >"$FAKE_HERDR/.pane-idle-by-default"
export AC_KICKOFF_READY_BUDGET=4

make_home
repo="$(make_repo proj)"

# A fake harness template; its text sits unexecuted in the pane buffer. Being a
# CUSTOM template it also puts the %q-escaped prompt on the launch line, so the
# kickoff assertions below match on REAL spaces - which only the separately
# delivered prompt line has (the ac-spawn-teardown.test.sh idiom).
printf 'echo crew __ID__ reading __BRIEF__; sleep 300\n' >"$AC_HOME/config/launch-fake"

# --- a harness that came up: unchanged ----------------------------------------

"$BIN/ac-brief.sh" up1 proj --mode local-only >/dev/null
out="$("$BIN/ac-spawn.sh" up1 "$repo" --harness fake --mode local-only 2>/dev/null)"
assert_contains "$out" "spawned up1" "a live harness still spawns"
assert_contains "$(cat "$(fake_pane_buf up1)")" \
  "You are an agent-crew crewmate. Read and follow the brief" "a live harness still gets its kickoff"

# --- a pane that fell back to a shell: fail closed -----------------------------

: >"$FAKE_HERDR/.spawn-dead"   # every pane created from here on is a bare shell
: >"$FAKE_HERDR/log"           # so the send-text count below is this spawn's alone
"$BIN/ac-brief.sh" dead1 proj --mode local-only >/dev/null
rc=0
err="$("$BIN/ac-spawn.sh" dead1 "$repo" --harness fake --mode local-only 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "a dead pane must FAIL the spawn, not sit silent on it"
assert_contains "$err" "did NOT come up" "the failure names what went wrong"
assert_contains "$err" "WITHHELD" "the failure says the kickoff was withheld"
assert_contains "$err" "crew dead1 reading" "the failure carries the pane's last lines as evidence"
assert_no_file "$AC_HOME/state/dead1.meta" "a refused spawn leaves no task in flight"
assert_contains "$(cat "$AC_HOME/state/dead1.status")" "failed:" "the status log records the failure"
sends="$(grep -c 'pane send-text' "$FAKE_HERDR/log" || true)"
assert_eq "$sends" "1" "only the launch line was typed - nothing was typed into the shell"
case "$(cat "$FAKE_HERDR/log")" in
  *"You are an agent-crew crewmate. Read and follow"*) fail "the kickoff prompt was typed into a bare shell" ;;
esac

# --- a pane that could not be read: today's delivery, plus a warning -----------

rm -f "$FAKE_HERDR/.spawn-dead"
: >"$FAKE_HERDR/.probe-unreadable"
"$BIN/ac-brief.sh" blind1 proj --mode local-only >/dev/null
rc=0
err="$("$BIN/ac-spawn.sh" blind1 "$repo" --harness fake --mode local-only 2>&1 >/dev/null)" || rc=$?
assert_eq "$rc" "0" "an unreadable probe is not evidence of a dead harness - the spawn stands"
assert_contains "$err" "could not read" "the unverified probe warns"
assert_contains "$err" "survived the kickoff" \
  "the post-kickoff re-check keeps state 2 distinct too: it warns, it never refuses"
assert_contains "$(cat "$(fake_pane_buf blind1)")" \
  "You are an agent-crew crewmate. Read and follow the brief" "an unreadable probe still delivers the kickoff"
rm -f "$FAKE_HERDR/.probe-unreadable"

# --- a harness that came up and then DIED ON THE KICKOFF: fail closed ----------
# The pane the earlier fixtures cannot express: ALIVE at the gate, DEAD after
# the prompt. The pattern carries REAL spaces, so it matches the separately
# delivered kickoff line and NOT the %q-escaped copy on the custom template's
# launch line - the death has to land after the gate to be this case at all.

printf 'agent-crew crewmate. Read and follow' >"$FAKE_HERDR/.die-on-text"
"$BIN/ac-brief.sh" died1 proj --mode local-only >/dev/null
rc=0
err="$("$BIN/ac-spawn.sh" died1 "$repo" --harness fake --mode local-only 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "a harness that died ON the kickoff must FAIL the spawn, not report success"
assert_contains "$err" "NO LONGER UP" "the failure names what the probe actually saw"
assert_contains "$err" "LIKELY cause" \
  "the kickoff is named as the likely cause, never as one the probe established"
assert_contains "$err" "NOTHING is in flight" "the failure says the spawn is refused"
assert_contains "$err" "a non-shell foreground process held the pane" \
  "the failure states what the probe observed, never that the harness itself held the pane"
assert_no_file "$AC_HOME/state/died1.meta" "a spawn refused after the kickoff leaves no task in flight"
assert_contains "$(cat "$AC_HOME/state/died1.status")" "failed:" "the status log records the death"
rm -f "$FAKE_HERDR/.die-on-text"

# --- codex: a bare Enter answers the startup trust dialog BEFORE the prompt ----
# codex's dialog is a key-driven select, and an `n` or a `2` anywhere in typed
# text picks "2. No, quit" - so the kickoff prompt must never be the first thing
# typed at a codex pane (contract: the codex startup-dialog block in
# bin/ac-spawn.sh). Counting the enters that precede the kickoff line is what
# distinguishes "answered the dialog first" from "typed into it".

enters_before_kickoff() {
  awk '/pane send-text/ && /crewmate\. Read and follow/ { exit }
       /pane send-keys/ && /enter/ { n++ }
       END { print n + 0 }' "$FAKE_HERDR/log"
}

: >"$FAKE_HERDR/log"
"$BIN/ac-brief.sh" cx1 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" cx1 "$repo" --harness codex --mode local-only >/dev/null 2>&1
assert_eq "$(enters_before_kickoff)" "2" \
  "codex gets a bare Enter (the dialog answer) on top of the launch-line submit"
assert_contains "$(cat "$(fake_pane_buf cx1)")" \
  "You are an agent-crew crewmate. Read and follow the brief" "codex still gets its kickoff"
"$BIN/ac-teardown.sh" cx1 --force >/dev/null 2>&1

: >"$FAKE_HERDR/log"
"$BIN/ac-brief.sh" cl1 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" cl1 "$repo" --harness claude --mode local-only >/dev/null 2>&1
assert_eq "$(enters_before_kickoff)" "1" \
  "no other harness gets the codex dialog answer - only the launch-line submit precedes its kickoff"
"$BIN/ac-teardown.sh" cl1 --force >/dev/null 2>&1

# --- the dialog answer is covered by the SAME came-up gate --------------------
# The bare Enter is typed BEFORE the gate, so the existing gate - not a third
# probe - is what stands between that keystroke and the kickoff. A pane whose
# harness dies ON the dialog answer must therefore be refused with NOTHING typed
# into the shell it became: that is the invariant the gate exists for.

: >"$FAKE_HERDR/log"
: >"$FAKE_HERDR/.die-on-bare-enter"
"$BIN/ac-brief.sh" cxdead proj --mode local-only >/dev/null
rc=0
err="$("$BIN/ac-spawn.sh" cxdead "$repo" --harness codex --mode local-only 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "a codex pane whose harness died on the dialog answer must FAIL the spawn"
assert_contains "$err" "did NOT come up" "the gate, not the post-kickoff re-check, is what caught it"
assert_contains "$err" "WITHHELD" "the kickoff was withheld from the shell the Enter left behind"
case "$(cat "$FAKE_HERDR/log")" in
  *"You are an agent-crew crewmate. Read and follow"*) fail "the kickoff prompt was typed into a bare shell" ;;
esac
rm -f "$FAKE_HERDR/.die-on-bare-enter"

# --- a CUSTOM launch-codex template gets no borrowed keystroke -----------------
# Launch PROVENANCE decides, not the harness name: a custom template's TUI is
# unknown, so it gets no keystroke borrowed from the built-in codex TUI - the
# same rule the '/effort ultracode' line already follows for launch-claude.

: >"$FAKE_HERDR/log"
printf 'echo crew __ID__ reading __BRIEF__; sleep 300\n' >"$AC_HOME/config/launch-codex"
"$BIN/ac-brief.sh" cx2 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" cx2 "$repo" --harness codex --mode local-only >/dev/null 2>&1
assert_eq "$(enters_before_kickoff)" "1" \
  "a custom launch-codex template gets no dialog answer - only its own launch-line submit"
assert_contains "$(cat "$(fake_pane_buf cx2)")" \
  "You are an agent-crew crewmate. Read and follow the brief" "it still gets its kickoff"
rm -f "$AC_HOME/config/launch-codex"
"$BIN/ac-teardown.sh" cx2 --force >/dev/null 2>&1

# --- a --resume-from whose recorded session id claude no longer knows ---------
# The exact incident this gate exists for (live 2026-07-21, bin/ac-spawn.sh
# header): a recorded session_id claude does not recognise prints "No
# conversation found" and drops the pane to a bare shell. The gate is the SAME
# one asserted above for a generic dead pane - this composes it with
# --resume-from to pin that the resume launch line is covered too, not just a
# fresh spawn.

mkdir -p "$TMP/stub"
printf '#!/usr/bin/env bash\nsleep 300\n' >"$TMP/stub/claude"
chmod +x "$TMP/stub/claude"
export PATH="$TMP/stub:$PATH"

"$BIN/ac-brief.sh" rs1 proj --mode local-only >/dev/null
"$BIN/ac-spawn.sh" rs1 "$repo" --harness claude --mode local-only >/dev/null 2>&1
old_sid="$(awk -F= '$1=="session_id"{print $2}' "$AC_HOME/state/rs1.meta")"
[ -n "$old_sid" ] || fail "setup: claude spawn must record session_id"
"$BIN/ac-teardown.sh" rs1 --force >/dev/null 2>&1

: >"$FAKE_HERDR/.spawn-dead"   # every pane created from here on is a bare shell
: >"$FAKE_HERDR/log"
"$BIN/ac-brief.sh" rs1-r2 proj --mode local-only >/dev/null
rc=0
err="$("$BIN/ac-spawn.sh" rs1-r2 "$repo" --resume-from rs1 --mode local-only 2>&1)" || rc=$?
[ "$rc" != 0 ] || fail "a resume whose session id claude no longer knows must FAIL the spawn"
assert_contains "$err" "did NOT come up" "the resume composition hits the same came-up gate"
assert_contains "$err" "WITHHELD" "the kickoff was withheld, not typed into the shell claude fell back to"
assert_no_file "$AC_HOME/state/rs1-r2.meta" "a refused resume leaves no task in flight"
assert_contains "$(cat "$AC_HOME/state/rs1-r2.status")" "failed:" "the status log records the refusal"
grep -q -- "--resume $old_sid" "$FAKE_HERDR/log" || fail "the resume launch line still carried the recorded (stale) session id"
rm -f "$FAKE_HERDR/.spawn-dead"

pass
