#!/usr/bin/env bash
# ac-backend-orca.test.sh - the orca driver of the backend contract behind the
# per-call dispatch: handle persistence, three-state liveness, capture,
# verified send, key mapping, came-up probe, agent idle/blocked, wait stamp,
# kill - plus the guarantees the dispatch owes herdr: per-task routing inside
# one process, and no herdr RPC ever issued under the orca backend.
# shellcheck disable=SC2016  # script bodies are deliberately unexpanded here

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

command -v jq >/dev/null || { printf 'SKIP: jq not available\n'; exit 0; }

make_home
make_fake_orca
make_fake_herdr
export AC_SEND_SETTLE=0.05

run_backend() {
  # run_backend <backend> <script> - source the libs with the fake CLIs on
  # PATH and the given backend, then run the script body.
  AC_BACKEND="$1" AC_HOME="$AC_HOME" bash -c "
    set -euo pipefail
    . '$BIN/ac-lib.sh'
    . '$BIN/ac-backend.sh'
    $2
  "
}

# --- window_new + handle + target ------------------------------------------------

run_backend orca '
  backend_window_new o1 /tmp/wt
  backend_window_alive o1
  [ "$(backend_target o1)" = "orca:term1" ]
' >/dev/null
assert_eq "$(cat "$AC_HOME/state/.pane-o1")" "term1 tab1" \
  "orca handle+tab recorded in the shared 2-field grammar"
assert_contains "$(cat "$FAKE_ORCA/log")" \
  "terminal create --worktree path:/tmp/wt --title crew:home/o1" \
  "a project-worktree pane groups under ITS OWN worktree node"
assert_contains "$(cat "$FAKE_ORCA/log")" "cd '/tmp/wt'" \
  "window_new moves the shell to the requested dir (create has no cwd flag)"
assert_eq "$(cat "$FAKE_HERDR/log" 2>/dev/null || true)" "" \
  "no herdr RPC under the orca backend"

# --- window_alive: three states --------------------------------------------------

touch "$FAKE_ORCA/terminals/term1.exited"
rc=0; run_backend orca 'backend_window_alive o1' || rc=$?
assert_eq "$rc" "1" "a disconnected terminal is GONE"
rm -f "$FAKE_ORCA/terminals/term1.exited"

# Vanished terminal, reachable runtime: `show` fails but `status` answers -
# the control call on the same CLI is the definite GONE.
mv "$FAKE_ORCA/terminals/term1.buf" "$FAKE_ORCA/term1.buf.bak"
rc=0; run_backend orca 'backend_window_alive o1' || rc=$?
assert_eq "$rc" "1" "a runtime that answers but cannot show the terminal is GONE"
mv "$FAKE_ORCA/term1.buf.bak" "$FAKE_ORCA/terminals/term1.buf"

touch "$FAKE_ORCA/.unreachable"
rc=0; run_backend orca 'backend_window_alive o1' || rc=$?
assert_eq "$rc" "2" "an unreachable runtime is UNOBSERVABLE, never a verdict"
rm -f "$FAKE_ORCA/.unreachable"

: >"$FAKE_ORCA/log"
rc=0; run_backend orca 'backend_window_alive nohandle' || rc=$?
assert_eq "$rc" "1" "no recorded handle stays GONE - a local fact costs no RPC"
assert_eq "$(cat "$FAKE_ORCA/log")" "" "the no-handle answer asks the runtime nothing"

# --- capture ---------------------------------------------------------------------

printf 'one\ntwo\nthree\n' >"$FAKE_ORCA/terminals/term1.buf"
out="$(run_backend orca 'backend_capture o1 2')"
assert_eq "$out" "two
three" "capture tails the requested lines"
out="$(run_backend orca 'backend_capture_pane term1 1')"
assert_eq "$out" "three" "raw-pane capture addresses the handle directly"
assert_fails run_backend orca 'backend_capture_pane "" 1'

# A full-screen TUI SITTING STILL emits nothing new, so the CLI's default
# accumulated read comes back EMPTY while the pane plainly renders a prompt -
# its own help calls that default "unsuitable for verifying rendered output".
# Every capture here answers a question about what the pane SHOWS (did the
# harness come up, did the submit land, did a marker appear), so the driver
# must read the RENDERED screen.
: >"$FAKE_ORCA/terminals/term1.buf"
printf '> ready for input\n' >"$FAKE_ORCA/terminals/term1.screen"
out="$(run_backend orca 'backend_capture o1 5')"
assert_contains "$out" "ready for input" \
  "capture reads the RENDERED screen, not the accumulated stream an idle TUI leaves empty"
assert_contains "$(cat "$FAKE_ORCA/log")" "terminal read --terminal term1 --limit 5 --screen" \
  "the read asks for the screen explicitly"
rm -f "$FAKE_ORCA/terminals/term1.screen"
printf 'one\ntwo\nthree\n' >"$FAKE_ORCA/terminals/term1.buf"

# --- send_line: type, verified submit, strand, unobservable ----------------------

: >"$FAKE_ORCA/log"
run_backend orca 'backend_send_line o1 "hello crew"' >/dev/null
assert_contains "$(cat "$FAKE_ORCA/log")" "--text hello crew" \
  "text typed without submitting"
assert_contains "$(cat "$FAKE_ORCA/terminals/term1.buf")" "hello crew" \
  "the verified Enter landed the composer into the transcript"

