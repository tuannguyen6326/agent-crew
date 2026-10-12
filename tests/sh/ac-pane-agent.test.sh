#!/usr/bin/env bash
# ac-pane-agent.test.sh - the vendored pane-turn helper: NDJSON protocol,
# Stop-hook turn end, transcript detection, workspace placement, close verb,
# and arg validation. herdr and claude are stubbed; the stub's `pane run`
# simulates a finished claude turn (touches the Stop-hook marker and writes
# the transcript).
# shellcheck disable=SC2016

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
RBIN="$(make_retired_bin)"
repo="$(make_repo)"
stub="$TMP/stubbin"
mkdir -p "$stub"
export HDLOG="$TMP/hd.log" FAKEHOME="$TMP/fakehome"
mkdir -p "$FAKEHOME"
# The helper resolves transcripts through ac_claude_transcript_root; the stub
# claude writes them under the fake HOME every run below passes.
export AC_CLAUDE_TRANSCRIPT_ROOT="$FAKEHOME/.claude/projects"

cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "tab list") if [ -n "${HD_TABS:-}" ]; then cat "$HD_TABS"; else echo '{"result":{"tabs":[]}}'; fi ;;
  "pane list") if [ -n "${HD_PANES:-}" ]; then cat "$HD_PANES"; else echo '{"result":{"panes":[]}}'; fi ;;
  "pane split") echo '{"result":{"pane":{"pane_id":"pS1"}}}' ;;
  "workspace get") case "${3:-}" in wP) exit 0 ;; *) echo '{"error":"gone"}'; exit 1 ;; esac ;;
  "workspace list") cat "${WSLIST:-/dev/null}" 2>/dev/null || echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wP"}}}' ;;
  "workspace close") : ;;
  "tab create")
    case "$*" in *"--workspace wSTALE"*) exit 1 ;; esac
    echo '{"result":{"tab":{"tab_id":"tP"},"root_pane":{"pane_id":"pP1"}}}' ;;
  "pane run")
    [ -z "${HD_RUN_SLEEP:-}" ] || sleep "$HD_RUN_SLEEP"
    cwd="$(printf '%s' "$4" | sed -n "s/^cd '\([^']*\)'.*/\1/p")"
    marker="$(sed -n "s/.*touch '\([^']*\)'.*/\1/p" "$cwd/.claude/settings.local.json")"
    slug="$(printf '%s' "$cwd" | sed 's/[/.]/-/g')"
    mkdir -p "$HOME/.claude/projects/$slug"
    # Every turn is a NEW claude session, so every turn writes a NEW
    # transcript: reusing one name left each later run with nothing the
    # new-session glob could resolve, i.e. the very empty-transcript hole this
    # suite now asserts is fail-closed.
    n="$(cat "$HDLOG.n" 2>/dev/null || printf 0)"; n=$((n + 1)); printf '%s\n' "$n" >"$HDLOG.n"
    sid=test-sid; [ "$n" -gt 1 ] && sid="test-sid-$n"
    tf="$HOME/.claude/projects/$slug/$sid.jsonl"
    ts=""; [ -z "${HD_TS:-}" ] || ts="\"timestamp\":\"$HD_TS\","
    if [ -n "${HD_RACE_TEXT:-}" ]; then
      # The verdict's flush RACES the Stop-hook marker: at the instant the
      # marker fires the last assistant message is still a tool_use, and the
      # text lands a beat later. This is exactly what a real reviewer's 20KB
      # verdict did - written, then harvested a few hundred ms too early.
      printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}' >"$tf"
      touch "$marker"
      ( sleep 2; printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"the verdict"}]}}' >>"$tf" ) &
    else
      printf '{"type":"assistant",%s"message":{"content":[{"type":"text","text":"[]"}]}}\n' "$ts" >"$tf"
      touch "$marker"
    fi ;;
  "pane close") echo "CLOSE-PANE $3" >>"$HDLOG" ;;
  # A closed pane stops resolving, which is what --replace-pane's `closed`
  # verification reads. HD_STICKY names a pane the stub keeps alive however
  # often it is closed (the herdr-refused-the-close case).
  "pane get") { [ "$3" != "${HD_STICKY:-}" ] && grep -q "CLOSE-PANE $3\$" "$HDLOG" 2>/dev/null; } && exit 1
              echo '{"result":{"pane":{"pane_id":"pP1","agent_status":"idle"}}}' ;;
esac
exit 0
EOF
chmod +x "$stub/herdr"

pf="$TMP/prompt.md"
printf 'review this\n' >"$pf"
# Placement (FAMILY WORKSPACE GROUPING): no AC_WINDOW_FAMILY in this env, so
# the pane resolves the fleet ROOT workspace by label; a leftover retired knob
# must be inert.
printf 'wSTALE\n' >"$AC_HOME/config/herdr-workspace-agents"
export WSLIST="$TMP/ws.json"
echo '{"result":{"workspaces":[]}}' >"$WSLIST"

out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r1)"
assert_contains "$out" '"event":"transcript"' "transcript announced"
assert_contains "$out" '"event":"done","status":"ok"' "turn ends ok via Stop-hook marker"
assert_contains "$out" '"session_id":"test-sid"' "session id from transcript name"
assert_contains "$out" '"source":"transcript"' "an ok turn names where its payload came from"

log="$(cat "$HDLOG")"
assert_contains "$log" "workspace create --label home --no-focus" "no family: the fleet root workspace is created by label (retired knob ignored)"
assert_contains "$log" "tab create --workspace wP" "pane lands in the resolved workspace"
assert_contains "$log" "--label ac-ship-agent" "default kind=ship keeps the ship tab label"
assert_contains "$log" "pane rename pP1 ac-ship-agent:r1" "pane labeled"

# THE VERDICT FLUSH RACES THE MARKER. The last assistant message is a tool_use
# at the instant the Stop hook fires; the text lands a beat later. Read once
# and it looks like a turn that stopped mid-pass - which is how a real 20KB
# verdict, fully written, was harvested a few hundred ms too early and thrown
# out. The turn end must SETTLE, not snapshot. (HDLOG.n is NOT reset: a fresh
# session name is what announce_transcript will adopt - reusing test-sid leaves
# the run looking at r1's already-seen transcript.)
out="$(HD_RACE_TEXT=1 PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label race1)"
assert_contains "$out" '"event":"done","status":"ok"' "a turn-end that beats the transcript flush waits for the text, not errors"
case "$out" in *"carries no text"*) fail "the settle window was not honoured: $out" ;; esac
: >"$HDLOG"
# --await-file: a turn end is NOT the end of the round while work the agent
# started is still in flight. A reviewer that fanned scout lanes out as
# subagents ended its turn at once - the Agent tool launches asynchronously
# and takes no flag to wait - so the marker fired, the round was harvested and
# the pane reaped with three lanes still running and nobody left to read them.
# With the file named here absent, a marker is CONSUMED and the poll goes on:
# the completing subagents wake the agent, it finishes with its evidence, and
# the marker it fires then is the one that ends the turn.
af="$TMP/await.flag"; rm -f "$af"
# The second marker stands in for the reviewer being woken by its finished
# subagents and ending a turn again; the subshell's own status must not reach
# set -e through `wait`, or a missed marker path kills the suite silently.
# The FIRST final message is stamped in the past - a verdict written before the
# fan-out - and the woken turn appends one stamped now: only that one may end
# the turn (contract: AWAIT, second clause).
( sleep 4; touch "$af"
  m="$(sed -n "s/.*touch '\([^']*\)'.*/\1/p" "$repo/.claude/settings.local.json" | tail -1)"
  # ledger present, old verdict still last: this marker must be HELD
  sleep 1; [ -z "$m" ] || touch "$m"
  sleep 3
  slug="$(printf '%s' "$repo" | sed 's/[/.]/-/g')"
  tfile="$(ls -t "$FAKEHOME/.claude/projects/$slug"/*.jsonl | head -1)"
  printf '{"type":"assistant","timestamp":"%s","message":{"content":[{"type":"text","text":"verdict after the fan-out"}]}}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$tfile"
  # new verdict last: this marker ends the turn
  sleep 1; [ -z "$m" ] || touch "$m" ) &
out="$(HD_TS=2020-01-01T00:00:00Z PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label await1 --await-file "$af" 2>&1 || true)"
wait || true
assert_contains "$out" '"event":"done","status":"ok"' "a held turn still ends ok once the awaited file exists"
assert_contains "$out" "await" "the hold is announced on the event stream"
assert_contains "$out" "predates" "a final message older than the ledger is held, not harvested"
# ...and it IS a hold: with the file never appearing, the turn cannot end.
rm -f "$af"
out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label await2 --await-file "$af" --timeout 5 2>&1 || true)"
case "$out" in *'"status":"ok"'*) fail "a turn must not end while the awaited file is absent: $out" ;; esac
: >"$HDLOG"

# --kind names the caller on both herdr surfaces (tab + pane).
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind qa --label q1 >/dev/null
assert_contains "$(cat "$HDLOG")" "--label ac-qa-agent" "kind=qa tab label"
assert_contains "$(cat "$HDLOG")" "ac-qa-agent:q1" "kind=qa pane label"
assert_contains "$log" "AC_HOME=" "the caller's fleet home is pinned onto the pane shell"

# FAMILY-SCOPED tab label: a verifier lease is a DETACHED exact-ref checkout
# (BRANCH empty), and the reuse step adopts tabs by label SESSION-WIDE -
# without the family in the label, every codereview pane in the session
# shared the bare 'ac-codereview-agent' tab: the second family's verifier
# split into the first family's tab, in the wrong workspace, bypassing
# AC_WINDOW_FAMILY (FAMILY WORKSPACE GROUPING, captain ruling).
: >"$HDLOG"
git -C "$repo" checkout -q --detach
PATH="$stub:$PATH" HOME="$FAKEHOME" AC_WINDOW_FAMILY=famx \
  "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label c1 >/dev/null
assert_contains "$(cat "$HDLOG")" "--label ac-codereview-agent-famx" \
  "detached lease: the FAMILY scopes the tab label, so cross-family adoption is impossible by name"

# ...and adoption is scoped to the FAMILY WORKSPACE structurally: a tab with
# the RIGHT label in the WRONG workspace (pre-family-label leftover, label
# collision) is never adopted - the pane creates its own tab in the family
# workspace instead of splitting into the stranger.
: >"$HDLOG"
export HD_TABS="$TMP/tabs.json"
printf '{"result":{"tabs":[{"tab_id":"tWRONG","label":"ac-codereview-agent-famx","workspace_id":"wOTHER"}]}}\n' >"$HD_TABS"
PATH="$stub:$PATH" HOME="$FAKEHOME" AC_WINDOW_FAMILY=famx \
  "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label c2 >/dev/null
wlog="$(cat "$HDLOG")"
assert_contains "$wlog" "tab create --workspace wP" "wrong-workspace tab skipped: a fresh tab is created in the family workspace"
case "$wlog" in *"pane split"*) fail "a tab outside the family workspace must never be adopted" ;; esac

# ...while a same-label tab IN the family workspace still stacks rounds.
: >"$HDLOG"
printf '{"result":{"tabs":[{"tab_id":"tP","label":"ac-codereview-agent-famx","workspace_id":"wP"}]}}\n' >"$HD_TABS"
export HD_PANES="$TMP/panes.json"
printf '{"result":{"panes":[{"pane_id":"pP1","tab_id":"tP"}]}}\n' >"$HD_PANES"
PATH="$stub:$PATH" HOME="$FAKEHOME" AC_WINDOW_FAMILY=famx \
  "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label c3 >/dev/null
assert_contains "$(cat "$HDLOG")" "pane split pP1" "same family workspace: round N splits into the existing tab"

# Several candidates: the FIRST same-label tab in the family workspace is
# adopted, its FIRST pane is split, and only THIS workspace's default "1" tabs
# are swept afterwards.
: >"$HDLOG"
printf '{"result":{"tabs":[{"tab_id":"tWRONG","label":"ac-codereview-agent-famx","workspace_id":"wOTHER"},{"tab_id":"t1a","label":"1","workspace_id":"wP"},{"tab_id":"tP","label":"ac-codereview-agent-famx","workspace_id":"wP"},{"tab_id":"tP2","label":"ac-codereview-agent-famx","workspace_id":"wP"},{"tab_id":"t1b","label":"1","workspace_id":"wOTHER"},{"tab_id":"t1c","label":"1","workspace_id":"wP"}]}}\n' >"$HD_TABS"
printf '{"result":{"panes":[{"pane_id":"pZ","tab_id":"tP2"},{"pane_id":"pP7","tab_id":"tP"},{"pane_id":"pP8","tab_id":"tP"}]}}\n' >"$HD_PANES"
PATH="$stub:$PATH" HOME="$FAKEHOME" AC_WINDOW_FAMILY=famx \
  "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label c4 --pane-file "$TMP/adopt.pane" >/dev/null
alog="$(cat "$HDLOG")"
assert_eq "$(cat "$TMP/adopt.pane")" "pS1 tP" "the first same-label tab in the family workspace is the one adopted"
assert_contains "$alog" "pane split pP7 --direction" "the adopted tab's first pane is the one split"
assert_contains "$alog" "tab close t1a" "a default \"1\" tab in the family workspace is swept"
assert_contains "$alog" "tab close t1c" "every default \"1\" tab in the family workspace is swept"
case "$alog" in *"tab close t1b"*) fail "a default \"1\" tab in ANOTHER workspace must never be swept" ;; esac
unset HD_TABS HD_PANES
git -C "$repo" checkout -q main
assert_contains "$log" "claude --permission-mode auto" "claude launched in the pane"
assert_file "$repo/.claude/settings.local.json" "stop hook installed"
case "$log" in *"--model"*) fail "no model anywhere must pass no --model" ;; esac
case "$log" in *"--effort"*) fail "no effort anywhere must pass no --effort" ;; esac

# --replace-pane retires the PREVIOUS turn's pane once the new one is up, and
# REPORTS whether that took. It stays best-effort and never fatal - the new pane
# is already placed - but a supersede that silently left the old agent alive
# against the same task-scoped resources is the orphan class this reporting
# exists to make visible.
: >"$HDLOG"
out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r-rep --replace-pane pOLD)"
assert_contains "$(cat "$HDLOG")" "pane close pOLD" "--replace-pane closes the superseded pane"
assert_contains "$out" '"event":"replace-pane","pane":"pOLD","closed":true' "a supersede that took is reported closed"
assert_contains "$out" '"event":"done","status":"ok"' "the new turn still completes normally"
# A superseded pane herdr refused to close is reported NOT closed, and the turn
# is still a success - the caller decides what to do about the survivor.
: >"$HDLOG"
out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" HD_STICKY=pSTUCK "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r-rep2 --replace-pane pSTUCK)"
assert_contains "$out" '"event":"replace-pane","pane":"pSTUCK","closed":false' "a supersede that did NOT take is reported"
assert_contains "$out" '"event":"done","status":"ok"' "a failed supersede never fails the new turn"

# --pane-file publishes the live pane+tab identity before the launched turn
# finishes, so a supervising caller can publish runtime metadata without a
# false gone: race.
pane_file="$TMP/pane.handle"
pane_out="$TMP/pane.out"
HD_RUN_SLEEP=2 PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" \
    --label r-early --pane-file "$pane_file" >"$pane_out" &
pane_pid=$!
i=0
while [ ! -s "$pane_file" ] && kill -0 "$pane_pid" 2>/dev/null && [ "$i" -lt 30 ]; do
  sleep 0.1
  i=$((i + 1))
done
assert_eq "$(cat "$pane_file" 2>/dev/null || true)" "pP1 tP" \
  "--pane-file publishes pane and tab before turn completion"
kill -0 "$pane_pid" 2>/dev/null || fail "pane turn ended before the early handle was observed"
wait "$pane_pid"
assert_contains "$(cat "$pane_out")" '"event":"done","status":"ok"' \
  "early publication does not change terminal output"

# The pane judge runs on the FLEET's model, not claude's default: config/model
# is what ac-spawn hands crewmates, and a reviewer/qa agent quietly weaker than
# the fleet pinned is a judgment made at the wrong depth, silently.
printf 'opus\n' >"$AC_HOME/config/model"
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r-model >/dev/null
assert_contains "$(cat "$HDLOG")" "claude --permission-mode auto --model opus" "fleet config/model reaches the pane claude"
# An explicit caller model wins over the fleet default.
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r-model2 --model sonnet >/dev/null
assert_contains "$(cat "$HDLOG")" "--model sonnet" "--model overrides the fleet default"
case "$(cat "$HDLOG")" in *"--model opus"*) fail "explicit model must not be shadowed by config/model" ;; esac
rm -f "$AC_HOME/config/model"

# --- per-role verification model (codereview / qa): default claude opus ----------
# Verification panes default to opus, DECOUPLED from the fleet crewmate model:
# config/model must NOT lower them, and the per-role knob / env override it.
printf 'sonnet\n' >"$AC_HOME/config/model"   # fleet crewmate model - must not reach a verification pane
for k in codereview qa; do
  : >"$HDLOG"
  PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind "$k" --label "d-$k" >/dev/null
  assert_contains "$(cat "$HDLOG")" "--model opus" "kind=$k defaults to opus, not the fleet model"
  case "$(cat "$HDLOG")" in *"--model sonnet"*) fail "verification pane ($k) must not inherit fleet config/model" ;; esac
done
# A NON-verification kind DOES ride the fleet ladder (no opus default).
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind learning --label d-learn >/dev/null
assert_contains "$(cat "$HDLOG")" "--model sonnet" "a non-verification kind keeps the fleet config/model"
rm -f "$AC_HOME/config/model"
# The per-role config knob (AC_HOME caller) overrides the opus default.
printf 'haiku\n' >"$AC_HOME/config/codereview-model"
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label d-cr >/dev/null
assert_contains "$(cat "$HDLOG")" "--model haiku" "config/codereview-model overrides the opus default"
rm -f "$AC_HOME/config/codereview-model"
# The env rung (what ac-spawn threads to a homeless pane) wins over the config knob.
printf 'sonnet\n' >"$AC_HOME/config/qa-model"
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" AC_FLEET_MODEL_QA=opus "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind qa --label d-qa >/dev/null
assert_contains "$(cat "$HDLOG")" "--model opus" "AC_FLEET_MODEL_QA env wins over config/qa-model"
rm -f "$AC_HOME/config/qa-model"
# An explicit --model still wins over the per-role default.
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label d-flag --model sonnet >/dev/null
assert_contains "$(cat "$HDLOG")" "--model sonnet" "--model flag wins over the per-role opus default"

# --- per-role verification AGENT (codereview / qa): default claude -------------
# The design (routed-pane-rules-for-gate-codereview-
# roomchief, TASK 2): the SAME rung the model knob occupies, so the harness
# and its model/effort travel together - never a knob composing a model onto
# a harness the knob itself did not also choose.
for k in codereview qa; do
  : >"$HDLOG"
  PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind "$k" --label "a-$k" >/dev/null
  assert_contains "$(cat "$HDLOG")" "claude --permission-mode auto" "kind=$k defaults to the claude arm with no agent knob"
done
# A knob naming a NON-claude harness resolves onto the CREWMATE arm, which the
# stub above does not implement - that leg is proven for real further down,
# where the crewmate-arm stub lives (search: codereview-agent resolves codex).
# The env rung (what ac-spawn threads to a homeless pane) wins over the config knob.
printf 'codex\n' >"$AC_HOME/config/qa-agent"
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" AC_FLEET_AGENT_QA=claude "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind qa --label a-qa-env >/dev/null
assert_contains "$(cat "$HDLOG")" "claude --permission-mode auto" "AC_FLEET_AGENT_QA env wins over config/qa-agent"
rm -f "$AC_HOME/config/qa-agent"
# An explicit --harness still wins over the per-role agent knob.
printf 'codex\n' >"$AC_HOME/config/codereview-agent"
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label a-cr-flag --harness claude >/dev/null
assert_contains "$(cat "$HDLOG")" "claude --permission-mode auto" "--harness flag wins over the per-role agent knob"
rm -f "$AC_HOME/config/codereview-agent"

# --- per-role verification EFFORT (codereview / qa) -----------------------------
# Inserted ABOVE the shared fleet effort ladder (not replacing it): unset stays
# byte-identical to before this knob existed (asserted last, below).
printf 'high\n' >"$AC_HOME/config/codereview-effort"
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label e-cr-cfg >/dev/null
assert_contains "$(cat "$HDLOG")" "--effort high" "config/codereview-effort resolves"
rm -f "$AC_HOME/config/codereview-effort"
# The env rung wins over the config knob.
printf 'low\n' >"$AC_HOME/config/qa-effort"
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" AC_FLEET_EFFORT_QA=xhigh "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind qa --label e-qa-env >/dev/null
assert_contains "$(cat "$HDLOG")" "--effort xhigh" "AC_FLEET_EFFORT_QA env wins over config/qa-effort"
rm -f "$AC_HOME/config/qa-effort"
# An explicit --effort still wins over the per-role knob.
printf 'high\n' >"$AC_HOME/config/codereview-effort"
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label e-cr-flag --effort low >/dev/null
assert_contains "$(cat "$HDLOG")" "--effort low" "--effort flag wins over the per-role knob"
rm -f "$AC_HOME/config/codereview-effort"
# With NO per-role knob, codereview/qa still fall through to the shared fleet
# effort ladder unchanged - the new knob is an ADDITIONAL rung, not a
# replacement, so an existing fleet pinning only config/effort sees no change.
printf 'medium\n' >"$AC_HOME/config/effort"
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label e-cr-fleet >/dev/null
assert_contains "$(cat "$HDLOG")" "--effort medium" "codereview falls through to config/effort with no codereview-effort set"
rm -f "$AC_HOME/config/effort"

# Effort rides the SAME fleet ladder as model (config/effort, ac-spawn's knob):
# a judge thinking at a shallower tier than the fleet pinned is the same silent
# mis-depth as a weaker model.
printf 'high\n' >"$AC_HOME/config/effort"
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r-eff >/dev/null
assert_contains "$(cat "$HDLOG")" "claude --permission-mode auto --effort high" "fleet config/effort reaches the pane claude"
# An explicit caller effort wins over the fleet default.
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r-eff2 --effort low >/dev/null
assert_contains "$(cat "$HDLOG")" "--effort low" "--effort overrides the fleet default"
case "$(cat "$HDLOG")" in *"--effort high"*) fail "explicit effort must not be shadowed by config/effort" ;; esac
# ultracode is the claude PRESET: xhigh on the launch line and NOTHING else -
# the '/effort ultracode' TUI line is ac-spawn's kickoff mechanism and has no
# counterpart in a one-shot pane turn.
printf 'ultracode\n' >"$AC_HOME/config/effort"
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r-eff3 >/dev/null
assert_contains "$(cat "$HDLOG")" "--effort xhigh" "ultracode maps to --effort xhigh"
case "$(cat "$HDLOG")" in *"/effort ultracode"*) fail "ultracode must add no TUI slash line to a one-shot pane turn" ;; esac
# An invalid value is refused through the helper's own error protocol, BEFORE
# any pane is placed: a bad value must never reach the launch line.
printf 'turbo\n' >"$AC_HOME/config/effort"
: >"$HDLOG"
out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r-eff4 2>&1 || true)"
assert_contains "$out" '"status":"error"' "invalid effort is a protocol error"
assert_contains "$out" "invalid effort: turbo" "the error names the rejected value"
case "$(cat "$HDLOG")" in *"pane run"*) fail "invalid effort must be refused before a pane is placed" ;; esac
rm -f "$AC_HOME/config/effort"
# The error event is NDJSON its readers parse with jq under pipefail
# (ac-learn.sh, ac-gate.sh): a message carrying a quote, a backslash or a
# newline must still be ONE valid line with the raw value intact, or the
# reader dies before its own refusal branch.
for bad in "$TMP/no\\such\"dir" "$(printf '%s\n%s' "$TMP/two" lines)"; do
  out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$bad" --prompt-file "$pf" --label r-json 2>/dev/null || true)"
  assert_eq "$(printf '%s\n' "$out" | grep -c .)" "1" "one error event per failure, never split: $bad"
  assert_eq "$(printf '%s' "$out" | jq -r 'select(.event=="done") | .error' 2>/dev/null)" "cwd missing: $bad" \
    "...valid JSON carrying the raw value: $bad"
done

