#!/usr/bin/env bash
# ac-send.test.sh - ac-send.sh delivery integrity: TEXT into a BLOCKED pane is
# refused (--force overrides; --key stays allowed - it IS the deliberate dialog
# answer), and a stranded submit surfaces as a visible failure, never "sent".
# Driven through the fake herdr CLI (tests/sh/helpers.sh): its .status file feeds
# agent_blocked, its .drop-enters knob strands submits.

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

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

# A slash command answers nothing, so /compact typed into a stamped pane leaves
# the stamp for the steer that does answer the captain's pending item.
mk_crewmate s2b pA2b tA2b
printf 'blocked\n' >"$FAKE_HERDR/panes/pA2b.reported"
touch "$AC_HOME/state/.captain-wait-s2b"
"$BIN/ac-send.sh" s2b /compact >/dev/null || fail "a slash command into a stamped pane must be delivered"
assert_file "$AC_HOME/state/.captain-wait-s2b" "a slash command leaves the captain-wait stamp standing"

# --- REWAKE LATCH (watch.ts header): a delivered non-slash steer clears it --------
# too, the same transition and the same site as the ENDED BUSY LATCH clear
# above - a steered gate round answered and re-printed inside one AC_POLL
# interval never crosses a busy sample, so it must not wait on one either.
mk_crewmate s2c pA2c tA2c
touch "$AC_HOME/state/.rewake-s2c"
"$BIN/ac-send.sh" s2c 'keep going' >/dev/null
assert_no_file "$AC_HOME/state/.rewake-s2c" "a delivered non-slash steer clears the re-wake latch too"

mk_crewmate s2d pA2d tA2d
touch "$AC_HOME/state/.rewake-s2d"
"$BIN/ac-send.sh" s2d /compact >/dev/null || fail "a slash command must still be delivered"
assert_file "$AC_HOME/state/.rewake-s2d" "a slash command leaves the re-wake latch standing, same as the captain-wait stamp"

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
# the sentence a chief reads as "my crewmate died". ac-peek.sh's half of the
# shared guard is asserted here beside ac-send's (tests/sh/ac-peek.test.sh owns
# the rest of peek).
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

# --- a backend that cannot be READ at all is UNOBSERVABLE, never gone ----------------
# Contract: ac-backend.sh WINDOW LIVENESS is THREE-STATE (0 alive / 1 gone /
# 2 unobservable), and a case that enumerates 2 and defaults everything else to
# gone reads any other failure as a dead pane. These rows once drove a driver
# that failed to LOAD (bash's 127, through a lab bin/ with the herdr driver
# renamed); both entries' backend verbs are native now (src/lib.ts
# backendCall), so no driver can fail to load under them, and the rows reach
# the same unobservable read with herdr absent from PATH (the liveness
# ladder's 2).
mk_crewmate lf1 pLF1 tLF1
nh_path="$(dirname "$(command -v bun)"):/usr/bin:/bin:/usr/sbin:/sbin"
if [ -z "$(PATH="$nh_path" command -v herdr || true)" ]; then
  err="$(PATH="$nh_path" "$BIN/ac-send.sh" lf1 'still there?' 2>&1)" \
    && fail "send must refuse when herdr cannot be run"
  assert_contains "$err" "lf1" "the send refusal names the id"
  assert_contains "$err" "backend" "send's refusal of an unrunnable herdr blames the BACKEND, not the pane"
  case "$err" in *"window gone"*) \
    fail "THE REGRESSION: send must never call an unobservable backend a gone window" ;; esac
  err="$(PATH="$nh_path" "$BIN/ac-peek.sh" lf1 2>&1)" \
    && fail "peek must refuse when herdr cannot be run"
  assert_contains "$err" "backend" "peek's refusal of an unrunnable herdr blames the BACKEND, not the pane"
  case "$err" in *"window gone"*) \
    fail "THE REGRESSION: peek must never call an unobservable backend a gone window" ;; esac
else
  printf 'SKIP: send and peek with herdr absent - bun shares its directory with a herdr on this host\n'
