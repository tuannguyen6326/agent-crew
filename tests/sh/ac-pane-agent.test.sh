#!/usr/bin/env bash
# ac-pane-agent.test.sh - the vendored pane-turn helper: NDJSON protocol,
# Stop-hook turn end, transcript detection, orca placement, close verb, and
# arg validation. orca and claude are stubbed; the stub's `terminal create`
# --command simulates a finished claude turn (touches the Stop-hook marker and
# writes the transcript).
# shellcheck disable=SC2016

# Fail-closed sourcing: unsourced (suite run outside tests/sh/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

make_home
# tfinal <transcript> - the callers' own transcript reader, src/lib.ts's
# transcriptFinal (src/gate.ts and src/verify.ts call it).
tfinal() { (cd "$ROOT" && bun --no-env-file -e "const L = await import('./src/lib.ts'); process.stdout.write(Buffer.from(L.transcriptFinal(process.argv[1]).text, 'latin1'));" "$1"); }
repo="$(make_repo)"
stub="$TMP/stubbin"
mkdir -p "$stub"
export HDLOG="$TMP/hd.log" FAKEHOME="$TMP/fakehome"
mkdir -p "$FAKEHOME"
# orca is the only valid backend (herdr is refused everywhere - T8's cutover),
# so no row below needs to pin AC_BACKEND: a bare run already resolves orca.
# The helper resolves transcripts through ac_claude_transcript_root; the stub
# claude writes them under the fake HOME every run below passes.
export AC_CLAUDE_TRANSCRIPT_ROOT="$FAKEHOME/.claude/projects"

# This file's own local orca stub (below) models only terminal placement
# end-to-end: `terminal create --command <line>` runs that line SYNCHRONOUSLY
# (as orcaPlacePane's own call is), exactly as the original's herdr stub ran
# `pane run`'s composed line. Handles are counter-named term<n>/tab<n> and
# tracked as files under $ORCA_HANDLES so `terminal show`/`close` can answer.
export ORCA_HANDLES="$TMP/orca-handles"
mkdir -p "$ORCA_HANDLES"
cat >"$stub/orca" <<'EOF'
#!/usr/bin/env bash
echo "orca $*" >>"$HDLOG"
cmd="" term=""
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    --command) i=$((i+1)); cmd="${args[$i]}" ;;
    --terminal) i=$((i+1)); term="${args[$i]}" ;;
  esac
  i=$((i+1))
done
simulate_turn() {
  # Run in the BACKGROUND, detached from the stub's own exit: a real terminal
  # tool hands back its handle as soon as the pane exists and runs --command
  # INSIDE it asynchronously (the pane is a live claude session, not a value
  # the create call waits on) - unlike the old herdr stub, whose placement and
  # `pane run` were two SEPARATE synchronous calls with --pane-file published
  # in between.
  [ -z "${HD_RUN_SLEEP:-}" ] || sleep "$HD_RUN_SLEEP"
  cwd="$(printf '%s' "$1" | sed -n "s/^cd '\([^']*\)'.*/\1/p")"
  marker="$(sed -n "s/.*touch '\([^']*\)'.*/\1/p" "$cwd/.claude/settings.local.json")"
  slug="$(printf '%s' "$cwd" | sed 's/[/.]/-/g')"
  mkdir -p "$HOME/.claude/projects/$slug"
  # Every turn is a NEW claude session, so every turn writes a NEW
  # transcript: reusing one name left each later run with nothing the
  # new-session glob could resolve, i.e. the very empty-transcript hole this
  # suite now asserts is fail-closed.
  hn="$(cat "$HDLOG.n" 2>/dev/null || printf 0)"; hn=$((hn + 1)); printf '%s\n' "$hn" >"$HDLOG.n"
  sid=test-sid; [ "$hn" -gt 1 ] && sid="test-sid-$hn"
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
  fi
}
case "${1:-} ${2:-}" in
  "worktree show") printf '{"ok":false,"error":{"message":"selector_not_found"}}\n'; exit 1 ;;
  "terminal create")
    n="$(cat "$HDLOG.tn" 2>/dev/null || printf 0)"; n=$((n + 1)); printf '%s\n' "$n" >"$HDLOG.tn"
    h="term$n"; t="tab$n"
    : >"$ORCA_HANDLES/$h"
    printf '{"ok":true,"result":{"terminal":{"handle":"%s","tabId":"%s"}}}\n' "$h" "$t"
    [ -n "$cmd" ] && ( simulate_turn "$cmd" </dev/null >/dev/null 2>&1 & )
    exit 0 ;;
  "terminal close")
    [ "$term" = "${ORCA_STICKY:-}" ] || rm -f "$ORCA_HANDLES/$term"
    echo "CLOSE-TERM $term" >>"$HDLOG"
    printf '{"ok":true,"result":{}}\n'; exit 0 ;;
  "terminal show")
    if [ -f "$ORCA_HANDLES/$term" ]; then
      printf '{"ok":true,"result":{"terminal":{"connected":true}}}\n'; exit 0
    fi
    printf '{"ok":false,"error":{"message":"terminal_not_found"}}\n'; exit 1 ;;
esac
exit 0
EOF
chmod +x "$stub/orca"

pf="$TMP/prompt.md"
printf 'review this\n' >"$pf"

out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r1)"
assert_contains "$out" '"event":"transcript"' "transcript announced"
assert_contains "$out" '"event":"done","status":"ok"' "turn ends ok via Stop-hook marker"
assert_contains "$out" '"session_id":"test-sid"' "session id from transcript name"
assert_contains "$out" '"source":"transcript"' "an ok turn names where its payload came from"

log="$(cat "$HDLOG")"
assert_contains "$log" "terminal create" "the pane is placed through orca terminal create"
assert_contains "$log" "--title crew:" "the terminal is titled for the fleet"
assert_contains "$log" "ac-ship" "default kind=ship names the terminal (no tab/pane rename surface under orca)"

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

# --kind names the caller in the terminal's title; orca has no separate
# tab/pane rename surface (that was herdr's own naming scheme, retired).
: >"$HDLOG"
PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --kind qa --label q1 >/dev/null
assert_contains "$(cat "$HDLOG")" "ac-qa" "kind=qa names the terminal"
assert_contains "$log" "AC_HOME=" "the caller's fleet home is pinned onto the pane shell"

git -C "$repo" checkout -q main
assert_contains "$log" "claude --permission-mode auto" "claude launched in the pane"
assert_file "$repo/.claude/settings.local.json" "stop hook installed"
case "$log" in *"--model"*) fail "no model anywhere must pass no --model" ;; esac
case "$log" in *"--effort"*) fail "no effort anywhere must pass no --effort" ;; esac

# --replace-pane retires the PREVIOUS turn's terminal once the new one is up,
# and REPORTS whether that took. It stays best-effort and never fatal - the
# new pane is already placed - but a supersede that silently left the old
# agent alive against the same task-scoped resources is the orphan class this
# reporting exists to make visible.
: >"$HDLOG"
out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r-rep --replace-pane pOLD)"
assert_contains "$(cat "$HDLOG")" "terminal close --terminal pOLD" "--replace-pane closes the superseded terminal"
assert_contains "$out" '"event":"replace-pane","pane":"pOLD","closed":true' "a supersede that took is reported closed"
assert_contains "$out" '"event":"done","status":"ok"' "the new turn still completes normally"
# A superseded terminal orca refused to close is reported NOT closed, and the
# turn is still a success - the caller decides what to do about the survivor.
: >"$ORCA_HANDLES/pSTUCK"
: >"$HDLOG"
out="$(PATH="$stub:$PATH" HOME="$FAKEHOME" ORCA_STICKY=pSTUCK "$BIN/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label r-rep2 --replace-pane pSTUCK)"
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
case "$(cat "$pane_file" 2>/dev/null || true)" in
  term*\ tab*) ;;
  *) fail "--pane-file publishes pane and tab before turn completion (got: $(cat "$pane_file" 2>/dev/null || true))" ;;
esac
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
case "$(cat "$HDLOG")" in *"terminal create"*) fail "invalid effort must be refused before a pane is placed" ;; esac
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
case "$(cat "$HDLOG")" in *"terminal create"*) fail "an unarmed harness must be refused before a pane is placed" ;; esac

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
case "$(cat "$HDLOG")" in *"terminal create"*) fail "an unresolvable profile must place no pane" ;; esac
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
assert_contains "$(cat "$HDLOG")" "terminal create" "the lane's pane is placed like any other"
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
cat >"$nstub/orca" <<'EOF'
#!/usr/bin/env bash
echo "orca $*" >>"$HDLOG"
cmd="" term=""
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in
    --command) i=$((i+1)); cmd="${args[$i]}" ;;
    --terminal) i=$((i+1)); term="${args[$i]}" ;;
  esac
  i=$((i+1))
