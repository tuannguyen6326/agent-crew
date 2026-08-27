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

pass
