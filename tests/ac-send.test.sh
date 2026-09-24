#!/usr/bin/env bash
# ac-send.test.sh - ac-send.sh delivery integrity: TEXT into a BLOCKED pane is
# refused (--force overrides; --key stays allowed - it IS the deliberate dialog
# answer), and a stranded submit surfaces as a visible failure, never "sent".
# Driven through the fake herdr CLI (tests/helpers.sh): its .status file feeds
# agent_blocked, its .drop-enters knob strands submits.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_herdr
make_home

mk_crewmate() {
  # mk_crewmate <id> <pane> <tab> - a live crewmate: meta + handle + fake pane.
  # Carries NO harness field, so its ARRIVAL is per-harness-UNKNOWN and every
  # confirmed submit below reads the honest `delivered (arrival unverified)
  # to` verb (contract: ac-lib.sh claude transcript arrival check) - the
  # dedicated arrival-check section further down owns the CONFIRMED/REFUTED
  # claude-capable cases via mk_claude_crewmate.
  printf 'backend=herdr\n' >"$AC_HOME/state/$1.meta"
  printf '%s %s\n' "$2" "$3" >"$AC_HOME/state/.pane-$1"
  printf '%s\n' "$2" >"$FAKE_HERDR/tabs/$3"
  : >"$FAKE_HERDR/panes/$2.buf"
}

# --- happy path: text delivered and submit verified --------------------------------

mk_crewmate s1 pA1 tA1
out="$("$BIN/ac-send.sh" s1 'hello crew')"
assert_contains "$out" "delivered (arrival unverified) to herdr:pane-pA1" \
  "a target with no arrival capability still reports the target, honestly"
assert_contains "$(cat "$FAKE_HERDR/panes/pA1.buf")" "hello crew" "text submitted into the pane"
# A CONFIRMED steer is recorded durably - the chief's index of what it asked,
# so a restart is not amnesia (the crewmate leg of the deputy routed: rule).
assert_contains "$(cat "$AC_HOME/state/s1.status")" "steered: hello crew" \
  "a confirmed steer lands on the status record"

# --- blocked pane: TEXT refused without --force -------------------------------------

printf 'blocked\n' >"$FAKE_HERDR/panes/pA1.status"
err="$("$BIN/ac-send.sh" s1 'danger text' 2>&1)" \
  && fail "text into a blocked pane must be refused"
assert_contains "$err" "BLOCKED on an interactive prompt" "refusal names the hazard"
assert_contains "$err" "--force" "refusal names the override"
case "$(cat "$FAKE_HERDR/log")" in *"send-text pA1 danger text"*) \
  fail "refused text must never reach the pane" ;; esac

# --- --key stays allowed while blocked (the deliberate dialog answer) ---------------

out="$("$BIN/ac-send.sh" s1 --key Escape)"
assert_contains "$out" "delivered (unverified) to herdr:pane-pA1" \
  "--key answers a blocked pane without --force"
case "$out" in *"sent to"*) \
  fail "a key press is never acknowledged - it must not claim the verified wording" ;; esac
assert_contains "$(cat "$FAKE_HERDR/log")" "pane send-keys pA1 escape" "key delivered"

# --- a captain-wait STAMPED pane accepts the answering text without --force ---------
# The stamp masks the pane view with the fleet's OWN blocked report (contract:
# ac-backend.sh CAPTAIN-WAIT STAMP); the steer that answers it must not be
# refused by that stamp, and a confirmed delivery clears it so herdr's
# detection re-asserts.

mk_crewmate s2 pA2 tA2
printf 'blocked\n' >"$FAKE_HERDR/panes/pA2.reported"
touch "$AC_HOME/state/.captain-wait-s2"
out="$("$BIN/ac-send.sh" s2 'answer: keep the cache')"
assert_contains "$out" "delivered (arrival unverified) to herdr:pane-pA2" "stamped pane accepts the answering steer"
assert_no_file "$AC_HOME/state/.captain-wait-s2" "delivery clears the stamp file"
assert_no_file "$FAKE_HERDR/panes/pA2.reported" "delivery releases the reported state"

