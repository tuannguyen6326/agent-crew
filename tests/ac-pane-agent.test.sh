#!/usr/bin/env bash
# ac-pane-agent.test.sh - the vendored pane-turn helper: NDJSON protocol,
# Stop-hook turn end, transcript detection, workspace placement, close verb,
# and arg validation. herdr and claude are stubbed; the stub's `pane run`
# simulates a finished claude turn (touches the Stop-hook marker and writes
# the transcript).
# shellcheck disable=SC2016

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
repo="$(make_repo)"
stub="$TMP/stubbin"
mkdir -p "$stub"
export HDLOG="$TMP/hd.log" FAKEHOME="$TMP/fakehome"
mkdir -p "$FAKEHOME"

cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$HDLOG"
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "tab list") echo '{"result":{"tabs":[]}}' ;;
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
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"[]"}]}}' \
      >"$HOME/.claude/projects/$slug/$sid.jsonl"
    touch "$marker" ;;
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
# AC_WINDOW_FAMILY (FAMILY WORKSPACE GROUPING, captain order 2026-08-06).
: >"$HDLOG"
git -C "$repo" checkout -q --detach
PATH="$stub:$PATH" HOME="$FAKEHOME" AC_WINDOW_FAMILY=famx \
  "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label c1 >/dev/null
assert_contains "$(cat "$HDLOG")" "--label ac-codereview-agent-famx" \
  "detached lease: the FAMILY scopes the tab label, so cross-family adoption is impossible by name"
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
# Landed captain decision 2026-07-28 (routed-pane-rules-for-gate-codereview-
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
# (this pane agent) passes no selector - captain ruling 2026-07-28,
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
out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind learning --label p-arm 2>&1 || true)"
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
case "$(cat "$HDLOG")" in *"pane run"*) fail "an unresolvable profile must place no pane" ;; esac
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
assert_contains "$(bash -c ". '$BIN/ac-lib.sh'; . '$BIN/ac-pipeline-lib.sh'; ac_transcript_final '$tr_path'")" \
  "verdict: passed - harvested from the pane" "the caller's own transcript reader finds the scrollback verdict"

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
mkdir -p "$fake/bin"
cp "$BIN/ac-lib.sh" "$BIN/ac-harness.sh" "$BIN/ac-backend.sh" "$BIN/ac-pane-agent.sh" "$BIN/ac-dispatch-select.sh" "$fake/bin/"
echo '{"result":{"workspaces":[]}}' >"$WSLIST"
: >"$HDLOG"
env -u AC_HOME PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label nohome >/dev/null
assert_contains "$(cat "$HDLOG")" "workspace create --label agent-crew --no-focus" \
  "no AC_HOME: the fixed fleet's root workspace, never the checkout basename"
assert_no_file "$fake/config" "no AC_HOME: no config/ minted inside the checkout"
# ...and NOT ONE BYTE on stderr. This script's stdout+stderr are ONE stream to
# its caller: ac-verify.sh:1107-1108 launches it as `"$pane_bin" ... >"$result"
# 2>&1` and then parses that file with `jq -c 'select(.event == "done")'`
# (:1137). jq aborts on the first non-JSON line and emits NOTHING, so a single
# stray diagnostic - ac_home's homeless refusal, say - turns a valid verdict
# into `verifier <id> emitted no terminal result` and fails EVERY codereview
# and QA round a crewmate launches. The homeless rungs must degrade QUIETLY.
err="$(env -u AC_HOME -u AC_FLEET_STATE PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label nohome-quiet 2>&1 >/dev/null)"
assert_eq "$err" "" "no AC_HOME: the pane agent writes NOTHING to stderr (it shares stdout with the NDJSON its caller jq-parses)"
# The state dir it uses is the fleet's when told, never the checkout's: same
# AC_FLEET_STATE rung its siblings ac-done.sh:77 and ac-verify.sh:362-368 carry.
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
  AC_FLEET_PROFILE_CODEREVIEW='harness=claude model=opus effort=max' \
  PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind codereview --label prof-env >/dev/null
assert_contains "$(cat "$HDLOG")" "--model opus --effort max" \
  "homeless caller: the threaded profile supplies model and effort"
case "$(cat "$HDLOG")" in *"--model haiku"*) fail "the threaded profile supersedes the per-role model env" ;; esac
# Atomic on the wire as well: a threaded harness-only profile stays bare rather
# than picking up the fleet scalars beside it.
: >"$HDLOG"
env -u AC_HOME AC_FLEET_MODEL=sonnet AC_FLEET_EFFORT=high \
  AC_FLEET_PROFILE_QA='harness=claude model= effort=' \
  PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind qa --label prof-bare >/dev/null
case "$(cat "$HDLOG")" in *"--model"*|*"--effort"*) fail "a threaded harness-only profile must stay bare" ;; esac
# And the refusal holds on the homeless rung too - the arm set is a property of
# this helper, not of who could read the config.
: >"$HDLOG"
out="$(env -u AC_HOME AC_FLEET_PROFILE_QA='harness=fictional model= effort=' \
  PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind qa --label prof-arm 2>&1 || true)"