done
case "${1:-} ${2:-}" in
  "worktree show") printf '{"ok":false,"error":{"message":"selector_not_found"}}\n'; exit 1 ;;
  "terminal create")
    printf '{"ok":true,"result":{"terminal":{"handle":"pP1","tabId":"tP"}}}\n'
    # the turn ENDS (marker touched) but no transcript is ever written
    cwd="$(printf '%s' "$cmd" | sed -n "s/^cd '\([^']*\)'.*/\1/p")"
    marker="$(sed -n "s/.*touch '\([^']*\)'.*/\1/p" "$cwd/.claude/settings.local.json")"
    touch "$marker"
    exit 0 ;;
  "terminal read")
    out="" sep=""
    while IFS= read -r l; do out="$out$sep\"$l\""; sep=","; done <"${SCROLLBACK:-/dev/null}"
    printf '{"ok":true,"result":{"terminal":{"tail":[%s]}}}\n' "$out" ;;
esac
exit 0
EOF
chmod +x "$nstub/orca"
export SCROLLBACK=/dev/null
out="$(PATH="$nstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo2" --prompt-file "$pf" --label nofile 2>&1 || true)"
case "$out" in *'"status":"ok"'*) fail "an unresolvable transcript must never report ok" ;; esac
assert_contains "$out" '"event":"done"' "the refusal still speaks the done protocol"
assert_contains "$out" '"status":"error"' "an unharvestable turn is a protocol error"
assert_fails env PATH="$nstub:$PATH" HOME="$FAKEHOME" \
  "$BIN/ac-pane-agent.sh" run --cwd "$repo2" --prompt-file "$pf" --label nofile2

# A SUCCESSFUL scrollback harvest is usable AND marked: the payload is written
# as a one-message transcript - the exact jsonl shape transcriptFinal
# already parses - so ac-ship.sh/ac-qa.sh read the verdict from the same
# `transcript` path, and "source":"scrollback" tells them which harvest ran.
printf 'verdict: passed - harvested from the pane\n' >"$TMP/scrollback.txt"
export SCROLLBACK="$TMP/scrollback.txt"
out="$(PATH="$nstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$repo2" --prompt-file "$pf" --label sb)"
assert_contains "$out" '"status":"ok"' "a scrollback harvest completes the turn"
assert_contains "$out" '"source":"scrollback"' "the payload is marked scrollback-sourced"
tr_path="$(printf '%s\n' "$out" | sed -n 's/.*"transcript":"\([^"]*\)".*/\1/p' | tail -1)"
assert_contains "$(tfinal "$tr_path")" \
  "verdict: passed - harvested from the pane" "the caller's own transcript reader finds the scrollback verdict"

# --- fail-closed harvest: a turn that ended on a bare tool_use ----------------
# The MARKER arm is where real rounds end - measured over the 477 stored
# codereview rounds in both fleet homes, the idle fallback below ran 3 times and
# every other round, passing and failing alike, ended here. Its own comment
# already declares the contract ("FAIL CLOSED: the turn ended, so a payload is
# owed"), but the code guarded an empty transcript PATH while the caller asks a
# different question six lines later: transcriptFinal (src/lib.ts)
# takes the LAST assistant message, and a session that stopped after a completed
# tool call has one carrying only tool_use. The pane reported ok, the caller then
# died on "transcript has no final message", and the previous round's receipt sat
# on disk looking current.
repo3="$(make_repo toolend)"
tstub="$TMP/toolend-bin"; mkdir -p "$tstub"
cat >"$tstub/orca" <<'EOF'
#!/usr/bin/env bash
echo "orca $*" >>"$HDLOG"
cmd=""
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in --command) i=$((i+1)); cmd="${args[$i]}" ;; esac
  i=$((i+1))
done
case "${1:-} ${2:-}" in
  "worktree show") printf '{"ok":false,"error":{"message":"selector_not_found"}}\n'; exit 1 ;;
  "terminal create")
    printf '{"ok":true,"result":{"terminal":{"handle":"pP1","tabId":"tP"}}}\n'
    # The turn ENDS on the Stop-hook marker, and the transcript it leaves behind
    # is the shape a session killed mid-pass leaves: assistant text EARLIER in the
    # turn, then a bare tool_use as the LAST assistant message.
    cwd="$(printf '%s' "$cmd" | sed -n "s/^cd '\([^']*\)'.*/\1/p")"
    marker="$(sed -n "s/.*touch '\([^']*\)'.*/\1/p" "$cwd/.claude/settings.local.json")"
    slug="$(printf '%s' "$cwd" | sed 's/[/.]/-/g')"
    mkdir -p "$HOME/.claude/projects/$slug"
    t="$HOME/.claude/projects/$slug/toolend-sid.jsonl"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"reading the sources"}]}}' >"$t"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}' >>"$t"
    printf '%s\n' '{"type":"user","message":{"content":[{"type":"tool_result","content":"..."}]}}' >>"$t"
    touch "$marker"
    exit 0 ;;
  "terminal read") printf '{"ok":true,"result":{"terminal":{"tail":[]}}}\n' ;;
esac
exit 0
EOF
chmod +x "$tstub/orca"
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
assert_eq "$(tfinal "$tr_path")" ""   "transcriptFinal finds no final message in exactly the transcript the pane refused"

# close verb retires the pane; bad args fail with a protocol error event.
: >"$HDLOG"
PATH="$stub:$PATH" "$BIN/ac-pane-agent.sh" close --pane pP1
assert_contains "$(cat "$HDLOG")" "terminal close --terminal pP1" "close verb"
out="$(PATH="$stub:$PATH" "$BIN/ac-pane-agent.sh" run --prompt-file "$pf" 2>&1 || true)"
assert_contains "$out" '"status":"error"' "missing cwd is a protocol error"
out="$(PATH="$stub:$PATH" "$BIN/ac-pane-agent.sh" bogus 2>&1 || true)"
assert_contains "$out" '"status":"error"' "unknown verb rejected"

# --- no AC_HOME: fixed group label, nothing written into the checkout ----------
# Pane agents are launched from crewmate panes, which carry no AC_HOME by
# design (ac-qa.sh header). ac_home() then answers the checkout that owns bin/
# - a pool worktree, or the distro repo - and the group used to be named after
# its basename with the knob persisted into a config/ dir minted right there.
# Run from a COPY of bin/ so the assertions can never touch the real checkout.
fake="$TMP/fakecheckout"
mkdir -p "$fake/bin" "$fake/src"
cp "$BIN/ac-lib.sh" "$BIN/ac-harness.sh" "$BIN/ac-backend.sh" "$BIN/ac-backend-orca.sh" "$BIN/ac-pane-agent.sh" "$BIN/ac-dispatch-select.sh" "$BIN/ac-bun.sh" "$fake/bin/"
cp "$ROOT/src/dispatch-select.ts" "$ROOT"/src/lib*.ts "$ROOT/src/backlog.ts" "$ROOT/src/pane-agent.ts" "$fake/src/"
: >"$HDLOG"
env -u AC_HOME PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label nohome >/dev/null
assert_contains "$(cat "$HDLOG")" "terminal create" "no AC_HOME: the pane still places, homeless"
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
: >"$HDLOG"
env -u AC_HOME AC_FLEET_NAME=drydock PATH="$stub:$PATH" HOME="$FAKEHOME" \
  "$fake/bin/ac-pane-agent.sh" run --cwd "$repo" --prompt-file "$pf" --label told >/dev/null
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
case "$(cat "$HDLOG")" in *"terminal create"*) fail "a threaded unarmed harness must place no pane" ;; esac

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
cat >"$cstub/orca" <<'EOF'
#!/usr/bin/env bash
cmd=""
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in --command) i=$((i+1)); cmd="${args[$i]}" ;; esac
  i=$((i+1))
