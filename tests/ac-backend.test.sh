#!/usr/bin/env bash
# ac-backend.test.sh - backend dispatch: the herdr adapter (the only backend)
# against a stub CLI (pane handle persistence, alive, capture, send, kill,
# focus), and rejection of removed (tmux/wezterm) and unknown backend names.
# shellcheck disable=SC2016  # script bodies are deliberately unexpanded here

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
stub="$TMP/stubbin"
mkdir -p "$stub"

run_backend() {
  # run_backend <backend> <script> - source the libs with the stub PATH and
  # the given backend, then run the script body.
  PATH="$stub:$PATH" AC_BACKEND="$1" AC_HOME="$AC_HOME" bash -c "
    set -euo pipefail
    . '$BIN/ac-lib.sh'
    . '$BIN/ac-backend.sh'
    $2
  "
}

# --- herdr -----------------------------------------------------------------------

export HDLOG="$TMP/hd.log"
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "tab create") echo '{"result":{"tab":{"tab_id":"t7"},"root_pane":{"pane_id":"p9"}}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wCM"}}}' ;;
  "pane read") printf 'one\ntwo\n' ;;
esac
exit 0
EOF
chmod +x "$stub/herdr"

export fleet="$(basename "$AC_HOME")"
run_backend herdr '
  backend_window_new h1 /tmp
  backend_window_alive h1
  [ "$(backend_target h1)" = "herdr:pane-p9" ]
' >/dev/null
assert_eq "$(cat "$AC_HOME/state/.pane-h1")" "p9 t7" "herdr pane+tab handle recorded"
assert_contains "$(cat "$HDLOG")" "workspace create --label $fleet · h1 --no-focus" "herdr creates the task's FAMILY workspace on first use (family = the flat id itself)"
assert_contains "$(cat "$HDLOG")" "tab create --workspace wCM --cwd /tmp --label crew:h1 --no-focus" "herdr tab lands in the family workspace"

out="$(run_backend herdr 'backend_capture h1 1')"
assert_eq "$out" "two" "herdr capture tails (generous fetch, local trim)"
assert_contains "$(cat "$HDLOG")" "pane read p9 --source recent --lines 200" "herdr read fetches generously"

# Raw-pane capture: a pane agent (ac-pane-agent.sh) holds only the herdr pane
# id and has NO state/.pane-<id> handle, so the id-keyed capture cannot reach
# it. backend_capture_pane addresses the pane directly - and fails closed on an
# empty id rather than reading whatever `pane read ""` answers.
out="$(run_backend herdr 'backend_capture_pane pRAW 1')"
assert_eq "$out" "two" "raw-pane capture tails like the id-keyed one"
assert_contains "$(cat "$HDLOG")" "pane read pRAW --source recent --lines 200" "raw-pane capture addresses the pane id with no handle lookup"
assert_fails run_backend herdr 'backend_capture_pane "" 1'

# send_line verifies its submit by capture-change, so this stub's pane read
# output must REACT per call (the log grows on every CLI hit) - a first-Enter
# ack, no focus-steal, no retry.
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "tab create") echo '{"result":{"tab":{"tab_id":"t7"},"root_pane":{"pane_id":"p9"}}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wCM"}}}' ;;
  "workspace get")
    case "${3:-}" in
      wK) printf '{"result":{"workspace":{"label":"%s (crewmate)"}}}\n' "$fleet" ;;
      wC) printf '{"result":{"workspace":{"label":"%s (crewchief)"}}}\n' "$fleet" ;;
    esac ;;
  "tab get") echo '{"result":{"tab":{"tab_id":"t7","label":"crew:h1"}}}' ;;
  "pane read") printf 'one\ntwo\nr%s\n' "$(wc -l <"$HDLOG")" ;;
esac
exit 0
EOF
run_backend herdr 'backend_send_line h1 "hello crew"' >/dev/null
assert_contains "$(cat "$HDLOG")" "pane send-text p9 hello crew" "herdr send-text called"
assert_contains "$(cat "$HDLOG")" "pane send-keys p9 enter" "herdr Enter sent separately"
case "$(cat "$HDLOG")" in *"tab focus"*) fail "an acked first submit must not focus-steal" ;; esac

run_backend herdr 'backend_send_key h1 C-c' >/dev/null
assert_contains "$(cat "$HDLOG")" "pane send-keys p9 ctrl+c" "herdr key normalization"

run_backend herdr 'backend_kill_window h1' >/dev/null
assert_contains "$(cat "$HDLOG")" "tab get t7" "kill proves ownership before closing"
assert_contains "$(cat "$HDLOG")" "tab close t7" "herdr tab close called"
assert_no_file "$AC_HOME/state/.pane-h1" "herdr handle removed on kill"