# A LARGE payload is typed in chunks and must reassemble byte-identically:
# one big --text write measurably lost its first ~4KB (a ~4.7KB kickoff
# arrived as its last 723 bytes - live, 2026-08-26).
big="$(printf 'chunkpayload-%03d ' $(seq 1 80))"
: >"$FAKE_ORCA/log"
run_backend orca "backend_send_line o1 \"$big\"" >/dev/null
sends="$(grep -c -- '--text .*chunkpayload' "$FAKE_ORCA/log" || true)"
[ "$sends" -ge 2 ] || fail "a >512B payload must be typed in more than one chunk (got $sends)"
assert_contains "$(cat "$FAKE_ORCA/terminals/term1.buf")" "$big" \
  "the chunked payload reassembles byte-identically in the transcript"
case "$(cat "$FAKE_ORCA/log")" in
  *"terminal switch"*) fail "an acked first submit must not focus-steal" ;;
esac

: >"$FAKE_ORCA/log"
printf '99\n' >"$FAKE_ORCA/terminals/term1.drop-enters"
rc=0; run_backend orca 'backend_send_line o1 "stranded text"' 2>/dev/null || rc=$?
assert_eq "$rc" "1" "a swallowed Enter is a STRAND after the one focused retry"
assert_contains "$(cat "$FAKE_ORCA/log")" "terminal switch --terminal term1" \
  "the strand retry focuses first"
rm -f "$FAKE_ORCA/terminals/term1.drop-enters"
: >"$FAKE_ORCA/terminals/term1.in"

# A swallowed Enter that still CHANGES the render (a popup closing, an
# argument hint filling) - the render-react check alone reads that change as
# a submit and reports "sent" while the text sits pending. The composer
# REGION still holding the text (between the last two rules - measured live:
# the transcript echoes a submitted line with the same glyph, so
# text-anywhere is no verdict) is what proves pending and buys the bounded
# retry Enter.
: >"$FAKE_ORCA/terminals/term1.in"
touch "$FAKE_ORCA/terminals/term1.popup-once"
run_backend orca 'backend_send_line o1 "steer past the popup"' >/dev/null \
  || fail "the retry Enter must land the steer once the popup closed"
assert_eq "$(cat "$FAKE_ORCA/terminals/term1.in")" "" \
  "a reported sent must leave the composer EMPTY - pending text is the false-success class"
assert_contains "$(cat "$FAKE_ORCA/terminals/term1.buf")" "steer past the popup" \
  "the steer reaches the transcript after the retry"
rm -f "$FAKE_ORCA/terminals/term1.popup-once"

# The pending check must survive a C locale: grep intervals over the 3-byte
# rule glyph bind to its last byte under LC_ALL=C and never match, silently
# reviving the false-"sent" class (measured on this host).
: >"$FAKE_ORCA/terminals/term1.in"
touch "$FAKE_ORCA/terminals/term1.popup-once"
LC_ALL=C LANG=C run_backend orca 'backend_send_line o1 "locale steer"' >/dev/null \
  || fail "the locale-pinned retry must land the steer"
assert_eq "$(cat "$FAKE_ORCA/terminals/term1.in")" "" \
  "the pending check holds under a C locale - no silent false-sent"
rm -f "$FAKE_ORCA/terminals/term1.popup-once"

# A DIALOG owns the pane: no verified submit may press Enter into it - not
# the first press, and never a focus-retry press (the digit options can grant
# a permanent always-allow). The refusal names the dialog.
printf 'dialog text\n' >"$FAKE_ORCA/terminals/term1.in"
touch "$FAKE_ORCA/terminals/term1.agentwait"
: >"$FAKE_ORCA/log"
rc=0; err="$(run_backend orca 'backend_send_line o1 "into a dialog"' 2>&1 1>/dev/null)" || rc=$?
[ "$rc" != 0 ] || fail "a dialog-owned pane must not report sent"
assert_contains "$err" "DIALOG" "the refusal names the dialog"
case "$(cat "$FAKE_ORCA/log")" in
  *--enter*) fail "no Enter may be pressed into a dialog-owned pane" ;;
esac
rm -f "$FAKE_ORCA/terminals/term1.agentwait"
: >"$FAKE_ORCA/terminals/term1.in"

# The bare submit verb now carries the text too: the kickoff retry is its one
# caller, and a textless verify read a trust popup closing as delivery.
printf 'kick text' >"$FAKE_ORCA/terminals/term1.in"
touch "$FAKE_ORCA/terminals/term1.popup-once"
run_backend orca 'backend_submit_verified o1 "kick text"' >/dev/null \
  || fail "the texted submit verb must land past the popup"
assert_eq "$(cat "$FAKE_ORCA/terminals/term1.in")" "" \
  "backend_submit_verified with text proves the composer cleared"
rm -f "$FAKE_ORCA/terminals/term1.popup-once"

touch "$FAKE_ORCA/.unreachable"
rc=0; run_backend orca 'backend_send_line o1 "x"' 2>/dev/null || rc=$?
assert_eq "$rc" "2" "an unreadable terminal reports UNOBSERVABLE, never a strand"
rm -f "$FAKE_ORCA/.unreachable"

run_backend orca 'backend_send_line_pane term1 "raw addressed"' >/dev/null
assert_contains "$(cat "$FAKE_ORCA/terminals/term1.buf")" "raw addressed" \
  "raw-pane send_line submits like the id-keyed one"
assert_fails run_backend orca 'backend_send_line_pane "" x'

# --- send_key: Enter / Escape / C-c mapping --------------------------------------