fi

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
  : >"$FAKE_HERDR/panes/$2.claude-composer"
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
assert_contains "$out" "sent to herdr:pane-pCNLOK" "...and its arrival is CONFIRMED, not merely unobserved"
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
assert_contains "$out" "delivered (arrival unverified) to herdr:pane-pCSL" "a slash command's arrival is unverified, never refuted"
sid_path="34343434-3434-3434-3434-343434343434"
mk_claude_crewmate cpath pCPA tCPA "$sid_path"
mk_turn "$sid_path" "the captain's last typed line"
err="$("$BIN/ac-send.sh" cpath '/tmp/brief.md holds the next step' 2>&1)" \
  && fail "a steer that merely starts with a path is still arrival-checked"
assert_contains "$err" "arrival REFUTED" "only a command-shaped first word skips the arrival check"

# A LONG send into a claude composer lands as its TAIL (measured live on claude
# 2.1.283: 4.7KB typed, the composer kept the last ~480 chars, mid-word), and
# the Enter after it submitted that tail as the whole instruction. The composer
# must PROVE it holds the message before Enter; an empty composer shows a dim
# hint that is not a draft, and a real draft is never typed over.
mk_claude_crewmate ctail pCTL tCTL "dddddddd-dddd-dddd-dddd-dddddddddddd"
: >"$FAKE_HERDR/panes/pCTL.claude-composer"
long="$(printf 'instruction %03d, ' $(seq 1 60))"
printf '40\n' >"$FAKE_HERDR/panes/pCTL.keep-tail"
err="$("$BIN/ac-send.sh" ctail "$long" 2>&1)" && fail "a composer holding only the tail must not be submitted"
assert_contains "$err" "NOTHING was submitted" "the refusal says nothing went out"
assert_contains "$err" "pointer" "...and names the file-pointer remedy"
[ -z "$(tr -d '[:space:]' <"$FAKE_HERDR/panes/pCTL.buf")" ] || fail "the tail must never reach the transcript"
[ -s "$FAKE_HERDR/panes/pCTL.in" ] && fail "the refused tail is cleared from the composer"
rm -f "$FAKE_HERDR/panes/pCTL.keep-tail"
mk_turn "dddddddd-dddd-dddd-dddd-dddddddddddd" "$long"
out="$("$BIN/ac-send.sh" ctail "$long")" || fail "a composer showing the whole message submits it"
assert_contains "$(cat "$FAKE_HERDR/panes/pCTL.buf")" "instruction 060" "the whole message went out"
printf 'a captain draft in progress' >"$FAKE_HERDR/panes/pCTL.in"
err="$("$BIN/ac-send.sh" ctail 'short steer' 2>&1)" && fail "a composer holding a draft must not be typed into"
assert_contains "$(cat "$FAKE_HERDR/panes/pCTL.in")" "a captain draft in progress" "the draft is left untouched"
case "$(cat "$FAKE_HERDR/panes/pCTL.in")" in *"short steer"*) fail "nothing may be typed after a draft" ;; esac
: >"$FAKE_HERDR/panes/pCTL.in"
# claude 2.1.299 draws an empty composer with no hint as `❯` and one NBSP
# (measured live); that separator is not a draft, so the steer goes out.
: >"$FAKE_HERDR/panes/pCTL.nbsp-empty"
mk_turn "dddddddd-dddd-dddd-dddd-dddddddddddd" "short steer"
err="$("$BIN/ac-send.sh" ctail 'short steer' 2>&1)" || fail "an NBSP-only composer is empty, not a draft: $err"
assert_contains "$(cat "$FAKE_HERDR/panes/pCTL.buf")" "short steer" "the steer reached the transcript"
rm -f "$FAKE_HERDR/panes/pCTL.nbsp-empty"

# A claude pane whose composer cannot be SEEN (no rules on screen - a dialog,
# a menu, an unreadable pane) proves nothing, so nothing is typed; --force is
# the deliberate way to type into whatever is there.
: >"$FAKE_HERDR/panes/pCTL.read-fails"
err="$("$BIN/ac-send.sh" ctail 'steer into an unreadable pane' 2>&1)" && fail "an unreadable claude pane must not be typed into"
assert_contains "$err" "delivery UNVERIFIED" "an unreadable pane is the exit-2 case, not a refused composer"
[ -s "$FAKE_HERDR/panes/pCTL.in" ] && fail "nothing is typed into an unreadable pane"
rm -f "$FAKE_HERDR/panes/pCTL.read-fails"
rm -f "$FAKE_HERDR/panes/pCTL.claude-composer"
err="$("$BIN/ac-send.sh" ctail 'steer into the unknown' 2>&1)" && fail "an unseen claude composer must not be typed into"
assert_contains "$err" "cannot see the composer" "the refusal says why"
[ -s "$FAKE_HERDR/panes/pCTL.in" ] && fail "nothing is typed into an unseen composer"
"$BIN/ac-send.sh" ctail --force 'forced steer' >/dev/null 2>&1 || true
assert_contains "$(cat "$FAKE_HERDR/panes/pCTL.buf")" "forced steer" "--force types and submits without the proof"
: >"$FAKE_HERDR/panes/pCTL.claude-composer"