done
case "${1:-} ${2:-}" in
  "worktree show") printf '{"ok":false,"error":{"message":"selector_not_found"}}\n'; exit 1 ;;
  "terminal create")
    printf '{"ok":true,"result":{"terminal":{"handle":"pP1","tabId":"tP"}}}\n'
    cwd="$(printf '%s' "$cmd" | sed -n "s/^cd '\([^']*\)'.*/\1/p")"
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
      | sed "s/^touch '//;s/'\$//" | while read -r m; do touch "$m"; done
    exit 0 ;;
esac
exit 0
EOF
chmod +x "$cstub/orca"
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

# --- reap: the dead-cwd sweep does not apply to orca; its panes reap by handle (reap-pane) --------------
# `reap` never reads an argument and never touches any backend: it always
# answers the fixed note below and exits 0 - reap-pane (next) is how an orca
# pane agent is actually retired.
out="$("$BIN/ac-pane-agent.sh" reap)"
assert_eq "$out" '{"event":"reap","note":"the dead-cwd sweep does not apply to orca; its panes reap by handle (reap-pane)"}' \
  "reap is a fixed no-op note"
out="$("$BIN/ac-pane-agent.sh" reap --dry-run --an-otherwise-unknown-arg)"
assert_eq "$out" '{"event":"reap","note":"the dead-cwd sweep does not apply to orca; its panes reap by handle (reap-pane)"}' \
  "reap never reads its args, not even an unknown one"

# --- reap-pane: retire ONE known orca terminal, VERIFYING the close -------------
# Targets a KNOWN pane id: closes it through orca `terminal close`, then
# VERIFIES by polling `terminal show` up to eight times 0.25s apart while it
# stays connected, and reports whichever way it landed.
make_fake_orca
mk_term() {  # mk_term <handle> - a live orca terminal the stub answers for.
  : >"$FAKE_ORCA/terminals/$1.buf"; : >"$FAKE_ORCA/terminals/$1.in"
  printf 'tab-%s\n' "$1" >"$FAKE_ORCA/terminals/$1.tab"
}

mk_term pT
: >"$FAKE_ORCA/log"
out="$("$BIN/ac-pane-agent.sh" reap-pane --pane pT)"
assert_contains "$(cat "$FAKE_ORCA/log")" "orca terminal close --terminal pT" "reap-pane closes the target terminal"
assert_contains "$out" '"event":"reap-pane-done"' "reap-pane emits its done event"
assert_contains "$out" '"pane":"pT"' "the event names the pane"
assert_contains "$out" '"closed":true' "reap-pane VERIFIES the close and reports it took"
[ ! -f "$FAKE_ORCA/terminals/pT.buf" ] || fail "a closed terminal must not survive"

# No pane id -> a clean no-op, exit 0.
set +e
out="$("$BIN/ac-pane-agent.sh" reap-pane)"
rc=$?
set -e
assert_eq "$rc" "0" "reap-pane with no pane id is a clean no-op"
assert_contains "$out" '"note":"no pane id"' "reap-pane notes the missing pane id"

# Best-effort and trap-safe: a pane id orca never heard of (already gone, or a
# stranger) still exits 0 and is reported closed - nothing left to verify.
set +e
out="$("$BIN/ac-pane-agent.sh" reap-pane --pane pGONE)"
rc=$?
set -e
assert_eq "$rc" "0" "reap-pane exits 0 even for an unknown pane"
assert_contains "$out" '"closed":true' "an already-gone terminal reports closed"

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
  "the payload is wrapped in the one-message shape transcriptFinal parses"
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
# The real orca terminal mechanics (title/agentIdentity liveness, composer
# send/enter, idle wait) are the shared make_fake_orca fixture's own job -
# reimplementing that here would just re-litigate it with less rigor. This
# wraps it ONLY to run a terminal's --command (which make_fake_orca's own
# `create` does not execute): everything else passes straight through.
make_fake_orca
mv "$TMP/stubbin/orca" "$TMP/stubbin/orca.real"
cat >"$TMP/stubbin/orca" <<EOF
#!/usr/bin/env bash
cmd="" rest=()
args=("\$@"); i=0
while [ \$i -lt \${#args[@]} ]; do
  case "\${args[\$i]}" in
    --command) i=\$((i+1)); cmd="\${args[\$i]}" ;;
    *) rest+=("\${args[\$i]}") ;;
  esac
  i=\$((i+1))
done
echo "orca \$*" >>"$HDLOG"
out="\$("$TMP/stubbin/orca.real" "\${rest[@]}")"
printf '%s\n' "\$out"
if [ "\$1 \$2" = "terminal create" ] && [ -n "\$cmd" ]; then
  h="\$(printf '%s' "\$out" | sed -n 's/.*"handle":"\([^"]*\)".*/\1/p')"
  printf '%s\n' "\$cmd" >>"$HDLOG.cmd"
  ORCA_HANDLE="\$h" sh -c "\$cmd" >/dev/null 2>&1 &
fi
EOF
chmod +x "$TMP/stubbin/orca"
# The fake harness IS a crewmate: it comes up (claiming its own terminal's
# title, which flips harnessUp off the shell default), waits for its typed
# instruction (flushed into the SAME terminal's .buf by the real make_fake_orca
# send+enter), writes the verdict where told, then announces completion with
# the exact command the instruction named. Fault-injection files drive the
# failure legs.
cat >"$kstub/codex" <<'EOF'
#!/usr/bin/env bash
echo "codex $*" >>"$CLOG"
d="$CSTATE"
t="$FAKE_ORCA/terminals/$ORCA_HANDLE"
[ -f "$d/die-at-launch" ] && exit 9
printf 'codex\n' >"$t.title"
printf 'codex\n' >"$t.agent"
printf 'codex ready\n' >>"$t.buf"
for _ in $(seq 1 400); do grep -q 'touch ' "$t.buf" 2>/dev/null && break; sleep 0.05; done
line="$(tr '\n' ' ' <"$t.buf")"
vf="$(printf '%s' "$line" | sed -n 's/.*WRITE it to the file \([^ ]*\).*/\1/p' | head -1)"
mk="$(printf '%s' "$line" | sed -n "s/.*command: touch '\([^']*\)'.*/\1/p" | head -1)"
[ -f "$d/no-verdict" ] || printf '%s\n' "${CVERDICT:-verdict: passed - written by the crewmate}" >"$vf"
[ -f "$d/no-announce" ] || touch "$mk"
exec sleep "${CSLEEP:-5}"
EOF
cp "$kstub/codex" "$kstub/opencode"
chmod +x "$kstub/codex" "$kstub/opencode"
crepo="$(make_repo crewarm)"
creset() { rm -f "$cstate"/*; : >"$HDLOG"; : >"$HDLOG.cmd"; : >"$CLOG"; rm -rf "$FAKE_ORCA/terminals"; mkdir -p "$FAKE_ORCA/terminals"; : >"$FAKE_ORCA/.n"; }
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
buf="$(cat "$FAKE_ORCA/terminals/term1.buf")"
assert_contains "$buf" "$pf" "the typed line points the agent at the prompt file"
assert_contains "$buf" "WRITE it to the file" "the typed line redirects the final message to a file"
assert_contains "$buf" "this exact command: touch '" "the typed line names the completion announcement, path quoted so it stays runnable"
# The verdict file IS the final message, read back through the caller's own
# reader - so ac-ship.sh/ac-qa.sh parse it exactly as they parse a claude turn.
tr_path="$(printf '%s\n' "$out" | sed -n 's/.*"event":"done".*"transcript":"\([^"]*\)".*/\1/p')"
assert_contains "$(tfinal "$tr_path")" \
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

# PROCESS-UP IS NOT INPUT-READY. A live harness process can hold the pane
# while its TUI is still rendering and has no composer yet. Typing during that
# window is dropped; worse, the boot render itself keeps changing, so the
# generic render-change submit verifier can mistake that unrelated redraw for
# an accepted prompt. This is the live Kimi K3 failure: the pane stayed idle
# with an empty composer until the caller's 180s timeout, while the same
# prompt sent after the TUI was ready worked immediately. The gate (pane-agent
# run's readiness loop) is the SAME for every crewmate harness: idle AND a
# non-blank render held stable three reads running, before anything is typed.
#
# make_fake_orca's own delay-ready-secs knob models exactly this: a spinner
# title (not idle) and dropped sends until the clocked delay elapses, then the
# idle glyph. creset leaves the next terminal deterministically named term1.
creset
: >"$FAKE_ORCA/terminals/term1.delay-ready-secs"; printf '1\n' >"$FAKE_ORCA/terminals/term1.delay-ready-secs"
out="$(PATH="$kstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$crepo" \
  --prompt-file "$pf" --timeout 20 --harness opencode --kind qa --label c2-ready 2>&1 || true)"
assert_contains "$out" '"event":"done","status":"ok"' \
  "an OpenCode verifier waits for its input surface before delivering the prompt"
assert_contains "$(cat "$FAKE_ORCA/terminals/term1.buf")" "$pf" \
  "the readiness-gated kickoff reaches the OpenCode transcript"

# If the input surface never becomes ready, the verifier fails closed with the
# readiness diagnosis and types nothing. It must not degrade back to the
# generic full-turn timeout that hid the live failure.
creset
printf '9999\n' >"$FAKE_ORCA/terminals/term1.delay-ready-secs"
out="$(PATH="$kstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$crepo" \
  --prompt-file "$pf" --timeout 2 --harness opencode --kind qa --label c2-not-ready 2>&1 || true)"
assert_contains "$out" '"status":"error"' \
  "an OpenCode verifier fails closed when its input surface never becomes ready"
assert_contains "$out" "input surface did not become ready" \
  "the refusal names input readiness instead of reporting a generic turn timeout"
case "$(cat "$HDLOG")" in *"terminal send"*"--text"*) \
  fail "a verifier with no input-ready evidence must type no kickoff" ;; esac