: >"$FAKE_ORCA/log"
run_backend orca 'backend_send_key o1 C-c' >/dev/null
assert_contains "$(cat "$FAKE_ORCA/log")" "--interrupt" "C-c maps to --interrupt"

run_backend orca 'backend_send_key o1 Escape' >/dev/null
esc="$(printf '\033')"
case "$(cat "$FAKE_ORCA/terminals/term1.in")" in
  *"$esc"*) ;;
  *) fail "Escape must reach the composer as the raw ESC byte" ;;
esac
: >"$FAKE_ORCA/terminals/term1.in"

run_backend orca 'backend_send_key_pane term1 Enter' >/dev/null
assert_fails run_backend orca 'backend_send_key_pane "" Enter'

# --- harness came-up probe: proven SHELL / proven TUI / else unobservable --------

rc=0; run_backend orca 'backend_harness_up o1' || rc=$?
assert_eq "$rc" "1" "a shell title (zsh) reads as SHELL - no harness came up"
printf -- '-zsh\n' >"$FAKE_ORCA/terminals/term1.title"
rc=0; run_backend orca 'backend_harness_up_pane term1' || rc=$?
assert_eq "$rc" "1" "a login-shell title (-zsh) is still a shell"
# A non-shell ASCII title alone proves nothing (a themed zsh titles itself
# with the CWD - measured live); a satisfied tui-idle, or a harness GLYPH
# title (claude's ✳/◐ spinner vocabulary - measured), proves a TUI came up.
printf 'claude\n' >"$FAKE_ORCA/terminals/term1.title"
rc=0; run_backend orca 'backend_harness_up o1' || rc=$?
assert_eq "$rc" "2" "a non-shell ASCII title with no idle TUI stays UNOBSERVABLE, never UP"
touch "$FAKE_ORCA/terminals/term1.idle"
run_backend orca 'backend_harness_up o1'
rm -f "$FAKE_ORCA/terminals/term1.idle"
printf '\342\227\220 Learning transaction placement\n' >"$FAKE_ORCA/terminals/term1.title"
run_backend orca 'backend_harness_up o1'
printf 'claude\n' >"$FAKE_ORCA/terminals/term1.title"
rc=0; run_backend orca 'backend_harness_up_pane ""' || rc=$?
assert_eq "$rc" "2" "an empty handle is UNOBSERVABLE"
touch "$FAKE_ORCA/.unreachable"
rc=0; run_backend orca 'backend_harness_up o1' || rc=$?
assert_eq "$rc" "2" "an unreadable terminal is UNOBSERVABLE, never a dead harness"
rm -f "$FAKE_ORCA/.unreachable"
touch "$FAKE_ORCA/terminals/term1.exited"
rc=0; run_backend orca 'backend_harness_up o1' || rc=$?
assert_eq "$rc" "2" "an exited terminal cannot be probed - UNOBSERVABLE"
rm -f "$FAKE_ORCA/terminals/term1.exited"

# --- agent idle / blocked / captain-wait stamp -----------------------------------

rc=0; run_backend orca 'backend_agent_idle o1' || rc=$?
assert_eq "$rc" "1" "no tui-idle satisfaction reads as not idle"
touch "$FAKE_ORCA/terminals/term1.idle"
run_backend orca 'backend_agent_idle o1'
run_backend orca 'backend_agent_idle_pane term1'
assert_fails run_backend orca 'backend_agent_idle_pane ""'
rm -f "$FAKE_ORCA/terminals/term1.idle"
# Orca's tui-idle NEVER satisfies on a fleet pane (TUI launched from an
# exec'd shell, not the terminal's own command - measured live), so the
# driver also reads the harness's OWN title glyph: idle settles on a
# leading U+2733 (claude, measured), a working spinner glyph does not.
printf '\342\234\263 Claude Code\n' >"$FAKE_ORCA/terminals/term1.title"
run_backend orca 'backend_agent_idle o1'
printf '\342\227\220 working on things\n' >"$FAKE_ORCA/terminals/term1.title"
rc=0; run_backend orca 'backend_agent_idle o1' || rc=$?
assert_eq "$rc" "1" "a working-glyph title is not idle"

# --- Orca's OWN harness detection: every harness, not claude's glyphs -----------
# Measured on codex 0.150.1 under orca CLI 1.4.188, both pane shapes: `show`
# reports agentIdentity ("codex") once the TUI owns the pane, and a startup
# dialog rides agentWait {source:"prompt-text", reason} while the exec'd
# shell's title still reads "cd". Codex's OWN title is the cwd basename when
# idle and a braille spinner (U+2807 ...) before it while working; tui-idle
# DOES satisfy for codex (it never did for claude), but it also satisfies
# under the spinner, so the spinner, not tui-idle, tells working from idle.
printf 'cd\n' >"$FAKE_ORCA/terminals/term1.title"
printf 'codex-update-prompt\n' >"$FAKE_ORCA/terminals/term1.dialog"
run_backend orca 'backend_harness_up o1' \
  || fail "a startup dialog named by agentWait IS a harness - came-up must read UP"
rc=0; run_backend orca 'backend_agent_idle o1' || rc=$?
assert_eq "$rc" "1" "a pane parked on a startup dialog is not idle"
rm -f "$FAKE_ORCA/terminals/term1.dialog"
printf 'agent-crew\n' >"$FAKE_ORCA/terminals/term1.title"
printf 'codex\n' >"$FAKE_ORCA/terminals/term1.agent"
run_backend orca 'backend_harness_up o1' \
  || fail "agentIdentity=codex proves the harness came up without any claude glyph"