# --- the dispatched pane profile (config/crew-dispatch.json `panes`) ------------
# A pane agent cannot judge a prose `when`, so its profile is looked up by KIND.
# The single most important property is the one asserted FIRST: a fleet that
# configures no panes block behaves exactly as it does today, including a fleet
# that already uses crew-dispatch for its CREWMATES. Borrowing those rules for a
# verification pane would silently move the fleet's judge onto another harness -
# the exact thing safety part 6 forbids.
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{
  "rules": [{"when": "anything at all", "use": {"harness": "codex", "model": "gpt"}}],
  "default": {"harness": "codex"}
}
EOF
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label p-none >/dev/null
assert_contains "$(cat "$HDLOG")" "claude --permission-mode auto --model opus" \
  "a crewmate dispatch table with no panes block leaves the pane exactly as today"
case "$(cat "$HDLOG")" in *codex*) fail "rules[] must never be borrowed for a verification pane" ;; esac

# A panes entry supplies the whole triple, and SUPERSEDES the per-role model
# knob for that kind: a profile is atomic, so its model travels with its harness
# rather than being overridden by a knob that knows nothing about the harness.
printf 'haiku\n' >"$AC_HOME/config/codereview-model"
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{"panes": {"codereview": {"harness": "claude", "model": "sonnet", "effort": "high"},
           "qa": {"harness": "claude"},
           "learning": {"harness": "fictional"}}}
EOF
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label p-cr >/dev/null
assert_contains "$(cat "$HDLOG")" "claude --permission-mode auto --model sonnet --effort high" \
  "a dispatched profile supplies harness, model and effort together"
case "$(cat "$HDLOG")" in *"--model haiku"*) fail "config/codereview-model must not override a dispatched profile" ;; esac
rm -f "$AC_HOME/config/codereview-model"

# A ROUTED panes.codereview resolves its MANDATORY default when the caller
# (this pane agent) passes no selector - captain ruling,
# routed-pane-rules-for-gate-codereview-roomchief. Before this fix a routed
# panes.codereview died at emit ("dispatch profile has no harness") because
# the routed form was gated behind `[ "$k" = qa ]`. Restores the previous
# config verbatim afterwards - later cases in this file depend on the
# panes.qa/panes.learning entries set above.
orig_dispatch="$(cat "$AC_HOME/config/crew-dispatch.json")"
jq '.panes.codereview = {
      rules: [
        {when: "an agent picking deliberately, never this caller",
         use: {harness: "claude", model: "opus", effort: "xhigh"},
         why: "n/a - this pane agent passes no selector"}
      ],
      default: {harness: "claude", model: "sonnet", effort: "medium"}
    }' "$AC_HOME/config/crew-dispatch.json" >"$AC_HOME/config/crew-dispatch.json.tmp"
mv "$AC_HOME/config/crew-dispatch.json.tmp" "$AC_HOME/config/crew-dispatch.json"
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label p-routed >/dev/null
assert_contains "$(cat "$HDLOG")" "claude --permission-mode auto --model sonnet --effort medium" \
  "a routed panes.codereview resolves its mandatory default, not the numbered rule"
printf '%s' "$orig_dispatch" >"$AC_HOME/config/crew-dispatch.json"

# ATOMICITY, the clause that makes the profile real: an entry naming only a
# harness launches with NO model. Falling through to the opus default here is
# what would compose a claude model name onto a non-claude harness the moment a
# second arm exists - so the empty stays empty, and the harness's own default wins.
printf 'high\n' >"$AC_HOME/config/effort"
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind qa --label p-qa >/dev/null
assert_contains "$(cat "$HDLOG")" "claude --permission-mode auto \"" \
  "a harness-only profile launches bare: no model, no effort"
case "$(cat "$HDLOG")" in *"--model"*) fail "a harness-only profile must not fall through to the opus default" ;; esac
case "$(cat "$HDLOG")" in *"--effort"*) fail "a harness-only profile must not inherit config/effort" ;; esac
rm -f "$AC_HOME/config/effort"

# The explicit caller flags still win, per knob (they carry review.model /
# AC_REVIEW_MODEL / AC_QA_MODEL).
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label p-flag --model opus >/dev/null
assert_contains "$(cat "$HDLOG")" "--model opus" "an explicit --model still wins over a dispatched profile"
case "$(cat "$HDLOG")" in *"--model sonnet"*) fail "the profile model must not shadow an explicit flag" ;; esac

# --- fail closed: a harness with no implemented arm at all ----------------------
# Refused BEFORE a pane is placed. Placing one costs the caller a full timeout
# per round and reports status:timeout, which reads like a slow reviewer rather
# than a misconfiguration.
: >"$HDLOG"
# The resolver refuses a name no arm can launch before the pane agent sees it,
# and its reason reaches the caller.
out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind learning --label p-typo 2>&1 || true)"
assert_contains "$out" '"status":"error"' "an unlaunchable harness is a protocol error"
assert_contains "$out" "harness 'fictional'" "the resolver's refusal names the harness"
# A custom template makes it launchable, and it still has no pane arm.
: >"$AC_HOME/config/launch-fictional"
out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind learning --label p-arm 2>&1 || true)"
rm -f "$AC_HOME/config/launch-fictional"
assert_contains "$out" '"status":"error"' "an unarmed harness is a protocol error"
assert_contains "$out" "fictional" "the refusal names the harness it will not place"
assert_contains "$out" "claude" "the refusal names the harnesses that ARE armed"
assert_contains "$out" "codex" "the refusal names the crewmate-arm harnesses too"
case "$(cat "$HDLOG")" in *"pane run"*) fail "an unarmed harness must be refused before a pane is placed" ;; esac

# A MISCONFIGURED profile is refused too - never silently degraded to the ladder
# below. Falling through would put the judge back on the defaults while the
# fleet believes its pin is in force: the silent-wrong-answer failure the whole
# ladder exists to end.
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{"panes": {"codereview": {"model": "opus"}}}
EOF
: >"$HDLOG"
out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label p-bad 2>&1 || true)"
assert_contains "$out" '"status":"error"' "a panes entry with no harness is a protocol error"
assert_contains "$out" "codereview" "the refusal names the kind it could not resolve"
printf '%s' "$out" | jq -e . >/dev/null || fail "a carried refusal quoting JSON keeps the event valid JSON: $out"
case "$(cat "$HDLOG")" in *"pane run"*) fail "an unresolvable profile must place no pane" ;; esac
rm -f "$AC_HOME/config/crew-dispatch.json"

# A LANES-shaped kind has no single profile BY DESIGN, and every lane launch
# carries its own --harness - the flag that takes the whole triple and leaves
# the profile unread. Resolving one anyway turned a correct declaration into a
# fatal misconfiguration and killed every scout lane of a live review round.
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{"panes": {"codereview-scout": {"lanes": [
  {"harness": "claude", "model": "sonnet"},
  {"harness": "codex", "model": "gpt-5.6-sol"}]}}}
EOF
: >"$HDLOG"
out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" \
  --prompt-file "$pf" --kind codereview-scout --harness claude --label p-lane 2>&1 || true)"
case "$out" in *'"status":"error"'*) fail "a lane naming its own harness must not ask for a single profile: $out" ;; esac
assert_contains "$(cat "$HDLOG")" "pane run" "the lane's pane is placed like any other"
# The guard the fix must NOT weaken: with no --harness there IS nothing to run,
# so the same declaration stays a refusal rather than degrading to the ladder.
: >"$HDLOG"
out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" \
  --prompt-file "$pf" --kind codereview-scout --label p-lane2 2>&1 || true)"
assert_contains "$out" '"status":"error"' "a lanes-shaped kind with no --harness resolves nothing and is refused"
assert_contains "$out" "codereview-scout" "...naming the kind"
rm -f "$AC_HOME/config/crew-dispatch.json"

# --- the shared launch mote (ac_build_launch): --resume, and NO session pin -----
# The launch command is composed by ac-backend.sh's ac_build_launch, the same
# helper ac-spawn uses. A resume names the caller's session; a fresh turn pins
# NOTHING - a one-shot pane harvests its session id from the transcript, and a
# pinned --session-id here would be ac-spawn's crewmate-lifecycle convention
# leaking into a mechanism that has no use for it.
rslug="$(printf '%s' "$repo" | sed 's/[/.]/-/g')"
mkdir -p "$FAKEHOME/.claude/projects/$rslug"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"[]"}]}}' \
  >"$FAKEHOME/.claude/projects/$rslug/sid-abc.jsonl"
: >"$HDLOG"
out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r-res --resume sid-abc)"
assert_contains "$(cat "$HDLOG")" "claude --permission-mode auto --resume sid-abc" "--resume rides the shared launch line"
assert_contains "$out" '"session_id":"sid-abc"' "the resumed session is the one reported"
case "$(cat "$HDLOG")" in *"--session-id"*) fail "a one-shot pane turn must pin no --session-id" ;; esac

# --- fail-closed harvest: an unresolvable transcript is never status:ok --------
# A claude session dir holding only subagents/+tool-results/ has no *.jsonl to
# glob, so transcript harvest is structurally impossible there. The turn still
# ends on the Stop-hook marker - and used to report ok with "transcript":"",
# which overwrote the caller's durable session pointer with an empty string and
# then died late and misleadingly. Now the helper falls back to the pane's own
# scrollback, and REFUSES to report ok when even that is empty.
repo2="$(make_repo nojsonl)"
nstub="$TMP/nojsonl-bin"; mkdir -p "$nstub"
cat >"$nstub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "tab list") echo '{"result":{"tabs":[]}}' ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wP"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tP"},"root_pane":{"pane_id":"pP1"}}}' ;;
  # the turn ENDS (marker touched) but no transcript is ever written
  "pane run")
    cwd="$(printf '%s' "$4" | sed -n "s/^cd '\([^']*\)'.*/\1/p")"
    marker="$(sed -n "s/.*touch '\([^']*\)'.*/\1/p" "$cwd/.claude/settings.local.json")"
    touch "$marker" ;;
  "pane get") echo '{"result":{"pane":{"pane_id":"pP1","agent_status":"idle"}}}' ;;
  "pane read") cat "${SCROLLBACK:-/dev/null}" ;;
esac
exit 0
EOF
chmod +x "$nstub/herdr"
export SCROLLBACK=/dev/null
out="$(PATH="$nstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo2" --prompt-file "$pf" --label nofile 2>&1 || true)"
case "$out" in *'"status":"ok"'*) fail "an unresolvable transcript must never report ok" ;; esac
assert_contains "$out" '"event":"done"' "the refusal still speaks the done protocol"
assert_contains "$out" '"status":"error"' "an unharvestable turn is a protocol error"
assert_fails env PATH="$nstub:$PATH" HOME="$FAKEHOME" \
  "$BIN/ac-pane-agent.sh" run --cwd "$repo2" --prompt-file "$pf" --label nofile2

# A SUCCESSFUL scrollback harvest is usable AND marked: the payload is written
# as a one-message transcript - the exact jsonl shape ac_transcript_final
# already parses - so ac-ship.sh/ac-qa.sh read the verdict from the same
# `transcript` path, and "source":"scrollback" tells them which harvest ran.
printf 'verdict: passed - harvested from the pane\n' >"$TMP/scrollback.txt"
export SCROLLBACK="$TMP/scrollback.txt"
out="$(PATH="$nstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo2" --prompt-file "$pf" --label sb)"
assert_contains "$out" '"status":"ok"' "a scrollback harvest completes the turn"
assert_contains "$out" '"source":"scrollback"' "the payload is marked scrollback-sourced"
tr_path="$(printf '%s\n' "$out" | sed -n 's/.*"transcript":"\([^"]*\)".*/\1/p' | tail -1)"
assert_contains "$(bash -c ". '$BIN/ac-lib.sh'; . '$RBIN/ac-pipeline-lib.sh'; ac_transcript_final '$tr_path'")" \
  "verdict: passed - harvested from the pane" "the caller's own transcript reader finds the scrollback verdict"

# --- fail-closed harvest: a turn that ended on a bare tool_use ----------------
# The MARKER arm is where real rounds end - measured over the 477 stored
# codereview rounds in both fleet homes, the idle fallback below ran 3 times and
# every other round, passing and failing alike, ended here. Its own comment
# already declares the contract ("FAIL CLOSED: the turn ended, so a payload is
# owed"), but the code guarded an empty transcript PATH while the caller asks a
# different question six lines later: ac_transcript_final (tests/fixtures/ac-pipeline-lib.sh)
# takes the LAST assistant message, and a session that stopped after a completed
# tool call has one carrying only tool_use. The pane reported ok, the caller then
# died on "transcript has no final message", and the previous round's receipt sat
# on disk looking current.
repo3="$(make_repo toolend)"
tstub="$TMP/toolend-bin"; mkdir -p "$tstub"
cat >"$tstub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "tab list") echo '{"result":{"tabs":[]}}' ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wP"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tP"},"root_pane":{"pane_id":"pP1"}}}' ;;
  # The turn ENDS on the Stop-hook marker, and the transcript it leaves behind
  # is the shape a session killed mid-pass leaves: assistant text EARLIER in the
  # turn, then a bare tool_use as the LAST assistant message.
  "pane run")
    cwd="$(printf '%s' "$4" | sed -n "s/^cd '\([^']*\)'.*/\1/p")"
    marker="$(sed -n "s/.*touch '\([^']*\)'.*/\1/p" "$cwd/.claude/settings.local.json")"
    slug="$(printf '%s' "$cwd" | sed 's/[/.]/-/g')"
    mkdir -p "$HOME/.claude/projects/$slug"
    t="$HOME/.claude/projects/$slug/toolend-sid.jsonl"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"reading the sources"}]}}' >"$t"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}' >>"$t"
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","content":"..."}]}}' >>"$t"
    touch "$marker" ;;
  "pane get") echo '{"result":{"pane":{"pane_id":"pP1","agent_status":"idle"}}}' ;;
  "pane read") echo '' ;;
esac
exit 0
EOF
chmod +x "$tstub/herdr"
trc=0
out="$(PATH="$tstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo3" --prompt-file "$pf" --label toolend 2>&1)" || trc=$?
assert_eq "$trc" "1" "a turn ending on a bare tool_use exits non-zero"
assert_contains "$out" '"event":"done","status":"error"' "...and says error rather than ok"
assert_contains "$out" "no final message" "...naming what the caller will find missing"
assert_contains "$out" '"pane":"pP1"' "...carrying the pane so the caller can still reap what it opened"
case "$out" in *'"status":"ok"'*) fail "a turn that stopped mid-pass must never be reported ok: $out" ;; esac
# The caller's own reader must agree that there was nothing to harvest - that
# agreement is the whole point of asking its question here.
tr_path="$(printf '%s\n' "$out" | sed -n 's/.*"transcript":"\([^"]*\)".*/\1/p' | tail -1)"
assert_eq "$(bash -c ". '$BIN/ac-lib.sh'; . '$RBIN/ac-pipeline-lib.sh'; ac_transcript_final '$tr_path'")" ""   "ac_transcript_final finds no final message in exactly the transcript the pane refused"

# close verb retires the pane; bad args fail with a protocol error event.
: >"$HDLOG"
PATH="$stub:$PATH" "$BIN/ac-pane-agent.sh" close --pane pP1
assert_contains "$(cat "$HDLOG")" "pane close pP1" "close verb"
out="$(PATH="$stub:$PATH" "$BIN/ac-pane-agent.sh" run --prompt-file "$pf" 2>&1 || true)"
assert_contains "$out" '"status":"error"' "missing cwd is a protocol error"
out="$(PATH="$stub:$PATH" "$BIN/ac-pane-agent.sh" bogus 2>&1 || true)"
assert_contains "$out" '"status":"error"' "unknown verb rejected"

# Adopt-by-label: with a live labeled workspace in the list, no create happens.
# The twin is swept only on PROOF of emptiness - the stub's `tab list` answers
# [] for it, which herdr_ws_tabs_state reads as all-default (vacuously "1"-only).
echo '{"result":{"workspaces":[{"workspace_id":"wOLD","label":"home","tab_count":3},{"workspace_id":"wTWIN","label":"home","tab_count":1}]}}' >"$WSLIST"
: >"$HDLOG"
out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r2)"
assert_contains "$(cat "$HDLOG")" "tab create --workspace wOLD" "busiest labeled workspace adopted"
case "$(cat "$HDLOG")" in *"workspace create"*) fail "must adopt, not create a twin group" ;; esac
assert_contains "$(cat "$HDLOG")" "workspace close wTWIN" "twin group swept"

# FAMILY placement: an exported AC_WINDOW_FAMILY routes the pane into that
# family's workspace (the ac-verify.sh / ac-gate.sh contract).
echo '{"result":{"workspaces":[]}}' >"$WSLIST"
: >"$HDLOG"
AC_WINDOW_FAMILY=fam7 PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r3 >/dev/null
assert_contains "$(cat "$HDLOG")" "workspace create --label home · fam7 --no-focus" \
  "AC_WINDOW_FAMILY routes the pane into the family workspace"

# --- no AC_HOME: fixed group label, nothing written into the checkout ----------
# Pane agents are launched from crewmate panes, which carry no AC_HOME by
# design (ac-qa.sh header). ac_home() then answers the checkout that owns bin/
# - a pool worktree, or the distro repo - and the group used to be named after
# its basename with the knob persisted into a config/ dir minted right there.
# Run from a COPY of bin/ so the assertions can never touch the real checkout.
fake="$TMP/fakecheckout"
mkdir -p "$fake/bin" "$fake/src"
cp "$BIN/ac-lib.sh" "$BIN/ac-harness.sh" "$BIN/ac-backend.sh" "$BIN/ac-backend-orca.sh" "$BIN/ac-pane-agent.sh" "$BIN/ac-dispatch-select.sh" "$BIN/ac-bun.sh" "$fake/bin/"
cp "$ROOT/src/dispatch-select.ts" "$ROOT/src/lib.ts" "$ROOT/src/backlog.ts" "$ROOT/src/pane-agent.ts" "$fake/src/"
echo '{"result":{"workspaces":[]}}' >"$WSLIST"
: >"$HDLOG"
env -u AC_HOME PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label nohome >/dev/null
assert_contains "$(cat "$HDLOG")" "workspace create --label agent-crew --no-focus" \
  "no AC_HOME: the fixed fleet's root workspace, never the checkout basename"
assert_no_file "$fake/config" "no AC_HOME: no config/ minted inside the checkout"
# ...and NOT ONE BYTE on stderr. This script's stdout+stderr are ONE stream to
# its caller: ac-verify.sh (main pane launch) launches it as `"$pane_bin" ... >"$result"
# 2>&1` and then parses that file with `jq -c 'select(.event == "done")'`.
# jq aborts on the first non-JSON line and emits NOTHING, so a single
# stray diagnostic - ac_home's homeless refusal, say - turns a valid verdict
# into `verifier <id> emitted no terminal result` and fails EVERY codereview
# and QA round a crewmate launches. The homeless rungs must degrade QUIETLY.
err="$(env -u AC_HOME -u AC_FLEET_STATE PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label nohome-quiet 2>&1 >/dev/null)"
assert_eq "$err" "" "no AC_HOME: the pane agent writes NOTHING to stderr (it shares stdout with the NDJSON its caller jq-parses)"
# The state dir it uses is the fleet's when told, never the checkout's: same
# AC_FLEET_STATE rung its siblings ac-done.sh (its state_dir) and ac-verify.sh resolve_state_dir carry.
fleet_state="$TMP/pa-fleet-state"
mkdir -p "$fleet_state"
env -u AC_HOME AC_FLEET_STATE="$fleet_state" PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label told-state >/dev/null 2>&1
[ -d "$fleet_state/.pane-agent-tmp" ] \
  || fail "AC_FLEET_STATE routes the pane markers to the fleet's own state/, not the checkout's"
assert_no_file "$fake/state" "no AC_HOME: no state/ minted inside the checkout"
# The AC_HOME pin onto the pane shell is CONDITIONAL. A homeless caller has no
# fleet to pass on: ac_home() REFUSES rather than answering ac_root, so there
# is no FAKE home left to pin - a pool worktree that evaporates with the lease,
# or the distro checkout, where the pane claude used to build data/ and state/.
case "$(cat "$HDLOG")" in
  *"AC_HOME="*) fail "no AC_HOME: the pane shell must not be pinned to a fabricated home" ;;
esac
# The NAME is not fabricated either: a caller nobody told has no fleet token to
# pass on, so the pane keeps the fixed fallback rather than being handed the
# caller's own fallback dressed up as a fleet.
case "$(cat "$HDLOG")" in
  *"AC_FLEET_NAME="*) fail "no AC_HOME and no name: nothing to pass on, so nothing is pinned" ;;
esac

# --- homeless but TOLD: the fleet NAME rides the same rung as the AC_HOME pin --
# A crewmate carries AC_FLEET_NAME and no AC_HOME (ac-spawn.sh), so this caller
# resolves its OWN group right (first assert). But a fresh pane inherits
# NOTHING, so without passing the name on, the pane claude's own ac-*.sh calls -
# qa start's watch_open above all - fell back to the group every fleet on the box
# shares: the qa agent's tab in the fleet's group, the qa-watch tab it opens in
# the shared one. What the caller cannot DERIVE it can still have been TOLD.
echo '{"result":{"workspaces":[]}}' >"$WSLIST"
: >"$HDLOG"
env -u AC_HOME AC_FLEET_NAME=drydock PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label told >/dev/null
assert_contains "$(cat "$HDLOG")" "workspace create --label drydock --no-focus" \
  "homeless but told: the pane agent's own tab lands in ITS fleet's root workspace"
assert_contains "$(cat "$HDLOG")" "AC_FLEET_NAME=drydock" \
  "homeless but told: the name is passed on, so the pane's own tabs group there too"
case "$(cat "$HDLOG")" in
  *"AC_HOME="*) fail "a told name must not smuggle in a fabricated home" ;;
esac
assert_no_file "$fake/config" "homeless but told: still no config/ minted inside the checkout"

# A HOMELESS caller still judges at the fleet's tier. ac-spawn.sh prefixes the
# crewmate launch line with AC_FLEET_MODEL/AC_FLEET_EFFORT - two narrow scalars,
# not the whole home - so the ship reviewer and qa agent a crewmate starts stop
# falling through to claude's own default (live 2026-07-15: a fleet pinned to
# config/model=opus reviewed on claude-fable-5).
: >"$HDLOG"
env -u AC_HOME AC_FLEET_MODEL=opus AC_FLEET_EFFORT=ultracode PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label fleetenv >/dev/null
assert_contains "$(cat "$HDLOG")" "--model opus" "homeless caller: AC_FLEET_MODEL reaches the pane claude"
assert_contains "$(cat "$HDLOG")" "--effort xhigh" "homeless caller: AC_FLEET_EFFORT reaches the pane claude (ultracode -> xhigh)"
# The inherited fleet default is the FALLBACK, never an override: an explicit
# caller flag still wins (review.model / AC_QA_MODEL must stay meaningful).
: >"$HDLOG"
env -u AC_HOME AC_FLEET_MODEL=opus AC_FLEET_EFFORT=max PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label fleetenv2 --model sonnet --effort low >/dev/null
assert_contains "$(cat "$HDLOG")" "--model sonnet --effort low" "explicit flags override the inherited fleet knobs"
case "$(cat "$HDLOG")" in
  *"--model opus"* | *"--effort max"*) fail "AC_FLEET_* must not shadow an explicit flag" ;;
esac

# The DISPATCHED profile reaches a homeless pane on that same rung, as ONE
# scalar carrying the whole triple. ac-ship.sh review-agent and ac-qa.sh agent
# are themselves homeless (they run inside a crewmate pane), so they cannot
# resolve it either: ac-spawn.sh resolves it where AC_HOME is real and threads
# it. One scalar, not three, so the profile stays atomic on the wire too.
: >"$HDLOG"
env -u AC_HOME AC_FLEET_MODEL=sonnet AC_FLEET_MODEL_CODEREVIEW=haiku \
  AC_FLEET_PROFILE_CODEREVIEW=$'harness=claude\tmodel=opus\teffort=max' \
  PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label prof-env >/dev/null
assert_contains "$(cat "$HDLOG")" "--model opus --effort max" \
  "homeless caller: the threaded profile supplies model and effort"
case "$(cat "$HDLOG")" in *"--model haiku"*) fail "the threaded profile supersedes the per-role model env" ;; esac
# Atomic on the wire as well: a threaded harness-only profile stays bare rather
# than picking up the fleet scalars beside it.
: >"$HDLOG"
env -u AC_HOME AC_FLEET_MODEL=sonnet AC_FLEET_EFFORT=high \
  AC_FLEET_PROFILE_QA=$'harness=claude\tmodel=\teffort=' \
  PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind qa --label prof-bare >/dev/null