# The SAME gate binds the codex arm too (the two harnesses share one
# readiness loop in the pane agent).
creset
printf '1\n' >"$FAKE_ORCA/terminals/term1.delay-ready-secs"
out="$(PATH="$kstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$crepo" \
  --prompt-file "$pf" --timeout 20 --harness codex --kind codereview --label c-ready 2>&1 || true)"
assert_contains "$out" '"event":"done","status":"ok"' \
  "a codex verifier waits for its input surface before delivering the prompt"
assert_contains "$(cat "$FAKE_ORCA/terminals/term1.buf")" "$pf" \
  "the readiness-gated kickoff reaches the codex transcript"

creset
printf '9999\n' >"$FAKE_ORCA/terminals/term1.delay-ready-secs"
out="$(PATH="$kstub:$PATH" HOME="$FAKEHOME" "$BIN/ac-pane-agent.sh" run --cwd "$crepo" \
  --prompt-file "$pf" --timeout 2 --harness codex --kind codereview --label c-not-ready 2>&1 || true)"
assert_contains "$out" '"status":"error"' \
  "a codex verifier fails closed when its input surface never becomes ready"
assert_contains "$out" "input surface did not become ready" \
  "the refusal names input readiness instead of reporting a generic turn timeout"
case "$(cat "$HDLOG")" in *"terminal send"*"--text"*) \
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
case "$(cat "$HDLOG")" in *"terminal create"*) fail "a refused --resume must place no pane" ;; esac

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
cat >"$istub/orca" <<'EOF'
#!/usr/bin/env bash
echo "orca $*" >>"$HDLOG"
cmd=""
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in --command) i=$((i+1)); cmd="${args[$i]}" ;; esac
  i=$((i+1))
done
case "${1:-} ${2:-}" in
  "worktree show") printf '{"ok":false,"error":{"message":"selector_not_found"}}\n'; exit 1 ;;
  "terminal create")
    # The idle glyph title is BOTH harnessUp's and orcaAgentIdle's "up and
    # idle" signal: this models a pane that is live and idle, never a Stop
    # hook firing.
    printf '{"ok":true,"result":{"terminal":{"handle":"pP1","tabId":"tP"}}}\n'
    # A pane whose Stop hook stayed SILENT and then went idle: a transcript
    # with final assistant text, backdated past the mtime gate, and NO
    # marker. A fresh session id per leg, so the next leg's new-session glob
    # still resolves it.
    cwd="$(printf '%s' "$cmd" | sed -n "s/^cd '\([^']*\)'.*/\1/p")"
    slug="$(printf '%s' "$cwd" | sed 's/[/.]/-/g')"
    n="$(cat "$HDLOG.i" 2>/dev/null || printf 0)"; n=$((n + 1)); printf '%s\n' "$n" >"$HDLOG.i"
    mkdir -p "$HOME/.claude/projects/$slug"
    t="$HOME/.claude/projects/$slug/idle-sid-$n.jsonl"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"reading the sources"}]}}' >"$t"
    # A turn that DIED mid-pass: its last assistant message carries a tool_use
    # and no text, exactly what a session killed after a Read leaves behind.
    [ -f "$HDLOG.toolend" ] && printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{}}]}}' >>"$t"
    [ -z "${IDLE_TX:-}" ] || cp "$IDLE_TX" "$t"
    touch -t 200001010000 "$t"
    exit 0 ;;
  "terminal show") printf '{"ok":true,"result":{"terminal":{"connected":true,"title":"\xe2\x9c\xb3 fake"}}}\n' ;;
  "terminal read") printf '{"ok":true,"result":{"terminal":{"tail":["idle pane scrollback"]}}}\n' ;;
esac
exit 0
EOF
chmod +x "$istub/orca"
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
# anywhere, while transcriptFinal (src/lib.ts) takes the LAST
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

# A malformed AC_PANE_SETTLE_TRIES (an identifier) used to skip the whole
# retry loop - zero re-reads instead of the documented default (6), though
# the one check after the loop still ran. Count the settle sleeps through a
# logging stub (same transcript-never-settles setup as idle-toolend above).
settlelog="$TMP/settle.log"
settlestub="$TMP/settle-bin"; mkdir -p "$settlestub"
printf '#!/usr/bin/env bash\necho "$*" >>"%s"\nexit 0\n' "$settlelog" >"$settlestub/sleep"
chmod +x "$settlestub/sleep"
settlerun() { PATH="$settlestub:$istub:$PATH" HOME="$FAKEHOME" AC_PANE_SETTLE_SLEEP=0.313 "$BIN/ac-pane-agent.sh" run --cwd "$irepo" --prompt-file "$pf" --timeout 20 "$@" 2>&1; }
: >"$HDLOG.toolend"
# Count only the settle's OWN sleeps (its distinctive AC_PANE_SETTLE_SLEEP),
# never the main poll loop's unrelated "2" pauses through the same stub.
: >"$settlelog"
out="$(AC_PANE_SETTLE_TRIES=3 settlerun --label settle-valid)" || true
assert_eq "$(grep -cFx 0.313 "$settlelog")" "3" "AC_PANE_SETTLE_TRIES=3 retries exactly three times"
: >"$settlelog"
out="$(AC_PANE_SETTLE_TRIES=abc settlerun --label settle-malformed)" || true
assert_eq "$(grep -cFx 0.313 "$settlelog")" "6" "a malformed AC_PANE_SETTLE_TRIES falls back to its documented default (6), never zero retries"
rm -f "$HDLOG.toolend"

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
cat >"$sstub/orca" <<'EOF'
#!/usr/bin/env bash
cmd=""
args=("$@"); i=0
while [ $i -lt ${#args[@]} ]; do
  case "${args[$i]}" in --command) i=$((i+1)); cmd="${args[$i]}" ;; esac
  i=$((i+1))
done
case "${1:-} ${2:-}" in
  "worktree show") printf '{"ok":false,"error":{"message":"selector_not_found"}}\n'; exit 1 ;;
  "terminal create")
    printf '{"ok":true,"result":{"terminal":{"handle":"pP1","tabId":"tP"}}}\n'
    cwd="$(printf '%s' "$cmd" | sed -n "s/^cd '\([^']*\)'.*/\1/p")"
    slug="$(printf '%s' "$cwd" | sed 's/[/.]/-/g')"
    mkdir -p "$HOME/.claude/projects/$slug"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}' \
      >"$HOME/.claude/projects/$slug/stall-sid.jsonl"
    exit 0 ;;
  # A spinner-glyph title is backendAgentStatusPane's orca "working" (busy):
  # not a shell, not the idle glyph, and agentIdentity/agentWait stay null so
  # orcaAgentIdle's screen-stability leg (codex-only) never fires either.
  "terminal show") printf '{"ok":true,"result":{"terminal":{"connected":true,"title":"\xe2\x97\x90 fake"}}}\n' ;;
  "terminal read") printf '{"ok":true,"result":{"terminal":{"tail":["Working..."]}}}\n' ;;
