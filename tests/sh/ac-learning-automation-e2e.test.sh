#!/usr/bin/env bash
# ac-learning-automation-e2e.test.sh - due Learning runs automatically gate and
# apply exact fleet-local candidates without an `approved:` compatibility token.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

command -v jq >/dev/null || skip 'jq not available'
# shellcheck source=../../bin/ac-lib.sh
. "$BIN/ac-lib.sh"
make_home

stub="$TMP/pane-agent"
export AUTO_LOG="$TMP/auto.log"
cat >"$stub" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = reap-pane ]; then exit 0; fi
printf 'pane-agent %s\n' "$*" >>"$AUTO_LOG"
kind=""; cwd=""; prompt=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --kind) kind="$2"; shift 2 ;;
    --cwd) cwd="$2"; shift 2 ;;
    --prompt-file) prompt="$2"; shift 2 ;;
    *) shift ;;
  esac
done
case "$kind" in
  learning)
    cat >"$cwd/report.md" <<'REPORT'
# Learning Report
One candidate is supported by the pending source.
REPORT
    if [ -z "${OMIT_RETRO:-}" ]; then
      cat >"$cwd/retro.md" <<'RETRO'
# Retro
The same procedural lesson recurred.
RETRO
    fi
    if [ -n "${RULE_CANDIDATE:-}" ]; then
      cat >"$cwd/candidate-standing-rule.md" <<'RULECAND'
kind: rule
===rule===
- 2026-07-26: STANDING (captain): keep the fleet-local store authoritative.
RULECAND
    else
      cat >"$cwd/candidate-auto-skill.md" <<'CANDIDATE'
kind: skill
name: auto-skill
description: Apply the automatically distilled fleet procedure.
trigger: applying the distilled fleet procedure
===sources===
2026-07-26	auto	- LESSON: automate this recurring fleet procedure.
===skill===
# auto-skill

Apply the recurring fleet procedure.
CANDIDATE
    fi
    printf '{"event":"done","status":"ok","transcript":"/dev/null","pane":"learning-pane"}\n'
    ;;
  gate)
    [ -z "${GATE_UNAVAILABLE:-}" ] || exit 1
    decision="${GATE_DECISION:-continue}"
    transcript="$cwd/data/gate-transcript-$$.jsonl"
    # An honest judge does exactly this: take the two paths out of the prompt,
    # open both files, and quote what only a reader of them has.
    manifest="$(sed -n 's/^- INPUT MANIFEST: //p' "$prompt" | head -1)"
    plan="$(sed -n 's/^- ACTION PLAN: //p' "$prompt" | head -1)"
    quote="$(awk '{ if (length($0) > length(best)) best = $0 } END { print best }' "$manifest")"
    prun="$(dirname "$plan")"
    [ "$(basename "$prun")" != plans ] || prun="$(dirname "$prun")"
    payload="$(awk '{ if (length($0) > length(best)) best = $0 } END { print best }' \
      "$prun/$(jq -r '.actions[0].staged' "$plan")")"
    jq -cn --arg d "$decision" --arg q "$quote" --arg p "$payload" \
      --arg s "$(jq -r '.actions[0].new_sha256' "$plan")" \
      '{type:"assistant",message:{content:[{type:"text",text:("# Maintenance Gate Decision\n## Decision\n"+$d+"\n## Grounds\nThe immutable candidate and recoverable action plan agree.\n## Inputs Read\n- INPUT MANIFEST QUOTE: "+$q+"\n- ACTION PLAN NEW SHA-256: "+$s+"\n- STAGED PAYLOAD QUOTE: "+$p+"\n## Proposed Process\nApply only this hash-bound plan through the maintenance transaction.\n")} ]}}' \
      >"$transcript"
    printf '{"event":"done","status":"ok","transcript":"%s","pane":"gate-pane"}\n' "$transcript"
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$stub"

printf '## 2026-07-26 - family (chief)\n- LESSON: automate this recurring fleet procedure.\n' \
  >"$AC_HOME/records/learnings.md"
printf '%s\n' '- 2026-07-20: one-time fleet cleanup. [COMPLETED 2026-07-21]' \
  >"$AC_HOME/records/captain.md"
printf 'debriefs=8\ngeneration=0\n' >"$AC_HOME/state/.learn.meta"
printf '1\n' >"$AC_HOME/config/curate-every"

