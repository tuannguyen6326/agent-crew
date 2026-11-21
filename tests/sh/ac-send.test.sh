#!/usr/bin/env bash
# ac-send.test.sh - ac-send.sh delivery integrity: TEXT into a BLOCKED pane is
# refused (--force overrides; --key stays allowed - it IS the deliberate dialog
# answer), and a stranded submit surfaces as a visible failure, never "sent".
# Driven through the fake orca CLI (tests/sh/helpers.sh): its .agentwait knob
# feeds agent_blocked, its .drop-enters knob strands submits. The cutover
# (T8) refuses backend=herdr outright - the one herdr-pinned case below
# proves that refusal fires before any send is attempted.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_fake_orca
make_home

mk_crewmate() {
  # mk_crewmate <id> <handle> [<tab>] - a live crewmate: meta + handle + fake
  # terminal. Carries NO harness field, so its ARRIVAL is per-harness-UNKNOWN
  # and every confirmed submit below reads the honest `delivered (arrival
  # unverified) to` verb (contract: ac-lib.sh claude transcript arrival
  # check) - the dedicated arrival-check section further down owns the
  # CONFIRMED/REFUTED claude-capable cases via mk_claude_crewmate.
  printf 'backend=orca\n' >"$AC_HOME/state/$1.meta"
  printf '%s %s\n' "$2" "${3:-tab-$2}" >"$AC_HOME/state/.pane-$1"
  : >"$FAKE_ORCA/terminals/$2.buf"
}

# --- happy path: text delivered and submit verified --------------------------------

mk_crewmate s1 pA1
out="$("$BIN/ac-send.sh" s1 'hello crew')"
assert_contains "$out" "delivered (arrival unverified) to orca:pA1" \
  "a target with no arrival capability still reports the target, honestly"
assert_contains "$(cat "$FAKE_ORCA/terminals/pA1.buf")" "hello crew" "text submitted into the pane"
# A CONFIRMED steer is recorded durably - the chief's index of what it asked,
# so a restart is not amnesia (the crewmate leg of the deputy routed: rule).
assert_contains "$(cat "$AC_HOME/state/s1.status")" "steered: hello crew" \
  "a confirmed steer lands on the status record"

# --- cutover (T8): backend=herdr refuses before any send is attempted --------------
mk_crewmate hv pHV
sed -i '' 's/^backend=orca$/backend=herdr/' "$AC_HOME/state/hv.meta"
err="$("$BIN/ac-send.sh" hv 'should never arrive' 2>&1)" \
  && fail "a herdr-pinned meta must be refused, never silently re-routed to orca"
assert_eq "$err" "ERROR: unsupported backend 'herdr' (valid backend: orca)" \
  "the exact cutover error, nothing else"
assert_eq "$(cat "$FAKE_ORCA/terminals/pHV.buf")" "" "nothing reached the pane - refused before any side effect"
assert_no_file "$AC_HOME/state/hv.status" "nothing was recorded either"

# --- blocked pane: TEXT refused without --force -------------------------------------

touch "$FAKE_ORCA/terminals/pA1.agentwait"
err="$("$BIN/ac-send.sh" s1 'danger text' 2>&1)" \
  && fail "text into a blocked pane must be refused"
assert_contains "$err" "BLOCKED on an interactive prompt" "refusal names the hazard"
assert_contains "$err" "--force" "refusal names the override"
case "$(cat "$FAKE_ORCA/log")" in *"--text danger text"*) \
  fail "refused text must never reach the pane" ;; esac

# --- --key stays allowed while blocked (the deliberate dialog answer) ---------------

out="$("$BIN/ac-send.sh" s1 --key Escape)"
assert_contains "$out" "delivered (unverified) to orca:pA1" \
  "--key answers a blocked pane without --force"
case "$out" in *"sent to"*) \
  fail "a key press is never acknowledged - it must not claim the verified wording" ;; esac
esc="$(printf '\033')"
case "$(cat "$FAKE_ORCA/terminals/pA1.in")" in *"$esc"*) ;; *) fail "key delivered" ;; esac
: >"$FAKE_ORCA/terminals/pA1.in"
rm -f "$FAKE_ORCA/terminals/pA1.agentwait"

# --- a captain-wait STAMPED pane accepts the answering text without --force ---------
# The stamp masks agent_blocked's PRE-FLIGHT guard (contract: ac-backend.sh
# CAPTAIN-WAIT STAMP) so the steer that answers it is not refused before it
# even tries; a confirmed delivery clears it. Unlike herdr (whose own
# blocked-status read and its submit-time render check are independent),
# orca's submit-time dialog guard (orca_pane_dialog) reads the SAME
# agentWait field agent_blocked masks and is never maskable by the stamp -
# so this fixture, like the live case it models, has no dialog pending by
# submit time; only the PRE-FLIGHT guard is under test here.

mk_crewmate s2 pA2
touch "$AC_HOME/state/.captain-wait-s2"
out="$("$BIN/ac-send.sh" s2 'answer: keep the cache')"
assert_contains "$out" "delivered (arrival unverified) to orca:pA2" "stamped pane accepts the answering steer"
assert_no_file "$AC_HOME/state/.captain-wait-s2" "delivery clears the stamp file"

# A slash command answers nothing, so /compact typed into a stamped pane leaves
# the stamp for the steer that does answer the captain's pending item.
mk_crewmate s2b pA2b
touch "$AC_HOME/state/.captain-wait-s2b"
"$BIN/ac-send.sh" s2b /compact >/dev/null || fail "a slash command into a stamped pane must be delivered"
assert_file "$AC_HOME/state/.captain-wait-s2b" "a slash command leaves the captain-wait stamp standing"

# --- REWAKE LATCH (watch.ts header): a delivered non-slash steer clears it --------
# too, the same transition and the same site as the ENDED BUSY LATCH clear
# above - a steered gate round answered and re-printed inside one AC_POLL
# interval never crosses a busy sample, so it must not wait on one either.
mk_crewmate s2c pA2c
touch "$AC_HOME/state/.rewake-s2c"
"$BIN/ac-send.sh" s2c 'keep going' >/dev/null
assert_no_file "$AC_HOME/state/.rewake-s2c" "a delivered non-slash steer clears the re-wake latch too"

mk_crewmate s2d pA2d
touch "$AC_HOME/state/.rewake-s2d"
"$BIN/ac-send.sh" s2d /compact >/dev/null || fail "a slash command must still be delivered"
assert_file "$AC_HOME/state/.rewake-s2d" "a slash command leaves the re-wake latch standing, same as the captain-wait stamp"

# --- dead pane: the harness exited, TEXT would EXECUTE in the bare shell ------------
# window-alive still answers true (the terminal lives, holding a shell), and
# agent_blocked answers false (no dialog) - only the harness-up probe tells a
# live agent composer from a shell prompt that would run the steer as
# commands. No title at all (every OTHER crewmate here) is UNOBSERVABLE
# (2), not a shell - harness_up_orca only proves SHELL (1) off an explicit
# shell-named title, so this is the one case that needs it.

mk_crewmate s6 pA6
printf 'zsh\n' >"$FAKE_ORCA/terminals/pA6.title"
err="$("$BIN/ac-send.sh" s6 'summarize the diff' 2>&1)" \
  && fail "text into a dead-shell pane must be refused"
assert_contains "$err" "BARE SHELL" "refusal names the dead-shell hazard"
assert_contains "$err" "--force" "refusal names the override"
case "$(cat "$FAKE_ORCA/log")" in *"--text summarize"*) \
  fail "refused text must never reach the shell" ;; esac
out="$("$BIN/ac-send.sh" s6 --force 'true')" \
  || fail "--force must still type into the shell deliberately"
assert_contains "$out" "delivered (arrival unverified) to" "--force overrides the dead-shell refusal"

# --force overriding a genuinely blocked-but-not-dialog pane has no orca
# equivalent to test here: orca's agentWait is the ONE field both
# agent_blocked's pre-check and the submit's own dialog guard read, so
# --force bypassing only the pre-check still meets the submit's guard
# (section 10, V16, already proves "--force meets the dialog guard" for
# orca) - unlike herdr, where the pre-check and the submit's render-change
# verification are independent signals.

# --- one dropped Enter: the retry Enter lands, success stays honest ------------------