case "$(cat "$HDLOG")" in *"--model"*|*"--effort"*) fail "a threaded harness-only profile must stay bare" ;; esac
# And the refusal holds on the homeless rung too - the arm set is a property of
# this helper, not of who could read the config.
: >"$HDLOG"
out="$(env -u AC_HOME AC_FLEET_PROFILE_QA=$'harness=fictional\tmodel=\teffort=' \
  PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind qa --label prof-arm 2>&1 || true)"
assert_contains "$out" '"status":"error"' "a threaded unarmed harness is refused too"
assert_contains "$out" "fictional" "the homeless refusal names the harness"
case "$(cat "$HDLOG")" in *"pane run"*) fail "a threaded unarmed harness must place no pane" ;; esac

# THE ENV RUNG IS THE ONE PLACE A LEGACY VALUE STILL ARRIVES. A crewmate is
# long-lived: one spawned before the wire became TAB-separated carries the old
# SPACE-separated triple in its process environment for the rest of its life,
# and its verification panes read it from there. Splitting that on TAB yields
# the WHOLE line as the harness, which is how a live review round came to be
# refused for a harness named `claude model=... effort=...`. Both forms parse.
: >"$HDLOG"
env -u AC_HOME AC_FLEET_PROFILE_CODEREVIEW='harness=claude model=opus effort=max' \
  PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label prof-legacy >/dev/null
assert_contains "$(cat "$HDLOG")" "--model opus --effort max" \
  "a pre-TAB threaded profile from an already-running crewmate still resolves"
# ...including the case the TAB exists FOR: the legacy form splits on its own
# key boundaries, so even a spaced model name comes out of it whole.
: >"$HDLOG"
env -u AC_HOME AC_FLEET_PROFILE_CODEREVIEW='harness=claude model=Some Long Name effort=' \
  PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label prof-legacy2 >/dev/null
assert_contains "$(cat "$HDLOG")" "--model Some Long Name" \
  "a legacy line is split on its key boundaries, not on every space"

# --- two pane agents, ONE worktree: neither destroys the other's turn end -------
# The ship reviewer (ac-ship.sh review-agent) and the qa agent (ac-qa.sh agent)
# both run with --cwd the SAME crewmate worktree, so the old whole-file truncate
# of settings.local.json deleted the Stop hook of whichever agent was mid-turn
# (it then fell back to the 120s idle path or timed out) plus any permission
# grant claude wrote there itself under --permission-mode auto. Modeled exactly:
# agent B starts WHILE A's turn is in flight, and each turn ends by firing the
# hooks the FILE carries at that moment.
repo4="$(make_repo shared)"
mkdir -p "$repo4/.claude"
printf '%s\n' '{"permissions":{"allow":["Bash(ls:*)"]}}' >"$repo4/.claude/settings.local.json"
cstub="$TMP/concbin"; mkdir -p "$cstub"
export CBIN="$BIN" CPF="$pf" BOUT="$TMP/b.out"
cat >"$cstub/herdr" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "tab list") echo '{"result":{"tabs":[]}}' ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wP"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tP"},"root_pane":{"pane_id":"pP1"}}}' ;;
  "pane get") echo '{"result":{"pane":{"pane_id":"pP1","agent_status":"idle"}}}' ;;
  "pane run")
    cwd="$(printf '%s' "$4" | sed -n "s/^cd '\([^']*\)'.*/\1/p")"
    slug="$(printf '%s' "$cwd" | sed 's/[/.]/-/g')"
    mkdir -p "$HOME/.claude/projects/$slug"
    [ -n "${AC_TEST_AGENT_B:-}" ] \
      || AC_TEST_AGENT_B=1 "$CBIN/ac-pane-agent.sh" run --cwd "$cwd" --prompt-file "$CPF" \
           --label b --timeout 30 >"$BOUT" 2>&1   # B launches while A is mid-turn
    # Every turn is a NEW claude session, so every turn writes a NEW transcript.
    n="$(cat "$BOUT.n" 2>/dev/null || printf 0)"; n=$((n + 1)); printf '%s\n' "$n" >"$BOUT.n"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]}}' \
      >"$HOME/.claude/projects/$slug/sid-$n.jsonl"
    # The turn ends by firing whatever Stop hooks the file carries NOW - which
    # is precisely what the other agent's write used to destroy.
    grep -o "touch '[^']*'" "$cwd/.claude/settings.local.json" \
      | sed "s/^touch '//;s/'\$//" | while read -r m; do touch "$m"; done ;;
esac
exit 0
EOF
chmod +x "$cstub/herdr"
# `|| true`: a lost hook ends this run as a timeout (exit 1), and the suite's
# errexit would kill the script before the assertion could say so.
out="$(PATH="$cstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo4" --prompt-file "$pf" --label a --timeout 30 || true)"
assert_contains "$out" '"status":"ok"' "agent A's turn still ends after a second agent started in its worktree"
# On its OWN Stop hook, not the 120s idle fallback: losing the hook is exactly
# what degraded A to that fallback (or to a timeout) before.
case "$out" in *"idle-fallback"*) fail "A's own Stop-hook marker must end its turn, not the idle fallback" ;; esac
assert_contains "$(cat "$BOUT")" '"status":"ok"' "the second agent's own turn ends too"
nstop() { jq '.hooks.Stop | length' "$1"; }
assert_eq "$(nstop "$repo4/.claude/settings.local.json")" "2" "both agents' Stop hooks live in the one file"
assert_contains "$(cat "$repo4/.claude/settings.local.json")" 'Bash(ls:*)' \
  "a permission grant claude wrote itself is never destroyed by a pane agent"
assert_contains "$(cat "$repo4/.git/info/exclude")" ".claude/.ac-pane-agent.lock" \
  "the write lock is excluded from git like the settings file it guards"
assert_no_file "$repo4/.claude/.ac-pane-agent.lock" "the write lock is released, not leaked into the worktree"

# A finished agent's own hook is pruned on the next write (the pid in its marker
# path is gone), so the array cannot grow without bound across many runs.
out="$(PATH="$cstub:$PATH" HOME="$FAKEHOME" AC_TEST_AGENT_B=1 \
  "$BIN/ac-pane-agent.sh" run --cwd "$repo4" --prompt-file "$pf" --label a2 --timeout 30)"
assert_contains "$out" '"status":"ok"' "a later solo turn ends ok"
assert_eq "$(nstop "$repo4/.claude/settings.local.json")" "1" "dead agents' own hooks are pruned"

# A malformed / hand-edited file must not break the launch: fail soft to a
# fresh one rather than crashing the pane agent.
printf 'not json at all\n' >"$repo4/.claude/settings.local.json"
out="$(PATH="$cstub:$PATH" HOME="$FAKEHOME" AC_TEST_AGENT_B=1 \
  "$BIN/ac-pane-agent.sh" run --cwd "$repo4" --prompt-file "$pf" --label soft --timeout 30)"
assert_contains "$out" '"status":"ok"' "a malformed settings.local.json fails soft to a fresh file"
assert_eq "$(nstop "$repo4/.claude/settings.local.json")" "1" "the fresh file carries our hook"

# --- the two JSON writers keep the user's files byte-stable -------------------
# settings.local.json and ~/.claude.json are the USER's files, rewritten in
# place, so their exact serialization is the contract: one line with ", " and
# ": " (settings) or a 2-space indent (~/.claude.json), non-ASCII escaped as
# \uXXXX, number literals kept as written (1.0, 5e-05, a 17-digit integer, NaN),
# key order kept, no trailing newline, and the mode a fresh 0666-minus-umask
# file gets. Only OUR OWN dead hooks go; everything else is kept as it was.
hrepo="$(make_repo hookbytes)"
mkdir -p "$hrepo/.claude"
hset="$hrepo/.claude/settings.local.json"
own="$TMP/ac-pane-turnend.hookbytes-0a0b0c0d"
printf '{"a":"caf\303\251","f":1.0,"e":0.00005,"big":100000000000000001,"n":NaN,"k":{"10":1,"2":2},"hooks":{"Stop":[%s,%s,%s,%s,%s,%s]},"z":[]}' \
  "{\"hooks\":[{\"type\":\"command\",\"command\":\"touch '$own.99999999'\"}]}" \
  "{\"hooks\":[{\"type\":\"command\",\"command\":\"touch '$own.99999999'\\n\"}]}" \
  "{\"hooks\":[{\"type\":\"command\",\"command\":\"touch '$own.$$'\"}]}" \
  "{\"hooks\":[{\"type\":\"command\",\"command\":\"touch '$own.1'\"}]}" \
  "{\"hooks\":[{\"type\":\"command\",\"command\":\"touch '$own.2147483648'\"}]}" \
  "{\"matcher\":\"\",\"hooks\":[{\"type\":\"command\",\"command\":\"echo hi\"},{\"type\":\"command\",\"command\":\"touch '$own.99999999'\"}]}" \
  >"$hset"
chmod 600 "$hset"
out="$(umask 022; PATH="$cstub:$PATH" HOME="$FAKEHOME" AC_TEST_AGENT_B=1 \
  "$BIN/ac-pane-agent.sh" run --cwd "$hrepo" --prompt-file "$pf" --label bytes --timeout 30)"
assert_contains "$out" '"status":"ok"' "the merged-hook turn ends ok"
hmark="$(sed -n "s/.*touch '\([^']*\)'.*/\1/p" "$hset")"
printf '%s' "{\"a\": \"caf\\u00e9\", \"f\": 1.0, \"e\": 5e-05, \"big\": 100000000000000001, \"n\": NaN, \"k\": {\"10\": 1, \"2\": 2}, \"hooks\": {\"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"touch '$own.$$'\"}]}, {\"hooks\": [{\"type\": \"command\", \"command\": \"touch '$own.1'\"}]}, {\"hooks\": [{\"type\": \"command\", \"command\": \"touch '$own.2147483648'\"}]}, {\"matcher\": \"\", \"hooks\": [{\"type\": \"command\", \"command\": \"echo hi\"}, {\"type\": \"command\", \"command\": \"touch '$own.99999999'\"}]}, {\"hooks\": [{\"type\": \"command\", \"command\": \"touch '$hmark'\"}]}]}, \"z\": []}" >"$TMP/hookbytes.want"
cmp -s "$hset" "$TMP/hookbytes.want" \
  || fail "settings.local.json merge: want $(cat "$TMP/hookbytes.want") got $(cat "$hset")"
assert_eq "$(stat -f %Lp "$hset")" "644" "the merged file takes a fresh file's mode"
# A BOM makes the file unreadable JSON, which fails soft to a fresh object.
printf '\357\273\277{"keep":1}' >"$hset"
out="$(PATH="$cstub:$PATH" HOME="$FAKEHOME" AC_TEST_AGENT_B=1 \
  "$BIN/ac-pane-agent.sh" run --cwd "$hrepo" --prompt-file "$pf" --label bom --timeout 30)"
hmark="$(sed -n "s/.*touch '\([^']*\)'.*/\1/p" "$hset")"
printf '%s' "{\"hooks\": {\"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"touch '$hmark'\"}]}]}}" >"$TMP/hookbytes.want"
cmp -s "$hset" "$TMP/hookbytes.want" \
  || fail "settings.local.json with a BOM: want $(cat "$TMP/hookbytes.want") got $(cat "$hset")"

# The trust seed: our entry gains both flags (a falsy [] counts as unset, an
# existing key keeps its place), every other byte of the document survives the
# 2-space re-serialization.
trepo="$(make_repo trustbytes)"
tjson="$FAKEHOME/.claude.json"
printf '{"tips":{"10":1,"2":2},"name":"caf\303\251 \360\237\230\200","f":1.0,"e":0.00005,"big":100000000000000001,"n":NaN,"projects":{"/elsewhere":{"hasTrustDialogAccepted":false,"x":[]},"%s":{"hasCompletedProjectOnboarding":[],"keep":"x"}}}' "$trepo" >"$tjson"
chmod 600 "$tjson"
trun() {
  PATH="$cstub:$PATH" HOME="$FAKEHOME" AC_TEST_AGENT_B=1 \
    "$BIN/ac-pane-agent.sh" run --cwd "$trepo" --prompt-file "$pf" --label "$1" --timeout 30 >/dev/null
}
(umask 022; trun trust1)
printf '{\n  "tips": {\n    "10": 1,\n    "2": 2\n  },\n  "name": "caf\\u00e9 \\ud83d\\ude00",\n  "f": 1.0,\n  "e": 5e-05,\n  "big": 100000000000000001,\n  "n": NaN,\n  "projects": {\n    "/elsewhere": {\n      "hasTrustDialogAccepted": false,\n      "x": []\n    },\n    "%s": {\n      "hasCompletedProjectOnboarding": true,\n      "keep": "x",\n      "hasTrustDialogAccepted": true\n    }\n  }\n}' "$trepo" >"$TMP/trust.want"
cmp -s "$tjson" "$TMP/trust.want" || fail "~/.claude.json seed: want $(cat "$TMP/trust.want") got $(cat "$tjson")"
assert_eq "$(stat -f %Lp "$tjson")" "644" "the seeded file takes a fresh file's mode"
# Already trusted (any truthy pair), unreadable, or a BOM: the file is left
# exactly as it was - not re-serialized, not re-moded.
for tdoc in "{\"projects\":{\"$trepo\":{\"hasTrustDialogAccepted\":\"no\",\"hasCompletedProjectOnboarding\":1}}}" \
            '{"projects":' $'\357\273\277{"projects":{}}'; do
  printf '%s' "$tdoc" >"$tjson"; chmod 600 "$tjson"; cp -p "$tjson" "$TMP/trust.was"
  trun trust-keep
  cmp -s "$tjson" "$TMP/trust.was" || fail "~/.claude.json must be left untouched for: $tdoc"
  assert_eq "$(stat -f %Lp "$tjson")" "600" "an untouched ~/.claude.json keeps its mode"
done
rm -f "$tjson"
trun trust-none
assert_no_file "$tjson" "a missing ~/.claude.json is never created"

# --- reap: close OUR panes whose launch cwd is gone -----------------------------
# A dedicated herdr stub with canned tab/pane lists, kept out of the shared stub
# above: reap needs `pane list` (with cwd) and `tab close`, which the run/close
# stub does not model. LIVEDIR exists ($repo); DEADDIR never does.
rstub="$TMP/reapbin"; mkdir -p "$rstub"
export RLOG="$TMP/reap.log" RTABS="$TMP/tabs.json" RPANES="$TMP/panes.json"
deaddir="$TMP/gone-worktree"; rm -rf "$deaddir"   # the removed worktree
cat >"$rstub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$RLOG"
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "tab list")   cat "$RTABS" ;;
  "pane list")  cat "$RPANES" ;;
  "pane close") echo "CLOSE-PANE $3" >>"$RLOG" ;;
  "tab close")  echo "CLOSE-TAB $3" >>"$RLOG" ;;
esac
exit 0
EOF
chmod +x "$rstub/herdr"
# tA: ours, only pane dead   -> reap pane + close empty tab
# tB: ours, pane live        -> untouched
# tC: NOT ours, pane dead    -> untouched (wrong label)
# tD: ours, one dead one live -> reap the dead pane, KEEP the tab (a pane survives)
cat >"$RTABS" <<EOF
{"result":{"tabs":[
 {"tab_id":"tA","label":"ac-ship-agent-crew-foo"},
 {"tab_id":"tB","label":"ac-ship-agent"},
 {"tab_id":"tC","label":"crew:foo"},
 {"tab_id":"tD","label":"ac-ship-agent-x"},
 {"tab_id":"tQ","label":"ac-qa-agent-crew-bar"}]}}
EOF
cat >"$RPANES" <<EOF
{"result":{"panes":[
 {"pane_id":"pA","tab_id":"tA","cwd":"$deaddir"},
 {"pane_id":"pB","tab_id":"tB","cwd":"$repo"},
 {"pane_id":"pC","tab_id":"tC","cwd":"$deaddir"},
 {"pane_id":"pD1","tab_id":"tD","cwd":"$deaddir"},
 {"pane_id":"pD2","tab_id":"tD","cwd":"$repo"},
 {"pane_id":"pQ","tab_id":"tQ","cwd":"$deaddir"}]}}
EOF

# Dry-run: names the dead pane, touches nothing.
: >"$RLOG"
out="$(PATH="$rstub:$PATH" AC_HERDR_SESSION=test "$BIN/ac-pane-agent.sh" reap --dry-run)"
assert_contains "$out" '"pane":"pA"' "dry-run names the dead pane"
assert_contains "$out" '"dry_run":1' "dry-run flagged"
case "$(cat "$RLOG")" in *CLOSE-*) fail "dry-run must close nothing" ;; esac

# Real run: exactly the dead OURS panes close; the empty tab closes with them.
: >"$RLOG"
out="$(PATH="$rstub:$PATH" AC_HERDR_SESSION=test "$BIN/ac-pane-agent.sh" reap)"
log="$(cat "$RLOG")"
assert_contains "$log" "CLOSE-PANE pA" "dead pane in our tab reaped"
assert_contains "$log" "CLOSE-TAB tA" "the tab left empty is closed"
assert_contains "$log" "CLOSE-PANE pD1" "a dead pane is reaped even when a sibling survives"
assert_contains "$log" "CLOSE-PANE pQ" "a dead qa-kind pane is ours too (ac-<kind>-agent matcher)"
assert_contains "$log" "CLOSE-TAB tQ" "the emptied qa tab closes with it"
assert_contains "$out" '"panes":3,"tabs":2' "three dead panes, two emptied tabs"
case "$log" in *"CLOSE-PANE pB"*) fail "a live-cwd pane must never be reaped" ;; esac
case "$log" in *"CLOSE-TAB tD"*) fail "a tab with a surviving pane must not be closed" ;; esac
case "$log" in *"pC"*|*"tC"*) fail "a pane whose tab is not ours must never be touched" ;; esac
# (the no-herdr branch is left untested on purpose: line-35 PATH-hardening
# appends /opt/homebrew/bin, so a PATH without herdr cannot be forced here
# without also driving reap at the operator's REAL live session.)

# The matcher is ANCHORED and exact: ac-<lowercase kind>-agent, then "-" or the
# end. A regular FILE where the cwd should be is gone too; a pane with no
# recorded cwd is never reaped and keeps its tab. Events come in tab order,
# then pane order, and every tab close follows every pane close.
cat >"$RTABS" <<EOF
{"result":{"tabs":[
 {"tab_id":"tX1","label":"ac-ship-agentX"},
 {"tab_id":"tX2","label":"ac--agent"},
 {"tab_id":"tX3","label":"ac-Ship-agent"},
 {"tab_id":"tX4","label":"xac-ship-agent"},
 {"tab_id":"tH"},
 {"tab_id":"tE","label":"ac-n-agent"},
 {"tab_id":"tF","label":"ac-qa-agent-f"},
 {"tab_id":"tG","label":"ac-qa-agent-g"}]}}
EOF
cat >"$RPANES" <<EOF
{"result":{"panes":[
 {"pane_id":"pX1","tab_id":"tX1","cwd":"$deaddir"},
 {"pane_id":"pX2","tab_id":"tX2","cwd":"$deaddir"},
 {"pane_id":"pX3","tab_id":"tX3","cwd":"$deaddir"},
 {"pane_id":"pX4","tab_id":"tX4","cwd":"$deaddir"},
 {"pane_id":"pH","tab_id":"tH","cwd":"$deaddir"},
 {"pane_id":"pG1","tab_id":"tG"},
 {"pane_id":"pF1","tab_id":"tF","cwd":"$pf"},
 {"pane_id":"pE","tab_id":"tE","cwd":"$deaddir/with space"},
 {"pane_id":"pF2","tab_id":"tF","cwd":"$deaddir"},
 {"pane_id":"pG2","tab_id":"tG","cwd":"$deaddir"}]}}
EOF
out="$(PATH="$rstub:$PATH" AC_HERDR_SESSION=test "$BIN/ac-pane-agent.sh" reap --dry-run)"
want="$(printf '{"event":"reap","pane":"%s","cwd":"%s","dry_run":1}\n' pE "$deaddir/with space" pF1 "$pf" pF2 "$deaddir" pG2 "$deaddir")
{\"event\":\"reap-done\",\"panes\":4,\"tabs\":2,\"dry_run\":1}"
assert_eq "$out" "$want" "reap plans exactly our dead panes, in tab then pane order"
: >"$RLOG"
PATH="$rstub:$PATH" AC_HERDR_SESSION=test "$BIN/ac-pane-agent.sh" reap >/dev/null
assert_eq "$(grep CLOSE- "$RLOG" | tr '\n' ' ')" \
  "CLOSE-PANE pE CLOSE-PANE pF1 CLOSE-PANE pF2 CLOSE-PANE pG2 CLOSE-TAB tE CLOSE-TAB tF " \
  "the dead panes close first, then only the tabs they emptied"

# --- reap-pane: retire ONE known pane + tidy its tab / the shared workspace -----
# Unlike `reap` (dead-cwd keyed), this targets a KNOWN pane id and adds the
# last-tab-in-workspace close ac-learn.sh's scout needs. The pane-agent
# workspace is SHARED, so it closes ONLY that pane: its tab only if that empties
# it, and the workspace ONLY when the pane's tab was the last one there.
pstub="$TMP/panereapbin"; mkdir -p "$pstub"
export PRLOG="$TMP/panereap.log" PRTABS="$TMP/pr-tabs.json" PRPANES="$TMP/pr-panes.json"
cat >"$pstub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$PRLOG"
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "tab list")        cat "$PRTABS" ;;
  "pane list")       cat "$PRPANES" ;;
  "pane close")      echo "CLOSE-PANE $3" >>"$PRLOG" ;;
  "tab close")       echo "CLOSE-TAB $3" >>"$PRLOG" ;;
  "workspace close") echo "CLOSE-WS $3" >>"$PRLOG" ;;
  # A closed pane stops resolving - what reap-pane's `closed` verification
  # reads. PR_STICKY names a pane this stub keeps ALIVE however often it is
  # closed (the herdr-refused-the-close case).
  "pane get")        { [ "$3" != "${PR_STICKY:-}" ] && grep -q "CLOSE-PANE $3\$" "$PRLOG" 2>/dev/null; } && exit 1
                     echo '{"result":{"pane":{"pane_id":"'"$3"'"}}}' ;;
esac
exit 0
EOF
chmod +x "$pstub/herdr"
# wLAST: only tT              -> pT is the last tab's sole pane   (workspace close)
# wSHARED: tS + co-tenant tCo -> pS alone in tS, tCo keeps WS up  (tab close only)
# wSIB: tSib holds pSib+pOther -> a sibling survives             (pane close only)
cat >"$PRTABS" <<'EOF'
{"result":{"tabs":[
 {"tab_id":"tT","workspace_id":"wLAST","label":"ac-learning-agent-x"},
 {"tab_id":"tS","workspace_id":"wSHARED","label":"ac-learning-agent-y"},
 {"tab_id":"tCo","workspace_id":"wSHARED","label":"ac-ship-agent-z"},
 {"tab_id":"tSib","workspace_id":"wSIB","label":"ac-learning-agent-w"}]}}
EOF
cat >"$PRPANES" <<'EOF'
{"result":{"panes":[
 {"pane_id":"pT","tab_id":"tT"},
 {"pane_id":"pS","tab_id":"tS"},
 {"pane_id":"pCoP","tab_id":"tCo"},
 {"pane_id":"pSib","tab_id":"tSib"},
 {"pane_id":"pOther","tab_id":"tSib"}]}}
EOF

# Scenario A - last tab in the workspace: pane close + workspace close (no tab close).
: >"$PRLOG"
out="$(PATH="$pstub:$PATH" AC_HERDR_SESSION=test "$BIN/ac-pane-agent.sh" reap-pane --pane pT)"
log="$(cat "$PRLOG")"
assert_contains "$log" "CLOSE-PANE pT" "reap-pane closes the target pane"
assert_contains "$log" "CLOSE-WS wLAST" "the last tab in a workspace triggers workspace close"
case "$log" in *"CLOSE-TAB"*) fail "reap-pane must not tab-close the workspace's last tab" ;; esac
assert_contains "$out" '"event":"reap-pane-done"' "reap-pane emits its done event"
assert_contains "$out" '"closed":true' "reap-pane VERIFIES the close and reports it took"

# A reap that did NOT take says so. reap-pane keeps its always-exit-0 contract
# (callers arm it as an EXIT trap), so `closed` is the ONLY channel a caller has
# to tell a retired pane from an orphaned one - the silence that let pane agents
# orphan unnoticed.
: >"$PRLOG"
set +e
out="$(PATH="$pstub:$PATH" PR_STICKY=pT AC_HERDR_SESSION=test "$BIN/ac-pane-agent.sh" reap-pane --pane pT)"
rc=$?
set -e
assert_eq "$rc" "0" "a pane that survived the close still exits 0 (trap-safe contract intact)"
assert_contains "$out" '"closed":false' "a pane still alive after the close is reported NOT closed"