# --- focus (the consented redirect verb) --------------------------------------------

printf 'p9 t7\n' >"$AC_HOME/state/.pane-hf1"
: >"$HDLOG"
run_backend herdr 'backend_focus hf1' >/dev/null
assert_contains "$(cat "$HDLOG")" "tab focus t7" "herdr focus targets the tab"

# --- family workspace routing (AC_WINDOW_FAMILY contract) ---------------------------
# ac-backend.sh FAMILY WORKSPACE GROUPING: set non-empty = that family's
# workspace; set EMPTY = deliberately the fleet ROOT workspace; unset =
# derived from the id (scope ladder, ac_window_family).

: >"$HDLOG"
run_backend herdr 'AC_WINDOW_FAMILY=fam9 backend_window_new hc1 /tmp' >/dev/null
assert_contains "$(cat "$HDLOG")" "workspace create --label $fleet · fam9 --no-focus" "a named family lands in that family's workspace"
: >"$HDLOG"
run_backend herdr 'AC_WINDOW_FAMILY="" backend_window_new hc2 /tmp' >/dev/null
assert_contains "$(cat "$HDLOG")" "workspace create --label $fleet --no-focus" "an EMPTY family deliberately targets the fleet root workspace"
: >"$HDLOG"
run_backend herdr 'AC_SCOPE=myfam backend_window_new hc3 /tmp' >/dev/null
assert_contains "$(cat "$HDLOG")" "workspace create --label $fleet · myfam --no-focus" "unset: a scoped caller's AC_SCOPE names the family"
: >"$HDLOG"
run_backend herdr 'AC_FLEET_SCOPE=toldfam backend_window_new hc4 /tmp' >/dev/null
assert_contains "$(cat "$HDLOG")" "workspace create --label $fleet · toldfam --no-focus" "unset: the told AC_FLEET_SCOPE is the next rung"
: >"$HDLOG"
mkdir -p "$AC_HOME/data/epicfam-story1/spec"   # ac_family_of_id trusts a stage suffix only when its nested dir exists
run_backend herdr 'backend_window_new epicfam-story1-spec /tmp' >/dev/null
assert_contains "$(cat "$HDLOG")" "workspace create --label $fleet · epicfam-story1 --no-focus" "unset+unscoped: the id's own family (stage suffix stripped)"
rm -f "$AC_HOME/state/.pane-hc1" "$AC_HOME/state/.pane-hc2" "$AC_HOME/state/.pane-hc3" "$AC_HOME/state/.pane-hc4" "$AC_HOME/state/.pane-epicfam-story1-spec"

# --- herdr session knob ------------------------------------------------------------

# The ladder mirrors every other herdr caller: AC_HERDR_SESSION > the config
# knob. An AC_HERDR_SESSION inherited from the operator's shell sits on the top
# rung and would shadow the very knob these fixtures assert, so answer only
# from the fixtures below.
unset AC_HERDR_SESSION

printf 'lab\n' >"$AC_HOME/config/herdr-session"
: >"$HDLOG"
run_backend herdr '
  printf "p9 t7\n" >"$(ac_pane_file h2)"
  backend_send_key h2 Enter
' >/dev/null
assert_contains "$(cat "$HDLOG")" "pane send-keys p9 enter --session lab" "herdr routes to configured session"

: >"$HDLOG"
run_backend herdr 'AC_HERDR_SESSION=env1 backend_send_key h2 Enter' >/dev/null
assert_contains "$(cat "$HDLOG")" "pane send-keys p9 enter --session env1" "AC_HERDR_SESSION outranks the config knob"
rm -f "$AC_HOME/config/herdr-session"

: >"$HDLOG"
run_backend herdr 'AC_HERDR_SESSION=env1 backend_send_key h2 Enter' >/dev/null
assert_contains "$(cat "$HDLOG")" "pane send-keys p9 enter --session env1" "AC_HERDR_SESSION alone routes the session"

: >"$HDLOG"
run_backend herdr 'backend_send_key h2 Enter' >/dev/null
case "$(cat "$HDLOG")" in *--session*) fail "neither knob set: the default session takes no --session flag" ;; esac
rm -f "$AC_HOME/state/.pane-h2"

# --- herdr ask-alert (agent_status blocked) -----------------------------------------

cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "pane get")
    case "${3:-}" in
      pBLOCK) echo '{"result":{"pane":{"pane_id":"pBLOCK","agent_status":"blocked"}}}' ;;
      *) echo '{"result":{"pane":{"pane_id":"p7","agent_status":"working"}}}' ;;
    esac ;;