mk_crewmate s2 pA2
printf '1\n' >"$FAKE_ORCA/terminals/pA2.drop-enters"
out="$("$BIN/ac-send.sh" s2 'retry me')"
assert_contains "$out" "delivered (arrival unverified) to" "recovered strand still reports success"
assert_contains "$(cat "$FAKE_ORCA/log")" "terminal send --terminal pA2 --enter --json" "a text left pending earns a bare retry Enter"
assert_contains "$(cat "$FAKE_ORCA/terminals/pA2.buf")" "retry me" "retried text delivered"

# --- strand never resolved: visible FAILURE, never a false "sent" -------------------

mk_crewmate s3 pA3
printf '99\n' >"$FAKE_ORCA/terminals/pA3.drop-enters"
err="$("$BIN/ac-send.sh" s3 'lost steer' 2>&1)" \
  && fail "a stranded send must exit non-zero"
assert_contains "$err" "not acknowledged" "backend strand reason surfaces"
assert_contains "$err" "delivery NOT confirmed" "ac-send names the failure"
case "$err" in *"sent to"*) fail "a stranded send must not print sent" ;; esac
assert_contains "$(cat "$FAKE_ORCA/terminals/pA3.in")" "lost steer" "text sits in the composer, reported honestly"
case "$(cat "$AC_HOME/state/s3.status" 2>/dev/null)" in
  *"steered:"*) fail "an UNCONFIRMED steer must not be recorded as steered" ;;
esac

# --- the marked chief-to-deputy channel ---------------------------------------
# A crewdeputy is a chief with its own chat. Without a marker a routed order is
# indistinguishable from the captain typing into that pane, so the deputy cannot
# know its answer is owed to a parent chief that will never read the room.

reg="$AC_HOME/records/crewdeputies.md"
mk_deputy() {
  # mk_deputy <id> <handle> - a live crewdeputy: home, marker, meta, pane,
  # and its routing-table entry.
  mkdir -p "$AC_HOME/crewdeputies/$1"
  : >"$AC_HOME/crewdeputies/$1/.ac-crewdeputy-home"
  printf 'backend=orca\nkind=crewdeputy\n' >"$AC_HOME/state/$1.meta"
  printf '%s %s\n' "$2" "tab-$2" >"$AC_HOME/state/.pane-$1"
  : >"$FAKE_ORCA/terminals/$2.buf"
  printf '# Crewdeputies\n\n- %s - payments duty - home: %s/crewdeputies/%s - scope: payments - projects: none (added 2026-07-19T00:00:00Z)\n' \
    "$1" "$AC_HOME" "$1" >"$reg"
}

mk_deputy pay pP1
out="$("$BIN/ac-send.sh" pay 'fix the interest rounding')"
assert_contains "$out" "delivered (arrival unverified) to orca:pP1" "a routed order still reports its target"
buf="$(cat "$FAKE_ORCA/terminals/pP1.buf")"
assert_contains "$buf" "[chief-order home=$AC_HOME deputy=pay] fix the interest rounding" \
  "a crewdeputy target gets the chief-order marker, order text verbatim after it"
assert_eq "$(grep -c 'chief-order' "$FAKE_ORCA/terminals/pP1.buf" | tr -d ' ')" "1" \
  "the marker is applied exactly once"
assert_contains "$(cat "$AC_HOME/state/pay.status")" "routed: fix the interest rounding" \
  "a confirmed marked send records what was asked, so a restart is not amnesia"

# --key is a deliberate dialog answer, never an order - it carries no marker.
"$BIN/ac-send.sh" pay --key Escape >/dev/null
assert_eq "$(grep -c 'chief-order' "$FAKE_ORCA/terminals/pP1.buf" | tr -d ' ')" "1" "--key adds no marker"
: >"$FAKE_ORCA/terminals/pP1.in"

# An order that merely starts with /word is typed behind the marker, so it is an
# ordinary typed line that answers the deputy's captain-wait.
touch "$AC_HOME/state/.captain-wait-pay"
"$BIN/ac-send.sh" pay '/review the ledger diff' >/dev/null
assert_no_file "$AC_HOME/state/.captain-wait-pay" "a marked order starting with /word still clears the stamp"
# A multi-line order is ONE status event: unflattened, its later lines carry no
# timestamp and the last one reads as the deputy's current status.
"$BIN/ac-send.sh" pay "$(printf 'reconcile the ledger\nthen report back')" >/dev/null
assert_eq "$(tail -n 1 "$AC_HOME/state/pay.status" | sed 's/^[^ ]* //')" "routed: reconcile the ledger then report back" \
  "a multi-line routed order is recorded as one line"

# Every other kind is byte-unchanged: a marker leaking into ordinary crewmate
# steering would tell a crewmate to answer on a channel it does not own.
for k in ship scout roomchief; do
  mk_crewmate "k$k" "p$k"
  printf 'backend=orca\nkind=%s\n' "$k" >"$AC_HOME/state/k$k.meta"
  "$BIN/ac-send.sh" "k$k" "steer the $k" >/dev/null
  case "$(cat "$FAKE_ORCA/terminals/p$k.buf")" in
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
case "$(cat "$FAKE_ORCA/terminals/pP1.buf")" in *"route me"*) fail "a refused order must never reach the pane" ;; esac

# Refusal: the entry parses but the home is gone on disk.
mk_deputy pay pP1
rm -rf "$AC_HOME/crewdeputies/pay"
err="$("$BIN/ac-send.sh" pay 'route me' 2>&1)" && fail "a deputy whose home is gone must be refused"
assert_contains "$err" "home is gone" "the refusal names the missing home"
case "$(cat "$FAKE_ORCA/terminals/pP1.buf")" in *"route me"*) fail "a refused order must never reach the pane" ;; esac

# --- the crewmate path stays crewmate-addressed -------------------------------
# Steering a PANE AGENT (ship reviewer / qa / learning scout) is a different
# verb in a different script - bin/ac-pane-agent.sh steer, keyed on the pane
# label the backend holds, since a pane agent has no crewmate meta at all.
# ac-send.sh grew no branch for it: its no-meta refusal must still fire on a
# pane-agent handle, or an unknown id would have found a second, unguarded
# route to a pane.

err="$("$BIN/ac-send.sh" 'ac-codereview-agent:ship-review-r1' 'hello' 2>&1)" \
  && fail "ac-send must not resolve a pane-agent handle"
assert_contains "$err" "no crewmate meta" "the crewmate refusal still fires for a non-crewmate id"

# --- the WRITE-SIDE marker guard ----------------------------------------------
# A chief instructing a crewmate ABOUT the marker protocol types a bare marker
# verb into that pane; the watcher greps the pane TAIL, so the chief false-wakes
# ITSELF with its own words. ac-send warns and DELIVERS - steer text may
# legitimately quote a marker, so this is a footgun warning, never a policy.

mk_crewmate g1 pG1
err="$("$BIN/ac-send.sh" g1 'when you finish, print done: with a one-line summary' 2>&1 >/dev/null)"
assert_contains "$err" "done:" "the warning names the offending token"
assert_contains "$err" '`done:`' "the warning suggests the backtick-wrapped form"
assert_contains "$(cat "$FAKE_ORCA/terminals/pG1.buf")" \
  "print done: with a one-line summary" "warned text is delivered verbatim anyway"

# Exit status is UNCHANGED by the warning, and stdout still reports the target.
out="$("$BIN/ac-send.sh" g1 'and blocked: means the captain, not me' 2>/dev/null)" \
  || fail "the warning must not change the exit status"
assert_contains "$out" "delivered (arrival unverified) to orca:pG1" "a warned send still reports its target"

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
# the sentence a chief reads as "my crewmate died". ac-peek.sh's half of the
# shared guard is asserted here beside ac-send's (tests/sh/ac-peek.test.sh owns
# the rest of peek).
mk_crewmate u1 pU1
touch "$FAKE_ORCA/.unreachable"
err="$("$BIN/ac-send.sh" u1 'still there?' 2>&1)" && fail "send must still refuse an unreadable backend"
assert_contains "$err" "u1" "the send refusal names the id"
assert_contains "$err" "backend" "the send refusal blames the BACKEND, not the pane"
case "$err" in *"window gone"*) fail "an unreadable backend must never be called a gone window" ;; esac
err="$("$BIN/ac-peek.sh" u1 2>&1)" && fail "peek must still refuse an unreadable backend"
assert_contains "$err" "backend" "the peek refusal blames the BACKEND, not the pane"
case "$err" in *"window gone"*) fail "peek must not call an unreadable backend a gone window" ;; esac
rm -f "$FAKE_ORCA/.unreachable"