# Scenario B - co-tenant tab present: pane close + tab close, NEVER workspace close.
: >"$PRLOG"
PATH="$pstub:$PATH" AC_HERDR_SESSION=test "$BIN/ac-pane-agent.sh" reap-pane --pane pS >/dev/null
log="$(cat "$PRLOG")"
assert_contains "$log" "CLOSE-PANE pS" "reap-pane closes the target pane (co-tenant case)"
assert_contains "$log" "CLOSE-TAB tS" "an emptied tab is closed when a co-tenant keeps the workspace alive"
case "$log" in *"CLOSE-WS"*) fail "co-tenant guard: a workspace with another live tab is never closed" ;; esac

# Scenario C - a sibling pane shares the tab: pane close only.
: >"$PRLOG"
PATH="$pstub:$PATH" AC_HERDR_SESSION=test "$BIN/ac-pane-agent.sh" reap-pane --pane pSib >/dev/null
log="$(cat "$PRLOG")"
assert_contains "$log" "CLOSE-PANE pSib" "reap-pane closes the target pane (sibling case)"
case "$log" in *"CLOSE-TAB"*) fail "a tab with a surviving sibling pane must not be closed" ;; esac
case "$log" in *"CLOSE-WS"*) fail "a tab with a surviving sibling pane must not trigger workspace close" ;; esac

# Best-effort: every herdr close failing still exits 0 (safe to arm as an EXIT trap).
failstub="$TMP/panereapfail"; mkdir -p "$failstub"
cat >"$failstub/herdr" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "tab list")  cat "$PRTABS" ;;
  "pane list") cat "$PRPANES" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$failstub/herdr"
set +e
PATH="$failstub:$PATH" AC_HERDR_SESSION=test "$BIN/ac-pane-agent.sh" reap-pane --pane pT >/dev/null 2>&1
rc=$?
set -e
assert_eq "$rc" "0" "reap-pane exits 0 even when every herdr close fails"

# No pane id -> a clean no-op, exit 0.
set +e
out="$(PATH="$pstub:$PATH" AC_HERDR_SESSION=test "$BIN/ac-pane-agent.sh" reap-pane)"
rc=$?
set -e
assert_eq "$rc" "0" "reap-pane with no pane id is a clean no-op"
assert_contains "$out" '"note":"no pane id"' "reap-pane notes the missing pane id"

# Whatever herdr's lists cannot place, only the pane itself closes: a pane in
# no listed tab, a tab in no workspace, or lists that do not parse. A pane id
# listed twice belongs to its LAST tab, and a tab id listed twice to its LAST
# workspace.
cat >"$TMP/pr-tabs2.json" <<'EOF'
{"result":{"tabs":[
 {"tab_id":"tNoWs","label":"ac-learning-agent-v"},
 {"tab_id":"tDup","workspace_id":"wOld"},
 {"tab_id":"tDup","workspace_id":"wDup"},
 {"tab_id":"tDupCo","workspace_id":"wDup"}]}}
EOF
cat >"$TMP/pr-panes2.json" <<'EOF'
{"result":{"panes":[
 {"pane_id":"pNoWs","tab_id":"tNoWs"},
 {"pane_id":"pDup","tab_id":"tElse"},
 {"pane_id":"pDup","tab_id":"tDup"}]}}
EOF
printf 'not json\n' >"$TMP/pr-garbage.json"
prun() {
  : >"$PRLOG"
  PATH="$pstub:$PATH" PRTABS="$1" PRPANES="$2" AC_HERDR_SESSION=test \
    "$BIN/ac-pane-agent.sh" reap-pane --pane "$3" >/dev/null
  grep CLOSE- "$PRLOG" | tr '\n' ' '
}
assert_eq "$(prun "$TMP/pr-tabs2.json" "$TMP/pr-panes2.json" pNope)" "CLOSE-PANE pNope " "an unlisted pane closes alone"
assert_eq "$(prun "$TMP/pr-tabs2.json" "$TMP/pr-panes2.json" pNoWs)" "CLOSE-PANE pNoWs " "a tab in no workspace is left alone"
assert_eq "$(prun "$TMP/pr-tabs2.json" "$TMP/pr-panes2.json" pDup)" "CLOSE-PANE pDup CLOSE-TAB tDup " \
  "a twice-listed pane and tab each resolve to their last entry"
assert_eq "$(prun "$TMP/pr-garbage.json" "$TMP/pr-garbage.json" pT)" "CLOSE-PANE pT " "unparseable lists close the pane alone"

# --- steer: a chief steers a LIVE pane agent by its stable handle ----------------
# The handle IS the pane label ac-<kind>-agent:<label> the run verb writes at
# pane creation (`pane rename`, above) - so a chief that did NOT launch the pane
# resolves it from herdr itself, with no caller-private .pane file. The shared
# fake herdr (tests/sh/helpers.sh) is used from here on: its composer model is what
# proves a submit landed, and it reports pane labels the way real herdr does.
make_fake_herdr

mk_agent_pane() {
  # mk_agent_pane <pane> <tab> [<label>] - a live pane, labeled like a pane agent.
  printf '%s\n' "$1" >"$FAKE_HERDR/tabs/$2"
  : >"$FAKE_HERDR/panes/$1.buf"
  printf '%s\n' "$2" >"$FAKE_HERDR/panes/$1.tab"
  [ -n "${3:-}" ] && printf '%s\n' "$3" >"$FAKE_HERDR/panes/$1.label"
  return 0
}

mk_agent_pane pS1 tS1 "ac-codereview-agent:ship-review-r1"
out="$("$BIN/ac-pane-agent.sh" steer --agent ac-codereview-agent:ship-review-r1 'report your findings now')"
assert_contains "$out" "steered" "the steer confirms delivery"
assert_contains "$out" "pS1" "the confirmation names the pane it reached"
assert_contains "$(cat "$FAKE_HERDR/panes/pS1.buf")" "report your findings now" \
  "the line is SUBMITTED into the live pane agent, not left in the composer"

# An unknown handle is refused loudly - and the refusal NAMES the live handles,
# so a chief that mistyped one does not fall back to raw herdr to find it.
err="$("$BIN/ac-pane-agent.sh" steer --agent ac-qa-agent:nope 'hello' 2>&1)" \
  && fail "an unknown handle must be refused"
assert_contains "$err" "no live pane agent" "the refusal says the handle resolved to nothing"
assert_contains "$err" "ac-codereview-agent:ship-review-r1" "the refusal names the handles that DO exist"

# A pane that is not a pane agent is never steered through this verb: --pane is
# a disambiguator, not a backdoor into a crewmate's pane.
mk_agent_pane pC1 tC1
err="$("$BIN/ac-pane-agent.sh" steer --pane pC1 'not yours' 2>&1)" \
  && fail "a pane with no pane-agent label must be refused"
assert_contains "$err" "not a live pane agent" "the refusal says why"
case "$(cat "$FAKE_HERDR/panes/pC1.buf")" in *"not yours"*) fail "a refused steer must never reach the pane" ;; esac

# A stale handle - a pane id that is dead or was recycled away - fails loudly
# instead of steering whatever answers to that id now.
err="$("$BIN/ac-pane-agent.sh" steer --pane pGONE 'ghost' 2>&1)" \
  && fail "a dead pane id must be refused"
assert_contains "$err" "pGONE" "the refusal names the pane it could not prove"

# Two live panes sharing a handle (two repos at ship-review-r1) is AMBIGUOUS:
# refuse rather than steer a stranger's pane, and name the way through.
mk_agent_pane pS2 tS2 "ac-codereview-agent:ship-review-r1"
err="$("$BIN/ac-pane-agent.sh" steer --agent ac-codereview-agent:ship-review-r1 'which one' 2>&1)" \
  && fail "an ambiguous handle must be refused"
assert_contains "$err" "2 live panes" "the refusal counts the matches"
assert_contains "$err" "--pane" "the refusal names the disambiguator"
case "$(cat "$FAKE_HERDR/panes/pS1.buf")" in *"which one"*) fail "an ambiguous steer must reach no pane" ;; esac
out="$("$BIN/ac-pane-agent.sh" steer --pane pS2 'this one')"
assert_contains "$(cat "$FAKE_HERDR/panes/pS2.buf")" "this one" "--pane disambiguates and delivers"

# Delivery NOT confirmed is a LOUD failure, never a silent strand: non-zero,
# an actionable stderr line, and the text honestly still in the composer.
mk_agent_pane pS3 tS3 "ac-qa-agent:probe-task"
printf '99\n' >"$FAKE_HERDR/panes/pS3.drop-enters"
err="$("$BIN/ac-pane-agent.sh" steer --agent ac-qa-agent:probe-task 'lost steer' 2>&1)" \
  && fail "an unacknowledged submit must exit non-zero"
assert_contains "$err" "delivery NOT confirmed" "the strand is named"
assert_contains "$err" "pS3" "the failure names the pane, so the chief can peek and resubmit"
case "$err" in *"steered"*) fail "a stranded steer must not claim delivery" ;; esac
assert_contains "$(cat "$FAKE_HERDR/panes/pS3.in")" "lost steer" "the text sits in the composer, reported honestly"

# Steer is HERDR-ONLY: the handle is the pane NAME the herdr arm writes, and an
# orca pane agent carries none. On an orca fleet the verb refuses saying so -
# never by resolving a same-named pane in herdr's default session (another
# fleet's) and sending to it through the orca driver.
: >"$FAKE_HERDR/log"
err="$(AC_BACKEND=orca "$BIN/ac-pane-agent.sh" steer --agent ac-qa-agent:probe-task 'orca steer' 2>&1)" \
  && fail "steer on an orca fleet must refuse"
assert_contains "$err" "herdr-only" "the refusal names the real reason"
case "$err" in *"herdr pane read"*|*"delivery"*) fail "an orca steer must not reach any pane: $err" ;; esac
grep -q 'pane list\|send' "$FAKE_HERDR/log" && fail "an orca steer must not query or type into herdr: $(cat "$FAKE_HERDR/log")"

# --- steer: the GATE JUDGE independence guard ------------------------------------
# The gate judge is the ONE pane agent whose whole value is that the chief whose
# stage it judges did not shape its turn, so a CHIEF steer into it is refused and
# only a DECLARED captain gets through. The pane below is SYNTHETIC and
# LONG-LIVED - nothing here creates or reaps it the way ac-gate.sh reaps its own
# ephemeral judge - so the guard is proven in the shape a long-lived gate pane
# will have, with no second change owed.
mk_agent_pane pG1 tG1 "ac-gate-agent:widget-flow-spec"

err="$("$BIN/ac-pane-agent.sh" steer --agent ac-gate-agent:widget-flow-spec 'approve it' 2>&1)" \
  && fail "a chief steer into a gate pane must be refused"
assert_contains "$err" "pG1" "the refusal names the pane"
assert_contains "$err" "family 'widget-flow'" "the refusal names the family whose gate it is"
assert_contains "$err" "INDEPENDENT GATE JUDGE" "the refusal names the role it protects"
assert_contains "$err" "must not shape" "the refusal states the property, not only the role"
assert_contains "$err" "--captain" "the refusal names the captain's way through"
case "$(cat "$FAKE_HERDR/panes/pG1.buf" 2>/dev/null || true)" in
  *"approve it"*) fail "a refused gate steer must never be submitted into the pane" ;;
esac
case "$(cat "$FAKE_HERDR/panes/pG1.in" 2>/dev/null || true)" in
  *"approve it"*) fail "a refused gate steer must not even reach the composer" ;;
esac

# The CAPTAIN outranks the property and must not be locked out - and the way
# through is a DECLARATION by the caller, never an inference about who is asking.
out="$("$BIN/ac-pane-agent.sh" steer --captain --agent ac-gate-agent:widget-flow-spec 'approve it')"
assert_contains "$out" "steered" "a captain steer into a gate pane is delivered"
assert_contains "$(cat "$FAKE_HERDR/panes/pG1.buf")" "approve it" "the captain's line lands in the gate pane"

# --pane is a disambiguator, not a backdoor around the guard - and the SAME live
# pane refuses again after the captain used it, which is what makes this a guard
# on the judge rather than on a pane that was about to be reaped anyway.
err="$("$BIN/ac-pane-agent.sh" steer --pane pG1 'and again' 2>&1)" \
  && fail "--pane must not bypass the gate guard"
assert_contains "$err" "pG1" "the --pane refusal names the pane too"
case "$(cat "$FAKE_HERDR/panes/pG1.buf")" in
  *"and again"*) fail "a refused gate steer must never be submitted into the pane" ;;
esac

# This guards a JUDGE, not every verification pane: a qa pane steers with no
# --captain exactly as it did before (the codereview case above is its twin).
mk_agent_pane pQ1 tQ1 "ac-qa-agent:widget-flow"
out="$("$BIN/ac-pane-agent.sh" steer --agent ac-qa-agent:widget-flow 'run case 3')"
assert_contains "$out" "steered" "a qa pane agent still steers without --captain"
assert_contains "$(cat "$FAKE_HERDR/panes/pQ1.buf")" "run case 3" "the qa steer is unchanged"

# The live-agent registry is exactly the panes named ac-<kind>-agent:<label>,
# in herdr's order; a label may carry spaces, and a pane list herdr cannot
# serve is an EMPTY registry - the refusal still names which check failed.
mk_agent_pane pW1 tW1 "ac-qa-agent:two words"
mk_agent_pane pN1 tN1 "crew:not-an-agent"
mk_agent_pane pN2 tN2 "ac-qa-agent-nocolon"
err="$("$BIN/ac-pane-agent.sh" steer --agent ac-qa-agent:nope 'x' 2>&1)" && fail "an unknown handle must be refused"
assert_contains "$err" "live pane agents: ac-gate-agent:widget-flow-spec, ac-qa-agent:widget-flow, ac-codereview-agent:ship-review-r1, ac-codereview-agent:ship-review-r1, ac-qa-agent:probe-task, ac-qa-agent:two words" \
  "the refusal lists every live pane agent and nothing else, in herdr's order"
err="$("$BIN/ac-pane-agent.sh" steer --agent ac-codereview-agent:ship-review-r1 'x' 2>&1)" && fail "an ambiguous handle must be refused"
assert_contains "$err" "matches 2 live panes (pS1 pS2)" "the ambiguity names every matching pane"
assert_eq "$("$BIN/ac-pane-agent.sh" steer --pane pW1 'spaced')" "steered ac-qa-agent:two words (pane pW1)" \
  "a label with spaces resolves whole"
: >"$FAKE_HERDR/.pane-api-down"
err="$("$BIN/ac-pane-agent.sh" steer --pane pQ1 'x' 2>&1)" && fail "no pane list must refuse --pane"
assert_contains "$err" "pane 'pQ1' is not a live pane agent" "without a pane list, --pane is refused as not an agent"
assert_contains "$err" "live pane agents: none" "without a pane list, no agent is live"
err="$("$BIN/ac-pane-agent.sh" steer --agent ac-qa-agent:widget-flow 'x' 2>&1)" && fail "no pane list must refuse --agent"
assert_contains "$err" "no live pane agent named 'ac-qa-agent:widget-flow' - live pane agents: none" \
  "without a pane list, a handle resolves to nothing"
rm -f "$FAKE_HERDR/.pane-api-down"

# --- the ONE-SHOT COMMAND arm (--exec) -------------------------------------------
# A harness whose one-shot form is non-interactive (codex exec / claude -p /
# opencode run) needs no TUI arm: the process EXIT is the turn end and its
# STDOUT is the final message. The pane still exists - the caller watches the
# judge on herdr like any other pane agent - it just is not a session.
# The stub's `pane run` EXECUTES the composed line, which is exactly what a pane
# shell does, so these cases exercise the real launch line end to end.
xstub="$TMP/execbin"; mkdir -p "$xstub"
export XLOG="$TMP/exec.log"
cat >"$xstub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "tab list") echo '{"result":{"tabs":[]}}' ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wX"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tX"},"root_pane":{"pane_id":"pX1"}}}' ;;
  "pane run") printf '%s\n' "$4" >>"$HDLOG.cmd"; sh -c "$4" ;;
  "pane get") echo '{"result":{"pane":{"pane_id":"pX1","agent_status":"idle"}}}' ;;
esac
exit 0
EOF
cat >"$xstub/codex" <<'EOF'
#!/usr/bin/env bash
flags=("$@"); unset 'flags[${#flags[@]}-1]'
echo "codex ${flags[*]}" >>"$XLOG"
printf '%s' "${@: -1}" >"$XLOG.prompt"
# The failing leg PRINTS a plausible verdict and THEN dies: the exit status
# has to be what decides, or a rung that errored halfway would have its
# half-answer harvested as a judgment.
[ -f "$XLOG.fail" ] && { echo '{"verdict":"approve"}'; exit 7; }
[ -f "$XLOG.empty" ] && exit 0
echo '{"verdict":"approve"}'
EOF
cat >"$xstub/claude" <<'EOF'
#!/usr/bin/env bash
flags=("$@"); unset 'flags[${#flags[@]}-1]'
echo "claude ${flags[*]}" >>"$XLOG"
echo 'claude one-shot answer'
EOF
cat >"$xstub/opencode" <<'EOF'
#!/usr/bin/env bash
flags=("$@"); unset 'flags[${#flags[@]}-1]'
echo "opencode ${flags[*]}" >>"$XLOG"
echo 'opencode one-shot answer'
EOF
# EVERY harness this block reaches through --exec needs a stub HERE: the line
# really runs, so a missing one falls through $PATH to the operator's own CLI -
# which for an authenticating harness means a live sign-in on each suite run.
cat >"$xstub/agy" <<'EOF'
#!/usr/bin/env bash
flags=("$@"); unset 'flags[${#flags[@]}-1]'
echo "agy ${flags[*]}" >>"$XLOG"
echo 'agy one-shot answer'
EOF
chmod +x "$xstub/herdr" "$xstub/codex" "$xstub/claude" "$xstub/opencode" "$xstub/agy"
xrepo="$(make_repo execwt)"
xrun() { PATH="$xstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$xrepo" --prompt-file "$pf" "$@"; }

: >"$HDLOG"; : >"$HDLOG.cmd"; : >"$XLOG"
out="$(xrun --exec --harness codex --kind gate --label g1)"
assert_contains "$out" '"event":"done","status":"ok"' "a one-shot rung that exits 0 with output is an ok turn"
assert_contains "$out" '"source":"command"' "the ok event names the harvest that produced it"
assert_contains "$(cat "$XLOG")" "codex exec -s read-only" "the one-shot form runs, not the TUI"
# NO PANE. A one-shot's turn is a process: its exit ends the turn and its
# stdout is the final message, both of which the caller already has. The pane
# was placed on whatever backend the CALLER's env resolved - and a one-shot's
# callers are themselves panes, carrying no AC_HOME, so it resolved to the
# herdr default and opened herdr panes for an orca fleet, one per lane per
# round, owned by nobody.
case "$(cat "$HDLOG")" in *"pane run"*) fail "a one-shot must place no pane" ;; esac
case "$(cat "$HDLOG")" in *"tab create"*) fail "a one-shot must create no tab" ;; esac
tr="$(printf '%s\n' "$out" | sed -n 's/.*"event":"done".*"transcript":"\([^"]*\)".*/\1/p')"
assert_contains "$(cat "$tr")" "verdict" "the engine's stdout is the harvested payload"
assert_eq "$(jq -r '.message.content[0].text' "$tr" | head -1)" '{"verdict":"approve"}' \
  "the payload is wrapped in the one-message shape ac_transcript_final parses"
assert_contains "$(cat "$XLOG.prompt")" "review this" "the prompt file reaches the engine as its positional argument"
assert_contains "$(cat "$XLOG")" "codex exec -s read-only --skip-git-repo-check" \
  "the codex one-shot form skips codex's own git-repo trust check - the gate always runs it from the fleet home, never a git repo"

# The gate's judge cwd is the FLEET HOME (bin/ac-gate.sh's judge launch, --cwd "$(ac_home)"), and a fleet home
# is never a git repo - every input rides in the prompt instead. Prove
# ac-pane-agent composes and runs the form from such a cwd without erroring on
# its own account - the stub does not run codex's real trust-check, so that
# it also PASSES codex itself is proven separately, by a real gate run
# (data/gate-codex-rung-broken-by-cwd/spec/ in the drydock fleet).
nongit="$TMP/nongit-cwd"; mkdir -p "$nongit"
: >"$HDLOG"; : >"$HDLOG.cmd"; : >"$XLOG"
out="$(PATH="$xstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$nongit" --prompt-file "$pf" --exec --harness codex --kind gate --label g1b)"
assert_contains "$out" '"event":"done","status":"ok"' "the codex one-shot rung answers from a non-git cwd"
assert_contains "$(cat "$XLOG")" "--skip-git-repo-check" "the non-git-cwd run still carries the flag"

# CONDITION (a): --exec writes NOTHING into the caller's cwd. No .claude/, no
# lock, no git-exclude entry - the whole claude-only prep is skipped, and the
# marker/stdout/rc files live where the marker already lived (state/).
assert_no_file "$xrepo/.claude" "--exec must not create .claude/ in the cwd"
assert_no_file "$xrepo/.claude/settings.local.json" "--exec installs no Stop hook"
case "$(cat "$xrepo/.git/info/exclude" 2>/dev/null || true)" in
  *ac-pane-agent*) fail "--exec must not touch the repo's git excludes" ;;
esac

# CONDITION (d): a non-zero exit is THAT RUNG FAILED. Never ok, and never a
# scrollback fallback - scrollback is TUI chrome, unfit for a JSON contract.
touch "$XLOG.fail"
: >"$HDLOG"
out="$(xrun --exec --harness codex --kind gate --label g2 2>&1 || true)"
assert_contains "$out" '"status":"error"' "a rung that exits non-zero is not an ok turn"
assert_contains "$out" "7" "the refusal reports the exit status the rung died with"
case "$out" in *'"source":"scrollback"'*) fail "--exec must never fall back to the scrollback floor" ;; esac
rm -f "$XLOG.fail"

# rc 0 with EMPTY stdout is a failed rung too: a judge that said nothing has not
# judged, and reporting ok would hand the caller an empty verdict.
touch "$XLOG.empty"
out="$(xrun --exec --harness codex --kind gate --label g3 2>&1 || true)"
assert_contains "$out" '"status":"error"' "empty stdout is a failed rung, not an ok turn"
rm -f "$XLOG.empty"

# The one-message transcript is written byte for byte: one line, ", " and ": "
# separators, every byte outside printable ASCII escaped (a BOM, astral
# characters as a surrogate pair, CR LF, DEL, NUL), and a trailing newline.
# Stdout that is not valid UTF-8 cannot be wrapped, and the turn fails.
wstub="$TMP/wrapbin"; mkdir -p "$wstub"
export WRAP_PAYLOAD="$TMP/wrap.payload"
printf '#!/usr/bin/env bash\ncat "$WRAP_PAYLOAD"\n' >"$wstub/codex"
chmod +x "$wstub/codex"
printf '\357\273\277caf\303\251 \360\237\230\200 \342\200\250 "q" \\ / \t|\r\n|\177|\001\000end' >"$WRAP_PAYLOAD"
out="$(PATH="$wstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$xrepo" --prompt-file "$pf" --exec --harness codex --kind gate --label wrap1)"
tr="$(printf '%s\n' "$out" | sed -n 's/.*"event":"done".*"transcript":"\([^"]*\)".*/\1/p')"
printf '{"type": "assistant", "message": {"role": "assistant", "content": [{"type": "text", "text": "\\ufeffcaf\\u00e9 \\ud83d\\ude00 \\u2028 \\"q\\" \\\\ / \\t|\\r\\n|\\u007f|\\u0001\\u0000end"}]}}\n' >"$TMP/wrap.want"
cmp -s "$tr" "$TMP/wrap.want" || fail "wrapped transcript: want $(cat "$TMP/wrap.want") got $(cat "$tr")"
printf 'bad\377' >"$WRAP_PAYLOAD"
out="$(PATH="$wstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$xrepo" --prompt-file "$pf" --exec --harness codex --kind gate --label wrap2 2>&1 || true)"
assert_contains "$out" '"status":"error"' "stdout that is not UTF-8 fails the turn"
assert_contains "$out" "could not wrap the rung's stdout" "the refusal names the wrap"

# Per-harness one-shot shapes, each in its OWN dialect (the three forms that
# exist today - no speculative entries).
: >"$XLOG"
xrun --exec --harness codex --kind gate --label g4 --model gpt-5.6-sol --effort xhigh >/dev/null
assert_contains "$(cat "$XLOG")" "codex exec -s read-only --skip-git-repo-check -m gpt-5.6-sol -c model_reasoning_effort=xhigh" \
  "codex takes effort as a config override"
# codex always requests a reasoning summary: a
# real gate run otherwise emits none by codex's own default, and `auto` is the
# smallest footprint that still shows the captain what the second chief thought.
assert_contains "$(cat "$XLOG")" "-c model_reasoning_summary=auto" \
  "codex one-shot always carries the reasoning-summary override"
: >"$XLOG"
xrun --exec --harness claude --kind gate --label g5 --model opus --effort high >/dev/null
assert_contains "$(cat "$XLOG")" "claude -p --model opus --effort high" "claude one-shot is claude -p"
: >"$XLOG"
xrun --exec --harness opencode --kind gate --label g6 --model openrouter/openai/gpt-5.5 --effort max >/dev/null
assert_contains "$(cat "$XLOG")" "opencode run -m openrouter/openai/gpt-5.5 --variant max" "opencode takes effort as --variant"
# An unset knob passes NOTHING: the engine's own default stays in charge.
: >"$XLOG"
xrun --exec --harness codex --kind gate --label g7 >/dev/null
case "$(cat "$XLOG")" in *"-m "*) fail "an unset model must pass nothing to a one-shot rung" ;; esac
case "$(cat "$XLOG")" in *model_reasoning_effort*) fail "an unset effort must pass nothing to a one-shot rung" ;; esac
# unlike model/effort, the reasoning-summary override is UNCONDITIONAL - it is
# not a per-call knob, so it still lands with neither model nor effort set.
assert_contains "$(cat "$XLOG")" "-c model_reasoning_summary=auto" \
  "the reasoning-summary override is unconditional, unlike model/effort"