esac
exit 0
EOF
chmod +x "$sstub/orca"
src=0; out="$(AC_PANE_STALL_MAX=1 PATH="$nosleep:$sstub:$PATH" HOME="$FAKEHOME" \
  "$BIN/ac-pane-agent.sh" run --cwd "$srepo" --prompt-file "$pf" --label stall --timeout 60 2>&1)" || src=$?
assert_contains "$out" '"status":"error"' "a stalled busy pane escalates instead of burning the caller's timeout"
assert_contains "$out" "no transcript progress" "the escalation names the stall"
assert_contains "$out" "agent_status=working" "the escalation carries the busy status for diagnosis"
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
# AC_PANE_STALL_MAX's malformed-value fallback (to the documented default,
# 2700, same strictDecimal(x) ?? default shape as AC_PANE_SETTLE_TRIES
# above) proven end to end without a real 2700s wait: a `date +%s` stub
# answers the run's FIRST call (waitStart) far in the future - past any real
# file mtime, so the stall check's own mtime-floor is deterministic - then
# jumps once, for good, past the fallback bound; a fixed two-value answer,
# never an accelerating one, so an extra call can only repeat the jumped
# value, never spin. `timeout` is still the outer backstop. A FRESH repo
# (never srepo): newestNew() excludes every name that existed in its
# transcript dir before this run started, and srepo's dir already holds
# stall-sid.jsonl from the two legs above - reusing it would leave this
# leg's own transcript un-announced, spinning on "pane get" forever.
sfbrepo="$(make_repo stallfb2)"
sdate="$TMP/stall-date-bin"; mkdir -p "$sdate"
cat >"$sdate/date" <<EOF
#!/usr/bin/env bash
if [ -e "$TMP/stall-date.seen" ]; then
  echo 10000004999
else
  : >"$TMP/stall-date.seen"
  echo 9999999999
fi
EOF
chmod +x "$sdate/date"
src=0; out="$(AC_PANE_STALL_MAX=abc PATH="$sdate:$nosleep:$sstub:$PATH" HOME="$FAKEHOME" \
  timeout 15 "$BIN/ac-pane-agent.sh" run --cwd "$sfbrepo" --prompt-file "$pf" --label stall-fallback --timeout 20000 2>&1)" || src=$?
assert_contains "$out" "no transcript progress for over 2700s" "a malformed AC_PANE_STALL_MAX falls back to the documented default, 2700 - never a 1s/0 bound"
assert_contains "$out" "agent_status=working" "the fallback escalation still carries the busy status for diagnosis"
assert_eq "$src" "1" "the fallback bound escalates, exiting non-zero"

# --- the entry end to end against modelled backends, one scenario per row -----
# ONE world path ($XW) rebuilt by the row's own setup before the row runs - a git
# repo at $XW/cwd (one commit, one identity and date, branch main, its
# info/exclude), the prompt at $XW/pf, HOME=$XW/hd (its .claude.json),
# AC_CLAUDE_TRANSCRIPT_ROOT=$XW/tr, AC_FLEET_STATE=$XW/st, TMPDIR=$XW/tmp,
# XSTUB=$XW/stub (the stubs' answer files, state and logs), AC_HOME=$XW/home
# only where a row homes it. The env: the rest of the AC_* family unset unless a
# row names it (AC_SEND_SETTLE=0 and AC_STARTUP_DIALOG_BUDGET=2 from
# helpers.sh); cwd $XW/cwd; stdin /dev/null; LC_ALL=C unless a row names
# en_US.UTF-8. PATH: the leg's stubs (a logging herdr and orca answering from
# the world and modelling the pane - a session `pane run` writing the
# transcript and touching the Stop hook's marker, a composer whose Enter makes
# the crewmate write its verdict and announce - logging fakes of every harness
# CLI, `od` with fixed bytes, a no-op `sleep` unless a row runs real time, a
# `date +%s` that ticks one second per call from one instant) ahead of the suite's PATH, whose refusing
# stand-ins catch anything the stubs do not model. A row reads each call's
# exit, stdout and stderr (the k-th entry pid PID<k>, a marker's age, the bin
# root ROOT), the stub logs and the world: every path under $XW but stub/ and
# tmp/ with its mode and bytes (the repo as its info/exclude).
cd "$TMP" || fail "cd TMP"
XW="$TMP/xw"; XSTUBS="$TMP/xstubs"; XNOSLEEP="$TMP/xnosleep"
mkdir -p "$XSTUBS" "$XNOSLEEP"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' >"$TMP/xgitconfig"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/xgitconfig" \
  GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
# The pane model both backend stubs share: `session <launch line>` is a claude
# turn (the transcript written, the Stop hook's marker touched), `enter` flushes
# the composer and, for a crewmate's typed line, writes the verdict where told
# and touches the announced marker - each step skipped by its fault file.
# `ruled` frames a pending composer between two rules, the shape orca's
# pending check reads (bin/ac-backend-orca.sh orca_composer_pending).
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
    [ ! -s "$d/in" ] || { [ ! -e "$d/ruled" ] || echo '────────────'; printf '> '; cat "$d/in"; echo; [ ! -e "$d/ruled" ] || echo '────────────'; } ;;
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
  if [ -e "$d/$f.out" ] || [ -e "$d/$f.rc" ] || [ -e "$d/$f.sleep" ]; then
    [ ! -e "$d/$f.sleep" ] || /bin/sleep "$(cat "$d/$f.sleep")"
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
# own write error would land in the entry's stderr when the kill caught it in a
# read.
case "$*" in
  +%s) n="$(cat "$XSTUB/date.n" 2>/dev/null || echo 0)"; echo "$((n + 1))" >"$XSTUB/date.n"; echo "$((1767225600 + n))" 2>/dev/null ;;
  *) exec /bin/date "$@" ;;