out="$(AC_PANE_AGENT="$stub" "$BIN/ac-learn.sh" run)"
assert_contains "$out" "auto-applied: auto-skill" "continue automatically applies the candidate"
assert_file "$AC_HOME/skills/auto-skill/SKILL.md" "automatic Learning writes the fleet-local skill"
grep -q '^approved:' "$AC_HOME"/data/learning-*/candidates/auto-skill.md \
  && fail "automatic apply must not authenticate with a legacy approved token"
grep -qF -- '- [distilled -> auto-skill] sources=1 updated=2026-07-26' \
  "$AC_HOME/records/learnings.md" || fail "automatic apply writes one canonical pointer"
grep -qF -- '- LESSON: automate this recurring fleet procedure.' \
  "$AC_HOME/records/learnings-archive/auto-skill.md" \
  || fail "automatic apply archives the source verbatim"
receipt="$(find "$AC_HOME/data" -path '*/gates/auto-skill/decision.md' | head -1)"
assert_file "$receipt" "automatic candidate has a durable maintenance-gate receipt"
assert_contains "$(cat "$receipt")" 'decision: "continue"' "continue receipt authorizes apply"
grep -R -q '^status=complete$' "$AC_HOME/state/.maintenance-transactions" \
  || fail "automatic apply commits a completed transaction journal"
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "0" \
  "completed automatic cycle resets its captured cadence generation"
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "0" \
  "a due Curate cycle auto-runs and resets after the Learning tick"
grep -qF 'one-time fleet cleanup' "$AC_HOME/records/captain-archive.md" \
  || fail "due automatic Curate compacts an explicitly completed captain rule"
case "$(cat "$AUTO_LOG")" in
  *"--kind qa"*|*" test "*) fail "Learning automation must not invoke QA or unit tests" ;;
esac

# A revise decision preserves the raw source and applies nothing.
rm -rf "$AC_HOME/data"/learning-* "$AC_HOME/skills/auto-skill" \
  "$AC_HOME/records/learnings-archive"
printf '## 2026-07-26 - family (chief)\n- LESSON: automate this recurring fleet procedure.\n' \
  >"$AC_HOME/records/learnings.md"
printf 'debriefs=8\ngeneration=1\n' >"$AC_HOME/state/.learn.meta"
GATE_DECISION=revise AC_PANE_AGENT="$stub" \
  "$BIN/ac-learn.sh" run >/dev/null
assert_no_file "$AC_HOME/skills/auto-skill/SKILL.md" "revise applies no candidate"
grep -qF -- '- LESSON: automate this recurring fleet procedure.' \
  "$AC_HOME/records/learnings.md" || fail "revise preserves the pending source"

# A standing-rule candidate is captain-owned and escalates instead of applying.
# The escalation's links are what the captain clicks, so `candidate=` must name
# the immutable copy the plan was actually built from - the preparer mints a
# rule subject of its own, so a path rebuilt from the caller's subject misses.
rm -rf "$AC_HOME/data"/learning-* "$AC_HOME/data/learning"
printf 'debriefs=8\ngeneration=2\n' >"$AC_HOME/state/.learn.meta"
out="$(RULE_CANDIDATE=1 AC_PANE_AGENT="$stub" "$BIN/ac-learn.sh" run)"
assert_contains "$out" "ask-captain:" "a standing-rule candidate never auto-applies"
room="$AC_HOME/data/learning/room.md"
assert_file "$room" "the rule escalation is durable in the learning room"
link="$(grep -o 'candidate=[^;]*' "$room" | tail -1 | sed 's/^candidate=//')"
assert_file "$AC_HOME/$link" "the escalation's candidate= link resolves"

# A run whose scout is incomplete (no retro.md) preserves the retro window
# (examined stays false) and must withhold the automatic Curate too, even
# while Curate is due - a run that does not consume the window must not
# mutate the records the window is resolved from.
rm -rf "$AC_HOME/data"/learning-* "$AC_HOME/data/learning" "$AC_HOME/skills/auto-skill" \
  "$AC_HOME/records/learnings-archive" "$AC_HOME/records/captain-archive.md"
printf '## 2026-07-26 - family (chief)\n- LESSON: automate this recurring fleet procedure.\n' \
  >"$AC_HOME/records/learnings.md"
printf '%s\n' '- 2026-07-20: one-time fleet cleanup. [COMPLETED 2026-07-21]' \
  >"$AC_HOME/records/captain.md"
printf 'debriefs=8\ngeneration=3\n' >"$AC_HOME/state/.learn.meta"
printf 'runs_since=1\n' >"$AC_HOME/state/.curate.meta"
cap_before="$(cat "$AC_HOME/records/captain.md")"
out="$(OMIT_RETRO=1 AC_PANE_AGENT="$stub" "$BIN/ac-learn.sh" run 2>&1)"
assert_contains "$out" "Curate is due" "an incomplete scout warns that a due Curate is withheld"
assert_no_file "$AC_HOME/records/captain-archive.md" \
  "an incomplete scout must not let automatic Curate archive captain.md"