# agy's one-shot form differs from every other arm in four ways, each measured
# on a live CLI rather than assumed (oneshot_launch's own block records the
# probes). Two of them are load-bearing and invisible in a passing run: `-p`
# takes the NEXT token as its prompt, so it must be LAST or the caller's
# positional prompt is ignored in favour of a flag; and the model name carries
# spaces, so it must be quoted or the tier in its name becomes a stray word.
: >"$HDLOG"; : >"$HDLOG.cmd"; : >"$XLOG"
xrun --exec --harness agy --kind gate --label gagy --model 'Gemini 3.8 Flash (Low)' --timeout 900 >/dev/null
agy_cmd="$(cat "$XLOG" 2>/dev/null || true)"
assert_contains "$agy_cmd" "agy --mode plan" "the read-only boundary rides every agy one-shot"
assert_contains "$agy_cmd" "--dangerously-skip-permissions" "...alongside the flag without which a headless turn reads nothing"
assert_contains "$agy_cmd" "--model Gemini 3.8 Flash (Low)" "the model name reaches agy whole, spaces and all"
# agy's print mode has its OWN wait ceiling (--print-timeout, default 5m0s)
# that ran out under the rung's 900s budget: the CLI then exits 0 with an
# EMPTY stdout, and the rung reads that as "printed nothing" - 11 of 36 agy
# lanes across the lab home died that way. The rung's timeout is the one
# ceiling, so it is handed to agy in the duration form the CLI reads.
assert_contains "$agy_cmd" "--print-timeout 900s" "agy's print-mode ceiling is the rung's own timeout, never the CLI's 5m default"
# The stub logs every argument EXCEPT the last, which is the prompt - so a
# line ending in -p is the proof that -p sat last and took that prompt.
case "$agy_cmd" in *" -p") ;; *) fail "agy's -p must be LAST, taking the caller's prompt: $agy_cmd" ;; esac

# agy has no separate effort axis - its tier is part of the model name, and it
# REFUSES --effort beside one. A configured effort is reported, never swallowed.
# The cmd log is APPENDED to by the stub, so reset it here: reading it whole
# would assert against some earlier harness's launch line, which is exactly
# the false positive this case first produced.
: >"$HDLOG"; : >"$HDLOG.cmd"; : >"$XLOG"
out="$(xrun --exec --harness agy --kind gate --label gagy2 --model 'Gemini 3.8 Flash (Low)' --effort high 2>&1 || true)"
assert_contains "$out" '"event":"warning"' "a dropped effort is announced on the event stream"
assert_contains "$out" "inside the model name" "...naming why it could not be honoured"
case "$(cat "$XLOG" 2>/dev/null || true)" in
  *--effort*) fail "agy must never be launched with --effort - the CLI refuses the combination: $(cat "$XLOG")" ;;
esac

# A ONE-SHOT OUTLIVES THE PANE WATCHDOG. That watchdog asks the backend every
# fifth poll whether the pane is still open - and a one-shot HAS no pane, so the
# question was asked about an empty id, every backend said no, and every lane of
# every review round died `pane_closed while turn in flight` about eight seconds
# in, on a turn that was running fine. Its liveness signal is the background
# PROCESS, not a pane.
: >"$HDLOG"; : >"$HDLOG.cmd"; : >"$XLOG"
cat >"$xstub/slowcodex" <<'SLOW'
#!/usr/bin/env bash
# /bin/sleep by absolute path: the no-op sleep stub below sits on the PATH this
# harness inherits, and a shadowed sleep would end the turn before the watchdog
# tick this case exists to reach.
/bin/sleep 1
echo '{"verdict":"approve"}'
SLOW
chmod +x "$xstub/slowcodex"
mv "$xstub/codex" "$xstub/codex.fast"; mv "$xstub/slowcodex" "$xstub/codex"
# sleep stubbed out so the poll counter reaches the watchdog's fifth tick at
# once instead of in eight real seconds - the branch taken is identical. The
# harness calls /bin/sleep by absolute path so this stub cannot shadow it.
xnosleep="$TMP/xnosleep-bin"; mkdir -p "$xnosleep"
printf '#!/usr/bin/env bash\nexit 0\n' >"$xnosleep/sleep"; chmod +x "$xnosleep/sleep"
out="$(PATH="$xnosleep:$xstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run \
  --cwd "$xrepo" --prompt-file "$pf" --exec --harness codex --kind gate --label g-slow 2>&1 || true)"
mv "$xstub/codex.fast" "$xstub/codex"
case "$out" in *pane_closed*) fail "a one-shot has no pane to close: $out" ;; esac
assert_contains "$out" '"event":"done","status":"ok"' "a one-shot that outlives the watchdog tick still completes"

# A harness with no one-shot form is refused on the same rung, and the refusal
# says which mode it is talking about.
: >"$HDLOG"
out="$(xrun --exec --harness fictional --kind gate --label g9 2>&1 || true)"
assert_contains "$out" '"status":"error"' "an unarmed one-shot harness is a protocol error"
assert_contains "$out" "fictional" "the refusal names the harness"
assert_contains "$out" "--exec" "the refusal names the mode it refused for"
case "$(cat "$HDLOG")" in *"pane run"*) fail "an unarmed one-shot harness must be refused before a pane" ;; esac

# --- --observe: the ACTIVE-run observation descriptor seam (--exec ONLY) ---------
# ac-gate-watch tails a live gate from a descriptor the one-shot arm publishes
# BEFORE launch: pane/tab identity + the REAL prompt/stdout/stderr file paths the
# run uses. The observer follows those real bytes, never synthetic reasoning - so
# the descriptor must name the ACTUAL stream files. It is --exec-only: a normal
# verdict harvest has no private streams for an observer to tail.
obs="$TMP/observe.json"
: >"$HDLOG"; : >"$XLOG"
out="$(xrun --exec --harness codex --kind gate --label gobs --observe "$obs")"
assert_contains "$out" '"event":"done","status":"ok"' "the observed run still completes normally"
assert_file "$obs" "--observe publishes the observation descriptor"
# The pane/tab fields stay in the shape for compatibility but are EMPTY: a
# one-shot places no pane, and the observer follows the stream files below,
# which is all it ever read.
assert_eq "$(jq -r '.pane' "$obs")" "" "a one-shot descriptor names no pane"
assert_eq "$(jq -r '.tab' "$obs")" "" "...and no tab"
assert_eq "$(jq -r '.harness' "$obs")" "codex" "the descriptor names the harness"
assert_contains "$(cat "$(jq -r '.prompt' "$obs")")" "review this" "the descriptor points at the REAL prompt file"
# the stdout/stderr paths are the REAL per-run stream files the observer tails
case "$(jq -r '.out' "$obs")" in *.out) ;; *) fail "the descriptor must name the run's stdout stream file" ;; esac
case "$(jq -r '.err' "$obs")" in *.err) ;; *) fail "the descriptor must name the run's stderr stream file" ;; esac
# harvest is untouched by the seam: the verdict is still produced
tr="$(printf '%s\n' "$out" | sed -n 's/.*"transcript":"\([^"]*\)".*/\1/p' | tail -1)"
assert_contains "$(cat "$tr")" "verdict" "the descriptor never disturbs the verdict harvest"

# --observe is REFUSED outside --exec, before any pane is placed, publishing nothing.
: >"$HDLOG"
o2="$TMP/observe-noexec.json"
out="$(PATH="$xstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$xrepo" --prompt-file "$pf" --label noexec --observe "$o2" 2>&1 || true)"
assert_contains "$out" '"status":"error"' "--observe without --exec is a protocol error"
assert_contains "$out" "only valid with --exec" "the refusal names the constraint"
assert_no_file "$o2" "a refused --observe publishes no descriptor"

# An explicit --harness means the CALLER owns the whole triple: a profile's
# model belongs to the profile's harness, and must never be composed onto a
# different one (the flag-vs-profile coherence the arm owes, ac-pane-agent.sh
# HARNESS ARMS item 5).
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{"panes": {"gate": {"harness": "claude", "model": "sonnet", "effort": "high"}}}
EOF
: >"$XLOG"
xrun --exec --harness codex --kind gate --label g10 >/dev/null
assert_contains "$(cat "$XLOG")" "codex exec -s read-only" "an explicit --harness wins over the profile harness"
case "$(cat "$XLOG")" in *sonnet*) fail "a profile model must never be composed onto a different harness" ;; esac
case "$(cat "$XLOG")" in *"--effort high"*|*"reasoning_effort=high"*) fail "a profile effort must not travel to a different harness" ;; esac
# With NO --harness the panes.gate profile resolves as it does for every kind.
: >"$XLOG"
xrun --exec --kind gate --label g11 >/dev/null
assert_contains "$(cat "$XLOG")" "claude -p --model sonnet --effort high" "panes.gate supplies the one-shot triple"
rm -f "$AC_HOME/config/crew-dispatch.json"


# --- the CREWMATE arm (codex / opencode, no --exec) ------------------------------
# The design: the pane-agent SESSION is claude's; a
# verification turn dispatched to codex or opencode runs the CREWMATE contract
# instead - the harness is launched BARE, the prompt is TYPED as its own verified
# line (never argv, which is what killed opencode), the agent WRITES its final
# message to a file and ANNOUNCES its own completion. File exists = turn ended,
# file contents = the verdict, no harness-specific turn-end or transcript.
# The stub models a pane faithfully: `pane run` backgrounds the composed line,
# send-text fills a composer, Enter flushes it into the buffer, and process-info
# answers from whether the fake harness is running.
cstate="$TMP/crew-state"; mkdir -p "$cstate"
kstub="$TMP/crewbin"; mkdir -p "$kstub"
export CSTATE="$cstate" CLOG="$TMP/crew-harness.log"
cat >"$kstub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
[ "${1:-}" = --session ] && shift 2
d="$CSTATE"
case "${1:-} ${2:-}" in
  "tab list") echo '{"result":{"tabs":[]}}' ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wC"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tC"},"root_pane":{"pane_id":"pC1"}}}' ;;
  "pane run") printf '%s\n' "$4" >>"$HDLOG.cmd"; sh -c "$4" >/dev/null 2>&1 & ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"pC1","tab_id":"tC","agent_status":"idle"}}}\n' ;;
  "pane process-info")
    fg=-zsh; [ -f "$d/harness.up" ] && fg=harness
    printf '{"result":{"process_info":{"foreground_processes":[{"argv0":"%s","name":"v"}]}}}\n' "$fg" ;;
  "pane read")
    if [ -f "$d/delay-input-ready" ] && [ ! -f "$d/input-ready" ]; then
      n="$(cat "$d/boot-reads" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" >"$d/boot-reads"
      if [ "$n" -ge 3 ] && [ ! -f "$d/never-input-ready" ]; then
        touch "$d/input-ready"
        printf 'composer ready\n'
      else
        printf 'boot render %s\n' "$n"
      fi
    else
      printf 'composer ready\n'
      cat "$d/buf" 2>/dev/null || true
      [ -s "$d/in" ] && { printf '> '; cat "$d/in"; printf '\n'; }
    fi ;;
  "pane send-text")
    p="$3"; shift 3
    if [ -f "$d/delay-input-ready" ] && [ ! -f "$d/input-ready" ]; then
      printf 'dropped-before-input-ready\n' >>"$HDLOG"
    else
      printf '%s' "$*" >>"$d/in"
    fi ;;
  "pane send-keys")
    if [ "${4:-}" = enter ]; then
      if [ -s "$d/in" ]; then cat "$d/in" >>"$d/buf"; printf '\n' >>"$d/buf"; : >"$d/in"
      else printf 'BARE-ENTER\n' >>"$d/buf"; fi
    fi ;;
esac
exit 0
EOF
# The fake harness IS a crewmate: it comes up, waits for its typed instruction,
# writes the verdict where told, then announces completion with the exact
# command the instruction named. Fault-injection files drive the failure legs.
cat >"$kstub/codex" <<'EOF'
#!/usr/bin/env bash
echo "codex $*" >>"$CLOG"
d="$CSTATE"
[ -f "$d/die-at-launch" ] && exit 9
: >"$d/harness.up"
for _ in $(seq 1 400); do grep -q 'touch ' "$d/buf" 2>/dev/null && break; sleep 0.05; done
line="$(tr '\n' ' ' <"$d/buf")"
vf="$(printf '%s' "$line" | sed -n 's/.*WRITE it to the file \([^ ]*\).*/\1/p' | head -1)"
mk="$(printf '%s' "$line" | sed -n "s/.*command: touch '\([^']*\)'.*/\1/p" | head -1)"
[ -f "$d/no-verdict" ] || printf '%s\n' "${CVERDICT:-verdict: passed - written by the crewmate}" >"$vf"
[ -f "$d/no-announce" ] || touch "$mk"
exec sleep "${CSLEEP:-5}"
EOF
cp "$kstub/codex" "$kstub/opencode"
chmod +x "$kstub/herdr" "$kstub/codex" "$kstub/opencode"
crepo="$(make_repo crewarm)"
creset() { rm -f "$cstate"/*; : >"$cstate/buf"; : >"$cstate/in"; : >"$HDLOG"; : >"$HDLOG.cmd"; : >"$CLOG"; }
crun() { PATH="$kstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$crepo" --prompt-file "$pf" --timeout 40 "$@"; }

# The happy path: a codex verification turn completes through the file contract.
creset
out="$(crun --harness codex --kind codereview --label c1 --model gpt-5.6-sol --effort xhigh)"
assert_contains "$out" '"event":"done","status":"ok"' "a codex verification turn completes"
assert_contains "$out" '"source":"file"' "the ok event names the file harvest that produced it"
assert_contains "$(cat "$HDLOG.cmd")" "codex -c check_for_update_on_startup=false -m gpt-5.6-sol -c model_reasoning_effort=xhigh" \
  "the INTERACTIVE launch line is composed by the shared mote, in codex's own dialect"
case "$(cat "$HDLOG.cmd")" in *"codex exec"*) fail "the crewmate arm must not launch the one-shot form" ;; esac
# NO positional prompt on the launch line - that shape is what made opencode
# treat the prompt as a project directory and never start at all.
case "$(cat "$CLOG")" in *"$pf"*) fail "the prompt must never ride argv - the crewmate contract types it" ;; esac
# The prompt is TYPED as its own line, and it names all three parts of the
# contract: where to read the brief, where to write the verdict, how to announce.
buf="$(cat "$cstate/buf")"
assert_contains "$buf" "$pf" "the typed line points the agent at the prompt file"
assert_contains "$buf" "WRITE it to the file" "the typed line redirects the final message to a file"
assert_contains "$buf" "this exact command: touch '" "the typed line names the completion announcement, path quoted so it stays runnable"
# codex's startup dialog is answered exactly as the crewmate path answers it -
# a bare Enter FIRST, never the prompt (an 'n' in the text picks "2. No, quit").
assert_eq "$(head -1 "$cstate/buf")" "BARE-ENTER" "a built-in codex pane gets the bare Enter before any text"
# The verdict file IS the final message, read back through the caller's own
# reader - so ac-ship.sh/ac-qa.sh parse it exactly as they parse a claude turn.
tr_path="$(printf '%s\n' "$out" | sed -n 's/.*"event":"done".*"transcript":"\([^"]*\)".*/\1/p')"
assert_contains "$(bash -c ". '$BIN/ac-lib.sh'; . '$RBIN/ac-pipeline-lib.sh'; ac_transcript_final '$tr_path'")" \
  "verdict: passed - written by the crewmate" "the caller's transcript reader finds the file verdict"
assert_contains "$out" '"session_id":""' "the crewmate arm opens no resumable session and says so"
# Like --exec, it leaves NOTHING in the directory it merely ran in: no Stop hook
# to install, no ~/.claude.json seed, no git-exclude entry.
assert_no_file "$crepo/.claude" "the crewmate arm writes no .claude/ into the caller's worktree"
case "$(cat "$crepo/.git/info/exclude" 2>/dev/null || true)" in
  *ac-pane-agent*) fail "the crewmate arm must not touch the repo's git excludes" ;;
esac

# opencode rides the same arm - and gets NO codex keystroke: a keystroke belongs
# to the TUI it was verified against, never borrowed across harnesses.
creset
out="$(crun --harness opencode --kind qa --label c2)"
assert_contains "$out" '"event":"done","status":"ok"' "an opencode verification turn completes on the same arm"
assert_contains "$(cat "$HDLOG.cmd")" "opencode" "opencode launches through the shared mote too"
case "$(head -1 "$cstate/buf")" in BARE-ENTER) fail "only codex gets the startup-dialog Enter" ;; esac

# The per-role AGENT knob resolves a NON-claude harness with NO --harness flag -
# codereview-agent resolves codex (the design of
# routed-pane-rules-for-gate-codereview-roomchief TASK 2). Asserted HERE rather
# than beside its model/effort siblings because only this stub implements the
# crewmate arm a non-claude harness lands on. Read back off the REAL composed
# launch line, not the resolver's own reasoning.
creset
printf 'codex\n' >"$AC_HOME/config/codereview-agent"
out="$(crun --kind codereview --label c-agent-cfg)"
assert_contains "$out" '"event":"done","status":"ok"' "a codereview turn on the knob-resolved codex arm completes"
assert_contains "$(cat "$HDLOG.cmd")" "codex" "config/codereview-agent puts codex on the launch line with no --harness flag"
case "$(cat "$HDLOG.cmd")" in *"claude --permission-mode"*) fail "codereview-agent=codex must not still launch claude" ;; esac
rm -f "$AC_HOME/config/codereview-agent"

# The env rung outranks the config knob on that same rung (what ac-spawn threads
# to a homeless pane).
creset
printf 'claude\n' >"$AC_HOME/config/qa-agent"
out="$(AC_FLEET_AGENT_QA=codex crun --kind qa --label c-agent-env)"
assert_contains "$(cat "$HDLOG.cmd")" "codex" "AC_FLEET_AGENT_QA env wins over config/qa-agent"
rm -f "$AC_HOME/config/qa-agent"

# ATOMICITY ACROSS THE NEW KNOBS: agent+model+effort are ONE rung, so a fleet
# that pins all three per role gets exactly those three together - never a model
# composed onto a harness some other rung chose (the `codex -m opus` incoherence).
creset
printf 'codex\n' >"$AC_HOME/config/codereview-agent"
printf 'gpt-5.6-sol\n' >"$AC_HOME/config/codereview-model"
printf 'xhigh\n' >"$AC_HOME/config/codereview-effort"
out="$(crun --kind codereview --label c-agent-triple)"
assert_contains "$(cat "$HDLOG.cmd")" "codex -c check_for_update_on_startup=false -m gpt-5.6-sol -c model_reasoning_effort=xhigh" \
  "the per-role agent/model/effort knobs resolve together, in the resolved harness's own dialect"
rm -f "$AC_HOME/config/codereview-agent" "$AC_HOME/config/codereview-model" "$AC_HOME/config/codereview-effort"

# A DISPATCHED profile still outranks all three knobs, unchanged: the profile is
# atomic and sits ABOVE this rung, so a knob may not pull its harness away.
creset
printf 'codex\n' >"$AC_HOME/config/codereview-agent"
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{"panes": {"codereview": {"harness": "opencode", "model": "prof-model"}}}
EOF
out="$(crun --kind codereview --label c-agent-profile)"
assert_contains "$(cat "$HDLOG.cmd")" "opencode -m prof-model" \
  "a dispatched panes.codereview profile still outranks the per-role agent knob"
case "$(cat "$HDLOG.cmd")" in *codex*) fail "the agent knob must not override a dispatched profile's harness" ;; esac
rm -f "$AC_HOME/config/codereview-agent" "$AC_HOME/config/crew-dispatch.json"

# CONTRADICTION CHECK: the profile winning above is correct by design, but
# nothing told a human when it disagrees with a PINNED config/codereview-agent
# - a fleet that pinned codex there kept reviewing on whatever the profile
# named instead, silently. A "warning" event on the SAME NDJSON stream,
# emitted BEFORE the pane even places, closes that.
creset
printf 'codex\n' >"$AC_HOME/config/codereview-agent"
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{"panes": {"codereview": {"harness": "opencode", "model": "prof-model"}}}
EOF
out="$(crun --kind codereview --label c-agent-warn)"
assert_contains "$out" '"event":"warning"' "the configured-vs-profile disagreement is reported"
assert_contains "$out" 'codereview-agent-mismatch' "the warning names its own kind"
assert_contains "$out" 'config/codereview-agent=codex' "the warning names the configured engine"
assert_contains "$out" 'harness=opencode' "the warning names what actually won"
rm -f "$AC_HOME/config/codereview-agent" "$AC_HOME/config/crew-dispatch.json"

# No disagreement (both name codex) -> no warning.
creset
printf 'codex\n' >"$AC_HOME/config/codereview-agent"
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{"panes": {"codereview": {"harness": "codex"}}}
EOF
out="$(crun --kind codereview --label c-agent-agree)"
case "$out" in *'"event":"warning"'*) fail "matching config/codereview-agent and profile harness must not warn" ;; esac
rm -f "$AC_HOME/config/codereview-agent" "$AC_HOME/config/crew-dispatch.json"

# No config/codereview-agent pinned at all -> nothing to disagree with.
creset
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{"panes": {"codereview": {"harness": "opencode"}}}
EOF
out="$(crun --kind codereview --label c-agent-unset)"
case "$out" in *'"event":"warning"'*) fail "no configured engine means nothing to contradict" ;; esac
rm -f "$AC_HOME/config/crew-dispatch.json"

# qa is out of scope for this check (only codereview is verified/wired) - the
# same shape of disagreement on qa's own knobs must stay silent.
creset
printf 'codex\n' >"$AC_HOME/config/qa-agent"
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{"panes": {"qa": {"harness": "opencode"}}}
EOF
out="$(crun --kind qa --label c-agent-qa-noscope)"
case "$out" in *'"event":"warning"'*) fail "qa's config-vs-profile disagreement is out of scope for this check" ;; esac
rm -f "$AC_HOME/config/qa-agent" "$AC_HOME/config/crew-dispatch.json"

# PROCESS-UP IS NOT INPUT-READY. A live OpenCode process can hold the pane while
# its TUI is still rendering and has no composer yet. Typing during that window
# is dropped; worse, the boot render itself keeps changing, so the generic
# render-change submit verifier can mistake that unrelated redraw for an
# accepted prompt. This is the live Kimi K3 failure: the pane stayed idle with
# an empty composer until the caller's 180s timeout, while the same prompt sent
# after the TUI was ready worked immediately.
#
# The stub exposes the harness process and `agent_status=idle` at once - the
# same false signal the live Kimi proof observed - while changing its boot
# render on every capture and dropping any text sent before that render settles.
# The verifier must require a non-empty stable render as well as idle before it
# types anything.
# --timeout 20, matching the codex c-ready sibling below: crewmate_wait_input_ready
# (bin/ac-pane-agent.sh) gates BOTH harnesses through the identical
# observation loop, and the codex arm was MEASURED at ~8s of overhead on this
# same stub (records/repo-knowledge/agent-crew.md, by:
# pane-agent-codex-lacks-the-input-surface-ready-gate, 2026-07-26) - opencode,
# gated by the same code and measured faster, had no business sitting at a
# bound near that cost with ~zero margin. The prior `8` predates that
# measurement entirely (git log -S, initial release commit fd1b532) and was
# never revisited once the gate's real cost became known.
creset; : >"$cstate/delay-input-ready"
out="$(PATH="$kstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$crepo" \
  --prompt-file "$pf" --timeout 20 --harness opencode --kind qa --label c2-ready 2>&1 || true)"