# A SOLO session (AC_SOLO=1) never steers a pane - the crew is the chief's.
err="$(AC_SOLO=1 "$BIN/ac-send.sh" cother 'hello' 2>&1)" \
  && fail "a solo session's send must refuse"
assert_contains "$err" "solo session (AC_SOLO=1)" "the refusal names the solo session"


# --- the CLI contract, row by row ---------------------------------------------
# One side root ($H): a home at $H/home, the fake herdr's state at $H/herdr,
# the fake orca's at $H/orca and the claude transcript root at $H/claude; cwd
# is $H; stdin /dev/null unless a row feeds a file; LC_ALL=C unless a row names
# a locale; AC_SEND_SETTLE=0 unless a row sets it; EPOCHSECONDS pinned and a
# watcher beat at that instant, AC_GUARD_ROOT at a non-repo dir, and the
# guard's stamp removed before each run; PATH = $TMP/sstub first (a `date`
# answering iso's stamp with one fixed instant or failing on a date-fails
# file, a `sleep` logging every pause, a herdr wrapper whose `tab focus`
# answers a focus-rc file's status and which logs a verb's stdin on a
# stdin-<verb> file, an orca wrapper whose `terminal show` answers a JSON its
# jqs cannot index where a show-seq file's next line says bad), then
# make_fake_herdr's herdr and make_fake_orca's orca - no row reaches a real
# herdr or orca. A literal @H in an argument or an SENV value is the side
# root, and what a run printed reads it @H, the bin root ROOT.
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
cat >"$TMP/sstub/herdr" <<STUB
#!/bin/sh
if [ "\$1 \$2" = "tab focus" ] && [ -f "\$STUB_DIR/focus-rc" ]; then
  printf 'herdr %s\n' "\$*" >>"\$FAKE_HERDR/log"
  exit "\$(cat "\$STUB_DIR/focus-rc")"
fi
if [ -e "\$STUB_DIR/stdin-\$1-\$2" ]; then
  i="\$(cat)"
  printf 'herdr %s %s stdin=[%s]\n' "\$1" "\$2" "\$i" >>"\$STUB_DIR/stdin.log"