esac
exit 0
EOF
printf 'pBLOCK tX\n' >"$AC_HOME/state/.pane-hb1"
printf 'p7 tY\n' >"$AC_HOME/state/.pane-hb2"
run_backend herdr 'backend_agent_blocked hb1' >/dev/null || fail "blocked pane must report blocked"
assert_fails run_backend herdr 'backend_agent_blocked hb2'

# --- herdr adopt-by-label / twin-sweep ----------------------------------------------
# herdr_resolve_workspace: adopt the busiest workspace carrying the label,
# sweep provably-empty twins, create only when none exists. The stubs label
# their workspaces "$fleet · h<N>" - the family label of the flat test ids.

# (a) an existing correctly-labelled workspace is adopted instead of a create.
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wADOPT","label":"%s · h4","tab_count":3}]}}\n' "$fleet" ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tA"},"root_pane":{"pane_id":"pA"}}}' ;;
esac
exit 0
EOF
: >"$HDLOG"
run_backend herdr 'backend_window_new h4 /tmp' >/dev/null 2>&1
assert_contains "$(cat "$HDLOG")" "tab create --workspace wADOPT" "the existing labelled workspace is adopted"
case "$(cat "$HDLOG")" in *"workspace create"*) fail "an adoptable workspace must not trigger a create" ;; esac
rm -f "$AC_HOME/state/.pane-h4"

# (b) twins collapse to the busiest, the rest are closed - once the sweep's
# emptiness proof reads the twin's tabs as the default "1" alone.
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wSMALL","label":"%s · h5","tab_count":1},{"workspace_id":"wBIG","label":"%s · h5","tab_count":5}]}}\n' "$fleet" "$fleet" ;;
  "tab list")
    case "${4:-}" in
      wSMALL) echo '{"result":{"tabs":[{"label":"1"}]}}' ;;
    esac ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tB"},"root_pane":{"pane_id":"pB"}}}' ;;
esac
exit 0
EOF
: >"$HDLOG"
run_backend herdr 'backend_window_new h5 /tmp' >/dev/null 2>&1
assert_contains "$(cat "$HDLOG")" "tab create --workspace wBIG" "twins collapse to the busiest workspace"
assert_contains "$(cat "$HDLOG")" "tab list --workspace wSMALL" "the twin sweep proves emptiness before closing"
assert_contains "$(cat "$HDLOG")" "workspace close wSMALL" "a twin holding only herdr's default tab is closed"
rm -f "$AC_HOME/state/.pane-h5"

# --- herdr twin-sweep proof of emptiness ---------------------------------------------

# (d) a twin holding a live `crew:*` tab survives the sweep - closing the
# workspace would take that tab with it. The busiest twin is still adopted
# with no tab query of its own.
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wSMALL","label":"%s · h7","tab_count":1},{"workspace_id":"wBIG","label":"%s · h7","tab_count":5}]}}\n' "$fleet" "$fleet" ;;
  "tab list")
    case "${4:-}" in
      wSMALL) echo '{"result":{"tabs":[{"label":"crew:h7"}]}}' ;;
    esac ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tD"},"root_pane":{"pane_id":"pD"}}}' ;;
esac
exit 0
EOF
: >"$HDLOG"
run_backend herdr 'backend_window_new h7 /tmp' >/dev/null 2>&1
assert_contains "$(cat "$HDLOG")" "tab create --workspace wBIG" "twin sweep: busiest still adopted with a live crew:* twin around"
assert_contains "$(cat "$HDLOG")" "tab list --workspace wSMALL" "the sweep queries the twin's tabs"
case "$(cat "$HDLOG")" in *"workspace close wSMALL"*) fail "a twin holding a crew:* tab must not be closed" ;; esac
rm -f "$AC_HOME/state/.pane-h7"

# (e) a twin holding a non-crew:*, non-default human-named tab (the live
# captain-tab shape, e.g. "ac-lab") ALSO survives - the crew:*-only predicate
# alone would have killed this one.
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wSMALL","label":"%s · h8","tab_count":1},{"workspace_id":"wBIG","label":"%s · h8","tab_count":5}]}}\n' "$fleet" "$fleet" ;;
  "tab list")
    case "${4:-}" in
      wSMALL) echo '{"result":{"tabs":[{"label":"ac-lab"}]}}' ;;
    esac ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tE"},"root_pane":{"pane_id":"pE"}}}' ;;
esac
exit 0
EOF
: >"$HDLOG"
run_backend herdr 'backend_window_new h8 /tmp' >/dev/null 2>&1
assert_contains "$(cat "$HDLOG")" "tab create --workspace wBIG" "twin sweep: busiest still adopted with a human-named twin around"
case "$(cat "$HDLOG")" in *"workspace close wSMALL"*) fail "a twin holding a human-named tab must not be closed" ;; esac
rm -f "$AC_HOME/state/.pane-h8"