rc=0; run_backend orca 'backend_agent_idle o1' || rc=$?
assert_eq "$rc" "1" "identity alone is not idleness - tui-idle must satisfy"
touch "$FAKE_ORCA/terminals/term1.idle"
run_backend orca 'backend_agent_idle o1' || fail "codex: tui-idle satisfied + plain cwd title = idle"
assert_eq "$(run_backend orca 'backend_agent_status_pane term1')" "idle" "status reads idle for a resting codex"
printf '\342\240\207 agent-crew\n' >"$FAKE_ORCA/terminals/term1.title"
rc=0; run_backend orca 'backend_agent_idle o1' || rc=$?
assert_eq "$rc" "1" "codex: a braille spinner title is WORKING even while tui-idle satisfies"
assert_eq "$(run_backend orca 'backend_agent_status_pane term1')" "working" "status reads working under the braille spinner"
run_backend orca 'backend_harness_up o1' || fail "a spinner-titled codex is a harness that came up"
rm -f "$FAKE_ORCA/terminals/term1.idle" "$FAKE_ORCA/terminals/term1.agent"
printf 'zsh\n' >"$FAKE_ORCA/terminals/term1.title"

# --- startup dialogs answered BY NAME ---------------------------------------------
# Orca names the dialog; the driver answers the ones it knows with the key
# that is safe on THAT dialog (a bare Enter on codex's update prompt runs the
# upgrade - the measured incident that left a crewmate mid-install and never
# booting), reports an unknown one so the caller can fall back to the
# registry's blind key, and says when nothing is pending at all.
: >"$FAKE_ORCA/log"
rc=0; run_backend orca 'backend_dialog_answer o1' || rc=$?
assert_eq "$rc" "1" "no dialog pending reads 1"
printf 'codex-update-prompt\n' >"$FAKE_ORCA/terminals/term1.dialog"
printf 'codex-hooks-review-prompt\n' >"$FAKE_ORCA/terminals/term1.dialog-next"
run_backend orca 'backend_dialog_answer o1' || fail "a known dialog is answered (0)"
assert_contains "$(cat "$FAKE_ORCA/log")" "--text 2" "the update prompt is answered with 2 (Skip), never Enter"
assert_eq "$(head -1 "$FAKE_ORCA/terminals/term1.dialog")" "codex-hooks-review-prompt" "one answer, one dialog - the next one is left for the next call"
: >"$FAKE_ORCA/log"
run_backend orca 'backend_dialog_answer_pane term1' || fail "the pane twin answers too"
assert_contains "$(cat "$FAKE_ORCA/log")" "--text 2" "the hooks-review prompt is answered with 2 (trust the tracked hooks and continue)"
assert_no_file "$FAKE_ORCA/terminals/term1.dialog" "the last dialog is dismissed"
printf 'codex-something-new\n' >"$FAKE_ORCA/terminals/term1.dialog"
: >"$FAKE_ORCA/log"
rc=0; run_backend orca 'backend_dialog_answer o1' || rc=$?
assert_eq "$rc" "2" "an unknown dialog is reported (2), not guessed at"
case "$(cat "$FAKE_ORCA/log")" in *"terminal send"*) fail "an unknown dialog must receive no keystroke from the driver" ;; esac
rm -f "$FAKE_ORCA/terminals/term1.dialog"
rc=0; run_backend orca 'backend_dialog_answer_pane ""' || rc=$?
assert_eq "$rc" "3" "an empty handle is unobservable (3)"
touch "$FAKE_ORCA/.unreachable"
rc=0; run_backend orca 'backend_dialog_answer o1' || rc=$?
assert_eq "$rc" "3" "an unreachable backend is unobservable (3)"
rm -f "$FAKE_ORCA/.unreachable"
rc=0; run_backend herdr 'backend_dialog_answer_pane p1' || rc=$?
assert_eq "$rc" "3" "herdr names no dialog: always unobservable (3), the blind key stays"

# --- the startup SEQUENCE both launchers run ------------------------------------
# Named dialogs are answered as they appear (update, then hooks review), the
# blind Enter is NEVER typed while the backend can name what it sees, and the
# sequence ends once the harness is observed up.
printf 'cd\n' >"$FAKE_ORCA/terminals/term1.title"
printf 'codex-update-prompt\n' >"$FAKE_ORCA/terminals/term1.dialog"
printf 'codex-hooks-review-prompt\n' >"$FAKE_ORCA/terminals/term1.dialog-next"
printf 'codex\n' >"$FAKE_ORCA/terminals/term1.agent"
: >"$FAKE_ORCA/log"
run_backend orca 'backend_startup_dialogs_pane term1 codex'
assert_eq "$(grep -c -- '--text 2' "$FAKE_ORCA/log")" "2" "both codex dialogs are answered by name, in order"
case "$(cat "$FAKE_ORCA/log")" in *"--enter"*) fail "no blind Enter while every dialog was named" ;; esac
assert_no_file "$FAKE_ORCA/terminals/term1.dialog" "the sequence leaves no dialog standing"
# An unnamed dialog gets the registry's blind key exactly once.
printf 'codex-trust-prompt\n' >"$FAKE_ORCA/terminals/term1.dialog"
: >"$FAKE_ORCA/log"
run_backend orca 'backend_startup_dialogs o1 codex'
assert_eq "$(grep -c -- '--enter' "$FAKE_ORCA/log")" "1" "an unnamed dialog gets the blind Enter once"
# A harness with no registry key and nothing pending types nothing.
: >"$FAKE_ORCA/log"
run_backend orca 'backend_startup_dialogs o1 claude'
case "$(cat "$FAKE_ORCA/log")" in *"terminal send"*) fail "claude with nothing pending must receive no keystroke" ;; esac
# herdr: the blind key right away (pre-contract behaviour), and only for a
# harness whose registry names one.
: >"$FAKE_HERDR/log"
run_backend herdr 'backend_startup_dialogs_pane p1 codex'
assert_contains "$(cat "$FAKE_HERDR/log")" "send-keys p1 enter" "herdr presses the registry key at once"
: >"$FAKE_HERDR/log"
run_backend herdr 'backend_startup_dialogs_pane p1 claude'
case "$(cat "$FAKE_HERDR/log")" in *send*) fail "herdr types nothing for a keyless harness" ;; esac
rm -f "$FAKE_ORCA/terminals/term1.agent"
printf 'zsh\n' >"$FAKE_ORCA/terminals/term1.title"