fi
exec "$TMP/stubbin/herdr" "\$@"
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
exec "$TMP/stubbin/orca" "\$@"
STUB
chmod +x "$TMP/sstub/date" "$TMP/sstub/sleep" "$TMP/sstub/herdr" "$TMP/sstub/orca"
sseed() {
  rm -rf "$H"; mkdir -p "$H/home/state" "$H/home/config" "$H/home/records" "$H/herdr/panes" "$H/herdr/tabs" "$H/orca/terminals" "$H/claude/proj"
  printf 'off\n' >"$H/home/config/wedge-alarm"
  printf '%s\n' "$SEPOCH" >"$H/home/state/.last-watcher-beat"
}
smate() {  # smate <id> <pane> [<meta line>...] - a live herdr crewmate: its meta, handle, tab and an empty transcript
  local id="$1" p="$2"; shift 2
  printf 'backend=herdr\n' >"$H/home/state/$id.meta"
  [ "$#" = 0 ] || printf '%s\n' "$@" >>"$H/home/state/$id.meta"
  printf '%s t%s\n' "$p" "$p" >"$H/home/state/.pane-$id"
  printf '%s\n' "$p" >"$H/herdr/tabs/t$p"; : >"$H/herdr/panes/$p.buf"
}
sclaude() { smate "$1" "$2" harness=claude "session_id=$3"; : >"$H/herdr/panes/$2.claude-composer"; }   # sclaude <id> <pane> <session id>
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
  local x v a=() e=("LC_ALL=$SLC" "PATH=${SPATH:-$TMP/sstub:$TMP/stubbin:$PATH}" "FAKE_HERDR=$H/herdr" "FAKE_ORCA=$H/orca" "STUB_DIR=$H"
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
SBAD="ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)"
SSOLO='ERROR: a solo session (AC_SOLO=1) never steers a pane - the crew belongs to the chief session; hand it the order with bin/ac-remote.sh order (solo-session skill)'
SUNREAD="the BACKEND could not be read for c1 - nothing was delivered, and the pane's liveness is UNKNOWN (it may well be alive); check the backend itself (herdr status server), then send again"
SDEL='delivered (arrival unverified) to herdr:pane-pC1'
SKEY='delivered (unverified) to herdr:pane-pC1'
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

# 2. --key: every named spelling and two unnamed keys, pressed on the focused
#    tab, unverified; no key name (absent or ''); --force before --key is
#    legal and unused; a captain-wait stamp is cleared; a failing focus ends
#    the run silently with its status before any key (V5); an unreachable
#    backend is the BACKEND line before the key is even parsed; a stopped
#    server is a gone window.
for sk in Enter enter Escape Esc C-c ctrl+c x 'two words'; do
  srun c1 --key "$sk"; assert_eq "$SN_RC:$(sout):$(serr)" "0:$SKEY:" "2: --key '$sk'"
done
assert_contains "$(cat "$H/herdr/log")" "herdr pane send-keys pC1 two words" "2: an unnamed key is pressed verbatim"
srun c1 --key; assert_eq "$SN_RC:$(serr)" "1:ERROR: missing key name" "2: --key with no name"
srun c1 --key ''; assert_eq "$SN_RC:$(serr)" "1:ERROR: missing key name" "2: --key ''"
srun c1 --force --key Enter; assert_eq "$SN_RC:$(sout)" "0:$SKEY" "2: --force before --key is legal"
touch "$H/home/state/.captain-wait-c1"; printf 'blocked\n' >"$H/herdr/panes/pC1.reported"
srun c1 --key Escape; assert_no_file "$H/home/state/.captain-wait-c1" "2: a key clears the captain-wait stamp"
assert_no_file "$H/herdr/panes/pC1.reported" "2: ... and releases the reported state"
sput focus-rc 7
srun c1 --key Enter; assert_eq "$SN_RC:$(sout):$(serr)" "7::" "2 (V5): a failing focus ends the run silently with its status"
assert_eq "$(tail -n 1 "$H/herdr/log")" "herdr tab focus tpC1" "2 (V5): ... before any key is pressed"
rm -f "$H/focus-rc"
touch "$H/herdr/.unreachable"
srun c1 --key; assert_eq "$SN_RC:$(serr)" "1:ERROR: $SUNREAD" "2: an unreachable backend refuses before the key is parsed"
rm -f "$H/herdr/.unreachable"
touch "$H/herdr/.server-stopped"
srun c1 --key Enter; assert_eq "$SN_RC:$(serr)" "1:ERROR: window gone for c1" "2: a stopped server is a gone window"
rm -f "$H/herdr/.server-stopped"

# 3. text: none or '' is refused; an unreadable process probe delivers.
srun c1; assert_eq "$SN_RC:$(serr)" "1:ERROR: refusing to send an empty message" "3: no text"
srun c1 ''; assert_eq "$SN_RC:$(serr)" "1:ERROR: refusing to send an empty message" "3: an empty text"
srun c1 --force; assert_eq "$SN_RC:$(serr)" "1:ERROR: refusing to send an empty message" "3: --force and no text"
touch "$H/herdr/.probe-unreadable"
srun c1 'still delivered'; assert_eq "$SN_RC:$(sout)" "0:$SDEL" "3: an unreadable process probe delivers"
rm -f "$H/herdr/.probe-unreadable"

# 4. the write-side marker guard warns and delivers: tokens deduped in
#    first-seen order, a token at a line's end, a TAB or a CR after the colon
#    (the CR rides in the token); the verb list is the live AC_CAPTAIN_RE's,
#    an unparseable one reports nothing, and one off its text (an uppercase
#    verb) reports nothing under C and under UTF-8 alike.
srun c1 'blocked: x and done: y then done: z'; assert_eq "$SN_RC:$(sout):$(serr)" "0:$SDEL:${SWARN1}blocked: done:$SWARN2" "4: tokens deduped in first-seen order"
srun c1 $'line one\nfailed:'; assert_eq "$(serr)" "${SWARN1}failed:$SWARN2" "4: a token at a line's end"
srun c1 $'done:\tx'; assert_eq "$(serr)" "${SWARN1}done:$SWARN2" "4: a TAB after the colon"
srun c1 $'done:\rx'; assert_eq "$(serr)" "${SWARN1}done:"$'\r'"$SWARN2" "4: a CR rides in the token"
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
srun pay 'legacy entry'; assert_eq "$SN_RC:$(cat "$H/herdr/panes/pP1.buf")" "0:[chief-order home=$H/home deputy=pay] legacy entry" "5: a LEGACY entry routes"
rm -f "$H/home/records/crewdeputies.md"
srun pay 'route me'; assert_eq "$SN_RC:$(serr)" "1:ERROR: pay is a crewdeputy with no parseable entry in @H/home/records/crewdeputies.md - a routed order needs a home for its answer to land in; fix the registry line first" "5: no registry"
case "$(cat "$H/herdr/panes/pP1.buf")" in *"route me"*) fail "5: a refused order never reaches the pane" ;; esac
sput home/records/crewdeputies.md "- caf$(printf '\351') line
$SREG"
SLC=""; SENV=(LANG=en_US.UTF-8)
srun pay 'parse aborts'; assert_eq "$SN_RC:$(sout)" "2:" "5: a parse that aborts under UTF-8 ends the run with awk's status"
SLC=C; SENV=()
srun pay 'parse passes'; assert_eq "$SN_RC" 0 "5: ... the same registry parses under C"
sput home/records/crewdeputies.md "$SREG"
printf 'harness=claude\nsession_id=SIDP\n' >>"$H/home/state/pay.meta"; : >"$H/herdr/panes/pP1.claude-composer"
sturn SIDP "[chief-order home=$H/home deputy=pay] confirm me"
srun pay 'confirm me'; assert_eq "$SN_RC:$(sout)" "0:sent to herdr:pane-pP1" "5: a claude deputy's arrival compares the marked text"