# A REAL gone window keeps the wording (and the exit status) both callers had.
rm -f "$FAKE_ORCA/terminals/pU1".*
err="$("$BIN/ac-send.sh" u1 'anyone home?' 2>&1)" && fail "send still refuses a gone window"
assert_contains "$err" "window gone for u1" "a real gone window is reported exactly as before"
err="$("$BIN/ac-peek.sh" u1 2>&1)" && fail "peek still refuses a gone window"
assert_contains "$err" "window gone for u1" "peek reports a real gone window exactly as before"

# --- a backend that cannot be READ at all is UNOBSERVABLE, never gone ----------------
# Contract: ac-backend.sh WINDOW LIVENESS is THREE-STATE (0 alive / 1 gone /
# 2 unobservable), and a case that enumerates 2 and defaults everything else to
# gone reads any other failure as a dead pane. These rows once drove a driver
# that failed to LOAD (bash's 127, through a lab bin/ with the herdr driver
# renamed); both entries' backend verbs are native now (src/lib.ts
# backendCall), so no driver can fail to load under them, and the rows reach
# the same unobservable read with orca absent from PATH (the liveness
# ladder's 2).
mk_crewmate lf1 pLF1
nh_path="$(dirname "$(command -v bun)"):/usr/bin:/bin:/usr/sbin:/sbin"
if [ -z "$(PATH="$nh_path" command -v orca || true)" ]; then
  err="$(PATH="$nh_path" "$BIN/ac-send.sh" lf1 'still there?' 2>&1)" \
    && fail "send must refuse when orca cannot be run"
  assert_contains "$err" "lf1" "the send refusal names the id"
  assert_contains "$err" "backend" "send's refusal of an unrunnable orca blames the BACKEND, not the pane"
  case "$err" in *"window gone"*) \
    fail "THE REGRESSION: send must never call an unobservable backend a gone window" ;; esac
  err="$(PATH="$nh_path" "$BIN/ac-peek.sh" lf1 2>&1)" \
    && fail "peek must refuse when orca cannot be run"
  assert_contains "$err" "backend" "peek's refusal of an unrunnable orca blames the BACKEND, not the pane"
  case "$err" in *"window gone"*) \
    fail "THE REGRESSION: peek must never call an unobservable backend a gone window" ;; esac
else
  printf 'SKIP: send and peek with orca absent - bun shares its directory with an orca on this host\n'
fi

# --- F13: peek must not re-emit a raw captain marker into the caller's pane ---
# A crewmate's own captain-marker line, captured verbatim in its pane tail,
# must not land at column 0 of whatever pane is running ac-peek.sh (a
# roomchief peeking a needs-decision crewmate would false-wake its own
# fleet-watched chief pane). Asserted against the LIVE AC_CAPTAIN_RE, not a
# hardcoded copy.
mk_crewmate v1 pV1
printf 'needs-decision: which prefix should I use?\n' >"$FAKE_ORCA/terminals/pV1.buf"
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
  # harness/session_id make it ARRIVAL-CAPABLE (contract above). The
  # arrival check itself (ac-lib.ts claude transcript arrival check) reads
  # the META's harness=/session_id=, backend-neutral; herdr's own COMPOSER
  # PROOF (keep-tail/draft/nbsp/read-fails below) is a SEPARATE, herdr-only
  # mechanism with no orca counterpart (orca_prompt_send_pane proves no
  # composer content before Enter) - this file's own composer-proof section
  # stays herdr-pinned for that reason, reported as a gap, not ported.
  mk_crewmate "$1" "$2" "$3"
  printf 'harness=claude\nsession_id=%s\n' "$4" >>"$AC_HOME/state/$1.meta"
}

mk_turn() {
  # mk_turn <session-id> <content> - one typed-human-turn transcript file
  # under the isolated AC_CLAUDE_TRANSCRIPT_ROOT (tests/sh/helpers.sh), the
  # shape verified against a live transcript (tests/sh/ac-arrival.test.sh owns
  # that contract).
  mkdir -p "$AC_CLAUDE_TRANSCRIPT_ROOT/proj"
  printf '{"type":"user","promptSource":"typed","origin":{"kind":"human"},"message":{"role":"user","content":%s}}\n' \
    "$(printf '%s' "$2" | jq -Rs .)" >"$AC_CLAUDE_TRANSCRIPT_ROOT/proj/$1.jsonl"
}

sid_ok="cccccccc-cccc-cccc-cccc-cccccccccccc"
mk_claude_crewmate cok pCOK tCOK "$sid_ok"
mk_turn "$sid_ok" "confirmed steer text"
out="$("$BIN/ac-send.sh" cok 'confirmed steer text')"
assert_contains "$out" "sent to orca:pCOK" \
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
# ...and an INTACT newline-terminated steer is delivered, not refused: the
# reader drops the trailing newline from what arrived, so the comparison must
# drop it from what was sent - or the chief is told to resend a message that
# landed whole, and the crewmate gets it twice.
sid_nlok="cdcdcdcd-cdcd-cdcd-cdcd-cdcdcdcdcdcd"
mk_claude_crewmate cnlok pCNLOK tCNLOK "$sid_nlok"
mk_turn "$sid_nlok" "please rerun the suite and report"
out="$("$BIN/ac-send.sh" cnlok "please rerun the suite and report
" 2>&1)" || fail "an intact newline-terminated steer must be delivered: $out"
case "$out" in *REFUTED*) fail "an intact newline-terminated steer is not a refutation: $out" ;; esac
assert_contains "$out" "sent to orca:pCNLOK" "...and its arrival is CONFIRMED, not merely unobserved"
case "$out" in *unverified*) fail "an intact newline-terminated steer must confirm its arrival: $out" ;; esac

# A genuinely DIFFERENT arrival is not a truncation and must not be described
# as one - a wrong message and a cut message need different next moves.
sid_other="ffffffff-ffff-ffff-ffff-ffffffffffff"
mk_claude_crewmate cother pCOTH tCOTH "$sid_other"
mk_turn "$sid_other" "a completely unrelated line"
err="$("$BIN/ac-send.sh" cother 'the text that was actually sent' 2>&1)" \
  && fail "a wrong arrival must still be refused"
assert_contains "$err" "arrival REFUTED" "the verdict is unchanged for a wrong arrival too"
case "$err" in *TRUNCATED*) fail "an unrelated arrival must not be reported as a truncation" ;; esac

# A slash command runs locally and never lands as a typed turn (a live /compact
# is recorded as a <command-name> entry with no promptSource), so the last
# typed turn is still the one before it: arrival is UNOBSERVABLE, not REFUTED.
sid_slash="12121212-1212-1212-1212-121212121212"
mk_claude_crewmate cslash pCSL tCSL "$sid_slash"
mk_turn "$sid_slash" "the captain's last typed line"
out="$("$BIN/ac-send.sh" cslash /compact 2>&1)" || fail "a slash command must not be refused as a wrong arrival: $out"
assert_contains "$out" "delivered (arrival unverified) to orca:pCSL" "a slash command's arrival is unverified, never refuted"
sid_path="34343434-3434-3434-3434-343434343434"
mk_claude_crewmate cpath pCPA tCPA "$sid_path"
mk_turn "$sid_path" "the captain's last typed line"
err="$("$BIN/ac-send.sh" cpath '/tmp/brief.md holds the next step' 2>&1)" \
  && fail "a steer that merely starts with a path is still arrival-checked"
assert_contains "$err" "arrival REFUTED" "only a command-shaped first word skips the arrival check"

# herdr's composer-proof-before-Enter mechanism (keep-tail/draft/nbsp/
# read-fails knobs, AC_SEND_UNPROVEN) has no orca equivalent: ac-backend-orca.sh's
# backend_send_line_orca/orca_prompt_send_pane carries no keep-tail, draft
# or composer-visibility check before submitting. This whole cluster is a
# herdr-only gap with no orca-shaped test to migrate it to; tracked in report.md.