assert_eq "$(cat "$AC_HOME/records/captain.md")" "$cap_before" \
  "an incomplete scout leaves captain.md byte-identical"
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "1" \
  "an incomplete scout must not tick or reset the Curate cadence"

# A complete scout whose maintenance gate could not judge its one subject
# (scoutComplete true, examined false - the other preserving path) likewise
# preserves the retro window and must withhold Curate too.
rm -rf "$AC_HOME/data"/learning-* "$AC_HOME/data/learning" "$AC_HOME/skills/auto-skill" \
  "$AC_HOME/records/learnings-archive" "$AC_HOME/records/captain-archive.md"
printf '## 2026-07-26 - family (chief)\n- LESSON: automate this recurring fleet procedure.\n' \
  >"$AC_HOME/records/learnings.md"
printf '%s\n' '- 2026-07-20: one-time fleet cleanup. [COMPLETED 2026-07-21]' \
  >"$AC_HOME/records/captain.md"
printf 'debriefs=8\ngeneration=4\n' >"$AC_HOME/state/.learn.meta"
printf 'runs_since=1\n' >"$AC_HOME/state/.curate.meta"
cap_before="$(cat "$AC_HOME/records/captain.md")"
out="$(GATE_UNAVAILABLE=1 AC_PANE_AGENT="$stub" "$BIN/ac-learn.sh" run 2>&1)"
assert_contains "$out" "ask-captain:" "an unavailable gate escalates instead of silently continuing"
assert_contains "$out" "Curate is due" "a gate-unjudged run warns that a due Curate is withheld"
assert_no_file "$AC_HOME/records/captain-archive.md" \
  "a gate-unjudged run must not let automatic Curate archive captain.md"
assert_eq "$(cat "$AC_HOME/records/captain.md")" "$cap_before" \
  "a gate-unjudged run leaves captain.md byte-identical"
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "1" \
  "a gate-unjudged run must not tick or reset the Curate cadence"

# An examined run (complete scout, candidate applied) whose learnReset then
# fails - cadence lock held by a live peer - still preserves the retro window
# (debriefs/generation untouched, no last_run), so it is the THIRD
# window-preserving path and must withhold Curate too, even though the scout
# itself was examined.
rm -rf "$AC_HOME/data"/learning-* "$AC_HOME/data/learning" "$AC_HOME/skills/auto-skill" \
  "$AC_HOME/records/learnings-archive" "$AC_HOME/records/captain-archive.md"
printf '## 2026-07-26 - family (chief)\n- LESSON: automate this recurring fleet procedure.\n' \
  >"$AC_HOME/records/learnings.md"
printf '%s\n' '- 2026-07-20: one-time fleet cleanup. [COMPLETED 2026-07-21]' \
  >"$AC_HOME/records/captain.md"
printf 'debriefs=8\ngeneration=5\n' >"$AC_HOME/state/.learn.meta"
printf 'runs_since=1\n' >"$AC_HOME/state/.curate.meta"
cap_before="$(cat "$AC_HOME/records/captain.md")"
mkdir -p "$TMP/fastbin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/fastbin/sleep"
chmod +x "$TMP/fastbin/sleep"
mkdir -p "$AC_HOME/state/.learn-cadence.lock" \
  && printf '%s\n' "$$" >"$AC_HOME/state/.learn-cadence.lock/pid"
out="$(PATH="$TMP/fastbin:$PATH" AC_PANE_AGENT="$stub" "$BIN/ac-learn.sh" run 2>&1)"
ac_lock_release "$AC_HOME/state/.learn-cadence.lock"
assert_contains "$out" "cadence lock was busy" \
  "an examined run whose reset lost the lock reports the lock failure"
assert_contains "$out" "Curate is due" \
  "an examined run whose reset fails warns that a due Curate is withheld"
assert_no_file "$AC_HOME/records/captain-archive.md" \
  "an examined run whose reset fails must not let automatic Curate archive captain.md"
assert_eq "$(cat "$AC_HOME/records/captain.md")" "$cap_before" \
  "an examined run whose reset fails leaves captain.md byte-identical"
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "1" \
  "an examined run whose reset fails must not tick or reset the Curate cadence"
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "8" \
  "an examined run whose reset fails leaves the debrief counter untouched"

pass