# 6. a slash command (the DELIVERED line's first word) leaves a captain-wait
#    stamp standing and skips the arrival check (on a claude pane a REFUTED
#    line is the check running); /Compact, a path, a CR right after the word,
#    and an uppercase subcommand are no command.
sclaude cs pCS SIDS
sturn SIDS "the captain's last typed line"
for st in /compact '/compact now' '/a:b x'; do
  touch "$H/home/state/.captain-wait-c1"
  srun c1 "$st"; assert_file "$H/home/state/.captain-wait-c1" "6: '$st' is a command - the stamp stands"
  srun cs "$st"; assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to herdr:pane-pCS" "6: '$st' skips the arrival check"
done
for st in /Compact '/tmp/x y' $'/compact\r' '/a:B x'; do
  touch "$H/home/state/.captain-wait-c1"
  srun c1 "$st"; assert_no_file "$H/home/state/.captain-wait-c1" "6: '$st' is no command - the stamp is cleared"
  srun cs "$st"; assert_eq "$SN_RC:$(sout)" "1:" "6: '$st' is arrival-checked"
  assert_contains "$(serr)" "ERROR: arrival REFUTED for cs - " "6: '$st' ... and refuted"
done

# 7. the claude composer proof: an exported AC_SEND_UNPROVEN=1 does not skip
#    it, an exported 0 does not undo --force; the herdr session rides every
#    call.
sclaude ct pCT SIDT
sput herdr/panes/pCT.in 'a captain draft in progress'
SENV=(AC_SEND_UNPROVEN=1)
srun ct 'short steer'; assert_eq "$SN_RC:$(cat "$H/herdr/panes/pCT.in")" "1:a captain draft in progress" "7: an exported AC_SEND_UNPROVEN=1 does not skip the proof"
assert_eq "$(slast)" "ERROR: delivery REFUSED for ct - nothing was submitted (see stderr above)" "7: ... the draft is REFUSED"
sput herdr/panes/pCT.in ''
rm -f "$H/herdr/panes/pCT.claude-composer"
SENV=(AC_SEND_UNPROVEN=0)
srun ct --force 'forced steer'; assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to herdr:pane-pCT" "7: --force types without the proof, an exported 0 notwithstanding"
SENV=(AC_HERDR_SESSION=s9)
srun c1 'in a session'; assert_contains "$(cat "$H/herdr/log")" "herdr pane send-text pC1 in a session --session s9" "7: the herdr session rides the calls"
SENV=()