# A SOLO session (AC_SOLO=1) never steers a pane - the crew is the chief's.
err="$(AC_SOLO=1 "$BIN/ac-send.sh" cother 'hello' 2>&1)" \
  && fail "a solo session's send must refuse"
assert_contains "$err" "solo session (AC_SOLO=1)" "the refusal names the solo session"


# --- the CLI contract, row by row ---------------------------------------------
# One side root ($H): a home at $H/home, the fake orca's state at $H/orca and
# the claude transcript root at $H/claude; cwd is $H; stdin /dev/null unless a
# row feeds a file; LC_ALL=C unless a row names a locale; AC_SEND_SETTLE=0
# unless a row sets it; EPOCHSECONDS pinned and a watcher beat at that
# instant, AC_GUARD_ROOT at a non-repo dir, and the guard's stamp removed
# before each run; PATH = $TMP/sstub first (a `date` answering iso's stamp
# with one fixed instant or failing on a date-fails file, a `sleep` logging
# every pause, an orca wrapper whose `terminal show` answers a JSON its jqs
# cannot index where a show-seq file's next line says bad, and which logs a
# verb's stdin on a stdin-<verb1>-<verb2> file), then make_fake_orca's orca -
# no row reaches a real orca. A literal @H in an argument or an SENV value is
# the side root, and what a run printed reads it @H, the bin root ROOT.
make_fake_orca
H="$TMP/sside"
SEPOCH=1767225600
mkdir -p "$TMP/sguard-root" "$TMP/sstub" "$TMP/sjq"
ln -s "$(command -v jq)" "$TMP/sjq/jq"
cat >"$TMP/sstub/date" <<'STUB'
#!/bin/sh
if [ "$*" = "-u +%Y-%m-%dT%H:%M:%SZ" ]; then
  [ ! -e "$STUB_DIR/date-fails" ] || exit 3
  printf '2026-01-02T03:04:05Z\n'
  exit 0
fi
exec /bin/date "$@"
STUB
cat >"$TMP/sstub/sleep" <<'STUB'
#!/bin/sh
printf 'sleep %s\n' "$*" >>"$STUB_DIR/sleep.log"
exec /bin/sleep "$@"
STUB
cat >"$TMP/sstub/orca" <<STUB
#!/bin/sh
if [ "\$1 \$2" = "terminal show" ] && [ -s "\$STUB_DIR/show-seq" ]; then
  l="\$(head -n 1 "\$STUB_DIR/show-seq")"
  tail -n +2 "\$STUB_DIR/show-seq" >"\$STUB_DIR/show-seq.next"; mv "\$STUB_DIR/show-seq.next" "\$STUB_DIR/show-seq"
  if [ "\$l" = bad ]; then
    printf 'orca %s\\n' "\$*" >>"\$FAKE_ORCA/log"
    printf '{"ok":true,"result":{"terminal":"gone"}}\\n'
    exit 0
  fi
fi
if [ -e "\$STUB_DIR/stdin-\$1-\$2" ]; then
  i="\$(cat)"
  printf 'orca %s %s stdin=[%s]\n' "\$1" "\$2" "\$i" >>"\$STUB_DIR/stdin.log"
fi
if [ "\$1 \$2" = "terminal send" ] && [ -n "\${WRONG_TURN_ON_SUBMIT:-}" ]; then
  case " \$* " in
    *" --enter "*)
      # A REAL delay, then a REAL (unstubbed) timestamp: models claude
      # writing a wrong turn in the instant right after the Enter, so the
      # test can tell a baseline taken before the submit from one taken
      # after it - a static fixture written up front cannot.
      /bin/sleep 1.1
      ts="\$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '{"type":"user","promptSource":"typed","origin":{"kind":"human"},"timestamp":"%s","message":{"role":"user","content":"a wrong reply written right after this very submit"}}\n' "\$ts" >>"\$WRONG_TURN_ON_SUBMIT"
      ;;
  esac
fi
exec "$TMP/stubbin/orca" "\$@"
STUB
chmod +x "$TMP/sstub/date" "$TMP/sstub/sleep" "$TMP/sstub/orca"
sseed() {
  rm -rf "$H"; mkdir -p "$H/home/state" "$H/home/config" "$H/home/records" "$H/orca/terminals" "$H/claude/proj"
  printf 'off\n' >"$H/home/config/wedge-alarm"
  printf '%s\n' "$SEPOCH" >"$H/home/state/.last-watcher-beat"
}
smate() {  # smate <id> <pane> [<meta line>...] - a live orca crewmate: its meta, handle and an empty transcript
  local id="$1" p="$2"; shift 2
  printf 'backend=orca\n' >"$H/home/state/$id.meta"
  [ "$#" = 0 ] || printf '%s\n' "$@" >>"$H/home/state/$id.meta"
  printf '%s tab-%s\n' "$p" "$p" >"$H/home/state/.pane-$id"
  : >"$H/orca/terminals/$p.buf"; : >"$H/orca/terminals/$p.in"
}
sclaude() { smate "$1" "$2" harness=claude "session_id=$3"; }   # sclaude <id> <pane> <session id> - no composer-proof knob: orca has none (bin/ac-backend-orca.sh)
sorca() {  # sorca <id> <handle> - a live orca crewmate whose terminal shows a claude agent
  printf 'backend=orca\n' >"$H/home/state/$1.meta"
  printf '%s tab%s\n' "$2" "$2" >"$H/home/state/.pane-$1"
  : >"$H/orca/terminals/$2.buf"; : >"$H/orca/terminals/$2.in"
  printf 'claude\n' >"$H/orca/terminals/$2.title"; printf 'claude\n' >"$H/orca/terminals/$2.agent"
}
sput() { mkdir -p "$(dirname "$H/$1")"; printf '%s' "$2" >"$H/$1"; }   # sput <path under the side> <bytes>
sturn() {  # sturn <session id> <content> [<dir under the side>] - a transcript whose last typed human turn is <content>
  mkdir -p "$H/${3:-claude/proj}"
  printf '{"type":"user","promptSource":"typed","origin":{"kind":"human"},"message":{"role":"user","content":%s}}\n' \
    "$(printf '%s' "$2" | jq -Rs .)" >"$H/${3:-claude/proj}/$1.jsonl"
}
snorm() { LC_ALL=C sed -E -e "s#$H#@H#g" -e "s#$TMP/sshimlab#ROOT#g" -e "s#$ROOT#ROOT#g" "$1"; }
SLC=C; SENV=(); SHOMELESS=0; SPATH=""; SSTDIN=/dev/null; S_BIN="$BIN"; SN_RC=0
srun() {  # srun <args...> - the shim at the side root; sets SN_RC
  local x v a=() e=("LC_ALL=$SLC" "PATH=${SPATH:-$TMP/sstub:$TMP/stubbin:$PATH}" "FAKE_ORCA=$H/orca" "STUB_DIR=$H"
    "EPOCHSECONDS=$SEPOCH" "AC_GUARD_ROOT=$TMP/sguard-root" "AC_CLAUDE_TRANSCRIPT_ROOT=$H/claude" "AC_SEND_SETTLE=0")
  [ "$SHOMELESS" = 1 ] || e+=("AC_HOME=$H/home")
  for x in ${SENV[@]+"${SENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@H/$H}"); done
  for x in "$@"; do a+=("${x//@H/$H}"); done
  rm -f "$H"/home/state/.guard-stamp*
  SN_RC=0
  (cd "$H" && env -u AC_HOME -u AC_BACKEND -u AC_FLEET_STATE -u AC_HERDR_SESSION -u AC_HERDR_RPC_TIMEOUT -u AC_GUARD_QUIET \
    -u AC_GUARD_GRACE -u LANG -u LC_CTYPE -u AC_SOLO -u AC_SEND_UNPROVEN -u AC_CAPTAIN_RE -u CLAUDE_CONFIG_DIR \
    "${e[@]}" "$S_BIN/ac-send.sh" ${a[@]+"${a[@]}"}) <"$SSTDIN" >"$TMP/n.raw" 2>"$TMP/n.err" || SN_RC=$?
  snorm "$TMP/n.raw" >"$TMP/n.out"; snorm "$TMP/n.err" >"$TMP/n.err2"
}
sout() { cat "$TMP/n.out"; }
serr() { cat "$TMP/n.err2"; }
slast() { tail -n 1 "$TMP/n.err2"; }
SUSAGE="ERROR: usage: ac-send.sh <id> [--force] '<text>' | --key <key>"
SNOHOME='ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one'
SBAD="ERROR: unsupported backend 'tmux' (valid backend: orca)"
SSOLO='ERROR: a solo session (AC_SOLO=1) never steers a pane - the crew belongs to the chief session; hand it the order with bin/ac-remote.sh order (solo-session skill)'
SUNREAD="the BACKEND could not be read for c1 - nothing was delivered, and the pane's liveness is UNKNOWN (it may well be alive); check the backend itself, then send again"
SDEL='delivered (arrival unverified) to orca:pC1'
SKEY='delivered (unverified) to orca:pC1'
SWARN1='warning: this steer carries a bare marker verb ('
SWARN2=') - the watcher greps the pane TAIL, so your own words can wake you and stamp the pane (a mid-sentence marker soft-wraps to visual column 0 and matches). Backtick-wrap it (`done:`) or drop the trailing colon. Delivering anyway.'
sseed; smate c1 pC1