# (g) an unreadable tab query (non-zero exit) leaves the twin open - fail
# closed, an unknown answer must never authorize a close.
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wSMALL","label":"%s · h10","tab_count":1},{"workspace_id":"wBIG","label":"%s · h10","tab_count":5}]}}\n' "$fleet" "$fleet" ;;
  "tab list")
    case "${4:-}" in
      wSMALL) exit 1 ;;
    esac ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tG"},"root_pane":{"pane_id":"pG"}}}' ;;
esac
exit 0
EOF
: >"$HDLOG"
err="$(run_backend herdr 'backend_window_new h10 /tmp' 2>&1 >/dev/null)"
assert_contains "$(cat "$HDLOG")" "tab create --workspace wBIG" "twin sweep: busiest adopted, unreadable twin left alone"
case "$(cat "$HDLOG")" in *"workspace close wSMALL"*) fail "an unreadable tab query must not authorize a close" ;; esac
assert_contains "$err" "wSMALL" "the surviving twin is warned about by id"
rm -f "$AC_HOME/state/.pane-h10"

# --- legacy per-role group sweep -----------------------------------------------------
# herdr_sweep_legacy_groups: a retired "<fleet> (crewchief|crewmate|pane-agent)"
# workspace is closed once provably empty; one still holding a real tab stays.
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"wLEG","label":"%s (crewmate)","tab_count":1},{"workspace_id":"wLIVE","label":"%s (crewchief)","tab_count":1}]}}\n' "$fleet" "$fleet" ;;
  "tab list")
    case "${4:-}" in
      wLEG) echo '{"result":{"tabs":[{"label":"1"}]}}' ;;
      wLIVE) echo '{"result":{"tabs":[{"label":"crew:old-chief"}]}}' ;;
    esac ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wNEW"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tL"},"root_pane":{"pane_id":"pL"}}}' ;;
esac
exit 0
EOF
: >"$HDLOG"
run_backend herdr 'backend_window_new h11 /tmp' >/dev/null 2>&1
assert_contains "$(cat "$HDLOG")" "workspace close wLEG" "an empty legacy per-role group is swept"
case "$(cat "$HDLOG")" in *"workspace close wLIVE"*) fail "a legacy group still holding a real tab must not be closed" ;; esac
rm -f "$AC_HOME/state/.pane-h11"

# --- kill_window LAST-TAB FALLBACK ---------------------------------------------------
# herdr refuses to close a workspace's last tab; a proven-owned tab that is
# still present after its close retries as a workspace close - only on the
# emptiness proof (this tab + default "1" tabs and nothing else).
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "tab get") echo '{"result":{"tab":{"tab_id":"tZ","label":"crew:h12"}}}' ;;
  "tab close") exit 1 ;;   # herdr: cannot close the last tab in a workspace
  "tab list") echo '{"result":{"tabs":[{"tab_id":"wZ:tZ","label":"crew:h12"}]}}' ;;
esac
exit 0
EOF
printf 'pZ wZ:tZ\n' >"$AC_HOME/state/.pane-h12"
run_backend herdr 'backend_kill_window h12' >/dev/null 2>&1
assert_contains "$(cat "$HDLOG")" "workspace close wZ" "a last-tab refusal on an otherwise-empty workspace closes the workspace"
assert_no_file "$AC_HOME/state/.pane-h12" "handle removed with the fallback close"

# ...but never while another real tab lives in the workspace.
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "tab get") echo '{"result":{"tab":{"tab_id":"tY","label":"crew:h13"}}}' ;;
  "tab close") exit 1 ;;
  "tab list") echo '{"result":{"tabs":[{"tab_id":"wY:tY","label":"crew:h13"},{"tab_id":"wY:t2","label":"crew:other"}]}}' ;;
esac
exit 0
EOF
printf 'pY wY:tY\n' >"$AC_HOME/state/.pane-h13"
: >"$HDLOG"
err="$(run_backend herdr 'backend_kill_window h13' 2>&1 >/dev/null)" || true
case "$(cat "$HDLOG")" in *"workspace close wY"*) fail "an occupied workspace must not be closed by the fallback" ;; esac
assert_contains "$err" "wY" "the refusal names the workspace"

# --- send_line strand honesty (fake herdr: unfocused Enter no-ops) -----------------

# The fake composer model (tests/helpers.sh): send-text types into <p>.in,
# only an accepted enter submits it into the transcript; <p>.drop-enters
# no-ops enters silently, exit 0 - herdr's unfocused send-keys signature.
make_fake_herdr