# 8. arrival on a claude pane: REFUTED with a DIFFERENT text; sizes in
#    characters under UTF-8, bytes under C, never recorded; an intact `x\n\n`
#    confirms; no session id, no transcript, two transcripts for the id and a
#    tool-result turn are unobservable; the transcript root falls back to
#    CLAUDE_CONFIG_DIR, then HOME; the read cadence (AC_SEND_SETTLE) is the
#    sleep log's.
sclaude ca pCA SIDA
sturn SIDA 'confirmed steer text'
srun ca 'confirmed steer text'; assert_eq "$SN_RC:$(sout)" "0:sent to herdr:pane-pCA" "8: CONFIRMED"
srun ca 'the text actually sent'; assert_eq "$SN_RC:$(sout):$(serr)" "1::ERROR: arrival REFUTED for ca - sent 22 chars, arrived 20: a DIFFERENT text is in the composer, not a cut one - peek it (bin/ac-peek.sh ca) before resubmitting, since the composer already accepted SOMETHING" "8: REFUTED, a different text"
sturn SIDA ' chạy lại suite và báo cáo'
srun ca $'Đọc ba finding trong room trước, rồi chạy lại suite và báo cáo\n'; assert_contains "$(serr)" "sent 77 chars, arrived 33: TRUNCATED" "8: sizes in bytes under C"
SLC=""; SENV=(LANG=en_US.UTF-8)
srun ca $'Đọc ba finding trong room trước, rồi chạy lại suite và báo cáo\n'; assert_contains "$(serr)" "sent 62 chars, arrived 26: TRUNCATED" "8: sizes in characters under UTF-8"
SLC=C; SENV=()
assert_eq "$(cat "$H/home/state/ca.status")" "2026-01-02T03:04:05Z steered: confirmed steer text" "8: a REFUTED send is never recorded"
sturn SIDA 'intact'
srun ca $'intact\n\n'; assert_eq "$SN_RC:$(sout)" "0:sent to herdr:pane-pCA" "8: an intact x\\n\\n confirms"
smate cn pCN harness=claude session_id=; : >"$H/herdr/panes/pCN.claude-composer"
srun cn 'no session id'; assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to herdr:pane-pCN" "8: no session id"
sclaude cm pCM SIDM
srun cm 'two'; assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to herdr:pane-pCM" "8: no transcript"
sturn SIDM 'two'
sturn SIDM 'two' claude/proj2
srun cm 'two'; assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to herdr:pane-pCM" "8: two transcripts for one id"
rm -f "$H/claude/proj2/SIDM.jsonl"
srun cm 'two'; assert_eq "$SN_RC:$(sout)" "0:sent to herdr:pane-pCM" "8: ... and one confirms"
sput claude/proj/SIDM.jsonl '{"type":"user","promptSource":"typed","origin":{"kind":"human"},"message":{"role":"user","content":[{"type":"tool_result"}]}}
'
srun cm 'two'; assert_eq "$SN_RC:$(sout)" "0:delivered (arrival unverified) to herdr:pane-pCM" "8: a tool-result turn is no typed turn"
sturn SIDA 'from the config dir' cfg/projects/p
SENV=(AC_CLAUDE_TRANSCRIPT_ROOT= CLAUDE_CONFIG_DIR=@H/cfg)
srun ca 'from the config dir'; assert_eq "$SN_RC:$(sout)" "0:sent to herdr:pane-pCA" "8: the root falls back to CLAUDE_CONFIG_DIR"
sturn SIDA 'from home' fakehome/.claude/projects/p
SENV=(AC_CLAUDE_TRANSCRIPT_ROOT= HOME=@H/fakehome)
srun ca 'from home'; assert_eq "$SN_RC:$(sout)" "0:sent to herdr:pane-pCA" "8: ... then to HOME"
SENV=(AC_SEND_SETTLE=0.01)
rm -f "$H/sleep.log"
srun ca 'paced'; assert_eq "$(grep -c 'sleep 0.01' "$H/sleep.log")" 8 "8: the pause after typing, the one submit probe, then six arrival reads a settle apart"
SENV=()