# 1. the order before any pane is read: usage (none, ''), homeless (usage
#    alone, then with an id the refusal and the gate's own line), AC_SOLO=1
#    before the home and the usage - but after a refused backend name -, a
#    missing meta, a directory and a dangling link at the meta path, and a
#    meta's backend=tmux (the route's refusal).
srun; assert_eq "$SN_RC:$(sout):$(serr)" "1::$SUSAGE" "1: no arguments is the usage line"
srun ''; assert_eq "$SN_RC:$(serr)" "1:$SUSAGE" "1: an empty id is the usage line"
SHOMELESS=1
srun; assert_eq "$SN_RC:$(serr)" "1:$SUSAGE" "1: homeless with no id is the usage line"
srun c1 hi; assert_eq "$SN_RC:$(serr)" "1:$SNOHOME
ERROR: no crewmate meta for c1" "1: homeless with an id prints the refusal, then the gate's line"
SENV=(AC_SOLO=1)
srun c1 hi; assert_eq "$SN_RC:$(serr)" "1:$SSOLO" "1: AC_SOLO=1 refuses before the home is read"
SHOMELESS=0
srun; assert_eq "$SN_RC:$(serr)" "1:$SSOLO" "1: AC_SOLO=1 refuses before the usage line"
SENV=(AC_SOLO=1 AC_BACKEND=tmux)
srun c1 hi; assert_eq "$SN_RC:$(serr)" "1:$SBAD" "1: a refused backend name precedes the AC_SOLO refusal"
SENV=(AC_SOLO=yes)
srun c1 hi; assert_eq "$SN_RC:$(sout)" "0:$SDEL" "1: only AC_SOLO=1 is a solo session"
SENV=()
srun nope hi; assert_eq "$SN_RC:$(serr)" "1:ERROR: no crewmate meta for nope" "1: a missing meta"
mkdir "$H/home/state/d1.meta"
srun d1 hi; assert_eq "$SN_RC:$(slast)" "1:ERROR: no crewmate meta for d1" "1: a directory is no meta"
rmdir "$H/home/state/d1.meta"
ln -s nowhere "$H/home/state/d2.meta"
srun d2 hi; assert_eq "$SN_RC:$(slast)" "1:ERROR: no crewmate meta for d2" "1: a dangling link is no meta"
rm -f "$H/home/state/d2.meta"
sput home/state/t1.meta $'backend=tmux\n'
srun t1 hi; assert_eq "$SN_RC:$(serr)" "1:$SBAD" "1: a meta's backend=tmux is the route's refusal"
rm -f "$H/home/state/t1.meta"

# 2. --key: every named spelling and two unnamed keys, straight to the PTY
#    (orca_send_key_pane: "the herdr unfocused-send-keys quirk has no orca
#    counterpart, so no focus step" - bin/ac-backend-orca.sh - so V5's
#    failing-focus-before-key case and a stopped SERVER as a distinct "gone
#    window" path do not port: section 10's .exited already proves "window
#    gone" for orca, and release-agent/report-agent (the captain-wait
#    .reported release herdr RPCs) have no orca counterpart either) unless
#    the key is named, which is unverified; no key name (absent or ''); --force
#    before --key is legal and unused; a captain-wait stamp is cleared; an
#    unreachable backend is the BACKEND line before the key is even parsed.
for sk in Enter enter Escape Esc C-c ctrl+c x 'two words'; do
  srun c1 --key "$sk"; assert_eq "$SN_RC:$(sout):$(serr)" "0:$SKEY:" "2: --key '$sk'"
done
assert_contains "$(cat "$H/orca/log")" "orca terminal send --terminal pC1 --text two words" "2: an unnamed key is pressed verbatim"
# Escape/Esc/x/'two words' above typed (never submitted) into the composer -
# cleared directly rather than via a flushing Enter, which would otherwise
# commit a raw ESC byte into .buf and break every later --screen read's JSON.
: >"$H/orca/terminals/pC1.in"
srun c1 --key; assert_eq "$SN_RC:$(serr)" "1:ERROR: missing key name" "2: --key with no name"
srun c1 --key ''; assert_eq "$SN_RC:$(serr)" "1:ERROR: missing key name" "2: --key ''"
srun c1 --force --key Enter; assert_eq "$SN_RC:$(sout)" "0:$SKEY" "2: --force before --key is legal"
touch "$H/home/state/.captain-wait-c1"
srun c1 --key Escape; assert_no_file "$H/home/state/.captain-wait-c1" "2: a key clears the captain-wait stamp"
: >"$H/orca/terminals/pC1.in"
touch "$H/orca/.unreachable"
srun c1 --key; assert_eq "$SN_RC:$(serr)" "1:ERROR: $SUNREAD" "2: an unreachable backend refuses before the key is parsed"
rm -f "$H/orca/.unreachable"

# 3. text: none or '' is refused. herdr's "an unreadable process probe
#    delivers" case has no orca counterpart: herdr's harness-identity RPC
#    (process-info) is decoupled from its liveness RPC (pane get), so one can
#    fail unobservably while the other proves the window alive; orca's
#    window_alive AND harness_up (bin/ac-backend-orca.sh) both read the SAME
#    `terminal show` call's `connected` field, so a `terminal show` failure
#    kills window_alive first - there is no way to make harness_up alone
#    unobservable once the window is proven alive. Verified: forcing
#    `terminal show` to fail (.terminal-api-down) dies "could not be read for
#    c1" before harness_up is ever reached, never a delivery.
srun c1; assert_eq "$SN_RC:$(serr)" "1:ERROR: refusing to send an empty message" "3: no text"
srun c1 ''; assert_eq "$SN_RC:$(serr)" "1:ERROR: refusing to send an empty message" "3: an empty text"
srun c1 --force; assert_eq "$SN_RC:$(serr)" "1:ERROR: refusing to send an empty message" "3: --force and no text"

# 4. the write-side marker guard warns and delivers: tokens deduped in
#    first-seen order, a token at a line's end; the verb list is the live
#    AC_CAPTAIN_RE's, an unparseable one reports nothing, and one off its
#    text (an uppercase verb) reports nothing under C and under UTF-8 alike.
#    The herdr suite's TAB/CR-after-the-colon cases are not ported: fake
#    orca serves the composer through a JSON tail (helpers.sh tail_json, out
#    of this suite's write set) that jq rejects once it holds a raw control
#    byte (verified: jq itself errors "control characters ... must be
#    escaped" on one), so orca's pending check (orca_composer_pending) would
#    read nothing there and the case would pass without exercising it.
#    The marker-guard parse itself is already proven by the cases above.
srun c1 'blocked: x and done: y then done: z'; assert_eq "$SN_RC:$(sout):$(serr)" "0:$SDEL:${SWARN1}blocked: done:$SWARN2" "4: tokens deduped in first-seen order"
srun c1 $'line one\nfailed:'; assert_eq "$(serr)" "${SWARN1}failed:$SWARN2" "4: a token at a line's end"
SENV=("AC_CAPTAIN_RE=^(ack|nak):")
srun c1 'ack: and done: here'; assert_eq "$(serr)" "${SWARN1}ack:$SWARN2" "4: the verb list is the live AC_CAPTAIN_RE's"
SENV=("AC_CAPTAIN_RE=no group here")
srun c1 'done: here'; assert_eq "$(serr)" "" "4: an unparseable AC_CAPTAIN_RE reports nothing"
SENV=("AC_CAPTAIN_RE=^(Done|x):")
srun c1 'Done: x'; assert_eq "$(serr)" "" "4: a verb list off its text reports nothing under C"
SLC=""; SENV=(LANG=en_US.UTF-8 "AC_CAPTAIN_RE=^(Done|x):")
srun c1 'Done: x'; assert_eq "$SN_RC:$(sout):$(serr)" "0:$SDEL:" "4: ... nor under UTF-8"
SLC=C; SENV=()