rc=0; run_backend orca 'backend_agent_blocked o1' || rc=$?
assert_eq "$rc" "1" "agentWait null is not blocked"
touch "$FAKE_ORCA/terminals/term1.agentwait"
run_backend orca 'backend_agent_blocked o1'
run_backend orca 'backend_mark_wait o1 "waiting on captain"'
[ -e "$AC_HOME/state/.captain-wait-o1" ] || fail "mark_wait must leave the stamp file"
rc=0; run_backend orca 'backend_agent_blocked o1' || rc=$?
assert_eq "$rc" "1" "the captain-wait stamp masks blocked - no self-inflicted ask wakes"
run_backend orca 'backend_clear_wait o1'
[ ! -e "$AC_HOME/state/.captain-wait-o1" ] || fail "clear_wait must remove the stamp"
run_backend orca 'backend_clear_wait o1'
rm -f "$FAKE_ORCA/terminals/term1.agentwait"
assert_fails run_backend orca 'backend_mark_wait nohandle'

# --- raw status enum (backend_agent_status_pane) ---------------------------------
# ac-pane-agent's turn-end fallback needs the VALUE, not a boolean.
printf '\342\234\263 Claude Code\n' >"$FAKE_ORCA/terminals/term1.title"
assert_eq "$(run_backend orca 'backend_agent_status_pane term1')" "idle" \
  "an idle-glyph title reads as idle"
printf '\342\227\220 busy work\n' >"$FAKE_ORCA/terminals/term1.title"
assert_eq "$(run_backend orca 'backend_agent_status_pane term1')" "working" \
  "a spinner-glyph title reads as working"
# claude's spinner cycles the full quarter-moon set ◐◓◑◒ (measured live
# 2026-08-27: a working pane titled "◑ Shortfile-gate kickoff") - every
# phase must read working, never only the first.
for moon in '\342\227\223' '\342\227\221' '\342\227\222'; do
  printf "$moon busy work\n" >"$FAKE_ORCA/terminals/term1.title"
  assert_eq "$(run_backend orca 'backend_agent_status_pane term1')" "working" \
    "quarter-moon spinner phase $moon reads as working"
  run_backend orca 'backend_harness_up o1'
done
touch "$FAKE_ORCA/terminals/term1.agentwait"
assert_eq "$(run_backend orca 'backend_agent_status_pane term1')" "blocked" \
  "agentWait outranks the glyph - a parked prompt is blocked"
rm -f "$FAKE_ORCA/terminals/term1.agentwait"
touch "$FAKE_ORCA/.unreachable"
assert_eq "$(run_backend orca 'backend_agent_status_pane term1')" "unknown" \
  "an unreadable pane is unknown, never a guess"
rm -f "$FAKE_ORCA/.unreachable"
assert_eq "$(run_backend orca 'backend_agent_status_pane ""')" "unknown" \
  "an empty handle is unknown"
printf 'claude\n' >"$FAKE_ORCA/terminals/term1.title"

# --- verification-pane placement: RUNCMD as the pane's own command ---------------
: >"$FAKE_ORCA/log"
out="$(run_backend orca 'orca_place_pane /tmp/vp "cd /tmp/vp && echo agent-run" ac-codereview')"
case "$out" in term*\ tab*) ;; *) fail "place_pane must print '<handle> <tab>' (got: $out)" ;; esac
assert_contains "$(cat "$FAKE_ORCA/log")" "--command cd /tmp/vp && echo agent-run" \
  "the verification pane starts WITH its RUNCMD - nothing typed into a booting surface"

# --- kill ------------------------------------------------------------------------

: >"$FAKE_ORCA/log"
run_backend orca 'backend_kill_window o1'
[ ! -e "$AC_HOME/state/.pane-o1" ] || fail "kill must remove the handle file"
assert_contains "$(cat "$FAKE_ORCA/log")" "terminal close --terminal term1 --json" \
  "kill closes the PANE alone - the shared family tab dies with its last pane"
case "$(grep 'terminal close' "$FAKE_ORCA/log" | tail -n 1)" in
  *"--tab"*) fail "kill must never take the whole tab - siblings share it" ;;
esac
[ ! -e "$FAKE_ORCA/terminals/term1.buf" ] || fail "the fake terminal must be gone after close"
run_backend orca 'backend_kill_window o1'

# --- GROUPING: rooms = tabs under the HOME; workers under their worktrees -------
# Chief-kind panes (cwd = the home) get one FAMILY TAB per room under the
# home node; crewmate/verifier panes (cwd = a worktree) each get their own
# tab under that worktree's node.