# happy: submit acked first try, composer empties into the transcript
printf 'pF1\n' >"$FAKE_HERDR/tabs/tF1"; : >"$FAKE_HERDR/panes/pF1.buf"
printf 'pF1 tF1\n' >"$AC_HOME/state/.pane-sf1"
run_backend herdr 'backend_send_line sf1 "hello there"' >/dev/null
assert_contains "$(cat "$FAKE_HERDR/panes/pF1.buf")" "hello there" "submitted text reaches the transcript"
[ -s "$FAKE_HERDR/panes/pF1.in" ] && fail "composer must be empty after an acked send"

# one dropped Enter: strand detected, tab focused, verified retry lands - exit 0
printf 'pF2\n' >"$FAKE_HERDR/tabs/tF2"; : >"$FAKE_HERDR/panes/pF2.buf"
printf 'pF2 tF2\n' >"$AC_HOME/state/.pane-sf2"
printf '1\n' >"$FAKE_HERDR/panes/pF2.drop-enters"
run_backend herdr 'backend_send_line sf2 "steer msg"' >/dev/null
assert_contains "$(cat "$FAKE_HERDR/log")" "tab focus tF2" "strand focuses the tab before the retry"
assert_eq "$(grep -c "steer msg" "$FAKE_HERDR/panes/pF2.buf")" "1" "retry re-SUBMITS the stranded text exactly once (never re-types)"

# every Enter dropped: non-zero + loud stderr, text honestly still in the composer
printf 'pF3\n' >"$FAKE_HERDR/tabs/tF3"; : >"$FAKE_HERDR/panes/pF3.buf"
printf 'pF3 tF3\n' >"$AC_HOME/state/.pane-sf3"
printf '99\n' >"$FAKE_HERDR/panes/pF3.drop-enters"
err="$(run_backend herdr 'backend_send_line sf3 "lost msg"' 2>&1)" \
  && fail "a stranded send must exit non-zero"
assert_contains "$err" "not acknowledged" "strand failure is loud on stderr"
assert_contains "$(cat "$FAKE_HERDR/panes/pF3.in")" "lost msg" "text sits stranded in the composer"
case "$(cat "$FAKE_HERDR/panes/pF3.buf")" in *"lost msg"*) fail "stranded text must not appear submitted" ;; esac

# --- raw-pane send: the verified steer a pane agent has no handle for ---------------
# A pane agent (ac-pane-agent.sh) holds only the raw pane id herdr handed it -
# there is no state/.pane-<id> to key on - so the verified send comes in a
# raw-pane addressing too, exactly like Story 5's backend_capture_pane. The
# submit semantics are the id-keyed path's, unchanged: probe for the render to
# react, focus and retry once, then fail.

printf 'pR1\n' >"$FAKE_HERDR/tabs/tR1"; : >"$FAKE_HERDR/panes/pR1.buf"
printf 'tR1\n' >"$FAKE_HERDR/panes/pR1.tab"
run_backend herdr 'backend_send_line_pane pR1 "steer the reviewer"' >/dev/null
assert_contains "$(cat "$FAKE_HERDR/panes/pR1.buf")" "steer the reviewer" \
  "a raw-pane send submits with no persisted handle anywhere"
assert_no_file "$AC_HOME/state/.pane-pR1" "the raw-pane send reads no handle file"

# one dropped Enter: the pane's OWN tab (resolved from herdr, not from a handle
# file) is focused and the stranded text is re-SUBMITTED once - never re-typed.
printf 'pR2\n' >"$FAKE_HERDR/tabs/tR2"; : >"$FAKE_HERDR/panes/pR2.buf"
printf 'tR2\n' >"$FAKE_HERDR/panes/pR2.tab"
printf '1\n' >"$FAKE_HERDR/panes/pR2.drop-enters"
: >"$FAKE_HERDR/log"
run_backend herdr 'backend_send_line_pane pR2 "steer msg"' >/dev/null
assert_contains "$(cat "$FAKE_HERDR/log")" "tab focus tR2" \
  "strand focuses the pane's own tab before the retry"
assert_eq "$(grep -c "steer msg" "$FAKE_HERDR/panes/pR2.buf")" "1" \
  "the retry re-SUBMITS the stranded text exactly once"