# 5. the chief-order marker on a crewdeputy: a LEGACY entry routes; no
#    registry is refused before the pane; a registry byte that is not UTF-8
#    aborts the parse under UTF-8 and ends the run with awk's status; a claude
#    deputy's arrival compares the MARKED text.
sdep() {  # sdep <id> <pane> - a live crewdeputy: its home and marker, its meta and pane
  mkdir -p "$H/home/crewdeputies/$1"; : >"$H/home/crewdeputies/$1/.ac-crewdeputy-home"
  smate "$1" "$2" kind=crewdeputy
}
SREG="# Crewdeputies

- pay - payments duty - home: $H/home/crewdeputies/pay - scope: payments - projects: none (added 2026-07-19T00:00:00Z)
"
sdep pay pP1
sput home/records/crewdeputies.md "- pay - home: $H/home/crewdeputies/pay (added 2026-07-19T00:00:00Z)
"
srun pay 'legacy entry'; assert_eq "$SN_RC:$(cat "$H/orca/terminals/pP1.buf")" "0:[chief-order home=$H/home deputy=pay] legacy entry" "5: a LEGACY entry routes"
rm -f "$H/home/records/crewdeputies.md"
srun pay 'route me'; assert_eq "$SN_RC:$(serr)" "1:ERROR: pay is a crewdeputy with no parseable entry in @H/home/records/crewdeputies.md - a routed order needs a home for its answer to land in; fix the registry line first" "5: no registry"
case "$(cat "$H/orca/terminals/pP1.buf")" in *"route me"*) fail "5: a refused order never reaches the pane" ;; esac
sput home/records/crewdeputies.md "- caf$(printf '\351') line
$SREG"
SLC=""; SENV=(LANG=en_US.UTF-8)
srun pay 'parse aborts'; assert_eq "$SN_RC:$(sout)" "2:" "5: a parse that aborts under UTF-8 ends the run with awk's status"
SLC=C; SENV=()
srun pay 'parse passes'; assert_eq "$SN_RC" 0 "5: ... the same registry parses under C"
sput home/records/crewdeputies.md "$SREG"
printf 'harness=claude\nsession_id=SIDP\n' >>"$H/home/state/pay.meta"
sturn SIDP "[chief-order home=$H/home deputy=pay] confirm me"
srun pay 'confirm me'; assert_eq "$SN_RC:$(sout)" "0:sent to orca:pP1" "5: a claude deputy's arrival compares the marked text"

# 5b. the registry lookup is exact STRING equality, never awk's numeric ==:
#     deputy id 7 must read its OWN entry's home, not an earlier 07 entry's -
#     07's registered home here was never created, so a numeric match would refuse.
sdep 7 pD7
sput home/records/crewdeputies.md "# Crewdeputies

- 07 - home: $H/home/crewdeputies/07 (added 2026-07-19T00:00:00Z)
- 7 - home: $H/home/crewdeputies/7 (added 2026-07-19T00:00:00Z)
"
srun 7 'route to seven'
assert_eq "$SN_RC:$(cat "$H/orca/terminals/pD7.buf")" "0:[chief-order home=$H/home deputy=7] route to seven" \
  "5b: deputy id 7 reads its own registry entry, never 07's unbuilt home"

# 6. a slash command (the DELIVERED line's first word) leaves a captain-wait
#    stamp standing and skips the arrival check (on a claude pane a REFUTED
#    line is the check running); /Compact, a path, and an uppercase
#    subcommand are no command. The herdr suite's "a CR right after the
#    word" case is not ported, for the reason section 4 dropped two of its
#    own: a raw CR in the composer is unreadable through fake orca's JSON
#    tail (section 4's note above).
sclaude cs pCS SIDS
sturn SIDS "the captain's last typed line"
for st in /compact '/compact now' '/a:b x'; do
  touch "$H/home/state/.captain-wait-c1"
  srun c1 "$st"; assert_file "$H/home/state/.captain-wait-c1" "6: '$st' is a command - the stamp stands"
  srun cs "$st"; assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to orca:pCS" "6: '$st' skips the arrival check"
done
for st in /Compact '/tmp/x y' '/a:B x'; do
  touch "$H/home/state/.captain-wait-c1"
  srun c1 "$st"; assert_no_file "$H/home/state/.captain-wait-c1" "6: '$st' is no command - the stamp is cleared"
  srun cs "$st"; assert_eq "$SN_RC:$(sout)" "1:" "6: '$st' is arrival-checked"
  assert_contains "$(serr)" "ERROR: arrival REFUTED for cs - " "6: '$st' ... and refuted"
done

# 7. AC_SEND_UNPROVEN and AC_HERDR_SESSION are both herdr-only, with no orca
#    counterpart: the claude composer proof (AC_SEND_UNPROVEN gates it) does
#    not exist for orca at all (the gap noted earlier, above section 1), and
#    orca_json (bin/ac-backend-orca.sh) carries no session concept for
#    AC_HERDR_SESSION to ride - tracked in report.md, not ported.

# 8. arrival on a claude pane: REFUTED with a DIFFERENT text; sizes in
#    characters under UTF-8, bytes under C, never recorded; an intact `x\n\n`
#    confirms; no session id, no transcript, two transcripts for the id and a
#    tool-result turn are unobservable; the transcript root falls back to
#    CLAUDE_CONFIG_DIR, then HOME; the read cadence (AC_SEND_SETTLE) is the
#    sleep log's.
sclaude ca pCA SIDA
sturn SIDA 'confirmed steer text'
srun ca 'confirmed steer text'; assert_eq "$SN_RC:$(sout)" "0:sent to orca:pCA" "8: CONFIRMED"
srun ca 'the text actually sent'; assert_eq "$SN_RC:$(sout):$(serr)" "1::ERROR: arrival REFUTED for ca - sent 22 chars, arrived 20: a DIFFERENT text is in the composer, not a cut one - peek it (bin/ac-peek.sh ca) before resubmitting, since the composer already accepted SOMETHING" "8: REFUTED, a different text"
sturn SIDA ' chạy lại suite và báo cáo'
srun ca $'Đọc ba finding trong room trước, rồi chạy lại suite và báo cáo\n'; assert_contains "$(serr)" "sent 77 chars, arrived 33: TRUNCATED" "8: sizes in bytes under C"
SLC=""; SENV=(LANG=en_US.UTF-8)
srun ca $'Đọc ba finding trong room trước, rồi chạy lại suite và báo cáo\n'; assert_contains "$(serr)" "sent 62 chars, arrived 26: TRUNCATED" "8: sizes in characters under UTF-8"
SLC=C; SENV=()
assert_eq "$(cat "$H/home/state/ca.status")" "2026-01-02T03:04:05Z steered: confirmed steer text" "8: a REFUTED send is never recorded"
sturn SIDA 'intact'
srun ca $'intact\n\n'; assert_eq "$SN_RC:$(sout)" "0:sent to orca:pCA" "8: an intact x\\n\\n confirms"
smate cn pCN harness=claude session_id=
srun cn 'no session id'; assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to orca:pCN" "8: no session id"
sclaude cm pCM SIDM
srun cm 'two'; assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to orca:pCM" "8: no transcript"
sturn SIDM 'two'
sturn SIDM 'two' claude/proj2
srun cm 'two'; assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to orca:pCM" "8: two transcripts for one id"
rm -f "$H/claude/proj2/SIDM.jsonl"
srun cm 'two'; assert_eq "$SN_RC:$(sout)" "0:sent to orca:pCM" "8: ... and one confirms"
sput claude/proj/SIDM.jsonl '{"type":"user","promptSource":"typed","origin":{"kind":"human"},"message":{"role":"user","content":[{"type":"tool_result"}]}}
'
srun cm 'two'; assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to orca:pCM" "8: a tool-result turn is no typed turn"
sturn SIDA 'from the config dir' cfg/projects/p
SENV=(AC_CLAUDE_TRANSCRIPT_ROOT= CLAUDE_CONFIG_DIR=@H/cfg)
srun ca 'from the config dir'; assert_eq "$SN_RC:$(sout)" "0:sent to orca:pCA" "8: the root falls back to CLAUDE_CONFIG_DIR"
sturn SIDA 'from home' fakehome/.claude/projects/p
SENV=(AC_CLAUDE_TRANSCRIPT_ROOT= HOME=@H/fakehome)
srun ca 'from home'; assert_eq "$SN_RC:$(sout)" "0:sent to orca:pCA" "8: ... then to HOME"
SENV=(AC_SEND_SETTLE=0.01)
rm -f "$H/sleep.log"
srun ca 'paced'; assert_eq "$(grep -c 'sleep 0.01' "$H/sleep.log")" 6 "8: a send whose text left the composer pauses nowhere, then six arrival reads a settle apart"
SENV=()