run_backend orca '
  export AC_WINDOW_FAMILY=famx
  backend_window_new fx-chief "$AC_HOME"
  backend_window_new fx-crew1 /tmp/wt-fx
  export AC_WINDOW_FAMILY=famy
  backend_window_new fy-chief "$AC_HOME"
' >/dev/null
tab_fx="$(awk '{print $2}' "$AC_HOME/state/.pane-fx-chief")"
tab_crew="$(awk '{print $2}' "$AC_HOME/state/.pane-fx-crew1")"
tab_fy="$(awk '{print $2}' "$AC_HOME/state/.pane-fy-chief")"
[ "$tab_fx" != "$tab_fy" ] || fail "two rooms must open two tabs under the home"
[ "$tab_crew" != "$tab_fx" ] || fail "a worktree pane must NOT join the room tab - it lives under its worktree"
assert_contains "$(cat "$FAKE_ORCA/log")" "terminal create --worktree path:$AC_HOME --title crew:home/fx-chief" \
  "a chief-kind pane groups under the HOME node - creation titles carry the fleet token (crew:<fleet>/<id>, display-only) so mixed-fleet tab lists stay tellable"
assert_contains "$(cat "$FAKE_ORCA/log")" "terminal create --worktree path:/tmp/wt-fx --title crew:home/fx-crew1" \
  "a crewmate pane groups under its own worktree node"
assert_eq "$(cat "$AC_HOME/state/.orca-fam-famx")" "$tab_fx" \
  "the family record names the room's home tab"
assert_no_file "$AC_HOME/state/.orca-fam-_root" "a worktree pane mints no family record"

# config/orca-node pins the HOME node by FULL SELECTOR - measured: two Orca
# worktree entries can share one path (a workspace-scoped entry rides an
# `::workspace:` id suffix), and a `path:` selector always matches the main
# entry - so a deputy home under the same container as its parent needs the
# id selector to get its own sidebar node. Worker panes are unaffected.
printf 'id:fake-repo::/x::workspace:w1\n' >"$AC_HOME/config/orca-node"
run_backend orca '
  export AC_WINDOW_FAMILY=famz
  backend_window_new fz-chief "$AC_HOME"
  backend_window_new fz-crew /tmp/wt-fx
' >/dev/null
assert_contains "$(cat "$FAKE_ORCA/log")" "terminal create --worktree id:fake-repo::/x::workspace:w1 --title crew:home/fz-chief" \
  "config/orca-node pins the home-node selector verbatim"
assert_contains "$(cat "$FAKE_ORCA/log")" "terminal create --worktree path:/tmp/wt-fx --title crew:home/fz-crew" \
  "the pin never touches worker-pane placement"
run_backend orca 'backend_kill_window fz-chief; backend_kill_window fz-crew'
rm -f "$AC_HOME/config/orca-node"

# A second same-family pane AT THE HOME splits into the room tab.
run_backend orca '
  export AC_WINDOW_FAMILY=famx
  backend_window_new fx-aide "$AC_HOME"
' >/dev/null
assert_eq "$(awk '{print $2}' "$AC_HOME/state/.pane-fx-aide")" "$tab_fx" \
  "a same-family home pane SPLITS into the room tab"
assert_contains "$(cat "$FAKE_ORCA/log")" "terminal split --terminal" \
  "the second home pane arrives by split"

# Closing the last home pane of a room clears its record; a dead tab heals.
run_backend orca 'backend_kill_window fx-aide'
assert_file "$AC_HOME/state/.orca-fam-famx" "a surviving sibling keeps the family record"
run_backend orca 'backend_kill_window fx-chief'
assert_no_file "$AC_HOME/state/.orca-fam-famx" \
  "the last close clears the family record - the workspace ends with the room"
run_backend orca 'backend_kill_window fy-chief; backend_kill_window fx-crew1'
run_backend orca '
  export AC_WINDOW_FAMILY=famy
  backend_window_new fy-again "$AC_HOME"
' >/dev/null
[ "$(awk '{print $2}' "$AC_HOME/state/.pane-fy-again")" != "$tab_fy" ] \
  || fail "a family whose tab died must get a FRESH tab, not a stale record"
run_backend orca 'backend_kill_window fy-again'

# --- per-task dispatch: both drivers in ONE process ------------------------------

run_backend herdr '
  backend_window_new mixh /tmp
  [ "$(backend_target mixh)" = "herdr:pane-p1" ]
  export AC_BACKEND=orca
  backend_window_new mixo /tmp
  case "$(backend_target mixo)" in orca:term*) ;; *) exit 9 ;; esac
  export AC_BACKEND=herdr
  [ "$(backend_target mixh)" = "herdr:pane-p1" ]
' >/dev/null

# --- rejection: unknown names still refuse, naming the valid set -----------------

assert_fails run_backend tmux 'backend_target x1'
err="$(run_backend tmux 'backend_target x1' 2>&1 || true)"
assert_contains "$err" "valid backends: herdr, orca" \
  "rejection names the valid backend set"