# --- dead pane: the harness exited, TEXT would EXECUTE in the bare shell ------------
# window-alive still answers true (the terminal lives, holding a shell), and
# agent_blocked answers false (no dialog) - only the harness-up probe tells a
# live agent composer from a shell prompt that would run the steer as commands.

mk_crewmate s6 pA6 tA6
: >"$FAKE_HERDR/panes/pA6.dead"
err="$("$BIN/ac-send.sh" s6 'summarize the diff' 2>&1)" \
  && fail "text into a dead-shell pane must be refused"
assert_contains "$err" "BARE SHELL" "refusal names the dead-shell hazard"
assert_contains "$err" "--force" "refusal names the override"
case "$(cat "$FAKE_HERDR/log")" in *"send-text pA6"*) \
  fail "refused text must never reach the shell" ;; esac
out="$("$BIN/ac-send.sh" s6 --force 'true')" \
  || fail "--force must still type into the shell deliberately"
assert_contains "$out" "delivered (arrival unverified) to" "--force overrides the dead-shell refusal"

# --- --force sends text into a blocked pane deliberately ----------------------------

out="$("$BIN/ac-send.sh" s1 --force 'deliberate steer')"
assert_contains "$out" "delivered (arrival unverified) to" "--force overrides the refusal"
assert_contains "$(cat "$FAKE_HERDR/panes/pA1.buf")" "deliberate steer" "--force text delivered"

# --- one dropped Enter: focused retry lands, success stays honest -------------------

mk_crewmate s2 pA2 tA2
printf '1\n' >"$FAKE_HERDR/panes/pA2.drop-enters"
out="$("$BIN/ac-send.sh" s2 'retry me')"
assert_contains "$out" "delivered (arrival unverified) to" "recovered strand still reports success"
assert_contains "$(cat "$FAKE_HERDR/log")" "tab focus tA2" "strand focuses the tab before the retry"
assert_contains "$(cat "$FAKE_HERDR/panes/pA2.buf")" "retry me" "retried text delivered"

# --- strand never resolved: visible FAILURE, never a false "sent" -------------------

mk_crewmate s3 pA3 tA3
printf '99\n' >"$FAKE_HERDR/panes/pA3.drop-enters"
err="$("$BIN/ac-send.sh" s3 'lost steer' 2>&1)" \
  && fail "a stranded send must exit non-zero"
assert_contains "$err" "not acknowledged" "backend strand reason surfaces"
assert_contains "$err" "delivery NOT confirmed" "ac-send names the failure"
case "$err" in *"sent to"*) fail "a stranded send must not print sent" ;; esac
assert_contains "$(cat "$FAKE_HERDR/panes/pA3.in")" "lost steer" "text sits in the composer, reported honestly"
case "$(cat "$AC_HOME/state/s3.status" 2>/dev/null)" in
  *"steered:"*) fail "an UNCONFIRMED steer must not be recorded as steered" ;;
esac

# --- the marked chief-to-deputy channel ---------------------------------------
# A crewdeputy is a chief with its own chat. Without a marker a routed order is
# indistinguishable from the captain typing into that pane, so the deputy cannot
# know its answer is owed to a parent chief that will never read the room.

reg="$AC_HOME/records/crewdeputies.md"
mk_deputy() {
  # mk_deputy <id> <pane> <tab> - a live crewdeputy: home, marker, meta, pane,
  # and its routing-table entry.
  mkdir -p "$AC_HOME/crewdeputies/$1"
  : >"$AC_HOME/crewdeputies/$1/.ac-crewdeputy-home"
  printf 'backend=herdr\nkind=crewdeputy\n' >"$AC_HOME/state/$1.meta"
  printf '%s %s\n' "$2" "$3" >"$AC_HOME/state/.pane-$1"
  printf '%s\n' "$2" >"$FAKE_HERDR/tabs/$3"
  : >"$FAKE_HERDR/panes/$2.buf"
  printf '# Crewdeputies\n\n- %s - payments duty - home: %s/crewdeputies/%s - scope: payments - projects: none (added 2026-07-19T00:00:00Z)\n' \
    "$1" "$AC_HOME" "$1" >"$reg"
}