# 8b. a mid-turn QUEUED steer: a live transcript (2026-11-16) shows this as a
# queue-operation pair (enqueue, then remove reason="absorbed_mid_turn"), never
# as a typed turn - claude folds it into the turn already running. The last
# TYPED turn stays the one from before the send (here, an older watcher nudge)
# through the whole read budget; that must read as unverified, never as the
# false REFUTED this family exists to kill.
sid_q="99999999-9999-9999-9999-999999999999"
sclaude cq pCQ "$sid_q"
sturn "$sid_q" "an older watcher nudge"
cat >>"$H/claude/proj/$sid_q.jsonl" <<JSONL
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-02T03:04:05Z","sessionId":"$sid_q","content":"the queued steer text"}
{"type":"queue-operation","operation":"remove","timestamp":"2026-01-02T03:04:06Z","sessionId":"$sid_q","content":"the queued steer text","reason":"absorbed_mid_turn"}
JSONL
srun cq 'the queued steer text'
assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to orca:pCQ" "8b: a queued-but-intact mid-turn steer reads unverified, never REFUTED"
case "$(serr)" in *REFUTED*) fail "8b: a queued steer must never print REFUTED: $(serr)" ;; esac

# 8c. a STALE queue-operation must not mask a genuine wrong arrival: an
# earlier absorbed steer sharing the sent text, superseded by a NEWER typed
# turn that differs, is a real mismatch - ORDER inside the window decides,
# not mere presence of a matching queue entry anywhere in it.
sid_stale="88888888-8888-8888-8888-888888888888"
sclaude cstale pCSTALE "$sid_stale"
cat >"$H/claude/proj/$sid_stale.jsonl" <<JSONL
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-02T03:00:00Z","sessionId":"$sid_stale","content":"status?"}
{"type":"queue-operation","operation":"remove","timestamp":"2026-01-02T03:00:01Z","sessionId":"$sid_stale","content":"status?","reason":"absorbed_mid_turn"}
{"type":"user","promptSource":"typed","origin":{"kind":"human"},"message":{"role":"user","content":"junkstatus?"}}
JSONL
srun cstale 'status?'
assert_eq "$SN_RC:$(sout)" "1:" "8c: a stale absorbed queue entry does not mask a newer, wrong typed turn"
assert_contains "$(serr)" "ERROR: arrival REFUTED for cstale - " "8c: ...it still refutes"

# 8d. a queue-operation entry for a DIFFERENT text must not stand down a
# genuine refutation either - only an exact content match does.
sid_diffq="77777777-7777-7777-7777-777777777777"
sclaude cdiffq pCDQ "$sid_diffq"
sturn "$sid_diffq" "an older watcher nudge"
cat >>"$H/claude/proj/$sid_diffq.jsonl" <<JSONL
{"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-02T03:04:05Z","sessionId":"$sid_diffq","content":"a totally different queued text"}
{"type":"queue-operation","operation":"remove","timestamp":"2026-01-02T03:04:06Z","sessionId":"$sid_diffq","content":"a totally different queued text","reason":"absorbed_mid_turn"}
JSONL
srun cdiffq 'the queued steer text'
assert_eq "$SN_RC:$(sout)" "1:" "8d: a queue entry for a DIFFERENT text does not stand down a genuine refutation"
assert_contains "$(serr)" "ERROR: arrival REFUTED for cdiffq - " "8d: ...it still refutes"

# 8e. a STALE typed turn: the last typed turn is the one that already
# existed before this send, and nothing else gets written for the whole
# read budget (claude has not written the new turn yet within the budget -
# the pane can sit idle between turns for far longer than arrivalWait's
# seven reads). From content alone this is identical
# to 8c/8d's "genuinely wrong, final" fixtures - the one signal that tells
# them apart is the turn's OWN transcript timestamp: it predates this call,
# so it is provably the pre-send turn, not a verdict on this send. UNOBSERVABLE,
# never REFUTED; 8c/8d's untimestamped turns must keep refuting (asserted
# above - this case needs the timestamp to flip).
sid_pre="66666666-6666-6666-6666-666666666666"
sclaude cpre pCPRE "$sid_pre"
cat >"$H/claude/proj/$sid_pre.jsonl" <<JSONL
{"type":"user","promptSource":"typed","origin":{"kind":"human"},"timestamp":"2020-01-01T00:00:00Z","message":{"role":"user","content":"an old typed turn from well before this send"}}
JSONL
srun cpre 'the new steer this send actually types'
assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to orca:pCPRE" "8e: a stale pre-send typed turn, unchanged through the whole budget, reads unverified - never REFUTED"
case "$(serr)" in *REFUTED*) fail "8e: a stale pre-send typed turn must never print REFUTED: $(serr)" ;; esac

# 8f. the other direction: a genuinely DIFFERENT typed turn, even one
# timestamped strictly AFTER this call starts, still refutes - 8e's carve-out
# reads the mismatched turn's OWN timestamp, never just "it never changed
# again", so a real, finished, wrong reply (which also never changes again
# once written) must not be swallowed by it.
sid_fresh="55555555-5555-5555-5555-555555555555"
sclaude cfresh pCFRESH "$sid_fresh"
cat >"$H/claude/proj/$sid_fresh.jsonl" <<JSONL
{"type":"user","promptSource":"typed","origin":{"kind":"human"},"timestamp":"2099-01-01T00:00:00Z","message":{"role":"user","content":"a wrong reply, freshly timestamped"}}
JSONL
srun cfresh 'the text this send actually types'
assert_eq "$SN_RC:$(sout)" "1:" "8f: a fresh, genuinely wrong typed turn still refutes"
assert_contains "$(serr)" "ERROR: arrival REFUTED for cfresh - " "8f: ...the verdict is unchanged"

# 8g. the baseline 8e's carve-out compares against must be taken BEFORE the
# submit, never inside arrivalWait itself: claude can write a WRONG turn in
# the instant right after the Enter, before arrivalWait is even called, and a
# baseline taken any later would already be past that write, misreading a
# genuine wrong arrival as merely pre-existing. The fake backend writes the
# wrong turn itself - with a real, dynamically-captured timestamp - the
# moment the Enter lands, which a fixture written up front cannot model.
sid_race="44444444-4444-4444-4444-444444444444"
sclaude crace pCRACE "$sid_race"
SENV=("WRONG_TURN_ON_SUBMIT=@H/claude/proj/$sid_race.jsonl")
srun crace 'the text this send actually types'
SENV=()
assert_eq "$SN_RC:$(sout)" "1:" "8g: a wrong turn written right at submit time still refutes"
assert_contains "$(serr)" "ERROR: arrival REFUTED for crace - " "8g: ...the baseline predates the write, so it is not read as pre-existing"