# --- homeless resolution rides AC_FLEET_STATE ------------------------------------
# A crewmate pane deliberately carries NO AC_HOME and no AC_BACKEND - only the
# AC_FLEET_* channel (ac-spawn fleet_env). A verifier it calls (ac-verify via
# ac-qa) must still resolve the FLEET's backend, not the herdr default
# (measured: an orca-fleet QA round opened a herdr pane and leased from the
# crew-tree pool).
mkdir -p "$AC_HOME/config" "$AC_HOME/state"
printf 'orca\n' >"$AC_HOME/config/backend"
b="$(env -u AC_HOME -u AC_BACKEND AC_FLEET_STATE="$AC_HOME/state" bash -c "
  set -euo pipefail
  . '$BIN/ac-lib.sh'
  . '$BIN/ac-backend.sh'
  ac_backend
")"
assert_eq "$b" "orca" "a homeless caller resolves the fleet backend via AC_FLEET_STATE"
b="$(env -u AC_HOME AC_BACKEND=herdr AC_FLEET_STATE="$AC_HOME/state" bash -c "
  set -euo pipefail
  . '$BIN/ac-lib.sh'
  . '$BIN/ac-backend.sh'
  ac_backend
")"
assert_eq "$b" "herdr" "an explicit AC_BACKEND pin still outranks the fleet-state rung"
# The ROUTE and the herdr-RPC guard must resolve through the same ladder, not
# the raw env default: a homeless pane agent on an orca fleet placed its pane
# through the orca driver but READ it through herdr (capture, harness-up, the
# ready gate all route) - the pane came up unreadable and the prompt never
# landed.
printf 'HOMELESS-ORCA-BUF\n' >"$FAKE_ORCA/terminals/hless.buf"
printf 'tabH\n' >"$FAKE_ORCA/terminals/hless.tab"
out="$(env -u AC_HOME -u AC_BACKEND AC_FLEET_STATE="$AC_HOME/state" bash -c "
  set -euo pipefail
  . '$BIN/ac-lib.sh'
  . '$BIN/ac-backend.sh'
  backend_capture_pane hless 5
" 2>/dev/null || true)"
assert_contains "$out" "HOMELESS-ORCA-BUF" \
  "routed pane reads follow the fleet-state backend, never the raw env default"
err="$(env -u AC_HOME -u AC_BACKEND AC_FLEET_STATE="$AC_HOME/state" bash -c "
  . '$BIN/ac-lib.sh'
  . '$BIN/ac-backend.sh'
  herdr_cli pane list
" 2>&1 || true)"
assert_contains "$err" "leaked past the per-call dispatch" \
  "a homeless herdr RPC on an orca fleet dies as the leak it is"
rm -f "$AC_HOME/config/backend" "$FAKE_ORCA/terminals/hless.buf" "$FAKE_ORCA/terminals/hless.tab"

# --- orca_worktree_lease: branch source + freshest tip ---------------------------
# orca-lease-cuts-from-wrong-branch: the lease must cut from the repo's LIVE
# CHECKOUT branch (never ac_default_branch, which answers a different
# question) and resolve that branch's FRESHEST tip via ac_freshest_ref (local
# vs origin, origin wins on true divergence); an explicit override wins over
# the live checkout. make_fake_orca's `worktree create` hands --base-branch
# straight to `git worktree add` as a ref (tests/helpers.sh:734), so this runs
# the real branch/tip resolution end to end through the fake.

# A1: live checkout on a branch OTHER than default - lease cuts from THAT branch.
a1up="$(make_repo a1up)"
a1="$TMP/a1-clone"
git clone -q "$a1up" "$a1"
git -C "$a1" config user.email test@test
git -C "$a1" config user.name test
git -C "$a1" checkout -qb feature
printf 'feature work\n' >>"$a1/file.txt"
git -C "$a1" commit -qam "feature work"
a1_feature_sha="$(git -C "$a1" rev-parse feature)"
a1_main_sha="$(git -C "$a1" rev-parse main)"
[ "$a1_feature_sha" != "$a1_main_sha" ] || fail "A1 fixture: feature and main must differ"
a1_out="$(run_backend orca "orca_worktree_lease a1 '$a1'")"
assert_eq "$(git -C "$a1_out" rev-parse HEAD)" "$a1_feature_sha" \
  "A1: lease cuts from the live checkout branch (feature), not ac_default_branch (main)"

# A2: right branch checked out, but ORIGIN holds commits local lacks (true
# divergence) - ac_freshest_ref must pick origin, not a stale local ref.
# Measured (this task, real orca CLI 1.4.190 + the fake): a bare branch name
# already resolves to the LOCAL ref whenever local is ahead-or-equal (git's
# own ref-disambiguation order checks refs/heads/<name> before
# refs/remotes/*/<name>), so "origin behind local" never exercised the old
# code's bug - it already landed on the local tip by coincidence. The
# direction that actually discriminates is the mirror one: origin AHEAD,
# where the old bare-default-branch-name code silently stayed on the stale
# local tip with no symptom.
a2up="$(make_repo a2up)"
a2="$TMP/a2-clone"
git clone -q "$a2up" "$a2"
git -C "$a2" config user.email test@test
git -C "$a2" config user.name test
printf 'origin ahead\n' >>"$a2up/file.txt"
git -C "$a2up" commit -qam "origin ahead, pushed after clone"
git -C "$a2" fetch -q origin
a2_local_sha="$(git -C "$a2" rev-parse main)"
a2_origin_sha="$(git -C "$a2" rev-parse origin/main)"
[ "$a2_local_sha" != "$a2_origin_sha" ] || fail "A2 fixture: local and origin must differ"
a2_out="$(run_backend orca "orca_worktree_lease a2 '$a2'")"
assert_eq "$(git -C "$a2_out" rev-parse HEAD)" "$a2_origin_sha" \
  "A2: ac_freshest_ref picks origin's newer commit over the stale local ref"