mk_deputy pay pP1 tP1
out="$("$BIN/ac-send.sh" pay 'fix the interest rounding')"
assert_contains "$out" "delivered (arrival unverified) to herdr:pane-pP1" "a routed order still reports its target"
buf="$(cat "$FAKE_HERDR/panes/pP1.buf")"
assert_contains "$buf" "[chief-order home=$AC_HOME deputy=pay] fix the interest rounding" \
  "a crewdeputy target gets the chief-order marker, order text verbatim after it"
assert_eq "$(grep -c 'chief-order' "$FAKE_HERDR/panes/pP1.buf" | tr -d ' ')" "1" \
  "the marker is applied exactly once"
assert_contains "$(cat "$AC_HOME/state/pay.status")" "routed: fix the interest rounding" \
  "a confirmed marked send records what was asked, so a restart is not amnesia"

# --key is a deliberate dialog answer, never an order - it carries no marker.
"$BIN/ac-send.sh" pay --key Escape >/dev/null
assert_eq "$(grep -c 'chief-order' "$FAKE_HERDR/panes/pP1.buf" | tr -d ' ')" "1" "--key adds no marker"

# Every other kind is byte-unchanged: a marker leaking into ordinary crewmate
# steering would tell a crewmate to answer on a channel it does not own.
for k in ship scout roomchief; do
  mk_crewmate "k$k" "p$k" "t$k"
  printf 'backend=herdr\nkind=%s\n' "$k" >"$AC_HOME/state/k$k.meta"
  "$BIN/ac-send.sh" "k$k" "steer the $k" >/dev/null
  case "$(cat "$FAKE_HERDR/panes/p$k.buf")" in
    *chief-order*) fail "kind=$k must never carry the chief-order marker" ;;
  esac
  # The marker channel stays deputy-only; the durable record every kind DOES
  # get is the plain steered: line, never routed:.
  case "$(cat "$AC_HOME/state/k$k.status" 2>/dev/null)" in
    *routed:*) fail "kind=$k records no routed: line" ;;
  esac
  assert_contains "$(cat "$AC_HOME/state/k$k.status")" "steered: steer the $k" \
    "kind=$k still gets the durable steered: record"
done

# Refusal: no parseable registry entry - the answer would have nowhere to land.
printf '# Crewdeputies\n\n' >"$reg"
err="$("$BIN/ac-send.sh" pay 'route me' 2>&1)" && fail "a deputy with no registry entry must be refused"
assert_contains "$err" "no parseable entry" "the refusal names the missing registry entry"
case "$(cat "$FAKE_HERDR/panes/pP1.buf")" in *"route me"*) fail "a refused order must never reach the pane" ;; esac

# Refusal: the entry parses but the home is gone on disk.
mk_deputy pay pP1 tP1
rm -rf "$AC_HOME/crewdeputies/pay"
err="$("$BIN/ac-send.sh" pay 'route me' 2>&1)" && fail "a deputy whose home is gone must be refused"
assert_contains "$err" "home is gone" "the refusal names the missing home"
case "$(cat "$FAKE_HERDR/panes/pP1.buf")" in *"route me"*) fail "a refused order must never reach the pane" ;; esac

# --- the crewmate path stays crewmate-addressed -------------------------------
# Steering a PANE AGENT (ship reviewer / qa / learning scout) is a different
# verb in a different script - bin/ac-pane-agent.sh steer, keyed on the pane
# label herdr holds, since a pane agent has no crewmate meta at all. ac-send.sh
# grew no branch for it: its no-meta refusal must still fire on a pane-agent
# handle, or an unknown id would have found a second, unguarded route to a pane.

err="$("$BIN/ac-send.sh" 'ac-codereview-agent:ship-review-r1' 'hello' 2>&1)" \
  && fail "ac-send must not resolve a pane-agent handle"
assert_contains "$err" "no crewmate meta" "the crewmate refusal still fires for a non-crewmate id"

# --- the WRITE-SIDE marker guard ----------------------------------------------
# A chief instructing a crewmate ABOUT the marker protocol types a bare marker
# verb into that pane; the watcher greps the pane TAIL, so the chief false-wakes
# ITSELF with its own words. ac-send warns and DELIVERS - steer text may
# legitimately quote a marker, so this is a footgun warning, never a policy.