# 9. the status record: `steered: <text, LFs as spaces>`, stamped by date(1)
#    and mirrored to the task's timeline.
srun c1 $'two\nlines'; assert_eq "$(tail -n 1 "$H/home/state/c1.status")" "2026-01-02T03:04:05Z steered: two lines" "9: one record per send"
assert_eq "$(tail -n 1 "$H/home/data/c1/timeline.log")" "2026-01-02T03:04:05Z steered: two lines" "9: ... mirrored to the timeline"

# 10. orca: keys; a text delivered to orca:<handle>, past an agent_blocked
#     whose jq -e failed (status 5 is not blocked); agentWait blocks text,
#     and --force reaches the send's dialog guard - nothing typed, no Enter,
#     NOT confirmed (V16); a shell title is a bare shell; an endless strand on
#     a pane Orca cannot observe (an observed one is Orca's to deliver); an
#     exited terminal is gone; an unreachable runtime is the BACKEND line.
sorca o1 term1
for sk in Enter Escape C-c x; do
  srun o1 --key "$sk"; assert_eq "$SN_RC:$(sout)" "0:delivered (unverified) to orca:term1" "10: orca --key '$sk'"
done
sorca o1 term1   # the typed keys (Escape, x) sit in the fake's composer
srun o1 'orca steer'; assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to orca:term1" "10: an orca text"
assert_contains "$(cat "$H/orca/terminals/term1.buf")" "orca steer" "10: ... submitted"
sput show-seq $'ok\nbad\n'
srun o1 'past a show jq cannot index'; assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to orca:term1" "10: agent_blocked's jq -e status 5 is not blocked"
touch "$H/orca/terminals/term1.agentwait"
srun o1 'into a dialog'; assert_contains "$(serr)" "ERROR: o1 is BLOCKED on an interactive prompt" "10: agentWait blocks text"
srun o1 --force 'into a dialog'; assert_eq "$SN_RC:$(slast)" "1:ERROR: delivery NOT confirmed for o1 - the text likely sits stranded in the composer (see stderr above)" "10 (V16): --force meets the dialog guard"
assert_contains "$(serr)" "ac-backend: a DIALOG owns the pane of orca:term1" "10 (V16): ... after the driver's own line"
rm -f "$H/orca/terminals/term1.agentwait"
sput orca/terminals/term1.in ''
printf 'zsh\n' >"$H/orca/terminals/term1.title"; rm -f "$H/orca/terminals/term1.agent"
srun o1 'ls'; assert_contains "$(serr)" "ERROR: o1's pane is a BARE SHELL" "10: a shell title is a bare shell"
sorca o1 term1; rm -f "$H/orca/terminals/term1.agent"
sput orca/terminals/term1.drop-enters $'99\n'
srun o1 'stuck'; assert_eq "$SN_RC:$(slast)" "1:ERROR: delivery NOT confirmed for o1 - the text likely sits stranded in the composer (see stderr above)" "10: an endless strand"
rm -f "$H/orca/terminals/term1.drop-enters"
touch "$H/orca/terminals/term1.exited"
srun o1 hi; assert_eq "$SN_RC:$(serr)" "1:ERROR: window gone for o1" "10: an exited terminal is gone"
rm -f "$H/orca/terminals/term1.exited"
touch "$H/orca/.unreachable"
srun o1 hi; assert_eq "$SN_RC:$(serr)" "1:ERROR: the BACKEND could not be read for o1 - nothing was delivered, and the pane's liveness is UNKNOWN (it may well be alive); check the backend itself, then send again" "10: an unreachable runtime"
rm -f "$H/orca/.unreachable"

# 11. the guard: a stale beat with crew in flight prints WATCHER-DOWN ahead of
#     the usage line and stamps state/.guard-stamp; a guard that is not
#     executable stays silent; a reader gone before the final line ends the
#     run with SIGPIPE's 141; a stdout closed outright ends it 1 after the
#     delivery.
rm -f "$H/home/state/.last-watcher-beat"
srun; assert_eq "$SN_RC:$(serr)" "1:WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh
$SUSAGE" "11: the guard's block precedes the usage line"
assert_file "$H/home/state/.guard-stamp" "11: ... and stamps"
mkdir -p "$TMP/sshimlab"
cp -R "$BIN" "$TMP/sshimlab/bin"; ln -s "$ROOT/src" "$TMP/sshimlab/src"
chmod -x "$TMP/sshimlab/bin/ac-guard.sh"
S_BIN="$TMP/sshimlab/bin"
srun; assert_eq "$SN_RC:$(serr)" "1:$SUSAGE" "11: a non-executable guard is silent"
S_BIN="$BIN"
sseed; smate c1 pC1
sclosed() {  # sclosed <stdout redirect> - the exit of a --key send whose stdout is a closed pipe (|) or closed outright (>&-)
  (cd "$H" && env -u AC_BACKEND -u AC_SOLO LC_ALL=C PATH="$TMP/sstub:$TMP/stubbin:$PATH" FAKE_ORCA="$H/orca" STUB_DIR="$H" \
    EPOCHSECONDS="$SEPOCH" AC_GUARD_ROOT="$TMP/sguard-root" AC_HOME="$H/home" AC_SEND_SETTLE=0 \
    bash -c 'if [ "$1" = pipe ]; then "$0/ac-send.sh" c1 --key Enter | true; printf "%s" "${PIPESTATUS[0]}"; else "$0/ac-send.sh" c1 --key Enter >&- 2>/dev/null; printf "%s" "$?"; fi' "$BIN" "$1") </dev/null
}
assert_eq "$(sclosed pipe)" "141" "11: a reader gone before the final line ends the run with 141"
assert_eq "$(sclosed shut)" "1" "11: a closed stdout ends the run 1"
assert_contains "$(cat "$H/orca/log")" "orca terminal send --terminal pC1 --enter" "11: ... after the key was pressed"

# 12. stdin, bytes, the home, and bun.
# - STDIN BY POSITION: the submit check's `terminal read` reads /dev/null,
#   never the caller's stdin - one read for a plain text send Orca cannot
#   observe (the composer-pending check after the prompt send, per
#   orcaPromptSend), with or without the harness probe.
printf 'caller bytes\n' >"$TMP/sstdin.in"
touch "$H/stdin-terminal-read"
SSTDIN="$TMP/sstdin.in"
srun c1 'with stdin'; assert_eq "$SN_RC:$(sout)" "0:$SDEL" "12: a send with stdin attached delivers"
assert_eq "$(cat "$H/stdin.log")" "orca terminal read stdin=[]" "12: its pane reads take /dev/null"
rm -f "$H/stdin.log"
srun c1 --force 'forced with stdin'; assert_eq "$SN_RC:$(cat "$H/stdin.log")" "0:orca terminal read stdin=[]" "12: without the probe too"
SSTDIN=/dev/null
rm -f "$H/stdin.log" "$H/stdin-terminal-read"
# - argv arrives decoded: a byte that is not UTF-8 in the id is U+FFFD in the
#   refusal.
srun "$(printf '\351')" hi
assert_eq "$SN_RC:$(serr)" "1:ERROR: no crewmate meta for $(printf '\357\277\275')" "12: a non-UTF-8 id is refused as U+FFFD"
# - HOME RESOLUTION: an AC_HOME that cannot be entered names the variable.
SENV=(AC_HOME=@H/missing)
srun c1 hi; assert_eq "$SN_RC:$(sout):$(serr)" "1::ERROR: AC_HOME is not a readable directory: @H/missing
ERROR: no crewmate meta for c1" "12: an unenterable AC_HOME names the variable"
SENV=()
# - BUN ABSENT from PATH: the shim refuses and nothing is sent.
SPATH="$TMP/sstub:$TMP/stubbin:$TMP/sjq:/usr/bin:/bin:/usr/sbin:/sbin"
if [ -z "$(PATH="$SPATH" command -v bun || true)" ]; then
  srun c1 'no bun'
  assert_eq "$SN_RC:$(sout):$(serr)" "1::ERROR: required tool not found: bun" "12: bun absent - the shim refuses"
  case "$(cat "$H/orca/terminals/pC1.buf")" in *"no bun"*) fail "12: bun absent - nothing is typed" ;; esac
else
  printf 'SKIP: row 12 bun-absent - bun sits in /usr/bin or /bin on this host\n'
fi
SPATH=""

pass