# 9. the status record: `steered: <text, LFs as spaces>`, stamped by date(1)
#    and mirrored to the task's timeline.
srun c1 $'two\nlines'; assert_eq "$(tail -n 1 "$H/home/state/c1.status")" "2026-01-02T03:04:05Z steered: two lines" "9: one record per send"
assert_eq "$(tail -n 1 "$H/home/data/c1/timeline.log")" "2026-01-02T03:04:05Z steered: two lines" "9: ... mirrored to the timeline"

# 10. orca: keys; a text delivered to orca:<handle>, past an agent_blocked
#     whose jq -e failed (status 5 is not blocked); agentWait blocks text,
#     and --force reaches the send's dialog guard - typed, no Enter, NOT
#     confirmed (V16); a shell title is a bare shell; an endless strand; an
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
sorca o1 term1
sput orca/terminals/term1.drop-enters $'99\n'
srun o1 'stuck'; assert_eq "$SN_RC:$(slast)" "1:ERROR: delivery NOT confirmed for o1 - the text likely sits stranded in the composer (see stderr above)" "10: an endless strand"
rm -f "$H/orca/terminals/term1.drop-enters"
touch "$H/orca/terminals/term1.exited"
srun o1 hi; assert_eq "$SN_RC:$(serr)" "1:ERROR: window gone for o1" "10: an exited terminal is gone"
rm -f "$H/orca/terminals/term1.exited"
touch "$H/orca/.unreachable"
srun o1 hi; assert_eq "$SN_RC:$(serr)" "1:ERROR: the BACKEND could not be read for o1 - nothing was delivered, and the pane's liveness is UNKNOWN (it may well be alive); check the backend itself (herdr status server), then send again" "10: an unreachable runtime"
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
  (cd "$H" && env -u AC_BACKEND -u AC_SOLO LC_ALL=C PATH="$TMP/sstub:$TMP/stubbin:$PATH" FAKE_HERDR="$H/herdr" FAKE_ORCA="$H/orca" STUB_DIR="$H" \
    EPOCHSECONDS="$SEPOCH" AC_GUARD_ROOT="$TMP/sguard-root" AC_HOME="$H/home" AC_SEND_SETTLE=0 \
    bash -c 'if [ "$1" = pipe ]; then "$0/ac-send.sh" c1 --key Enter | true; printf "%s" "${PIPESTATUS[0]}"; else "$0/ac-send.sh" c1 --key Enter >&- 2>/dev/null; printf "%s" "$?"; fi' "$BIN" "$1") </dev/null
}
assert_eq "$(sclosed pipe)" "141" "11: a reader gone before the final line ends the run with 141"
assert_eq "$(sclosed shut)" "1" "11: a closed stdout ends the run 1"
assert_contains "$(cat "$H/herdr/log")" "herdr pane send-keys pC1 enter" "11: ... after the key was pressed"

# 12. stdin, bytes, the home, and bun.
# - STDIN BY POSITION: the submit check's `pane read` reads /dev/null, never
#   the caller's stdin, with or without the harness probe.
printf 'caller bytes\n' >"$TMP/sstdin.in"
touch "$H/stdin-pane-read"
SSTDIN="$TMP/sstdin.in"
srun c1 'with stdin'; assert_eq "$SN_RC:$(sout)" "0:$SDEL" "12: a send with stdin attached delivers"
assert_eq "$(cat "$H/stdin.log")" "herdr pane read stdin=[]
herdr pane read stdin=[]" "12: its pane reads take /dev/null"
rm -f "$H/stdin.log"
srun c1 --force 'forced with stdin'; assert_eq "$SN_RC:$(cat "$H/stdin.log")" "0:herdr pane read stdin=[]
herdr pane read stdin=[]" "12: without the probe too"
SSTDIN=/dev/null
rm -f "$H/stdin.log" "$H/stdin-pane-read"
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
  case "$(cat "$H/herdr/panes/pC1.buf")" in *"no bun"*) fail "12: bun absent - nothing is typed" ;; esac
else
  printf 'SKIP: row 12 bun-absent - bun sits in /usr/bin or /bin on this host\n'
fi
SPATH=""

pass