mk_crewmate g1 pG1 tG1
err="$("$BIN/ac-send.sh" g1 'when you finish, print done: with a one-line summary' 2>&1 >/dev/null)"
assert_contains "$err" "done:" "the warning names the offending token"
assert_contains "$err" '`done:`' "the warning suggests the backtick-wrapped form"
assert_contains "$(cat "$FAKE_HERDR/panes/pG1.buf")" \
  "print done: with a one-line summary" "warned text is delivered verbatim anyway"

# Exit status is UNCHANGED by the warning, and stdout still reports the target.
out="$("$BIN/ac-send.sh" g1 'and blocked: means the captain, not me' 2>/dev/null)" \
  || fail "the warning must not change the exit status"
assert_contains "$out" "delivered (arrival unverified) to herdr:pane-pG1" "a warned send still reports its target"

# The backtick-wrapped form IS the suggested fix - warning on it would be noise.
err="$("$BIN/ac-send.sh" g1 'print `done:` when you finish' 2>&1 >/dev/null)"
case "$err" in *warning*) fail "the backtick-wrapped token must not warn" ;; esac
err="$("$BIN/ac-send.sh" g1 'that is a real needs-decision for the captain' 2>&1 >/dev/null)"
case "$err" in *warning*) fail "dropping the colon must not warn" ;; esac

# The detector itself: reusable by any writer (text in, offending tokens out,
# exit 1 when the text is clean) - ac-room.sh post must be able to call it as is.
. "$BIN/ac-lib.sh"
assert_eq "$(ac_bare_marker_verbs 'print done: or blocked: when you stop' | tr '\n' ' ')" \
  "done: blocked: " "the detector names every offending token, in order"
assert_fails ac_bare_marker_verbs 'nothing to see here, all done'

# --- an unreadable BACKEND is not a gone window -------------------------------------
# Contract: ac-backend.sh WINDOW LIVENESS. Both entrypoints refuse on the same
# one-line liveness guard, and during the 2026-07-25 herdr protocol mismatch both
# told the chief `window gone for <id>` about panes that were demonstrably alive -
# the sentence a chief reads as "my crewmate died". ac-peek.sh has no test file of
# its own; its half of the shared guard is asserted here beside ac-send's.
mk_crewmate u1 pU1 tU1
touch "$FAKE_HERDR/.unreachable"
err="$("$BIN/ac-send.sh" u1 'still there?' 2>&1)" && fail "send must still refuse an unreadable backend"
assert_contains "$err" "u1" "the send refusal names the id"
assert_contains "$err" "backend" "the send refusal blames the BACKEND, not the pane"
case "$err" in *"window gone"*) fail "an unreadable backend must never be called a gone window" ;; esac
err="$("$BIN/ac-peek.sh" u1 2>&1)" && fail "peek must still refuse an unreadable backend"
assert_contains "$err" "backend" "the peek refusal blames the BACKEND, not the pane"
case "$err" in *"window gone"*) fail "peek must not call an unreadable backend a gone window" ;; esac
rm -f "$FAKE_HERDR/.unreachable"

# A REAL gone window keeps the wording (and the exit status) both callers had.
rm -f "$FAKE_HERDR/panes/pU1.buf" "$FAKE_HERDR/tabs/tU1"
err="$("$BIN/ac-send.sh" u1 'anyone home?' 2>&1)" && fail "send still refuses a gone window"
assert_contains "$err" "window gone for u1" "a real gone window is reported exactly as before"
err="$("$BIN/ac-peek.sh" u1 2>&1)" && fail "peek still refuses a gone window"
assert_contains "$err" "window gone for u1" "peek reports a real gone window exactly as before"

# --- exit 127 (a driver failed to LOAD) is UNOBSERVABLE, never gone ------------------
# Contract: ac-backend.sh WINDOW LIVENESS is THREE-STATE (0 alive / 1 gone /
# 2 unobservable); backend_window_alive_herdr never returns anything else, but
# ac_backend_route's PER-CALL dispatch ("backend_${fn}_herdr") means a driver
# function that failed to load - the exact production shape, not a hand-picked
# sentinel - makes bash itself return 127 (command not found) from the very
# call being classified. A case that enumerates 2 and defaults everything else
# to gone reads that load failure as a dead pane.
make_loadfail_bin
mk_crewmate lf1 pLF1 tLF1
err="$("$LOADFAIL_BIN/ac-send.sh" lf1 'still there?' 2>&1)" \
  && fail "send must refuse when the backend driver fails to load"