assert_contains "$out" '"event":"done","status":"ok"' \
  "an OpenCode verifier waits for its input surface before delivering the prompt"
case "$(cat "$HDLOG")" in *dropped-before-input-ready*) \
  fail "the kickoff must not be typed merely because the OpenCode process is up" ;; esac
assert_contains "$(cat "$cstate/buf")" "$pf" \
  "the readiness-gated kickoff reaches the OpenCode transcript"

# If herdr never observes the input surface, the verifier fails closed with the
# readiness diagnosis and types nothing. It must not degrade back to the generic
# full-turn timeout that hid the live failure.
creset; : >"$cstate/delay-input-ready"; : >"$cstate/never-input-ready"
out="$(PATH="$kstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$crepo" \
  --prompt-file "$pf" --timeout 2 --harness opencode --kind qa --label c2-not-ready 2>&1 || true)"
assert_contains "$out" '"status":"error"' \
  "an OpenCode verifier fails closed when its input surface never becomes ready"
assert_contains "$out" "input surface did not become ready" \
  "the refusal names input readiness instead of reporting a generic turn timeout"
case "$(cat "$HDLOG")" in *"pane send-text"*) \
  fail "a verifier with no input-ready evidence must type no kickoff" ;; esac

# CODEX HAS NO EQUIVALENT GATE (data/pane-agent-codex-lacks-the-input-surface-
# ready-gate). Unlike OpenCode above, the codex crewmate arm answers the
# startup-dialog Enter and then just sleeps a fixed ${AC_SEND_SETTLE:-0.4}s
# before typing the kickoff line - no observation of the composer at all. The
# stub reproduces the same delayed-input-surface fault OpenCode was proven
# against: typing before readiness is DROPPED, and the composer only becomes
# ready on its 3rd read. A codex arm that types on a fixed sleep, rather than
# waiting for that observation, delivers into a still-dropping composer and
# the kickoff never reaches the transcript.
creset; : >"$cstate/delay-input-ready"
out="$(PATH="$kstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$crepo" \
  --prompt-file "$pf" --timeout 20 --harness codex --kind codereview --label c-ready 2>&1 || true)"
assert_contains "$out" '"event":"done","status":"ok"' \
  "a codex verifier waits for its input surface before delivering the prompt"
case "$(cat "$HDLOG")" in *dropped-before-input-ready*) \
  fail "the kickoff must not be typed merely because the codex process is up" ;; esac
assert_contains "$(cat "$cstate/buf")" "$pf" \
  "the readiness-gated kickoff reaches the codex transcript"

# If herdr never observes the input surface, the codex arm must fail closed
# with the same readiness diagnosis OpenCode gives, and type nothing - never
# degrade to a generic full-turn timeout that hides which surface never came
# up.
creset; : >"$cstate/delay-input-ready"; : >"$cstate/never-input-ready"
out="$(PATH="$kstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$crepo" \
  --prompt-file "$pf" --timeout 2 --harness codex --kind codereview --label c-not-ready 2>&1 || true)"
assert_contains "$out" '"status":"error"' \
  "a codex verifier fails closed when its input surface never becomes ready"
assert_contains "$out" "input surface did not become ready" \
  "the refusal names input readiness instead of reporting a generic turn timeout"
case "$(cat "$HDLOG")" in *"pane send-text"*) \
  fail "a codex verifier with no input-ready evidence must type no kickoff" ;; esac

# FAIL CLOSED (a) - the agent announced its turn but wrote no verdict. A turn
# that ended with nothing to read is a FAILED turn, never ok with an empty
# payload (the same rule the scrollback floor is held to).
creset; : >"$cstate/no-verdict"
out="$(crun --harness codex --kind codereview --label c3 2>&1 || true)"
assert_contains "$out" '"status":"error"' "an announced turn with no verdict file is a protocol error"
assert_contains "$out" "no verdict" "the refusal says what was missing"
case "$out" in *'"status":"ok"'*) fail "an empty verdict must never be reported ok" ;; esac

# FAIL CLOSED (b) - the harness DIED. The launch line records its exit status and
# touches an exit marker, so a dead engine is refused in the seconds it actually
# took instead of burning the caller's whole timeout as a fake status:timeout.
creset; : >"$cstate/die-at-launch"
start="$(date +%s)"
out="$(crun --harness codex --kind codereview --label c4 2>&1 || true)"
assert_contains "$out" '"status":"error"' "a harness that exits without announcing is a protocol error"
assert_contains "$out" "9" "the refusal reports the exit status the harness died with"
[ "$(( $(date +%s) - start ))" -lt 30 ] || fail "a dead harness must be refused fast, not at the timeout"

# FAIL CLOSED (c) - the harness lives but never announces: that is the caller's
# timeout, reported honestly as one.
creset; : >"$cstate/no-announce"
# CSLEEP keeps the fake harness ALIVE past the deadline, so this leg can only
# end as a timeout: a harness that exited would take the (b) path above instead,
# and the two failures must stay distinguishable.
out="$(CSLEEP=60 PATH="$kstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$crepo" \
  --prompt-file "$pf" --timeout 6 --harness codex --kind codereview --label c5 2>&1 || true)"
assert_contains "$out" '"status":"timeout"' "a turn that never announces ends as a timeout"

# --resume is REFUSED on this arm, for the same reason --exec refuses it: codex
# and opencode pin no caller-minted session id, so there is no conversation to
# continue and a caller passing one believes there is.
creset
out="$(crun --harness codex --kind codereview --label c6 --resume sid-abc 2>&1 || true)"
assert_contains "$out" '"status":"error"' "--resume on the crewmate arm is a protocol error"
assert_contains "$out" "resume" "the refusal names the flag it will not honour"
case "$(cat "$HDLOG")" in *"pane run"*) fail "a refused --resume must place no pane" ;; esac

# --- the IDLE FALLBACK never reports ok without a DECLARED deliverable --------
# The turn-end exit is arm-specific and FAIL-CLOSED: each arm must PRODUCE a
# payload or the run refuses. The idle fallback asked only three questions -
# pane idle per herdr, transcript stale past 120s, any final assistant text -
# and not one of them asked whether the agent's DELIVERABLE was written. So a
# pane that idled MID-PASS reported status ok: the learning scout that hit the
# org monthly spend limit after 23 Reads wrote no report, exited 0 through this
# exit, and its caller then reset the retro anchor on a run that produced
# nothing (data/learning/room.md 13:36:13Z).
# Only the SESSION arm can reach this exit: inside the wait loop TRANSCRIPT is
# set by announce_transcript alone, which runs under `[ "$ARM" != session ] ||`.
#
# DISPUTED: whether the declared deliverable exists when the pane idles.
# HELD-CONSTANT: the same stub and pane (agent_status=idle), a transcript
#   backdated past the 120s mtime gate, a Stop-hook marker never touched, the
#   same --timeout, the same cwd.
# `sleep` is stubbed to a no-op for these legs ONLY: the fallback is gated on
# the loop COUNTER (i > 45), not on wall time, so an instant poll reaches the
# very same branch in seconds instead of 92 - and a real 2s poll would cost
# this file four 92s waits without changing one decision taken.
irepo="$(make_repo idlefb)"
istub="$TMP/idle-bin"; mkdir -p "$istub"
cat >"$istub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "tab list") echo '{"result":{"tabs":[]}}' ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wP"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tP"},"root_pane":{"pane_id":"pP1"}}}' ;;
  # A pane whose Stop hook stayed SILENT and then went idle: a transcript with
  # final assistant text, backdated past the mtime gate, and NO marker. A fresh
  # session id per leg, so the next leg's new-session glob still resolves it.
  "pane run")
    cwd="$(printf '%s' "$4" | sed -n "s/^cd '\([^']*\)'.*/\1/p")"
    slug="$(printf '%s' "$cwd" | sed 's/[/.]/-/g')"
    n="$(cat "$HDLOG.i" 2>/dev/null || printf 0)"; n=$((n + 1)); printf '%s\n' "$n" >"$HDLOG.i"
    mkdir -p "$HOME/.claude/projects/$slug"
    t="$HOME/.claude/projects/$slug/idle-sid-$n.jsonl"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"reading the sources"}]}}' >"$t"
    # A turn that DIED mid-pass: its last assistant message carries a tool_use
    # and no text, exactly what a session killed after a Read leaves behind.
    [ -f "$HDLOG.toolend" ] && printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}' >>"$t"
    [ -z "${IDLE_TX:-}" ] || cp "$IDLE_TX" "$t"
    touch -t 200001010000 "$t" ;;
  "pane get") echo '{"result":{"pane":{"pane_id":"pP1","agent_status":"idle"}}}' ;;
  "pane read") echo 'idle pane scrollback' ;;
esac
exit 0
EOF
chmod +x "$istub/herdr"
nosleep="$TMP/nosleep-bin"; mkdir -p "$nosleep"
printf '#!/usr/bin/env bash\nexit 0\n' >"$nosleep/sleep"
chmod +x "$nosleep/sleep"
irun() {
  PATH="$nosleep:$istub:$PATH" HOME="$FAKEHOME" \
    "$BIN/ac-pane-agent.sh" run --cwd "$irepo" --prompt-file "$pf" --timeout 20 "$@" 2>&1
}

# DIRECTION 2, and it is not decoration: the fallback exists because the Stop
# hook can fail to fire, and tightening it until a genuinely-finished turn hangs
# to timeout replaces one defect with another. A caller that declares NO
# deliverable behaves exactly as it did before this guard existed.
out="$(irun --label idle-none || true)"
assert_contains "$out" '"event":"note"' "the idle fallback still announces itself"
assert_contains "$out" 'idle-fallback used (agent_status=idle)' "the note names why it fired"
assert_contains "$out" '"event":"done","status":"ok"' \
  "an undeclared deliverable leaves the idle fallback exactly as it was"

# A TURN THAT DIED MID-PASS IS NOT AN OK TURN, even with no deliverable
# declared. The pane agent and its caller read the same transcript with two
# DIFFERENT questions: this file asked whether any assistant text exists
# anywhere, while ac_transcript_final (tests/fixtures/ac-pipeline-lib.sh) takes the LAST
# assistant message. A session killed after a tool call satisfies the first and
# returns empty from the second - so the pane reported ok and the caller then
# died on "transcript has no final message", leaving the previous round's
# receipt on disk looking current. Ask the caller's question here.
: >"$HDLOG.toolend"
irc=0; out="$(irun --label idle-toolend)" || irc=$?
rm -f "$HDLOG.toolend"
assert_eq "$irc" "1" "a turn whose last message carries no text exits non-zero"
assert_contains "$out" '"event":"done","status":"error"' \
  "...and says error rather than ok"
assert_contains "$out" "no final message" "...naming what the caller will find missing"
case "$out" in *'"status":"ok"'*) fail "a dead turn must never be reported ok: $out" ;; esac

# DIRECTION 2 with the declaration SATISFIED: a turn that genuinely finished
# wrote its deliverable before going quiet, so the fallback still passes it.
deliv="$TMP/idle-report.md"
printf '## Retro\nwritten before the turn went quiet\n' >"$deliv"
out="$(irun --label idle-ok --deliverable "$deliv" || true)"
assert_contains "$out" '"event":"done","status":"ok"' \
  "a written deliverable still exits ok through the idle fallback"

# DIRECTION 1, the regression this task closes: idle, stale transcript, final
# text present - and the deliverable never written. It must NOT be ok.
missing="$TMP/idle-never-written.md"
rm -f "$missing"
# rc captured on THIS run rather than re-run under assert_fails: that helper
# accepts any non-zero exit and discards stderr, so a broken harness reads
# identically to the refusal under test (assert_fails, tests/sh/helpers.sh).
irc=0; out="$(irun --label idle-bad --deliverable "$missing")" || irc=$?
case "$out" in *'"status":"ok"'*) fail "an idle pane with no deliverable must never report ok" ;; esac
assert_contains "$out" '"event":"done"' "the refusal still speaks the done protocol"
assert_contains "$out" '"status":"error"' "an unproduced deliverable is a protocol error"
assert_contains "$out" "$missing" "the refusal names the deliverable that is missing"
assert_contains "$out" '"pane":"pP1"' \
  "the refusal carries the pane, so the caller can still reap what it opened"
assert_eq "$irc" "1" "the refusal exits non-zero, so no caller reads it as a completed turn"

# An EMPTY deliverable is the partial-write case and is no deliverable either -
# the same rule the crewmate arm's verdict file is held to.
: >"$TMP/idle-empty.md"
out="$(irun --label idle-empty --deliverable "$TMP/idle-empty.md" || true)"
case "$out" in *'"status":"ok"'*) fail "an empty deliverable must never report ok" ;; esac

# The fallback's own question - is there ANY assistant text - answers no for a
# transcript that is not UTF-8, for one holding a line that parses to a non-
# object, and for text that is only Python-whitespace (U+001C counts), so the
# pane is held to the caller's timeout. U+FEFF is NOT whitespace: that text
# counts, and the fallback fires.
itx="$TMP/idle-tx.jsonl"
printf '%s\n%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"the verdict"}]}}' '[1]' >"$itx"
out="$(IDLE_TX="$itx" irun --label hft-nonobject --timeout 12 || true)"
assert_contains "$out" '"status":"timeout"' "a non-object line means no final text, so the fallback holds"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"the verdict \377"}]}}\n' >"$itx"
out="$(IDLE_TX="$itx" irun --label hft-notutf8 --timeout 12 || true)"
assert_contains "$out" '"status":"timeout"' "a transcript that is not UTF-8 has no final text, so the fallback holds"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":" \\u001c\\u00a0"}]}}\n' >"$itx"
out="$(IDLE_TX="$itx" irun --label hft-blank --timeout 12 || true)"
assert_contains "$out" '"status":"timeout"' "whitespace-only text is no final text, so the fallback holds"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"\\ufeff"}]}}\n' >"$itx"
out="$(IDLE_TX="$itx" irun --label hft-bom || true)"
assert_contains "$out" 'idle-fallback used' "a lone U+FEFF is text, so the fallback fires"

# Arg validation: no text, and no target, are usage errors.
assert_fails "$BIN/ac-pane-agent.sh" steer --agent ac-qa-agent:probe-task
assert_fails "$BIN/ac-pane-agent.sh" steer 'orphan text'

# --- BUSY-STALL BOUND: busy is not unbounded proof of liveness --------------
# A pane hung INSIDE one tool call keeps a busy agent_status and a static
# transcript, so the marker, the idle fallback (gated on idle/done), and pane
# death never fire - the caller used to burn its WHOLE timeout on a dead turn.
# DISPUTED: whether a busy pane with a static transcript may run unbounded.
# HELD-CONSTANT: the idle-fallback stub shape (same protocol answers), a
#   transcript written once at pane run and never again, a Stop-hook marker
#   never touched, sleep stubbed to a no-op, the same cwd/prompt.
srepo="$(make_repo stallfb)"
sstub="$TMP/stall-bin"; mkdir -p "$sstub"
cat >"$sstub/herdr" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "tab list") echo '{"result":{"tabs":[]}}' ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wP"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tP"},"root_pane":{"pane_id":"pP1"}}}' ;;
  "pane run")
    cwd="$(printf '%s' "$4" | sed -n "s/^cd '\([^']*\)'.*/\1/p")"
    slug="$(printf '%s' "$cwd" | sed 's/[/.]/-/g')"
    mkdir -p "$HOME/.claude/projects/$slug"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}' \
      >"$HOME/.claude/projects/$slug/stall-sid.jsonl" ;;
  "pane get") echo '{"result":{"pane":{"pane_id":"pP1","agent_status":"busy"}}}' ;;
  "pane read") echo 'Working...' ;;
esac
exit 0
EOF
chmod +x "$sstub/herdr"
src=0; out="$(AC_PANE_STALL_MAX=1 PATH="$nosleep:$sstub:$PATH" HOME="$FAKEHOME" \
  "$BIN/ac-pane-agent.sh" run --cwd "$srepo" --prompt-file "$pf" --label stall --timeout 60 2>&1)" || src=$?
assert_contains "$out" '"status":"error"' "a stalled busy pane escalates instead of burning the caller's timeout"
assert_contains "$out" "no transcript progress" "the escalation names the stall"
assert_contains "$out" "agent_status=busy" "the escalation carries the busy status for diagnosis"
assert_contains "$out" '"pane":"pP1"' "the escalation carries the pane, so the caller can still reap it"
assert_eq "$src" "1" "the stall escalation exits non-zero"
case "$out" in *'"status":"timeout"'*) fail "the stall bound must fire before the caller's timeout" ;; esac

# The bound is measured against THIS wait's start, not raw mtime: the
# idle-fallback legs above backdate their transcript to 2000 and still end via
# the fallback (asserted there) - a resumed session's prior-turn mtime is not
# this turn's stall. Here: AC_PANE_STALL_MAX=0 disables the bound outright,
# and the same stalled pane then runs to the caller's own timeout.
src=0; out="$(AC_PANE_STALL_MAX=0 PATH="$nosleep:$sstub:$PATH" HOME="$FAKEHOME" \
  "$BIN/ac-pane-agent.sh" run --cwd "$srepo" --prompt-file "$pf" --label stall-off --timeout 3 2>&1)" || src=$?
assert_contains "$out" '"status":"timeout"' "AC_PANE_STALL_MAX=0 disables the bound"

# --- differential: src/pane-agent.ts against the frozen bash original ---------
# DISPUTED: the implementation (tests/fixtures/ac-pane-agent.sh under bash vs src/pane-agent.ts through bin/ac-pane-agent.sh)
# HELD-CONSTANT: ONE world path ($XW) rebuilt by the row's own setup before each side's pass - a git repo at $XW/cwd (one commit, one identity and date, branch main, its info/exclude), the prompt at $XW/pf, HOME=$XW/hd (its .claude.json), AC_CLAUDE_TRANSCRIPT_ROOT=$XW/tr, AC_FLEET_STATE=$XW/st, TMPDIR=$XW/tmp, XSTUB=$XW/stub (the stubs' answer files, state and logs), AC_HOME=$XW/home only where a row homes it; argv; env (the rest of the AC_* family unset unless a row names it; AC_SEND_SETTLE=0 and AC_STARTUP_DIALOG_BUDGET=2 from helpers.sh); cwd ($XW/cwd); stdin (/dev/null); LC_ALL=C unless a row names en_US.UTF-8; PATH = the leg's stubs (a logging herdr and orca answering from the world and modelling the pane - a session `pane run` writing the transcript and touching the Stop hook's marker, a composer whose Enter makes the crewmate write its verdict and announce - logging fakes of every harness CLI, `od` with fixed bytes, a no-op `sleep` unless a row runs real time or counts its sleeps (one logging its argv), a `date +%s` that ticks one second per call from one instant) ahead of the suite's PATH, whose refusing stand-ins catch anything the stubs do not model; the live bin/ beside each entry. Each call's exit, stdout and stderr compared whole once normalised (the k-th entry pid of a pass PID<k>, a marker's age, either bin root ROOT), then the stub logs in call order and the world: every path under $XW but stub/ and tmp/ with its mode and bytes (the repo as its info/exclude).
cd "$TMP" || fail "cd TMP"
xobin="$(make_oracle_bin ac-pane-agent)"
cmp -s "$xobin/ac-pane-agent.sh" "$ROOT/tests/fixtures/ac-pane-agent.sh" || fail "the oracle bin holds the frozen original"
XW="$TMP/xw"; XSTUBS="$TMP/xstubs"; XNOSLEEP="$TMP/xnosleep"; XLOGSLEEP="$TMP/xlogsleep"
mkdir -p "$XSTUBS" "$XNOSLEEP" "$XLOGSLEEP"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' >"$TMP/xgitconfig"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/xgitconfig" \
  GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
# The pane model both backend stubs share: `session <launch line>` is a claude
# turn (the transcript written, the Stop hook's marker touched), `enter` flushes
# the composer and, for a crewmate's typed line, writes the verdict where told
# and touches the announced marker - each step skipped by its fault file.
cat >"$XSTUBS/xsim" <<'STUB'
#!/usr/bin/env bash
d="$XSTUB"
case "$1" in
  session)
    cwd="$(printf '%s' "$2" | sed -n "s/^cd '\([^']*\)'.*/\1/p")"
    marker="$(sed -n "s/.*touch '\([^']*\)'.*/\1/p" "$cwd/.claude/settings.local.json" 2>/dev/null | tail -1)"
    slug="$(printf '%s' "$cwd" | sed 's/[/.]/-/g')"
    mkdir -p "$AC_CLAUDE_TRANSCRIPT_ROOT/$slug"
    tf="$AC_CLAUDE_TRANSCRIPT_ROOT/$slug/$(cat "$d/sid" 2>/dev/null || echo test-sid).jsonl"
    if [ -e "$d/transcript" ]; then cat "$d/transcript" >"$tf"
    elif [ ! -e "$d/no-transcript" ]; then printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"[]"}]}}' >"$tf"; fi
    [ ! -e "$d/backdate" ] || touch -t 200001010000 "$tf" 2>/dev/null
    [ -e "$d/no-marker" ] || [ -z "$marker" ] || touch "$marker" ;;
  enter)
    [ ! -e "$d/strand" ] && [ -s "$d/in" ] || exit 0
    line="$(cat "$d/in")"; printf '%s\n' "$line" >>"$d/buf"; : >"$d/in"
    vf="$(printf '%s' "$line" | sed -n 's/.*WRITE it to the file \([^ ]*\) - that.*/\1/p')"
    mk="$(printf '%s' "$line" | sed -n "s/.*command: touch '\([^']*\)'\$/\1/p")"
    [ -n "$vf" ] || exit 0
    if [ -e "$d/empty-verdict" ]; then : >"$vf"
    elif [ ! -e "$d/no-verdict" ]; then printf '%s\n' "$(cat "$d/verdict" 2>/dev/null || echo 'verdict: passed')" >"$vf"; fi
    [ -e "$d/no-announce" ] || touch "$mk" ;;
  render)
    if [ -e "$d/render.n" ]; then n=$(($(cat "$d/render.n") + 1)); echo "$n" >"$d/render.n"; echo "boot $n"; exit 0; fi
    echo 'composer ready'; cat "$d/buf" 2>/dev/null
    [ ! -s "$d/in" ] || { printf '> '; cat "$d/in"; echo; } ;;
esac
STUB
# herdr: every call logged with its argv bracketed and the HERDR_SESSION it
# saw; the n-th call of a verb answers from <verb>.<n>.{out,rc,sleep} when any
# exists, else <verb>.{out,rc,sleep}, else the pane model.
cat >"$XSTUBS/herdr" <<'STUB'
#!/usr/bin/env bash
d="$XSTUB"
{ printf herdr; for a in "$@"; do printf ' [%s]' "$a"; done; printf ' {%s}\n' "${HERDR_SESSION-}"; } >>"$d/herdr.log"
[ "${1:-}" != --session ] || shift 2
[ "$#" -lt 2 ] || [ "${*: -2:1}" != --session ] || set -- "${@:1:$#-2}"
v="${1:-}-${2:-}"
n=$(($(cat "$d/$v.n" 2>/dev/null || echo 0) + 1)); echo "$n" >"$d/$v.n"
for f in "$v.$n" "$v"; do
  if [ -e "$d/$f.out" ] || [ -e "$d/$f.rc" ] || [ -e "$d/$f.sleep" ]; then
    [ ! -e "$d/$f.sleep" ] || /bin/sleep "$(cat "$d/$f.sleep")"
    [ ! -e "$d/$f.out" ] || cat "$d/$f.out"
    exit "$(cat "$d/$f.rc" 2>/dev/null || echo 0)"
  fi