# every Enter dropped: non-zero, and the text honestly sits in the composer -
# the CALLER owns the loud message (ac-pane-agent.sh steer names the handle).
printf 'pR3\n' >"$FAKE_HERDR/tabs/tR3"; : >"$FAKE_HERDR/panes/pR3.buf"
printf 'tR3\n' >"$FAKE_HERDR/panes/pR3.tab"
printf '99\n' >"$FAKE_HERDR/panes/pR3.drop-enters"
assert_fails run_backend herdr 'backend_send_line_pane pR3 "lost steer"'
assert_contains "$(cat "$FAKE_HERDR/panes/pR3.in")" "lost steer" "text sits stranded in the composer"
case "$(cat "$FAKE_HERDR/panes/pR3.buf")" in *"lost steer"*) fail "stranded text must not appear submitted" ;; esac

# Fails closed on an empty pane id rather than typing into whatever
# `pane send-text ""` reaches (the backend_capture_pane floor, same reason).
assert_fails run_backend herdr 'backend_send_line_pane "" "nowhere"'

# --- send_key focuses first (herdr's unfocused send-keys no-ops) --------------------
# Contract: ac-backend.sh delivery verification - `pane send-keys` needs FOCUS, so a
# blind key press evaporates on an unfocused pane (exit 0, nothing done). The key
# path cannot probe for an ack (a bare key may legitimately redraw nothing), so
# focusing FIRST is the whole guarantee it has.

printf 'pK1\n' >"$FAKE_HERDR/tabs/tK1"; : >"$FAKE_HERDR/panes/pK1.buf"
printf 'pK1 tK1\n' >"$AC_HOME/state/.pane-sk1"
: >"$FAKE_HERDR/log"
run_backend herdr 'backend_send_key sk1 Enter' >/dev/null
assert_contains "$(grep -e 'tab focus tK1' -e 'pane send-keys pK1' "$FAKE_HERDR/log" | head -1)" \
  "tab focus tK1" "send_key focuses the tab BEFORE the key, never after"
assert_contains "$(cat "$FAKE_HERDR/log")" "pane send-keys pK1 enter" "the key still reaches the pane"

# --- captain-wait stamp: mark/clear, ask-reader suppression, kill sweep --------------
# Contract: ac-backend.sh CAPTAIN-WAIT STAMP.

printf 'pW1 crew:sw1\n' >"$FAKE_HERDR/tabs/tW1"; : >"$FAKE_HERDR/panes/pW1.buf"
printf 'pW1 tW1\n' >"$AC_HOME/state/.pane-sw1"
run_backend herdr 'backend_mark_wait sw1 "needs-decision: pick A or B"'
assert_eq "$(cat "$FAKE_HERDR/panes/pW1.reported")" "blocked" "mark_wait reports blocked to herdr"
assert_contains "$(cat "$FAKE_HERDR/log")" "pane report-agent pW1 --source ac-fleet" "stamp is source-attributed"
assert_file "$AC_HOME/state/.captain-wait-sw1" "stamp ownership recorded"

# The fleet's own stamp must never read back as an interactive-prompt block
# (it would ask:-wake the watcher and refuse the answering send).
assert_fails run_backend herdr 'backend_agent_blocked sw1'

# A REAL blocked pane (no stamp) still reads blocked.
printf 'pW2\n' >"$FAKE_HERDR/tabs/tW2"; : >"$FAKE_HERDR/panes/pW2.buf"
printf 'pW2 tW2\n' >"$AC_HOME/state/.pane-sw2"
printf 'blocked\n' >"$FAKE_HERDR/panes/pW2.status"
run_backend herdr 'backend_agent_blocked sw2'

# clear releases the report and the ownership file; a second clear is a
# no-op that never releases a state the fleet does not own.
run_backend herdr 'backend_clear_wait sw1'
assert_no_file "$FAKE_HERDR/panes/pW1.reported" "clear_wait releases the reported state"
assert_no_file "$AC_HOME/state/.captain-wait-sw1" "clear_wait removes the ownership file"
run_backend herdr 'backend_clear_wait sw1'
assert_eq "$(grep -c 'release-agent pW1' "$FAKE_HERDR/log")" "1" "clear without a stamp releases nothing"

# kill_window sweeps the stamp file with the pane.
run_backend herdr 'backend_mark_wait sw1 "blocked: waiting on API key"'
run_backend herdr 'backend_kill_window sw1'
assert_no_file "$AC_HOME/state/.captain-wait-sw1" "kill_window removes the stamp file"

# --- kill_window ownership proof (the chief-pane-death regression) -------------------
# Contract: ac-backend.sh KILL OWNERSHIP PROOF. state/.pane-<id> outlives its tab
# (ac-spawn.sh --recover deliberately leaves it behind) and herdr recycles tab
# ids, while every chief pane co-tenants the ONE chiefs workspace and herdr drops
# a workspace whose last tab dies - so an unproven close has killed FOREIGN chief
# tabs (three observed deaths).