assert_contains "$err" "lf1" "the send refusal names the id"
assert_contains "$err" "backend" "a 127 (driver load failure) must blame the BACKEND, not the pane"
case "$err" in *"window gone"*) \
  fail "THE REGRESSION: exit 127 (loadable-driver failure) must never read as a gone window" ;; esac
err="$("$LOADFAIL_BIN/ac-peek.sh" lf1 2>&1)" \
  && fail "peek must refuse when the backend driver fails to load"
assert_contains "$err" "backend" "peek's 127 refusal blames the BACKEND, not the pane"
case "$err" in *"window gone"*) \
  fail "THE REGRESSION: peek must never call exit 127 a gone window" ;; esac

# --- F13: peek must not re-emit a raw captain marker into the caller's pane ---
# A crewmate's own captain-marker line, captured verbatim in its pane tail,
# must not land at column 0 of whatever pane is running ac-peek.sh (a
# roomchief peeking a needs-decision crewmate would false-wake its own
# fleet-watched chief pane). Asserted against the LIVE AC_CAPTAIN_RE, not a
# hardcoded copy.
mk_crewmate v1 pV1 tV1
printf 'needs-decision: which prefix should I use?\n' >"$FAKE_HERDR/panes/pV1.buf"
out="$("$BIN/ac-peek.sh" v1)"
. "$BIN/ac-lib.sh"
case "$out" in *"needs-decision: which prefix"*) ;; *) fail "the marker text itself must survive, only its column-0 position is neutralized: $out" ;; esac
if grep -qE "$AC_CAPTAIN_RE" <<<"$out"; then
  fail "ac-peek.sh must not re-emit a line matching the LIVE AC_CAPTAIN_RE: $out"
fi

# --- ARRIVAL: a claude-capable target, CONFIRMED vs REFUTED ------------------
# Contract: ac-lib.sh claude transcript arrival check. A confirmed SUBMIT
# above (every case so far) is not a confirmed ARRIVAL; a target this fleet
# CAN check (claude, with a resolvable session transcript) is held to the
# stricter bar - the measured incident this family exists to kill.

mk_claude_crewmate() {
  # mk_claude_crewmate <id> <pane> <tab> <session-id> - a live crewmate whose
  # harness/session_id make it ARRIVAL-CAPABLE (contract above).
  mk_crewmate "$1" "$2" "$3"
  printf 'harness=claude\nsession_id=%s\n' "$4" >>"$AC_HOME/state/$1.meta"
}

mk_turn() {
  # mk_turn <session-id> <content> - one typed-human-turn transcript file
  # under the isolated AC_CLAUDE_TRANSCRIPT_ROOT (tests/helpers.sh), the
  # shape verified against a live transcript (tests/ac-arrival.test.sh owns
  # that contract).
  mkdir -p "$AC_CLAUDE_TRANSCRIPT_ROOT/proj"
  printf '{"type":"user","promptSource":"typed","origin":{"kind":"human"},"message":{"role":"user","content":%s}}\n' \
    "$(printf '%s' "$2" | jq -Rs .)" >"$AC_CLAUDE_TRANSCRIPT_ROOT/proj/$1.jsonl"
}

sid_ok="cccccccc-cccc-cccc-cccc-cccccccccccc"
mk_claude_crewmate cok pCOK tCOK "$sid_ok"
mk_turn "$sid_ok" "confirmed steer text"
out="$("$BIN/ac-send.sh" cok 'confirmed steer text')"
assert_contains "$out" "sent to herdr:pane-pCOK" \
  "CONFIRMED arrival keeps the honest 'sent to' wording unchanged (A4, no regression)"
assert_contains "$(cat "$AC_HOME/state/cok.status")" "steered: confirmed steer text" \
  "a CONFIRMED steer still lands on the status record"