done
case "$v" in
  workspace-list) echo '{"result":{"workspaces":[]}}' ;;
  workspace-create) echo '{"result":{"workspace":{"workspace_id":"wP"}}}' ;;
  tab-list) echo '{"result":{"tabs":[]}}' ;;
  tab-create) echo '{"result":{"tab":{"tab_id":"tP"},"root_pane":{"pane_id":"pP1"}}}' ;;
  pane-list) echo '{"result":{"panes":[]}}' ;;
  pane-split) echo '{"result":{"pane":{"pane_id":"pS1"}}}' ;;
  pane-close) [ "$3" = "$(cat "$d/sticky" 2>/dev/null)" ] || echo "$3" >>"$d/closed" ;;
  pane-get)
    ! grep -qxF "$3" "$d/closed" 2>/dev/null || exit 1
    printf '{"result":{"pane":{"pane_id":"%s","tab_id":"tP","agent_status":"%s"}}}\n' "$3" "$(cat "$d/status" 2>/dev/null || echo idle)" ;;
  pane-process-info) printf '{"result":{"process_info":{"foreground_processes":[{"argv0":"%s"}]}}}\n' "$(cat "$d/fg" 2>/dev/null || echo codex)" ;;
  agent-explain) echo '{"state":"idle"}' ;;
  pane-read) if [ -e "$d/scrollback" ]; then cat "$d/scrollback"; else "$(dirname "$0")/xsim" render; fi ;;
  pane-send-text) printf '%s' "$4" >>"$d/in" ;;
  pane-send-keys) [ "$4" != enter ] || "$(dirname "$0")/xsim" enter ;;
  pane-run)
    case "$(cat "$d/run.mode" 2>/dev/null || echo session)" in
      session) "$(dirname "$0")/xsim" session "$4" ;;
      die) sh -c "$4" >/dev/null 2>&1 ;;
      fail) exit 1 ;;
    esac ;;
esac
exit 0
STUB
# orca, the same shape over the CLI's ok envelope; the terminal create's
# --command is the launch line, run through the pane model.
cat >"$XSTUBS/orca" <<'STUB'
#!/usr/bin/env bash
d="$XSTUB"
{ printf orca; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >>"$d/orca.log"
v="${1:-}-${2:-}"
n=$(($(cat "$d/$v.n" 2>/dev/null || echo 0) + 1)); echo "$n" >"$d/$v.n"
for f in "$v.$n" "$v"; do
  if [ -e "$d/$f.out" ] || [ -e "$d/$f.rc" ]; then
    [ ! -e "$d/$f.out" ] || cat "$d/$f.out"
    exit "$(cat "$d/$f.rc" 2>/dev/null || echo 0)"
  fi
done
arg() { local want="$1" prev="" a; shift; for a in "$@"; do [ "$prev" != "$want" ] || { printf '%s' "$a"; return; }; prev="$a"; done; }
case "$v" in
  worktree-show) echo '{"ok":false}'; exit 1 ;;
  terminal-create)
    case "$(cat "$d/run.mode" 2>/dev/null || echo session)" in session) "$(dirname "$0")/xsim" session "$(arg --command "$@")" ;; esac
    echo '{"ok":true,"result":{"terminal":{"handle":"h1","tabId":"tab1"}}}' ;;
  terminal-show)
    if grep -qxF "$(arg --terminal "$@")" "$d/closed" 2>/dev/null; then echo '{"ok":true,"result":{"terminal":{"connected":false}}}'
    else echo '{"ok":true,"result":{"terminal":{"connected":true,"title":"codex","agentIdentity":"codex"}}}'; fi ;;
  terminal-close) h="$(arg --terminal "$@")"; [ "$h" = "$(cat "$d/sticky" 2>/dev/null)" ] || echo "$h" >>"$d/closed"; echo '{"ok":true,"result":{}}' ;;
  terminal-read) "$(dirname "$0")/xsim" render | jq -R . | jq -cs '{ok:true,result:{terminal:{tail:.}}}' ;;
  terminal-send)
    if [ "$(arg --text "$@")" != "" ]; then printf '%s' "$(arg --text "$@")" >>"$d/in"; fi
    case " $* " in *" --enter "*) "$(dirname "$0")/xsim" enter ;; esac
    echo '{"ok":true,"result":{}}' ;;
  terminal-wait) echo '{"ok":true,"result":{"wait":{"satisfied":true}}}' ;;
  *) echo '{"ok":true,"result":{}}' ;;
esac
STUB
# Every harness CLI the one-shot rung (or a dying crewmate launch) runs: argv
# logged, the world's answer printed and its status taken; a crewmate launch
# that is told to die exits 9 at once.
cat >"$XSTUBS/fakeh" <<'STUB'
#!/usr/bin/env bash
d="$XSTUB"
{ printf '%s' "$(basename "$0")"; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\n'; } >>"$d/harness.log"
[ ! -e "$d/die" ] || exit 9
[ ! -e "$d/answer.sleep" ] || /bin/sleep "$(cat "$d/answer.sleep")"
[ ! -e "$d/signals" ] || perl -e 'printf "INT=%s QUIT=%s\n", $SIG{INT} // "DEFAULT", $SIG{QUIT} // "DEFAULT"'
if [ -e "$d/answer" ]; then cat "$d/answer"; elif [ ! -e "$d/no-answer" ]; then echo '{"verdict":"approve"}'; fi
exit "$(cat "$d/answer.rc" 2>/dev/null || echo 0)"
STUB
for h in claude codex opencode pi cursor-agent agy; do ln -sf fakeh "$XSTUBS/$h"; done
printf '#!/bin/sh\nprintf "           0a      1b      2c      3d\\n"\n' >"$XSTUBS/od"
cat >"$XSTUBS/date" <<'STUB'
#!/bin/sh
# A reader a signal row ended mid-call is no output of the entry: the stub's
# own write error would land on whichever side the kill caught in a read.
case "$*" in
  +%s) n="$(cat "$XSTUB/date.n" 2>/dev/null || echo 0)"; echo "$((n + 1))" >"$XSTUB/date.n"; echo "$((1767225600 + n))" 2>/dev/null ;;
  *) exec /bin/date "$@" ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' >"$XNOSLEEP/sleep"