# An owned tab - still labelled crew:<id> - is closed as before.
printf 'pO1 crew:so1\n' >"$FAKE_HERDR/tabs/tO1"; : >"$FAKE_HERDR/panes/pO1.buf"
printf 'pO1 tO1\n' >"$AC_HOME/state/.pane-so1"
run_backend herdr 'backend_kill_window so1' >/dev/null
assert_no_file "$FAKE_HERDR/tabs/tO1" "a tab still labelled for the id is closed"

# THE REGRESSION: a stale handle pointing at a LIVE FOREIGN tab must not close it.
printf 'pO2 crew:other-chief\n' >"$FAKE_HERDR/tabs/tO2"; : >"$FAKE_HERDR/panes/pO2.buf"
printf 'pO2 tO2\n' >"$AC_HOME/state/.pane-so2"
err="$(run_backend herdr 'backend_kill_window so2' 2>&1)" \
  || fail "a refused close must stay non-fatal (teardown's call site is || true-shaped)"
assert_file "$FAKE_HERDR/tabs/tO2" "a foreign tab survives a stale handle"
assert_contains "$err" "so2" "the refusal names the id"
assert_contains "$err" "tO2" "the refusal names the tab"
assert_no_file "$AC_HOME/state/.pane-so2" "the proven-stale handle is swept anyway"

# No label to prove ownership by (tab gone, or never labelled) - refuse too.
printf 'pO3 tO3\n' >"$AC_HOME/state/.pane-so3"
: >"$FAKE_HERDR/log"
run_backend herdr 'backend_kill_window so3' >/dev/null 2>&1 \
  || fail "an unprovable tab must not be fatal either"
case "$(cat "$FAKE_HERDR/log")" in *"tab close tO3"*) fail "an unprovable tab must not be closed" ;; esac

# --- adaptive submit-verify: a LATE redraw is not a strand ---------------------------
# Contract: ac-backend.sh delivery verification (the adaptive render-change probe).
# The kickoff-strand fix: a submit whose redraw lands AFTER the first probe but
# within the budget must verify as ACCEPTED - the probe polls the render and
# returns the instant it reacts, so a slow host no longer strands an
# already-accepted line. The stub returns pre-render bytes for the first N reads
# then the redrawn bytes, so "late redraw" is simulated with NO real sleep
# (AC_SEND_SETTLE=0 in the suite, so each poll is instant).

export SVREADS="$TMP/sv-reads"

# (i) late redraw: pre-render for the first 3 reads, redrawn after - the poll
# catches the reaction on a later step, so verify succeeds with NO false strand
# and NO focus+retry. (pre-read is #1; polls are #2, #3, then #4 reacts.)
: >"$SVREADS"
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "pane read")
    n="$(cat "$SVREADS" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" >"$SVREADS"
    if [ "$n" -le 3 ]; then printf 'prompt>\ncomposer draft\n'
    else printf 'prompt>\n'; fi ;;
esac
exit 0
EOF
chmod +x "$stub/herdr"
printf 'pSV tSV\n' >"$AC_HOME/state/.pane-sv1"
: >"$HDLOG"
run_backend herdr 'backend_send_line sv1 "late redraw"' >/dev/null \
  || fail "a late-but-accepted redraw must verify as accepted, not a strand"
case "$(cat "$HDLOG")" in *"tab focus"*) fail "a late redraw within budget must not focus-steal or retry" ;; esac
assert_contains "$(cat "$HDLOG")" "pane send-text pSV late redraw" "send-text delivered the line before the verified Enter"

# (ii) render NEVER reacts: the budget exhausts and the genuine strand is STILL
# detected - focus+retry fires and the loud stranded-unsubmitted stderr with a
# non-zero exit remain (real-strand detection not weakened by the adaptive poll).
: >"$SVREADS"
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  "pane read") printf 'prompt>\ncomposer draft\n' ;;
esac
exit 0
EOF
chmod +x "$stub/herdr"
printf 'pSV tSV\n' >"$AC_HOME/state/.pane-sv2"
: >"$HDLOG"
err="$(run_backend herdr 'backend_send_line sv2 "no ack"' 2>&1)" \
  && fail "a render that never reacts must exit non-zero (genuine strand)"
assert_contains "$err" "not acknowledged" "budget-exhausted strand is loud on stderr"
assert_contains "$(cat "$HDLOG")" "tab focus tSV" "genuine strand still focuses and retries once"

# --- unobservable submit: an unreadable pane is NOT a strand -------------------------
# Contract: ac-backend.sh delivery verification (the three-outcome probe).
# A FAILING `pane read` leaves pre and post BOTH empty, which the byte-compare
# cannot tell apart from a dropped Enter - so a submit that really went through
# was reported as a strand after 7 wasted probes. The read's own failure (which
# backend_capture_pane has always signalled, and both call sites swallowed) now
# surfaces as its own status and its own message.

cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
case "${1:-} ${2:-}" in
  # The pane is LIVE and focusable - only the READ fails, which is the whole
  # point: nothing else about the pane tells the sender anything is wrong.
  "pane get") printf '{"result":{"pane":{"pane_id":"%s","tab_id":"t%s"}}}\n' "$3" "$3" ;;
  "pane read") exit 1 ;;
esac
exit 0
EOF
chmod +x "$stub/herdr"
printf 'pUR tUR\n' >"$AC_HOME/state/.pane-ur1"
: >"$HDLOG"
rc=0
err="$(run_backend herdr 'backend_send_line ur1 "unreadable"' 2>&1)" || rc=$?
assert_eq "$rc" "2" "an unreadable pane returns the UNOBSERVABLE status, not the strand status"
assert_contains "$err" "could not read the pane" "the message says what actually failed"
case "$err" in *stranded*) fail "an unreadable pane must never claim the text is stranded" ;; esac
assert_contains "$(cat "$HDLOG")" "pane send-keys pUR enter" "the Enter is still pressed - only the verdict is lost"
assert_eq "$(grep -c 'pane read' "$HDLOG")" "2" "a pane that cannot be read burns no probe budget (one read per attempt, not 8)"

# The silent RAW-pane twin prints nothing, so its STATUS is the only way its
# caller (ac-pane-agent.sh steer) can tell the two failures apart.
rc=0
run_backend herdr 'backend_send_line_pane pURP "unreadable"' >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "2" "the raw-pane twin reports UNOBSERVABLE through its status"

# --- window_alive is THREE-STATE: alive / gone / unobservable -----------------------
# Contract: ac-backend.sh WINDOW LIVENESS. A failing `pane get` is not a verdict by
# itself - a backend that cannot answer at all looks exactly like a pane that is
# gone, and collapsing the two stamped BOTH live agents of a family
# `failed: window gone` during a herdr client/server protocol mismatch
# (2026-07-25). So `gone` needs a DEFINITE answer from a reachable backend.
make_fake_herdr
printf 'pAL\n' >"$FAKE_HERDR/tabs/tAL"; : >"$FAKE_HERDR/panes/pAL.buf"
printf 'pAL tAL\n' >"$AC_HOME/state/.pane-al1"
: >"$FAKE_HERDR/log"
rc=0; run_backend herdr 'backend_window_alive al1' || rc=$?
assert_eq "$rc" "0" "a pane the backend answers for is ALIVE"
case "$(cat "$FAKE_HERDR/log")" in *"pane list"*) \
  fail "the healthy path must cost no second socket call - the watcher polls it every cycle" ;; esac

# REAL gone: the backend still answers, and its answer does not carry this pane.
rm -f "$FAKE_HERDR/panes/pAL.buf"
rc=0; run_backend herdr 'backend_window_alive al1' || rc=$?
assert_eq "$rc" "1" "a reachable backend that does not list the pane is GONE"

# UNOBSERVABLE: every call fails the way a protocol mismatch fails.
# DISPUTED: whether the backend can answer. HELD-CONSTANT: the pane's own files -
# handle, tab and buffer are all restored first, so the pane really is there.
: >"$FAKE_HERDR/panes/pAL.buf"
touch "$FAKE_HERDR/.unreachable"
rc=0; run_backend herdr 'backend_window_alive al1' || rc=$?
rm -f "$FAKE_HERDR/.unreachable"
assert_eq "$rc" "2" "a backend that cannot answer is UNOBSERVABLE, never a verdict about the pane"

# A missing handle is a LOCAL read: it stays GONE and costs no socket call.
: >"$FAKE_HERDR/log"
rc=0; run_backend herdr 'backend_window_alive nohandle' || rc=$?
assert_eq "$rc" "1" "no recorded pane handle stays GONE - a local fact is never an outage"
assert_eq "$(cat "$FAKE_HERDR/log")" "" "the no-handle answer asks the backend nothing"

# --- dispatch validation: herdr is the ONLY backend ----------------------------------

# tmux and wezterm were removed (2026-07-17); their names must be refused,
# and the error must name herdr as the only backend.
assert_fails run_backend tmux 'backend_target x1'
assert_fails run_backend wezterm 'backend_target x1'
err="$(run_backend tmux 'backend_target x1' 2>&1 || true)"
assert_contains "$err" "herdr is the only backend" "rejection names herdr as the only backend"
assert_fails run_backend screen 'backend_target x1'

pass