sid_bad="dddddddd-dddd-dddd-dddd-dddddddddddd"
mk_claude_crewmate cbad pCBAD tCBAD "$sid_bad"
mk_turn "$sid_bad" "something else entirely arrived"
err="$("$BIN/ac-send.sh" cbad 'the text that was actually sent' 2>&1)" \
  && fail "REFUTED arrival must be refused - a text that arrived WRONG is worse than one that never arrived"
assert_contains "$err" "arrival REFUTED" "the refusal names the fact - arrival, not submit"
case "$err" in *"sent to"*) fail "THE REGRESSION THIS CLOSES: a REFUTED arrival must never print sent to" ;; esac
case "$(cat "$AC_HOME/state/cbad.status" 2>/dev/null)" in
  *"steered:"*) fail "a REFUTED steer must not be recorded as steered - it did not land as asked" ;;
esac

# --- a REFUTED arrival SAYS WHAT ARRIVED -------------------------------------
# MEASURED over five consecutive steers into one claude pane: 4700 chars
# arrived as 482, 1900 as 158, 1100 as 203, 2000 as 883 - the four that were
# REFUTED, against one 1700-char send that arrived whole and passed. The
# surviving fragment is the TAIL and it starts mid-word, so a chief peeking the
# pane after a REFUTED send sees text that looks exactly like a successful
# delivery, and three peeks in that run were read as proof of landing. The
# verdict was right every time; what it did not say is what actually landed.
sid_cut="eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee"
mk_claude_crewmate ccut pCCUT tCCUT "$sid_cut"
sent_head="Read the three findings in data/fam/room.md before you touch the fixer, and"
sent_tail=" then run the suite once more and report what changed."
mk_turn "$sid_cut" "$sent_tail"
err="$("$BIN/ac-send.sh" ccut "$sent_head$sent_tail" 2>&1)" \
  && fail "a truncated arrival must still be refused"
assert_contains "$err" "arrival REFUTED" "the verdict is unchanged"
assert_contains "$err" "TRUNCATED" \
  "...and it names the SHAPE: what arrived is the tail of what was sent, with the head cut"
assert_contains "$err" "$(printf '%s' "$sent_head$sent_tail" | wc -c | tr -d ' ')" \
  "the refusal gives the sent size, so the reader can judge without peeking"

# Two edges the shape test must survive: a steer that ENDS IN A NEWLINE
# (the transcript reader strips it from what arrived, so the raw suffix test
# would call a truncation "a DIFFERENT text"), and a non-ASCII steer, whose
# sizes must be characters - a byte count of a Vietnamese line runs ~20% high.
sid_nl="abababab-abab-abab-abab-abababababab"
mk_claude_crewmate cnl pCNL tCNL "$sid_nl"
nl_head="Đọc ba finding trong room trước, rồi"
nl_tail=" chạy lại suite và báo cáo"
mk_turn "$sid_nl" "$nl_tail"
err="$("$BIN/ac-send.sh" cnl "$nl_head$nl_tail
" 2>&1)" && fail "a truncated newline-terminated arrival must still be refused"
assert_contains "$err" "TRUNCATED" "a trailing newline on the sent text does not turn a truncation into a different text"
assert_contains "$err" "sent $(printf '%s' "$nl_head$nl_tail" | wc -m | tr -d ' ') chars" \
  "the sent size is counted in characters, not bytes"

# A genuinely DIFFERENT arrival is not a truncation and must not be described
# as one - a wrong message and a cut message need different next moves.
sid_other="ffffffff-ffff-ffff-ffff-ffffffffffff"
mk_claude_crewmate cother pCOTH tCOTH "$sid_other"
mk_turn "$sid_other" "a completely unrelated line"
err="$("$BIN/ac-send.sh" cother 'the text that was actually sent' 2>&1)" \
  && fail "a wrong arrival must still be refused"
assert_contains "$err" "arrival REFUTED" "the verdict is unchanged for a wrong arrival too"
case "$err" in *TRUNCATED*) fail "an unrelated arrival must not be reported as a truncation" ;; esac

# A SOLO session (AC_SOLO=1) never steers a pane - the crew is the chief's.
err="$(AC_SOLO=1 "$BIN/ac-send.sh" cother 'hello' 2>&1)" \
  && fail "a solo session's send must refuse"
assert_contains "$err" "solo session (AC_SOLO=1)" "the refusal names the solo session"

pass