printf '#!/bin/sh\necho "sleep $*" >>"$XSTUB/sleep.log"\n' >"$XLOGSLEEP/sleep"
chmod +x "$XSTUBS"/* "$XNOSLEEP/sleep" "$XLOGSLEEP/sleep"

xworld() {  # xworld - a fresh world: the repo (one commit on main), the prompt, the dirs the env names
  [ ! -e "$XW" ] || chmod -R u+rwX "$XW" 2>/dev/null
  rm -rf "$XW"; mkdir -p "$XW/cwd" "$XW/hd" "$XW/tr" "$XW/st" "$XW/tmp" "$XW/stub" "$XW/home/config" "$XW/home/state"
  git -C "$XW/cwd" init -q
  printf 'base\n' >"$XW/cwd/f.txt"; git -C "$XW/cwd" add f.txt; git -C "$XW/cwd" commit -qm base
  printf 'review this\n' >"$XW/pf"
}
xput() { mkdir -p "$(dirname "$XW/$1")"; printf '%b' "$2" >"$XW/$1"; }   # xput <path under the world> <printf %b bytes>
xs() { mkdir -p "$XW/stub"; printf '%b' "${2-}" >"$XW/stub/$1"; }   # xs <stub file> [<printf %b bytes>] - a fault or answer file
XLC=C; XENV=(); XPATH=""; XHOME=""; XCWD=cwd; XIN=/dev/null
xpath() { printf '%s' "${XPATH:-$XSTUBS:$XNOSLEEP:$PATH}"; }
xc() {  # xc <args...> - one pane-agent call by this pass's side for the call, its transcript appended
  local side bin="$BIN" rc=0 x v
  side="${XALT[$((XCALL % ${#XALT[@]}))]}"; XCALL=$((XCALL + 1))
  [ "$side" = n ] || bin="$xobin"
  local e=("LC_ALL=$XLC" "PATH=$(xpath)" "HOME=$XW/hd" "TMPDIR=$XW/tmp" "XSTUB=$XW/stub"
    "AC_CLAUDE_TRANSCRIPT_ROOT=$XW/tr" "AC_FLEET_STATE=$XW/st")
  [ -z "$XHOME" ] || e+=("AC_HOME=$XW/home")
  for x in ${XENV[@]+"${XENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@W/$XW}"); done
  local a=(); for x in "$@"; do a+=("${x//@W/$XW}"); done
  (cd "$XW/$XCWD" && exec env -u AC_HOME -u AC_FLEET_STATE -u AC_SCOPE -u AC_SOLO -u AC_BACKEND -u AC_HERDR_SESSION \
    -u AC_HERDR_RPC_TIMEOUT -u AC_WINDOW_FAMILY -u AC_FLEET_NAME -u CLAUDE_CONFIG_DIR -u AC_PANE_STALL_MAX \
    -u AC_PANE_SETTLE_TRIES -u AC_PANE_SETTLE_SLEEP -u AC_PANE_SCROLLBACK_LINES -u AC_LOCK_STALE_GRACE -u CDPATH \
    -u EPOCHSECONDS "${e[@]}" /bin/sh -c 'printf "%s\n" "$$" >>"$0"; exec "$@"' "$TMP/xpids.$XPASS" \
    "$bin/ac-pane-agent.sh" ${a[@]+"${a[@]}"}) <"$XIN" >"$TMP/x.out" 2>"$TMP/x.err" || rc=$?
  { printf '== %s\nrc=%s\n-- out\n' "$*" "$rc"; cat "$TMP/x.out"; printf -- '-- err\n'; cat "$TMP/x.err"; } >>"$TMP/xt.$XPASS"
}
# An async job of this shell starts with SIGINT and SIGQUIT ignored, so the
# background call restores both before it execs the entry, in a group of its
# own.
xbg() {  # xbg <signal> <wait-for text in a stub log> <args...> - one call in the background, signalled once the stubs logged <text>
  local sig="$1" want="$2" side bin="$BIN" rc=0 pid i=0; shift 2
  side="${XALT[$((XCALL % ${#XALT[@]}))]}"; XCALL=$((XCALL + 1))
  [ "$side" = n ] || bin="$xobin"
  (cd "$XW/$XCWD" && exec env -u AC_HOME -u AC_FLEET_STATE -u AC_SCOPE -u AC_SOLO -u AC_BACKEND -u AC_HERDR_SESSION \
    -u AC_WINDOW_FAMILY -u AC_FLEET_NAME -u CLAUDE_CONFIG_DIR -u AC_PANE_STALL_MAX -u CDPATH \
    "LC_ALL=$XLC" "PATH=$(xpath)" "HOME=$XW/hd" "TMPDIR=$XW/tmp" "XSTUB=$XW/stub" "AC_CLAUDE_TRANSCRIPT_ROOT=$XW/tr" \
    "AC_FLEET_STATE=$XW/st" ${XENV[@]+"${XENV[@]}"} perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; setpgrp(0, 0); exec @ARGV' "$bin/ac-pane-agent.sh" "$@") \
    </dev/null >"$TMP/x.out" 2>"$TMP/x.err" &
  pid=$!
  printf '%s\n' "$pid" >>"$TMP/xpids.$XPASS"
  while ! grep -qF -- "$want" "$XW/stub/herdr.log" "$XW/stub/harness.log" 2>/dev/null && [ "$i" -lt 200 ]; do /bin/sleep 0.05; i=$((i + 1)); done
  case "$sig" in -*) kill "-${sig#-}" -- "-$pid" 2>/dev/null ;; *) kill "-$sig" "$pid" 2>/dev/null ;; esac
  wait "$pid" 2>/dev/null || rc=$?
  { printf '== %s %s\nrc=%s\n-- out\n' "$sig" "$*" "$rc"; cat "$TMP/x.out"; printf -- '-- err\n'; cat "$TMP/x.err"; } >>"$TMP/xt.$XPASS"
}
xnorm() {  # xnorm <file> <pass> - the k-th entry pid PID<k>, a marker's age, either bin root ROOT
  local e=() k=0 p
  while IFS= read -r p; do [ -z "$p" ] || { k=$((k + 1)); e+=(-e "s/(^|[^0-9])$p([^0-9]|\$)/\\1PID$k\\2/g"); }; done <"$TMP/xpids.$2"
  LC_ALL=C sed -E ${e[@]+"${e[@]}"} -e 's/arrived -?[0-9]+s ago/arrived Ns ago/' \
    -e "s#$TMP/oracle-ac-pane-agent#ROOT#g" -e "s#$ROOT#ROOT#g" "$1"
}
xsnap() {  # xsnap <pass> - the world as one listing (the repo as its info/exclude, bun's own cache under HOME skipped), then the stub logs
  local n f
  (cd "$XW" && find . \( -path ./stub -o -path ./tmp -o -path ./cwd/.git -o -path ./hd/Library \) -prune -o -print | LC_ALL=C sort) >"$TMP/xnames"
  while IFS= read -r f; do
    [ "$f" != . ] || continue
    if [ -L "$XW/$f" ]; then printf '== %s -> %s\n' "$f" "$(readlink "$XW/$f")"; continue; fi
    printf '== %s %s\n' "$f" "$(stat -f %Sp "$XW/$f")"
    [ -d "$XW/$f" ] || { cat "$XW/$f" 2>/dev/null || printf '<unreadable>'; printf '\n'; }
  done <"$TMP/xnames" >"$TMP/xw.$1"
  { printf -- '-- exclude\n'; cat "$XW/cwd/.git/info/exclude" 2>/dev/null || true
    for f in herdr.log orca.log harness.log buf sleep.log; do printf -- '-- %s\n' "$f"; cat "$XW/stub/$f" 2>/dev/null || true; done
  } >>"$TMP/xw.$1"
}
xpass() {  # xpass <pass> <setup> <body> <side>... - rebuild the world, then the body's calls (shell text) by the sides in turn
  XPASS="$1"; : >"$TMP/xt.$1"; : >"$TMP/xpids.$1"; XCALL=0; XALT=("${@:4}")
  xworld; eval "$2"; eval "$3"; xsnap "$1"
  xnorm "$TMP/xt.$1" "$1" >"$TMP/xt2.$1"; xnorm "$TMP/xw.$1" "$1" >"$TMP/xw2.$1"
}
xrow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
xcmp() {  # xcmp <pass> <pass> - transcripts and worlds identical
  cmp -s "$TMP/xt2.$1" "$TMP/xt2.$2" || fail "pane-agent differential calls differ ($1 vs $2) at line $(xrow): $(diff -a "$TMP/xt2.$1" "$TMP/xt2.$2" | head -n 14)"
  cmp -s "$TMP/xw2.$1" "$TMP/xw2.$2" || fail "pane-agent differential world differs ($1 vs $2) at line $(xrow): $(diff -a "$TMP/xw2.$1" "$TMP/xw2.$2" | head -n 14)"
}
xsame() { xpass o "$1" "$2" o; xpass n "$1" "$2" n; xcmp o n; }   # xsame <setup> <body> - the oracle alone, then the port alone
xsameown() {  # xsameown <text> <setup> <body> - xsame once the original's own stderr lines holding <text> are shown and dropped (SHELL-OWN, named)
  xpass o "$2" "$3" o; xpass n "$2" "$3" n
  xhas "$1" o
  LC_ALL=C grep -vF -- "$1" "$TMP/xt2.o" >"$TMP/xt2.own" || true
  mv "$TMP/xt2.own" "$TMP/xt2.o"
  xcmp o n
}
xcont() {  # xcont <setup> <body> - the oracle alone, then the two sides alternating call by call, either side first
  xpass o "$1" "$2" o; xpass a "$1" "$2" o n; xpass b "$1" "$2" n o; xcmp o a; xcmp o b
}
xboth() { xpass o "$1" "$2" o; xpass n "$1" "$2" n; }   # xboth <setup> <body> - both sides, compared by the row itself
xt() { cat "$TMP/xt2.${1:-n}"; }
xhas() { assert_contains "$(xt "${2:-n}")" "$1" "pane-agent differential at line $(xrow)"; }   # xhas <text> [<pass>]
xlacks() { case "$(xt "${2:-n}")" in *"$1"*) fail "pane-agent differential at line $(xrow): '$1' found in pass ${2:-n}" ;; esac; }
xwhas() { assert_contains "$(cat "$TMP/xw2.${2:-n}")" "$1" "pane-agent differential world at line $(xrow)"; }
xwlacks() { case "$(cat "$TMP/xw2.${2:-n}")" in *"$1"*) fail "pane-agent differential world at line $(xrow): '$1' found in pass ${2:-n}" ;; esac; }
xnone() { :; }
xerr() { sed -n '/^-- err$/,$p' "$TMP/xt2.${1:-n}" | sed 1d; }   # xerr [<pass>] - a one-call pass's stderr
xbytes() { LC_ALL=C grep -qF -- "$(printf '%b' "$1")" "$TMP/xw2.${2:-n}" || fail "pane-agent differential world at line $(xrow): bytes '$1' not found in pass ${2:-n}"; }
xwithout() {  # xwithout <tool> - the leg's stubs and PATH with every dir holding <tool> mirrored without it
  local dirs d f key mirror out=""
  IFS=: read -r -a dirs <<<"$XSTUBS:$XNOSLEEP:$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ -x "$d/$1" ]; then
      key="$(cd "$d" && pwd -P)"; mirror="$TMP/xno$1$(printf '%s' "$key" | tr -c 'A-Za-z0-9' '_')"
      if [ ! -d "$mirror" ]; then
        mkdir -p "$mirror"
        for f in "$key"/*; do [ "$(basename "$f")" = "$1" ] || ln -sf "$f" "$mirror/$(basename "$f")" 2>/dev/null || true; done
      fi
      d="$mirror"
    fi
    out="${out:+$out:}$d"
  done
  printf '%s\n' "$out"
}
xrun() { xc run --cwd @W/cwd --prompt-file @W/pf --label r1 "$@"; }   # xrun <flags...> - a run with the world's cwd and prompt

# 1. Preamble and usage: the usage is a done error, an invalid backend refuses
#    first on every verb, the homeless run says nothing on stderr; a valueless
#    flag, HOME unset and a bun-less PATH are the named divergences.
xsame xnone 'xc'
xhas '{"event":"done","status":"error","error":"usage: ac-pane-agent.sh run --cwd DIR --prompt-file F"}'
xsame xnone 'xc bogus --pane p1'
xsame xnone 'xc run'
xhas '"error":"cwd missing: "'
for v in "close --pane p1" "steer --agent a hi" "reap-pane --pane p1" "reap" "run --cwd @W/cwd"; do
  XENV=(AC_BACKEND=tmux); xsame xnone "xc $v"; XENV=()
done
xhas "ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)" o
xsame xnone 'xrun'
assert_contains "$(xt)" "rc=0" "a homeless session turn ends ok"
assert_eq "$(xerr o):$(xerr n)" ":" "the homeless pane agent writes nothing on stderr, on either side"
# W12 SHELL-OWN (named): a value flag with no value or an empty one ends every
# verb 1, the shell's own line on one side and the flag's name on the other.
for v in "run --cwd" "run --cwd @W/cwd --timeout ''" "close --pane" "reap-pane --pane ''" "steer --agent"; do
  xboth xnone "xc $v"
  assert_contains "$(xt o)" "rc=1" "the original ends 1 on a valueless flag: $v"
  assert_contains "$(xt o)" "parameter null or not set" "the original's own line: $v"
  assert_contains "$(xt n)" "rc=1" "the port ends 1 on a valueless flag: $v"
  assert_contains "$(xt n)" "needs a value" "the port names the flag: $v"
  xwlacks '[pane] [run]' o; xwlacks '[pane] [run]' n
done
# HOME unset (named): the shell's unbound line, the port's ERROR; 1 on both.
for side in o n; do
  bin="$BIN"; [ "$side" = n ] || bin="$xobin"
  rc=0; out="$(cd "$TMP" && env -u HOME -u AC_HOME "PATH=$XSTUBS:$XNOSLEEP:$PATH" "$bin/ac-pane-agent.sh" close --pane p1 2>&1)" || rc=$?
  assert_eq "$rc" "1" "HOME unset ends $side 1"
  case "$side" in
    o) assert_contains "$out" "HOME: unbound variable" "the original dies on its PATH hardening" ;;
    n) assert_contains "$out" "ERROR: HOME is not set" "the port names the missing HOME" ;;
  esac
done
# BUN (W11, named): close never needed bun in the original; the shim does.
XPATH="$(xwithout bun)"; xboth xnone 'xc close --pane p1'; XPATH=""
assert_contains "$(xt o)" "rc=0" "the original closes without bun"
assert_contains "$(xt n)" "ERROR: required tool not found: bun" "the shim refuses without bun"
assert_contains "$(xt n)" "rc=1" "the shim's refusal ends 1"

# 2. run refusals in order, the profile rungs, the contradiction warning, the
#    ladders, effort, the arm refusals and agy's warning.
xsame xnone 'xrun --exec --resume s1 --pane-file @W/pf.pane'
xhas '"error":"--exec runs a one-shot command: there is no session to --resume"'
xsame xnone 'xrun --exec --pane-file @W/pf.pane'
xsame xnone 'xrun --observe @W/obs'
for k in Bad 'a b' 'x/y' 'q_r'; do xsame xnone "xrun --kind '$k'"; done
xhas '"error":"kind must be [a-z0-9-]: q_r"'
xbadjson() { xput home/config/crew-dispatch.json '{oops\n'; }
XHOME=1; xsame xbadjson 'xrun --exec --kind codereview'; XHOME=""
xhas "could not resolve a pane profile for kind 'codereview' ("
xprof() { xput home/config/crew-dispatch.json '{"panes":{"codereview":{"harness":"codex","model":"m1","effort":"high"},"qa":{"harness":"pi"}}}\n'; }
xprofagent() { xprof; xput home/config/codereview-agent 'cl"aude\n'; }
XHOME=1
xsame xprof 'xrun --exec --kind codereview'
xsame xprofagent 'xrun --exec --kind codereview'
xhas '"reason":"codereview-agent-mismatch"'
xsame xprof 'xrun --exec --kind qa --model mine'
XENV=(AC_FLEET_AGENT_CODEREVIEW=codex); xsame xprof 'xrun --exec --kind codereview'; XENV=()
xknobs() { xput home/config/qa-model 'cm\n'; xput home/config/qa-agent 'opencode\n'; xput home/config/effort 'low\n'; xput home/config/model 'fm\n'; }
xsame xknobs 'xrun --exec --kind qa'
xsame xknobs 'xrun --exec --kind gate'
xsame xknobs 'xrun --exec --kind qa --harness claude'
XHOME=""
XENV=(AC_FLEET_MODEL_QA=em AC_FLEET_AGENT_QA=codex AC_FLEET_EFFORT_QA=max); xsame xnone 'xrun --exec --kind qa'; XENV=()
XENV=(AC_FLEET_MODEL=fm AC_FLEET_EFFORT=high); xsame xnone 'xrun --exec --kind gate --harness claude'; xsame xnone 'xrun --exec --kind gate --harness claude --model m2'; XENV=()
XENV=('AC_FLEET_PROFILE_CODEREVIEW=harness=codex model=gpt 5 effort=high'); xsame xnone 'xrun --exec --kind codereview'; XENV=()
XENV=($'AC_FLEET_PROFILE_CODEREVIEW=harness=opencode\tmodel=\teffort='); xsame xnone 'xrun --exec --kind codereview'; XENV=()
for e in ultracode low bogus; do xsame xnone "xrun --exec --harness claude --effort $e"; done
xhas '"error":"invalid effort: bogus (expected low|medium|high|xhigh|max|ultracode)"'
xsame xnone 'xrun --exec --harness fictional'
xsame xnone 'xrun --harness fictional'
xsame xnone 'xrun --exec --harness agy --effort high --model "Gemini 3.8 Flash (Low)" --timeout 900'
xhas "the configured effort 'high' was dropped"
xsame xnone 'xrun --harness codex --resume s1'
xsame xnone 'xc run --cwd @W/nope --prompt-file @W/pf'
xsame xnone 'xc run --cwd @W/cwd --prompt-file @W/nope'

# 3. SESSION on herdr: the turn, the Stop-hook merge, the trust seed, the
#    exclude, placement and labels, ENVPIN, --resume, --replace-pane,
#    --pane-file, the harvests, AWAIT, the idle fallback, the stall bound, the
#    timeout and the liveness reads.
xsame xnone 'xrun'
xhas '"event":"done","status":"ok"'
xwhas '[pane] [run] [pP1] [cd '
xset() { xput cwd/.claude/settings.local.json "$1"; }
xmalformed() { xset '{oops'; }
xforeign() { xset '{"permissions":{"allow":["Bash"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other"}]}]}}'; }
xdeadours() { xset "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"touch '/x/ac-pane-turnend.cwd-00.99999999'\"}]}]}}"; }
xliveours() { xset "{\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"touch '/x/ac-pane-turnend.cwd-00.$$'\"}]}]}}"; }
for s in xmalformed xforeign xdeadours xliveours; do xsame "$s" 'xrun'; done
xlockheld() { mkdir -p "$XW/cwd/.claude/.ac-pane-agent.lock"; printf '%s\n' "$$" >"$XW/cwd/.claude/.ac-pane-agent.lock/pid"; }
xsame xlockheld 'xrun'
xsettingsdir() { mkdir -p "$XW/cwd/.claude/settings.local.json"; }
xsame xsettingsdir 'xrun'
xhas '"error":"could not install the Stop hook into '
xtrust() { xput hd/.claude.json '{"projects": {"/other": {"a": 1}}, "z": [1.0, 1e-05]}'; }
xtrusted() { xput hd/.claude.json "{\"projects\":{\"$XW/cwd\":{\"hasTrustDialogAccepted\":true,\"hasCompletedProjectOnboarding\":1}}}"; }
xtrustbad() { xput hd/.claude.json '[1]'; }
for s in xtrust xtrusted xtrustbad; do xsame "$s" 'xrun'; done
xexcl() { printf '.claude/settings.local.json\n' >>"$XW/cwd/.git/info/exclude"; }
xexclunterm() { printf 'secret.env' >"$XW/cwd/.git/info/exclude"; }   # W6 at parity: the append glues onto it
xexclnone() { rm -rf "$XW/cwd/.git/info"; }
for s in xexcl xexclunterm xexclnone; do xsame "$s" 'xrun'; done
xbranch() { git -C "$XW/cwd" checkout -qb crew/fam1-x; }
XENV=(AC_WINDOW_FAMILY=fam1); xsame xbranch 'xrun --kind codereview'; XENV=()
xadopt() { xs tab-list.out '{"result":{"tabs":[{"tab_id":"tO","label":"ac-ship-agent-main","workspace_id":"wP"},{"tab_id":"tD","label":"1","workspace_id":"wP"}]}}\n'; xs pane-list.out '{"result":{"panes":[{"pane_id":"pO1","tab_id":"tO"}]}}\n'; xs workspace-list.out '{"result":{"workspaces":[{"workspace_id":"wP","label":"agent-crew","tab_count":2}]}}\n'; }
xwrongws() { xs tab-list.out '{"result":{"tabs":[{"tab_id":"tO","label":"ac-ship-agent-main","workspace_id":"wOther"}]}}\n'; }
for s in xadopt xwrongws; do xsame "$s" 'xrun'; done
xsame xnone 'xrun --replace-pane pOld'
xsticky() { xs sticky pOld; }
xsame xsticky 'xrun --replace-pane pOld'
xhas '{"event":"replace-pane","pane":"pOld","closed":false}'
XHOME=1; xsame xnone 'xrun'; XHOME=""
xwhas ' AC_HOME='
XENV=(AC_FLEET_NAME=fl CLAUDE_CONFIG_DIR=@W/cfg); xsame xnone 'xrun'; XENV=()
XENV=(AC_HERDR_SESSION=s9); xsame xnone 'xrun'; XENV=()
xsid() { xs sid sid-1; xs no-transcript; mkdir -p "$XW/tr/$(printf '%s' "$XW/cwd" | sed 's/[/.]/-/g')"; printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"resumed"}]}}' >"$XW/tr/$(printf '%s' "$XW/cwd" | sed 's/[/.]/-/g')/sid-1.jsonl"; }
xsame xsid 'xrun --resume sid-1'
xsame xnone 'xrun --pane-file @W/st/pane'
xwhas 'pP1 tP'
xsame xnone 'xrun --pane-file @W/nodir/pane'   # W13 at parity: refused after placement
xscroll() { xs no-transcript; xs scrollback 'the verdict\nline two\n'; }
xsame xscroll 'xrun'
xhas '"source":"scrollback"'
xscrollempty() { xs no-transcript; xs scrollback ''; }
xsame xscrollempty 'xrun'
xtooluse() { xs transcript '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}\n'; }
XENV=(AC_PANE_SETTLE_TRIES=2); xsame xtooluse 'xrun'; XENV=()
xhas 'carries no text'
XPATH="$XSTUBS:$XLOGSLEEP:$PATH"; XENV=(AC_PANE_SETTLE_TRIES=abc); xsameown 'integer expression expected' xtooluse 'xrun'; XENV=(); XPATH=""   # W5 at parity: no settle re-reads, counted by the logged sleeps
xawaitabsent() { :; }
xsame xawaitabsent 'xrun --await-file @W/await --timeout 6'
xhas 'is absent - holding for the next turn end'
xawaitold() { xput await 'x\n'; xs transcript '{"type":"assistant","timestamp":"2001-01-01T00:00:00Z","message":{"content":[{"type":"text","text":"early"}]}}\n'; }
xsame xawaitold 'xrun --await-file @W/await --timeout 6'
xhas 'predates'
xawaitnew() { xput await 'x\n'; xs transcript '{"type":"assistant","timestamp":"2099-01-01T00:00:00Z","message":{"content":[{"type":"text","text":"late"}]}}\n'; }
xsame xawaitnew 'xrun --await-file @W/await --timeout 6'
# The idle fallback: no marker, a transcript last written in 2000, an idle
# pane, more than 45 polls of the ticking clock.
xidle() { xs no-marker; xs backdate; xs transcript '{"type":"assistant","message":{"content":[{"type":"text","text":"final"}]}}\n'; }
xsame xidle 'xrun --timeout 400'
xhas 'idle-fallback used (agent_status=idle)'
xsame xidle 'xrun --timeout 400 --deliverable @W/report.md'
xidledeliv() { xidle; xput report.md 'done\n'; }
xsame xidledeliv 'xrun --timeout 400 --deliverable @W/report.md'
xidletool() { xs no-marker; xs backdate; xs transcript '{"type":"assistant","message":{"content":[{"type":"text","text":"x"}]}}\n{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{}}]}}\n'; }
XENV=(AC_PANE_SETTLE_TRIES=1); xsame xidletool 'xrun --timeout 400'; XENV=()
xidledone() { xidle; xs status done; }
xsame xidledone 'xrun --timeout 400'
xidlebusy() { xidle; xs status busy; }
XENV=(AC_PANE_STALL_MAX=3); xsame xidlebusy 'xrun --timeout 400'; XENV=()
xhas 'no transcript progress for over 3s (agent_status=busy)'
XENV=(AC_PANE_STALL_MAX=abc); xsameown 'integer expression expected' xidlebusy 'xrun --timeout 30'; XENV=()   # W5 at parity: the bound off
XENV=(AC_PANE_STALL_MAX=0); xsame xidlebusy 'xrun --timeout 30'; XENV=()
# W9 at parity: a final message of a no-break space reads as text under C and
# as blank under UTF-8 (grep is spawned on both sides).
xnbsp() { xs transcript '{"type":"assistant","message":{"content":[{"type":"text","text":"\\u00a0"}]}}\n'; }
XENV=(AC_PANE_SETTLE_TRIES=1); xsame xnbsp 'xrun'; XLC=en_US.UTF-8; xsame xnbsp 'xrun'; XLC=C; XENV=()
xnomarker() { xs no-marker; }
for t in 0 -5 3 010; do xsame xnomarker "xrun --timeout $t"; done
xhas '"error":"turn did not end within 010s"'
xgone() { xs no-marker; xs pane-get.rc 1; }   # W1 at parity: one failed read is a dead pane
xsame xgone 'xrun --timeout 40'
xhas '"status":"pane_closed"'
xrunfail() { xs run.mode fail; }   # W10 at parity: a refused launch waits out the timeout
xsame xrunfail 'xrun --timeout 12'
xhas '"status":"timeout"'
# W2 at parity: a raw herdr call that hangs holds the run, whatever --timeout.
xhang() { xs no-marker; xs pane-get.sleep 1; }
for side in o n; do
  s0=$SECONDS; xpass "$side" xhang 'xrun --replace-pane pOld --timeout 0' "$side"
  [ $((SECONDS - s0)) -ge 1 ] || fail "a hung pane get holds the $side side's run past --timeout 0"
done
xcmp o n
# W4 (08) at parity: the pane is placed, the run ends 1 with nothing on stdout;
# the shell's own arithmetic and unbound lines are not reproduced.
xboth xnomarker 'xrun --timeout 08'
for p in o n; do assert_contains "$(xt "$p")" "rc=1"$'\n'"-- out"$'\n'"-- err" "08 ends the $p side 1, nothing printed"; xwhas '[pane] [run]' "$p"; done
assert_contains "$(xt o)" "value too great for base" "the original's own arithmetic line"
# Q3 (named): every other --timeout form is refused before any pane or rung,
# where the original placed the pane first.
for t in abc 1+1 0x3 1.5 10m ' 5'; do
  xboth xnomarker "xrun --timeout '$t'"
  assert_contains "$(xt n)" "\"error\":\"timeout must be a whole number of seconds: $t\"" "the port refuses --timeout '$t'"
  xwlacks '[pane] [run]' n
  xwhas '[pane] [run]' o
done

# 4. SESSION on orca: the worker placement, the liveness reads, --replace-pane,
#    a placement that fails, and the home arm.
XENV=(AC_BACKEND=orca)
xsame xnone 'xrun'
xhas '"event":"done","status":"ok"'
xwhas '[terminal] [create] [--worktree] [path:'
xorcagone() { xs no-marker; printf '%s\n' h1 >"$XW/stub/closed"; }
xsame xorcagone 'xrun --timeout 40'
xorcaunread() { xs no-marker; xs terminal-show.rc 1; }
xsame xorcaunread 'xrun --timeout 40'
xsame xnone 'xrun --replace-pane hOld'
xorcafail() { xs terminal-create.rc 1; }
xsame xorcafail 'xrun'
xhas '"error":"could not place orca pane"'
XHOME=1; XCWD=home; XENV=(AC_BACKEND=orca AC_WINDOW_FAMILY=fam1)
xhomegit() { git -C "$XW/home" init -q; }
xsame xhomegit 'xc run --cwd @W/home --prompt-file @W/pf --label h1 --kind learning'
XHOME=""; XCWD=cwd; XENV=()

# 5. CREWMATE on herdr and orca: the happy turn per harness, came-up, the
#    harness dying, a named dialog, input-ready never and past the deadline,
#    the stranded kickoff, the verdict empty or missing, no announcement.
xcrew() { xs run.mode crew; }
xsame xcrew 'xrun --harness codex --kind codereview --model gpt-5.6-sol --effort xhigh'
xhas '"source":"file"'
xwhas 'Read and follow the instructions in'
for h in opencode pi cursor; do xsame xcrew "xrun --harness $h --model m1 --effort high"; done
xcrewshell() { xcrew; xs fg -zsh; }
xsame xcrewshell 'xrun --harness codex'
xhas 'did not come up in its pane within 60s'
xcrewunread() { xcrew; xs pane-process-info.rc 1; }
xsame xcrewunread 'xrun --harness codex'
xhas 'could not read the pane to verify codex came up'
xcrewdie() { xs run.mode die; xs die; }
xsame xcrewdie 'xrun --harness codex'
xhas 'exited (status 9) before its pane could take a prompt'
xcrewdialog() { xcrew; xs agent-explain.1.out '{"state":"blocked","matched_rule":{"id":"startup_update"}}\n'; }
xsame xcrewdialog 'xrun --harness codex'
xcrewnever() { xcrew; xs render.n 0; }
xsame xcrewnever 'xrun --harness codex'
xhas 'input surface did not become ready within 60s'
xsame xcrewnever 'xrun --harness codex --timeout 8'
xcrewstrand() { xcrew; xs strand; }
xsame xcrewstrand 'xrun --harness codex'
xhas 'was NOT accepted by the pane'
xcrewempty() { xcrew; xs empty-verdict; }
xcrewnov() { xcrew; xs no-verdict; }
for s in xcrewempty xcrewnov; do xsame "$s" 'xrun --harness opencode'; done
xhas 'left no verdict at'
xcrewquiet() { xcrew; xs no-announce; }
xsame xcrewquiet 'xrun --harness codex --timeout 30'
xhas '"status":"timeout"'
XENV=(AC_BACKEND=orca)
xsame xcrew 'xrun --harness codex'
xhas '"source":"file"'
xorcadialog() { xcrew; xs terminal-show.out '{"ok":true,"result":{"terminal":{"connected":true,"title":"codex","agentIdentity":"codex","agentWait":{"reason":"other"}}}}\n'; }
xsame xorcadialog 'xrun --harness codex --timeout 20'
XENV=()

# 6. ONE-SHOT: each form with a model and an effort, agy's timeout and warning,
#    the rung's status and stdout, the rung dying without its marker,
#    --observe's descriptor, and the rung's INT/QUIT dispositions.
for h in codex claude opencode pi cursor; do
  xsame xnone "xrun --exec --harness $h --kind gate --model m1 --effort high"
  xsame xnone "xrun --exec --harness $h --kind gate"
done
xsame xnone 'xrun --exec --harness agy --kind gate --model "Gemini 3.8 Flash (Low)" --timeout 900'
xwhas '[--print-timeout] [900s] [-p]'
xrc7() { xs answer.rc 7; }
xsame xrc7 'xrun --exec --harness codex --kind gate'
xhas 'the one-shot rung exited 7'
xempty() { xs no-answer; }
xsame xempty 'xrun --exec --harness codex --kind gate'
xhas 'exited 0 but printed nothing'
xbadutf() { xs answer '\xe9\xe9\n'; }
xsame xbadutf 'xrun --exec --harness codex --kind gate'
xhas "could not wrap the rung's stdout"
xdeadsh() { mkdir -p "$XW/stub/shbin"; printf '#!/bin/sh\nexit 3\n' >"$XW/stub/shbin/sh"; chmod +x "$XW/stub/shbin/sh"; }
XPATH="$XW/stub/shbin:$XSTUBS:$XNOSLEEP:$PATH"; xsame xdeadsh 'xrun --exec --harness codex --kind gate'; XPATH=""
xhas 'the one-shot process died without ending its turn'
xsame xnone 'xrun --exec --harness codex --kind gate --observe @W/obs'
xwhas '{"pane":"","tab":"","harness":"codex","prompt":"'
xsigs() { xs signals; }
xsame xsigs 'xrun --exec --harness codex --kind gate'
xwhas 'INT=IGNORE QUIT=IGNORE'

# 7. close, reap-pane and reap on both backends.
xsame xnone 'xc close --pane p1'
xsame xnone 'xc close'
XENV=(AC_BACKEND=orca); xsame xnone 'xc close --pane h1 --bogus'; XENV=()
xsame xnone 'xc reap-pane'
xtabs() { xs tab-list.out "$1"; xs pane-list.out "$2"; }
xsib() { xtabs '{"result":{"tabs":[{"tab_id":"t1","workspace_id":"w1"}]}}\n' '{"result":{"panes":[{"pane_id":"p1","tab_id":"t1"},{"pane_id":"p2","tab_id":"t1"}]}}\n'; }
xlasttab() { xtabs '{"result":{"tabs":[{"tab_id":"t1","workspace_id":"w1"},{"tab_id":"t2","workspace_id":"w1"}]}}\n' '{"result":{"panes":[{"pane_id":"p1","tab_id":"t1"}]}}\n'; }
xlastws() { xtabs '{"result":{"tabs":[{"tab_id":"t1","workspace_id":"w1"}]}}\n' '{"result":{"panes":[{"pane_id":"p1","tab_id":"t1"}]}}\n'; }
xstickyp1() { xlastws; xs sticky p1; }
for s in xsib xlasttab xlastws xstickyp1; do xsame "$s" 'xc reap-pane --pane p1'; done
xhas '"closed":false'
XENV=(AC_BACKEND=orca); xsame xnone 'xc reap-pane --pane h1'; xstickyh1() { xs sticky h1; }; xsame xstickyh1 'xc reap-pane --pane h1'; XENV=()
XENV=(AC_BACKEND=orca); xsame xnone 'xc reap --bogus'; XENV=()
xsame xnone 'xc reap --bogus'
xreapw() {
  mkdir -p "$XW/live"
  xtabs '{"result":{"tabs":[{"tab_id":"t1","label":"ac-ship-agent-main"},{"tab_id":"t2","label":"ac-qa-agent"},{"tab_id":"t3","label":"crew:x"}]}}\n' \
    "{\"result\":{\"panes\":[{\"pane_id\":\"p1\",\"tab_id\":\"t1\",\"cwd\":\"$XW/gone a\\\"b\"},{\"pane_id\":\"p2\",\"tab_id\":\"t2\",\"cwd\":\"$XW/live\"},{\"pane_id\":\"p3\",\"tab_id\":\"t2\",\"cwd\":\"$XW/gone2\"},{\"pane_id\":\"p4\",\"tab_id\":\"t3\",\"cwd\":\"$XW/gone3\"}]}}\n"
}
xsame xreapw 'xc reap'
xsame xreapw 'xc reap --dry-run'
xhas '"event":"reap-done","panes":2,"tabs":1,"dry_run":1'

# 8. steer: resolution, the gate guard, the backend and argument refusals, the
#    delivery's three verdicts.
xagents() { xs pane-list.out '{"result":{"panes":[{"pane_id":"pA","label":"ac-codereview-agent:fam1-r1"},{"pane_id":"pB","label":"ac-gate-agent:fam1-spec"},{"pane_id":"pC","label":"crew:t1"},{"pane_id":"pD","label":"ac-qa-agent:a b, c"},{"pane_id":"pE","label":"ac-qa-agent:dup"},{"pane_id":"pF","label":"ac-qa-agent:dup"}]}}\n'; }
for v in "--agent ac-codereview-agent:fam1-r1 hello" "--agent nobody hello" "--agent ac-qa-agent:dup hi" "--pane pC hi" "--pane pA --agent nobody hi" \
         "--agent ac-gate-agent:fam1-spec hi" "--pane pB hi" "--agent 'ac-qa-agent:a b, c' hi" \
         "--agent a -x" "--agent a one two" "--agent a ''" "hi"; do
  xsame xagents "xc steer $v"
done
xsame xagents 'xc steer --agent ac-gate-agent:fam1-spec --captain hi'
xhas "steered ac-gate-agent:fam1-spec (pane pB)"
xunreadable() { xs pane-list.rc 1; }
xsame xunreadable 'xc steer --agent a hi'
xstranded() { xagents; xs strand; }
xsame xstranded 'xc steer --agent ac-codereview-agent:fam1-r1 hello'
xhas 'delivery NOT confirmed'
xunobs() { xagents; xs pane-read.rc 1; }
xsame xunobs 'xc steer --agent ac-codereview-agent:fam1-r1 hello'
xhas 'delivery UNVERIFIED'
XENV=(AC_BACKEND=orca); xsame xagents 'xc steer --agent a hi'; XENV=()

# 9. NDJSON bytes: raw interpolation (W3) of a quote, a backslash and a TAB in
#    the marker dir, the label and the cwd; fail()'s jq for the same bytes; a
#    byte that is no UTF-8 reaches the port decoded (named).
XENV=($'AC_FLEET_STATE=@W/s"t\\a\te'); xsame xnone 'xrun --exec --harness codex --kind gate'; XENV=()
xhas '"source":"command"'
XLBL=$'l"\\b\tc'; xsame xnone 'xrun --label "$XLBL"'
xsame xnone "xc run --cwd '@W/no\"pe' --prompt-file @W/pf"
xhas '"error":"cwd missing: '
xboth xnone "xrun --label \$'\\xe9'"
xbytes 'ac-ship-agent:\xe9]' o
xbytes 'ac-ship-agent:\xef\xbf\xbd]' n

# 10. Signals: TERM and HUP end both sides at once (143, 129), the pane or the
#     rung left running; INT to the pid alone is swallowed by the original and
#     ends the port 130 (named); a group INT leaves the rung, which ignores it.
# The stub's `pane run` holds 3 s, so the signal lands while the entry waits
# on it and no later call races the kill into one side's log.
xstall() { xs no-marker; xs pane-run.sleep 3; }
xsame xstall "xbg TERM '[pane] [run]' run --cwd $XW/cwd --prompt-file $XW/pf --label r1 --timeout 100000"
xhas 'rc=143'
xsame xstall "xbg HUP '[pane] [run]' run --cwd $XW/cwd --prompt-file $XW/pf --label r1 --timeout 100000"
xhas 'rc=129'
xslowrung() { xs answer.sleep 1; }
xsame xslowrung "xbg TERM 'codex [exec]' run --cwd $XW/cwd --prompt-file $XW/pf --exec --harness codex --kind gate --timeout 100000; /bin/sleep 2"
xwhas '{"verdict":"approve"}'
XPATH="$XSTUBS:$PATH"
xboth xstall "xbg INT '[pane] [run]' run --cwd $XW/cwd --prompt-file $XW/pf --label r1 --timeout 4"
xhas '"status":"timeout"' o
xhas 'rc=130' n
xlacks '"event":"done"' n
xsame xslowrung "xbg -INT 'codex [exec]' run --cwd $XW/cwd --prompt-file $XW/pf --exec --harness codex --kind gate --timeout 100000; /bin/sleep 2"
xhas 'rc=130'
xwhas '{"verdict":"approve"}'
XPATH=""

# 11. Continuation: a pane one side opened is reaped by the other's reap-pane;
#     a Stop hook one side installed is pruned by the other's merge once its
#     pid is gone.
xcont xnone 'xrun; xc reap-pane --pane pP1'
xcont xnone 'xrun; xrun'

# 12. The helper subcommands through the shim (Q5, named): the port runs them,
#     the original refused them as its usage error.
xboth xnone 'xc iso-epoch 2026-01-01T00:00:00Z; xc seed-trust @W/cwd; xc has-final-text @W/nope'
assert_contains "$(xt n)" $'rc=0\n-- out\n1767225600\n' "iso-epoch answers through the shim"
assert_contains "$(xt o)" '"error":"usage: ac-pane-agent.sh run --cwd DIR --prompt-file F"' "the original's usage error for a helper verb"
xlacks '"error":"usage' n

# 13. Where the original captured a helper with `$(...)`, its trailing LFs are
#     cut: a model ending in LF closes each launch form unless an effort flag
#     follows it, and the cwd's basename, the transcript root and the session
#     id read off a resumed transcript's name drop theirs. A path holding an
#     LF sits under tmp/, which the world listing (one name per line) skips.
XLF=$'gpt-6.1-sol\n'
xsame xcrew 'xrun --harness codex --model "$XLF"'
xwhas '-m gpt-6.1-sol; printf %s $?'
xsame xcrew 'xrun --harness codex --model "$XLF" --effort high'
xwhas $'-m gpt-6.1-sol\n -c model_reasoning_effort=high; printf'
xsame xnone 'xrun --exec --harness claude --kind gate --model "$XLF"'
xwhas 'claude [-p] [--model] [gpt-6.1-sol] [review this]'
xsame xnone 'xrun --exec --harness claude --kind gate --model "$XLF" --effort high'
xsame xnone 'xrun --model "$XLF"'
xwhas '--model gpt-6.1-sol "$(cat '
xsame xnone 'xrun --model "$XLF" --effort high'
xlfcwd() { mkdir -p "$XW/tmp/w"$'\n'; }
XLFCWD=$'@W/tmp/w\n'
xsame xlfcwd 'xc run --cwd "$XLFCWD" --prompt-file @W/pf --label r1 --exec --harness codex --kind gate'
xhas '/ac-pane-exec.w.PID1.jsonl","source":"command"'
xsame 'xlfcwd; xcrew' 'xc run --cwd "$XLFCWD" --prompt-file @W/pf --label r1 --harness codex --timeout 60'
xhas '"source":"file"'
xlftr() {  # xlftr <session id> - its transcript under the root tmp/tr, the pane writing none
  xs no-transcript; mkdir -p "$XW/tmp/tr/$(printf '%s' "$XW/cwd" | sed 's/[/.]/-/g')"
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"resumed"}]}}' >"$XW/tmp/tr/$(printf '%s' "$XW/cwd" | sed 's/[/.]/-/g')/$1.jsonl"
}
XENV=($'AC_CLAUDE_TRANSCRIPT_ROOT=@W/tmp/tr\n'); xsame 'xlftr sid-1' 'xrun --resume sid-1'; XENV=()
xhas '"source":"transcript"'
XLFSID=$'sid-1\n'
XENV=(AC_CLAUDE_TRANSCRIPT_ROOT=@W/tmp/tr); xsame 'xlftr "$XLFSID"' 'xrun --resume "$XLFSID" --model m1'; XENV=()
xhas '"status":"ok","session_id":"sid-1","transcript"'

pass