# A2b: the LITERAL FMS direction (room evidence: "origin lags local", correct
# branch NAME but 7 commits behind) - reconciled with the A2 measurement
# above by reading "local" as the live checkout's actual HEAD position, not
# its branch ref. A live checkout can advance PAST its own branch ref while
# DETACHED (the branch ref and origin's tracking ref both stay put) - the
# branch name then resolves "correctly" by name, yet ac_freshest_ref (which
# only ever compares refs/heads/<b> vs refs/remotes/origin/<b>) still lands
# behind, because neither ref moved. Measured (real orca CLI 1.4.190): a raw
# commit SHA given to --base-branch resolves to exactly that commit.
a2bup="$(make_repo a2bup)"
a2b="$TMP/a2b-clone"
git clone -q "$a2bup" "$a2b"
git -C "$a2b" config user.email test@test
git -C "$a2b" config user.name test
git -C "$a2b" checkout -qb feature
printf 'feature base\n' >>"$a2b/file.txt"
git -C "$a2b" commit -qam "feature base"
git -C "$a2b" push -q -u origin feature
git -C "$a2b" checkout -q --detach feature
printf 'detached ahead\n' >>"$a2b/file.txt"
git -C "$a2b" commit -qam "detached, ahead of the feature ref and origin - the FMS shape"
a2b_detached_sha="$(git -C "$a2b" rev-parse HEAD)"
a2b_feature_ref_sha="$(git -C "$a2b" rev-parse feature)"
[ "$a2b_detached_sha" != "$a2b_feature_ref_sha" ] \
  || fail "A2b fixture: detached HEAD must diverge from the feature branch ref"
a2b_out="$(run_backend orca "orca_worktree_lease a2b '$a2b'")"
assert_eq "$(git -C "$a2b_out" rev-parse HEAD)" "$a2b_detached_sha" \
  "A2b: a detached-HEAD live checkout ahead of its own branch ref (and origin) leases at HEAD's exact position, never the stale branch ref"

# A3: no divergence - no regression.
a3up="$(make_repo a3up)"
a3="$TMP/a3-clone"
git clone -q "$a3up" "$a3"
git -C "$a3" config user.email test@test
git -C "$a3" config user.name test
a3_same_sha="$(git -C "$a3" rev-parse main)"
a3_out="$(run_backend orca "orca_worktree_lease a3 '$a3'")"
assert_eq "$(git -C "$a3_out" rev-parse HEAD)" "$a3_same_sha" \
  "A3: no divergence - the lease cuts at the shared tip, no regression"

# A4: explicit override wins over the live checkout. Three distinct branches -
# default (main), live checkout (feature), override target (release) - so the
# assertion cannot pass by coincidentally matching ac_default_branch's own
# answer the way a two-branch fixture would.
a4up="$(make_repo a4up)"
a4="$TMP/a4-clone"
git clone -q "$a4up" "$a4"
git -C "$a4" config user.email test@test
git -C "$a4" config user.name test
git -C "$a4" checkout -qb feature
printf 'feature work\n' >>"$a4/file.txt"
git -C "$a4" commit -qam "feature work"
git -C "$a4" checkout -qb release main
printf 'release work\n' >>"$a4/file.txt"
git -C "$a4" commit -qam "release work"
git -C "$a4" checkout -q feature
a4_release_sha="$(git -C "$a4" rev-parse release)"
a4_out="$(run_backend orca "orca_worktree_lease a4 '$a4' release")"
assert_eq "$(git -C "$a4_out" rev-parse HEAD)" "$a4_release_sha" \
  "A4: an explicit base-branch override (release) wins over the live checkout (feature)"

# A5: an UNREGISTERED repo is registered by the lease itself - show-then-add,
# never a blind add (repo add on an already-registered path fails
# runtime_error, measured on the real CLI), so a second lease on the now-
# registered repo must not call add again.
a5="$(make_repo a5)"
: >"$FAKE_ORCA/.require-repo-reg"
a5_out="$(run_backend orca "orca_worktree_lease a5 '$a5'")" \
  || fail "A5: the lease must register an unregistered repo itself"
[ -d "$a5_out" ] || fail "A5: lease printed no worktree path"
grep -qxF "$a5" "$FAKE_ORCA/repos" \
  || fail "A5: the repo must be registered after the lease"
: >"$FAKE_ORCA/log"
run_backend orca "orca_worktree_lease a5b '$a5'" >/dev/null \
  || fail "A5: a lease on the registered repo must still work"
case "$(cat "$FAKE_ORCA/log")" in *"repo add"*) \
  fail "A5: a registered repo must not be re-added" ;; esac
rm -f "$FAKE_ORCA/.require-repo-reg"

# A6: a create that answers ok with NO usable path still REGISTERED a
# worktree in the runtime - the lease must release the leak by id, not
# return 1 over a stray registration nothing will ever clean.
a6="$(make_repo a6)"
: >"$FAKE_ORCA/.create-no-path"
: >"$FAKE_ORCA/log"
rc=0; run_backend orca "orca_worktree_lease a6 '$a6'" >/dev/null 2>&1 || rc=$?
[ "$rc" != 0 ] || fail "A6: a pathless create must fail the lease"
assert_contains "$(cat "$FAKE_ORCA/log")" "worktree rm --worktree id:wt-broken --force" \
  "A6: the leaked worktree is released by its id"
rm -f "$FAKE_ORCA/.create-no-path"

pass
