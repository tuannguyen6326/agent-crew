#!/usr/bin/env bash
# ac-learning-automation-e2e.test.sh - due Learning runs automatically gate and
# apply exact fleet-local candidates without an `approved:` compatibility token.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

command -v jq >/dev/null || { printf 'SKIP: jq not available\n'; exit 0; }
# shellcheck source=../bin/ac-lib.sh
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
    cat >"$cwd/retro.md" <<'RETRO'
# Retro
The same procedural lesson recurred.
RETRO
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
    decision="${GATE_DECISION:-continue}"
    transcript="$cwd/data/gate-transcript-$$.jsonl"
    jq -cn --arg d "$decision" \
      '{type:"assistant",message:{content:[{type:"text",text:("# Maintenance Gate Decision\n## Decision\n"+$d+"\n## Grounds\nThe immutable candidate and recoverable action plan agree.\n## Proposed Process\nApply only this hash-bound plan through the maintenance transaction.\n")} ]}}' \
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

out="$(AC_PANE_AGENT="$stub" AC_GATE_WATCH=off "$BIN/ac-learn.sh" run)"
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
GATE_DECISION=revise AC_PANE_AGENT="$stub" AC_GATE_WATCH=off \
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
out="$(RULE_CANDIDATE=1 AC_PANE_AGENT="$stub" AC_GATE_WATCH=off "$BIN/ac-learn.sh" run)"
assert_contains "$out" "ask-captain:" "a standing-rule candidate never auto-applies"
room="$AC_HOME/data/learning/room.md"
assert_file "$room" "the rule escalation is durable in the learning room"
link="$(grep -o 'candidate=[^;]*' "$room" | tail -1 | sed 's/^candidate=//')"
assert_file "$AC_HOME/$link" "the escalation's candidate= link resolves"

pass