assert_contains "$out" '"status":"error"' "a threaded unarmed harness is refused too"
assert_contains "$out" "fictional" "the homeless refusal names the harness"
case "$(cat "$HDLOG")" in *"pane run"*) fail "a threaded unarmed harness must place no pane" ;; esac

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
nstop() { python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["hooks"]["Stop"]))' "$1"; }
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

# --- steer: a chief steers a LIVE pane agent by its stable handle ----------------
# The handle IS the pane label ac-<kind>-agent:<label> the run verb writes at
# pane creation (`pane rename`, above) - so a chief that did NOT launch the pane
# resolves it from herdr itself, with no caller-private .pane file. The shared
# fake herdr (tests/helpers.sh) is used from here on: its composer model is what
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
chmod +x "$xstub/herdr" "$xstub/codex" "$xstub/claude" "$xstub/opencode"
xrepo="$(make_repo execwt)"
xrun() { PATH="$xstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$xrepo" --prompt-file "$pf" "$@"; }

: >"$HDLOG"; : >"$HDLOG.cmd"; : >"$XLOG"
out="$(xrun --exec --harness codex --kind gate --label g1)"
assert_contains "$out" '"event":"done","status":"ok"' "a one-shot rung that exits 0 with output is an ok turn"
assert_contains "$out" '"source":"command"' "the ok event names the harvest that produced it"
assert_contains "$(cat "$HDLOG.cmd")" "codex exec -s read-only" "the pane runs the one-shot form, not the TUI"
assert_contains "$(cat "$HDLOG")" "pane rename pX1 ac-gate-agent:g1" "the one-shot pane is labeled like any pane agent"
tr="$(printf '%s\n' "$out" | sed -n 's/.*"event":"done".*"transcript":"\([^"]*\)".*/\1/p')"
assert_contains "$(cat "$tr")" "verdict" "the engine's stdout is the harvested payload"
assert_eq "$(jq -r '.message.content[0].text' "$tr" | head -1)" '{"verdict":"approve"}' \
  "the payload is wrapped in the one-message shape ac_transcript_final parses"
assert_contains "$(cat "$XLOG.prompt")" "review this" "the prompt file reaches the engine as its positional argument"
assert_contains "$(cat "$HDLOG.cmd")" "codex exec -s read-only --skip-git-repo-check" \
  "the codex one-shot form skips codex's own git-repo trust check - the gate always runs it from the fleet home, never a git repo"

# The gate's judge cwd is the FLEET HOME (bin/ac-gate.sh:889), and a fleet home
# is never a git repo - every input rides in the prompt instead. Prove
# ac-pane-agent composes and runs the form from such a cwd without erroring on
# its own account - the stub does not run codex's real trust-check, so that
# it also PASSES codex itself is proven separately, by a real gate run
# (data/gate-codex-rung-broken-by-cwd/spec/ in the drydock fleet).
nongit="$TMP/nongit-cwd"; mkdir -p "$nongit"
: >"$HDLOG"; : >"$HDLOG.cmd"; : >"$XLOG"
out="$(PATH="$xstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$nongit" --prompt-file "$pf" --exec --harness codex --kind gate --label g1b)"
assert_contains "$out" '"event":"done","status":"ok"' "the codex one-shot rung answers from a non-git cwd"
assert_contains "$(cat "$HDLOG.cmd")" "--skip-git-repo-check" "the non-git-cwd run still carries the flag"

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

# Per-harness one-shot shapes, each in its OWN dialect (the three forms that
# exist today - no speculative entries).
: >"$XLOG"
xrun --exec --harness codex --kind gate --label g4 --model gpt-5.6-sol --effort xhigh >/dev/null
assert_contains "$(cat "$XLOG")" "codex exec -s read-only --skip-git-repo-check -m gpt-5.6-sol -c model_reasoning_effort=xhigh" \
  "codex takes effort as a config override"
# codex always requests a reasoning summary (captain decision 2026-07-26): a
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
assert_eq "$(jq -r '.pane' "$obs")" "pX1" "the descriptor names the live pane"
assert_eq "$(jq -r '.tab' "$obs")" "tX" "the descriptor names the tab"
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
# The captain's design (2026-07-22): the pane-agent SESSION is claude's; a
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
assert_contains "$(cat "$HDLOG.cmd")" "codex -m gpt-5.6-sol -c model_reasoning_effort=xhigh" \
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
assert_contains "$(bash -c ". '$BIN/ac-lib.sh'; . '$BIN/ac-pipeline-lib.sh'; ac_transcript_final '$tr_path'")" \
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
# codereview-agent resolves codex (captain decision 2026-07-28,
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
assert_contains "$(cat "$HDLOG.cmd")" "codex -m gpt-5.6-sol -c model_reasoning_effort=xhigh" \
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
# --timeout 20, matching the codex sibling at :1313: crewmate_wait_input_ready
# (bin/ac-pane-agent.sh:1147-1178) gates BOTH harnesses through the identical
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
# identically to the refusal under test (tests/helpers.sh:86).
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

pass