esac
STUB
printf '#!/bin/sh\nexit 0\n' >"$XNOSLEEP/sleep"
chmod +x "$XSTUBS"/* "$XNOSLEEP/sleep"

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
xc() {  # xc <args...> - one pane-agent call, its transcript appended
  # AC_BACKEND is NOT in the -u list below: it rides the no-config default
  # (orca) unless a row's own XENV names a backend, which then overrides it
  # in e[] below.
  local rc=0 x v
  local e=("LC_ALL=$XLC" "PATH=$(xpath)" "HOME=$XW/hd" "TMPDIR=$XW/tmp" "XSTUB=$XW/stub"
    "AC_CLAUDE_TRANSCRIPT_ROOT=$XW/tr" "AC_FLEET_STATE=$XW/st")
  [ -z "$XHOME" ] || e+=("AC_HOME=$XW/home")
  for x in ${XENV[@]+"${XENV[@]}"}; do v="${x#*=}"; e+=("${x%%=*}=${v//@W/$XW}"); done
  local a=(); for x in "$@"; do a+=("${x//@W/$XW}"); done
  (cd "$XW/$XCWD" && exec env -u AC_HOME -u AC_FLEET_STATE -u AC_SCOPE -u AC_SOLO -u AC_HERDR_SESSION \
    -u AC_HERDR_RPC_TIMEOUT -u AC_WINDOW_FAMILY -u AC_FLEET_NAME -u CLAUDE_CONFIG_DIR -u AC_PANE_STALL_MAX \
    -u AC_PANE_SETTLE_TRIES -u AC_PANE_SETTLE_SLEEP -u AC_PANE_SCROLLBACK_LINES -u AC_LOCK_STALE_GRACE -u CDPATH \
    -u EPOCHSECONDS "${e[@]}" /bin/sh -c 'printf "%s\n" "$$" >>"$0"; exec "$@"' "$TMP/xpids" \
    "$BIN/ac-pane-agent.sh" ${a[@]+"${a[@]}"}) <"$XIN" >"$TMP/x.out" 2>"$TMP/x.err" || rc=$?
  { printf '== %s\nrc=%s\n-- out\n' "$*" "$rc"; cat "$TMP/x.out"; printf -- '-- err\n'; cat "$TMP/x.err"; } >>"$TMP/xt"
}
# An async job of this shell starts with SIGINT and SIGQUIT ignored, so the
# background call restores both before it execs the entry, in a group of its
# own.
xbg() {  # xbg <signal> <wait-for text in a stub log> <args...> - one call in the background, signalled once the stubs logged <text>
  # AC_BACKEND stays out of -u here too - see xc's comment above.
  local sig="$1" want="$2" rc=0 pid i=0; shift 2
  (cd "$XW/$XCWD" && exec env -u AC_HOME -u AC_FLEET_STATE -u AC_SCOPE -u AC_SOLO -u AC_HERDR_SESSION \
    -u AC_WINDOW_FAMILY -u AC_FLEET_NAME -u CLAUDE_CONFIG_DIR -u AC_PANE_STALL_MAX -u CDPATH \
    "LC_ALL=$XLC" "PATH=$(xpath)" "HOME=$XW/hd" "TMPDIR=$XW/tmp" "XSTUB=$XW/stub" "AC_CLAUDE_TRANSCRIPT_ROOT=$XW/tr" \
    "AC_FLEET_STATE=$XW/st" ${XENV[@]+"${XENV[@]}"} perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; setpgrp(0, 0); exec @ARGV' "$BIN/ac-pane-agent.sh" "$@") \
    </dev/null >"$TMP/x.out" 2>"$TMP/x.err" &
  pid=$!
  printf '%s\n' "$pid" >>"$TMP/xpids"
  while ! grep -qF -- "$want" "$XW/stub/orca.log" "$XW/stub/harness.log" 2>/dev/null && [ "$i" -lt 200 ]; do /bin/sleep 0.05; i=$((i + 1)); done
  case "$sig" in -*) kill "-${sig#-}" -- "-$pid" 2>/dev/null ;; *) kill "-$sig" "$pid" 2>/dev/null ;; esac
  wait "$pid" 2>/dev/null || rc=$?
  { printf '== %s %s\nrc=%s\n-- out\n' "$sig" "$*" "$rc"; cat "$TMP/x.out"; printf -- '-- err\n'; cat "$TMP/x.err"; } >>"$TMP/xt"
}
xnorm() {  # xnorm <file> - the k-th entry pid PID<k>, a marker's age, the bin root ROOT
  local e=() k=0 p
  while IFS= read -r p; do [ -z "$p" ] || { k=$((k + 1)); e+=(-e "s/(^|[^0-9])$p([^0-9]|\$)/\\1PID$k\\2/g"); }; done <"$TMP/xpids"
  LC_ALL=C sed -E ${e[@]+"${e[@]}"} -e 's/arrived -?[0-9]+s ago/arrived Ns ago/' -e "s#$ROOT#ROOT#g" "$1"
}
xsnap() {  # xsnap - the world as one listing (the repo as its info/exclude, bun's own cache under HOME skipped), then the stub logs
  local f
  (cd "$XW" && find . \( -path ./stub -o -path ./tmp -o -path ./cwd/.git -o -path ./hd/Library \) -prune -o -print | LC_ALL=C sort) >"$TMP/xnames"
  while IFS= read -r f; do
    [ "$f" != . ] || continue
    if [ -L "$XW/$f" ]; then printf '== %s -> %s\n' "$f" "$(readlink "$XW/$f")"; continue; fi
    printf '== %s %s\n' "$f" "$(stat -f %Sp "$XW/$f")"
    [ -d "$XW/$f" ] || { cat "$XW/$f" 2>/dev/null || printf '<unreadable>'; printf '\n'; }
  done <"$TMP/xnames" >"$TMP/xsnap"
  { printf -- '-- exclude\n'; cat "$XW/cwd/.git/info/exclude" 2>/dev/null || true
    for f in herdr.log orca.log harness.log buf; do printf -- '-- %s\n' "$f"; cat "$XW/stub/$f" 2>/dev/null || true; done
  } >>"$TMP/xsnap"
}
xone() {  # xone <setup> <body> - rebuild the world, then the body's calls (shell text), the transcript and the world normalised
  : >"$TMP/xt"; : >"$TMP/xpids"
  xworld; eval "$1"; eval "$2"; xsnap
  xnorm "$TMP/xt" >"$TMP/xt2"; xnorm "$TMP/xsnap" >"$TMP/xsnap2"
}
xrow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this assertion
xt() { cat "$TMP/xt2"; }
xhas() { assert_contains "$(xt)" "$1" "pane-agent at line $(xrow)"; }   # xhas <text> - in the row's calls
xlacks() { case "$(xt)" in *"$1"*) fail "pane-agent at line $(xrow): '$1' found" ;; esac; }
xwhas() { assert_contains "$(cat "$TMP/xsnap2")" "$1" "pane-agent world at line $(xrow)"; }
xwlacks() { case "$(cat "$TMP/xsnap2")" in *"$1"*) fail "pane-agent world at line $(xrow): '$1' found" ;; esac; }
xnone() { :; }
xerr() { sed -n '/^-- err$/,$p' "$TMP/xt2" | sed 1d; }   # xerr - a one-call row's stderr
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

xrc() { xhas "rc=$1"$'\n-- out'; }   # xrc <status> - a call of the row exited <status>

# 1. Preamble and usage: no verb or an unknown one is the usage done error, an
#    invalid backend refuses first on every verb, a valueless flag names
#    itself, HOME unset and a bun-less PATH refuse.
xone xnone 'xc'
xrc 1; xhas '{"event":"done","status":"error","error":"usage: ac-pane-agent.sh run --cwd DIR --prompt-file F"}'
xone xnone 'xc bogus --pane p1'
xrc 1; xhas '{"event":"done","status":"error","error":"usage: ac-pane-agent.sh run --cwd DIR --prompt-file F"}'
xone xnone 'xc run'
xrc 1; xhas '{"event":"done","status":"error","error":"cwd missing: "}'
for v in "close --pane p1" "bogus --agent a hi" "reap-pane --pane p1" "reap" "run --cwd @W/cwd"; do
  XENV=(AC_BACKEND=tmux); xone xnone "xc $v"; XENV=()
  assert_eq "$(xerr)" "ERROR: unsupported backend 'tmux' (valid backend: orca)" "an invalid backend refuses first: $v"
  xrc 1; xwlacks '[pane] [run]'
done
for v in "run --cwd" "run --cwd @W/cwd --timeout ''"; do
  xone xnone "xc $v"
  xrc 1; xhas "needs a value"; xwlacks '[pane] [run]'
done
for v in "close --pane" "reap-pane --pane ''"; do
  xone xnone "xc $v"
  assert_eq "$(xerr)" "ERROR: --pane needs a value" "a valueless --pane is named: $v"
  xwlacks '[pane] [close]'
done
rc=0; out="$(cd "$TMP" && env -u HOME -u AC_HOME "PATH=$XSTUBS:$XNOSLEEP:$PATH" "$BIN/ac-pane-agent.sh" close --pane p1 2>&1)" || rc=$?
assert_eq "$rc:$out" "1:ERROR: HOME is not set" "HOME unset refuses"
XPATH="$(xwithout bun)"; xone xnone 'xc close --pane p1'; XPATH=""
xrc 1; assert_eq "$(xerr)" "ERROR: required tool not found: bun" "the shim refuses without bun"

# 2. run refusals in order, before any pane or rung; the profile rungs and the
#    ladders, as the harness CLI receives them; effort.
xone xnone 'xrun --exec --resume s1 --pane-file @W/pf.pane'
xrc 1; xhas '"error":"--exec runs a one-shot command: there is no session to --resume"'
xone xnone 'xrun --exec --pane-file @W/pf.pane'
xrc 1; xhas '"error":"--exec places no pane: there is no identity to write to --pane-file"'
for k in Bad 'a b' 'x/y' 'q_r'; do
  xone xnone "xrun --kind '$k'"
  xrc 1; xhas "\"error\":\"kind must be [a-z0-9-]: $k\""; xwlacks '[pane] [run]'
done
xbadjson() { xput home/config/crew-dispatch.json '{oops\n'; }
XHOME=1; xone xbadjson 'xrun --exec --kind codereview'; XHOME=""
xrc 1; xhas "\"error\":\"could not resolve a pane profile for kind 'codereview' ("; xhas ') - see bin/ac-dispatch-select.sh --pane codereview"'
xprof() { xput home/config/crew-dispatch.json '{"panes":{"codereview":{"harness":"codex","model":"m1","effort":"high"},"qa":{"harness":"pi"}}}\n'; }
XHOME=1
xone xprof 'xrun --exec --kind codereview'
xrc 0; xwhas 'codex [exec] [-s] [read-only] [--skip-git-repo-check] [-m] [m1] [-c] [model_reasoning_effort=high] [-c] [model_reasoning_summary=auto] [review this]'
xone xprof 'xrun --exec --kind qa --model mine'
xrc 0; xwhas 'pi [-p] [--model] [mine] [review this]'
xknobs() { xput home/config/qa-model 'cm\n'; xput home/config/qa-agent 'opencode\n'; xput home/config/effort 'low\n'; xput home/config/model 'fm\n'; }
xone xknobs 'xrun --exec --kind qa'
xrc 0; xwhas 'opencode [run] [-m] [cm] [--variant] [low] [review this]'
xone xknobs 'xrun --exec --kind gate'
xrc 0; xwhas 'claude [-p] [--model] [fm] [--effort] [low] [review this]'
xone xknobs 'xrun --exec --kind qa --harness claude'
xrc 0; xwhas $'-- harness.log\nclaude [-p] [review this]\n'
XHOME=""
XENV=(AC_FLEET_MODEL_QA=em AC_FLEET_AGENT_QA=codex AC_FLEET_EFFORT_QA=max); xone xnone 'xrun --exec --kind qa'; XENV=()
xrc 0; xwhas 'codex [exec] [-s] [read-only] [--skip-git-repo-check] [-m] [em] [-c] [model_reasoning_effort=max] [-c] [model_reasoning_summary=auto] [review this]'
XENV=(AC_FLEET_MODEL=fm AC_FLEET_EFFORT=high)
xone xnone 'xrun --exec --kind gate --harness claude'
xrc 0; xwhas $'-- harness.log\nclaude [-p] [review this]\n'
xone xnone 'xrun --exec --kind gate --harness claude --model m2'
xrc 0; xwhas $'-- harness.log\nclaude [-p] [--model] [m2] [review this]\n'
XENV=()
XENV=('AC_FLEET_PROFILE_CODEREVIEW=harness=codex model=gpt 5 effort=high'); xone xnone 'xrun --exec --kind codereview'; XENV=()
xrc 0; xwhas 'codex [exec] [-s] [read-only] [--skip-git-repo-check] [-m] [gpt'; xwhas '[-c] [model_reasoning_effort=high]'
XENV=($'AC_FLEET_PROFILE_CODEREVIEW=harness=opencode\tmodel=\teffort='); xone xnone 'xrun --exec --kind codereview'; XENV=()
xrc 0; xwhas $'-- harness.log\nopencode [run] [review this]\n'
xone xnone 'xrun --exec --harness claude --effort ultracode'
xrc 0; xwhas 'claude [-p] [--effort] [xhigh] [review this]'
xone xnone 'xc run --cwd @W/cwd --prompt-file @W/nope'
xrc 1; xhas "\"error\":\"prompt file missing: $XW/nope\""

# 3. SESSION, backend-neutral mechanics: a Stop hook that cannot be
#    installed, a lock another live pid holds, a ~/.claude.json that is no
#    object, the exclude lines, ENVPIN, --pane-file's directory, and the
#    --timeout grammar - none of this depends on which backend places the
#    pane, so it runs once, under the ambient (orca) default. The herdr-only
#    placement/label naming and AC_HERDR_SESSION this row used to cover have
#    no orca counterpart and are retired with herdr; the orca placement,
#    label and home-arm equivalents are row 4, next.
xsettingsdir() { mkdir -p "$XW/cwd/.claude/settings.local.json"; }
xone xsettingsdir 'xrun'
xrc 1; xhas "{\"event\":\"done\",\"status\":\"error\",\"error\":\"could not install the Stop hook into $XW/cwd/.claude/settings.local.json\"}"; xwlacks '[terminal] [create]'
xlockheld() { mkdir -p "$XW/cwd/.claude/.ac-pane-agent.lock"; printf '%s\n' "$$" >"$XW/cwd/.claude/.ac-pane-agent.lock/pid"; }
xone xlockheld 'xrun'
xrc 0; xhas '"event":"done","status":"ok"'
assert_eq "$(cat "$XW/cwd/.claude/.ac-pane-agent.lock/pid")" "$$" "a lock held by a live pid is left to its holder"
xtrustbad() { xput hd/.claude.json '[1]'; }
xone xtrustbad 'xrun'
xrc 0; assert_eq "$(cat "$XW/hd/.claude.json")" "[1]" "a ~/.claude.json that is no object is left as it was"
xexcl() { printf '.claude/settings.local.json\n' >>"$XW/cwd/.git/info/exclude"; }
xone xexcl 'xrun'
assert_eq "$(grep -c '^\.claude/' "$XW/cwd/.git/info/exclude")" 2 "a line the exclude already holds is not appended again"
xone 'rm -rf "$XW/cwd/.git/info"' 'xrun'
assert_eq "$(cat "$XW/cwd/.git/info/exclude")" $'.claude/settings.local.json\n.claude/.ac-pane-agent.lock' "a missing info/ gets both exclude lines"
XENV=(AC_FLEET_NAME=fl CLAUDE_CONFIG_DIR=@W/cfg); xone xnone 'xrun'; XENV=()
xwhas "[cd '$XW/cwd' && CLAUDE_CONFIG_DIR=$XW/cfg CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 AC_FLEET_NAME=fl claude --permission-mode auto"
xone xnone 'xrun --pane-file @W/nodir/pane'
xrc 1; xhas "{\"event\":\"done\",\"status\":\"error\",\"error\":\"pane-file directory does not exist: $XW/nodir\"}"
# Q3: every --timeout but a sign and decimal digits is refused before any pane
# or rung.
for t in abc 1+1 0x3 1.5 10m ' 5'; do
  xone 'xs no-marker' "xrun --timeout '$t'"
  xrc 1; xhas "\"error\":\"timeout must be a whole number of seconds: $t\""
  xwlacks '[terminal] [create]'
done

# 4. SESSION on orca: the worker placement, a terminal that disconnects,
#    --replace-pane, a placement that fails, and the home arm.
XENV=(AC_BACKEND=orca)
xone xnone 'xrun'
xrc 0; xhas '"event":"done","status":"ok"'; xhas '"pane":"h1"'
xwhas "orca [terminal] [create] [--worktree] [path:$XW/cwd] [--title] [crew:agent-crew/ac-ship] [--command] [cd '$XW/cwd' && CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 claude --permission-mode auto"
xone 'xs no-marker; printf "%s\n" h1 >"$XW/stub/closed"' 'xrun --timeout 40'
xrc 1; xhas '"status":"pane_closed"'; xhas '"error":"pane closed while turn in flight"'
# A leading-zero --timeout (048, 0100) used to read octal in the deadline's
# own arithmetic and end the run bare exit 1 with no event printed, AFTER
# the pane was already placed - these must still reach the SAME pane_closed
# verdict as any other timeout, never a silent bare exit. Comparable to the
# 40s above, not a tight bound: this races the real poll cycle against
# wall-clock time, and a short bound flakes under host load.
for lz in 048 0100; do
  xone 'xs no-marker; printf "%s\n" h1 >"$XW/stub/closed"' "xrun --timeout $lz"
  xrc 1; xhas '"status":"pane_closed"'; xhas '"error":"pane closed while turn in flight"'
done
xone xnone 'xrun --replace-pane hOld'
xrc 0; xhas '{"event":"replace-pane","pane":"hOld","closed":true}'; xwhas 'orca [terminal] [close] [--terminal] [hOld] [--json]'
xone 'xs terminal-create.rc 1' 'xrun'
xrc 1; xhas '{"event":"done","status":"error","error":"could not place orca pane"}'
XHOME=1; XCWD=home; XENV=(AC_BACKEND=orca AC_WINDOW_FAMILY=fam1)
xone 'git -C "$XW/home" init -q' 'xc run --cwd @W/home --prompt-file @W/pf --label h1 --kind learning'
XHOME=""; XCWD=cwd; XENV=()
xrc 0; xhas '"event":"done","status":"ok"'
xwhas "[--title] [crew:home/ac-learning] [--command] [cd '$XW/home' && CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 AC_HOME=$XW/home claude --permission-mode auto"

# The idle fallback (herdr idle|done; orca idle) is the SAME exit on either
# backend - prove it reaches orca too. `xs no-marker` suppresses the stub's
# own turn-end marker, so the only way this run can still end `ok` is the
# idle-fallback path itself; its own `idle-fallback used` note is what
# distinguishes that from a run that never got there.
XENV=(AC_BACKEND=orca)
xone 'xs no-marker; xs backdate; xs transcript "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"final\"}]}}\n"' \
  'xrun --timeout 400'
xrc 0; xhas '{"event":"note","path":"idle-fallback used (agent_status=idle)"}'; xhas '"event":"done","status":"ok"'
XENV=()

# 5. CREWMATE: each harness's TUI launch, a bare shell that never came up, an
#    unreadable pane, a named startup dialog answered automatically, the
#    input-ready wait cut at the deadline, the stranded kickoff, an empty
#    verdict, and the never-ready surface.
xcrew() { xs run.mode crew; }
xone xcrew 'xrun --harness codex --kind codereview --model gpt-5.6-sol --effort xhigh'
xrc 0; xhas '"source":"file","pane":"h1"'
xwhas "[cd '$XW/cwd' && CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 codex -c check_for_update_on_startup=false -m gpt-5.6-sol -c model_reasoning_effort=xhigh; printf %s \$? >"
xwhas "orca [terminal] [send] [--terminal] [h1] [--text] [Read and follow the instructions in $XW/pf."
xone xcrew 'xrun --harness opencode --model m1 --effort high'
xrc 0; xwhas "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 opencode -m m1; printf"
xone xcrew 'xrun --harness pi --model m1 --effort high'
xrc 0; xwhas "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 pi --tui-mode regular --model m1 --thinking high; printf"
xone xcrew 'xrun --harness cursor --model m1 --effort high'
xrc 0; xwhas "CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1 cursor-agent --yolo --model m1; printf"
xone 'xcrew; xs terminal-show.out "{\"ok\":true,\"result\":{\"terminal\":{\"connected\":true,\"title\":\"zsh\"}}}\n"' 'xrun --harness codex'
xrc 1; xhas "\"error\":\"harness 'codex' did not come up in its pane within 60s - every foreground process is a shell, so no prompt is delivered and the turn is REFUSED\""
xwlacks '[terminal] [send]'
xone 'xcrew; xs terminal-show.rc 1' 'xrun --harness codex'
xrc 1; xhas '{"event":"note","path":"could not read the pane to verify codex came up - delivering the prompt anyway"}'
xhas "\"error\":\"harness 'codex' came up but its input surface did not become ready within 60s - no prompt was delivered\""
# A dialog orca can NAME is answered on its own - no blind key, unlike the
# retired herdr arm's registry guess.
xone 'xcrew; xs terminal-show.2.out "{\"ok\":true,\"result\":{\"terminal\":{\"connected\":true,\"title\":\"codex\",\"agentIdentity\":\"codex\",\"agentWait\":{\"reason\":\"codex-update-prompt\"}}}}\n"' 'xrun --harness codex'
xrc 0; xhas '"source":"file"'; xwhas 'orca [terminal] [send] [--terminal] [h1] [--text] [2] [--json]'
xone 'xcrew; xs render.n 0' 'xrun --harness codex --timeout 8'
xrc 1; xhas "\"error\":\"harness 'codex' came up but its input surface did not become ready within 7s - no prompt was delivered\""
xone 'xcrew; xs strand; xs ruled' 'xrun --harness codex'
xrc 1; xhas "\"error\":\"the verification prompt was NOT accepted by the pane of 'codex' (stranded in its composer, or a dialog owns the pane), so no turn will ever start - REFUSED rather than waited out\""
xone 'xcrew; xs empty-verdict' 'xrun --harness opencode'
xrc 1; xhas "\"error\":\"verification agent 'opencode' produced no verdict: the agent announced its turn but left no verdict at $XW/st/.pane-agent-tmp/ac-pane-verdict.cwd.PID1\""
xone 'xcrew; xs terminal-show.out "{\"ok\":true,\"result\":{\"terminal\":{\"connected\":true,\"title\":\"codex\",\"agentIdentity\":\"codex\",\"agentWait\":{\"reason\":\"other\"}}}}\n"' 'xrun --harness codex --timeout 20'
xrc 1; xhas "\"error\":\"harness 'codex' came up but its input surface did not become ready within 19s - no prompt was delivered\""

# 6. ONE-SHOT: pi's and cursor's forms with and without a model and an effort,
#    the rung dying without its marker, and the rung's INT/QUIT dispositions.
xone xnone 'xrun --exec --harness pi --kind gate --model m1 --effort high'
xrc 0; xwhas 'pi [-p] [--model] [m1] [--thinking] [high] [review this]'
xone xnone 'xrun --exec --harness pi --kind gate'
xrc 0; xwhas $'-- harness.log\npi [-p] [review this]\n'
xone xnone 'xrun --exec --harness cursor --kind gate --model m1 --effort high'
xrc 0; xwhas 'cursor-agent [-p] [--trust] [--model] [m1] [review this]'
xone xnone 'xrun --exec --harness cursor --kind gate'
xrc 0; xwhas $'-- harness.log\ncursor-agent [-p] [--trust] [review this]\n'
xdeadsh() { mkdir -p "$XW/stub/shbin"; printf '#!/bin/sh\nexit 3\n' >"$XW/stub/shbin/sh"; chmod +x "$XW/stub/shbin/sh"; }
XPATH="$XW/stub/shbin:$XSTUBS:$XNOSLEEP:$PATH"; xone xdeadsh 'xrun --exec --harness codex --kind gate'; XPATH=""
xrc 1; xhas '"error":"the one-shot process died without ending its turn - no marker, no output to harvest"'
xone 'xs signals' 'xrun --exec --harness codex --kind gate'
xrc 0; xwhas 'INT=IGNORE QUIT=IGNORE'

# 7. close, reap-pane and reap: close with no pane and close past an unknown
#    word, reap-pane taken and not, reap's no-op note regardless of its args.
xone xnone 'xc close'
xrc 0; assert_eq "$(xerr)" "" "close with no pane is silent"; xwlacks '[close]'
xone xnone 'xc close --pane h1 --bogus'
xrc 0; xwhas 'orca [terminal] [close] [--terminal] [h1] [--json]'
xone xnone 'xc reap-pane --pane h1'
xrc 0; xhas '{"event":"reap-pane-done","pane":"h1","closed":true}'
xone 'xs sticky h1' 'xc reap-pane --pane h1'
xrc 0; xhas '{"event":"reap-pane-done","pane":"h1","closed":false}'
xone xnone 'xc reap --bogus'
xrc 0; xhas '{"event":"reap","note":"the dead-cwd sweep does not apply to orca; its panes reap by handle (reap-pane)"}'

# 8. Signals: TERM and HUP end the run at once (143, 129), the pane or the
#    rung left running; INT to the pid alone ends it 130 with no done event; a
#    group INT leaves the rung, which ignores it.
# The stub's `terminal create` holds 3 s, so the signal lands while the entry
# waits on it.
xstall() { xs no-marker; xs terminal-create.sleep 3; }
xone xstall "xbg TERM '[terminal] [create]' run --cwd $XW/cwd --prompt-file $XW/pf --label r1 --timeout 100000"
xhas 'rc=143'; xlacks '"event":"done"'
xone xstall "xbg HUP '[terminal] [create]' run --cwd $XW/cwd --prompt-file $XW/pf --label r1 --timeout 100000"
xhas 'rc=129'; xlacks '"event":"done"'
xslowrung() { xs answer.sleep 1; }
xone xslowrung "xbg TERM 'codex [exec]' run --cwd $XW/cwd --prompt-file $XW/pf --exec --harness codex --kind gate --timeout 100000; /bin/sleep 2"
xhas 'rc=143'; xwhas '{"verdict":"approve"}'
XPATH="$XSTUBS:$PATH"
xone xstall "xbg INT '[terminal] [create]' run --cwd $XW/cwd --prompt-file $XW/pf --label r1 --timeout 4"
xhas 'rc=130'; xlacks '"event":"done"'
xone xslowrung "xbg -INT 'codex [exec]' run --cwd $XW/cwd --prompt-file $XW/pf --exec --harness codex --kind gate --timeout 100000; /bin/sleep 2"
xhas 'rc=130'; xwhas '{"verdict":"approve"}'
XPATH=""

# 9. The helper subcommands are verbs reached through the shim.
xone xnone 'xc iso-epoch 2026-01-01T00:00:00Z; xc seed-trust @W/cwd; xc has-final-text @W/nope'
xhas $'== iso-epoch 2026-01-01T00:00:00Z\nrc=0\n-- out\n1767225600\n'
xhas $'== seed-trust @W/cwd\nrc=0\n'
xhas $'== has-final-text @W/nope\nrc=1\n'
xlacks '"error":"usage'

pass
