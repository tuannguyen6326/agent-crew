#!/usr/bin/env bash
# ac-dispatch-select.test.sh - dispatch profile resolution: fallback without
# config, default profile, single-profile rules, round-robin list rules,
# --list output, bad indices, the keyed --pane lookup, and ac-spawn's refusal
# to guess.

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

make_home

# No config: fall back to crew-harness (default claude).
assert_eq "$("$BIN/ac-dispatch-select.sh")" "harness=claude model= effort=" "fallback claude"
printf 'codex\n' >"$AC_HOME/config/crew-harness"
assert_eq "$("$BIN/ac-dispatch-select.sh")" "harness=codex model= effort=" "fallback crew-harness"
rm -f "$AC_HOME/config/crew-harness"

# --pane <kind>: the KEYED, judgment-free lookup a pane agent needs. ABSENT
# must be distinguishable from ERROR - absent is the byte-identical-to-today
# path every pane agent falls back to - so it is empty stdout AND exit 0, and
# both halves are asserted (empty stdout alone is also what a die produces).
pane_absent() {
  local out rc=0
  out="$("$BIN/ac-dispatch-select.sh" --pane "$1" 2>/dev/null)" || rc=$?
  assert_eq "$rc" "0" "${2:-absent}: must exit 0, not die"
  assert_eq "$out" "" "${2:-absent}: must print nothing"
}
pane_absent codereview "no config file"

cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{
  "rules": [
    {"when": "needs fresh web context", "use": {"harness": "grok"}},
    {"when": "big ambiguous refactor",
     "use": [{"harness": "claude", "model": "sonnet", "effort": "high"},
             {"harness": "codex", "model": "gpt", "effort": "high"}],
     "select": "quota-balanced"}
  ],
  "default": {"harness": "codex", "model": "gpt", "effort": "medium"}
}
EOF

assert_eq "$("$BIN/ac-dispatch-select.sh")" "harness=codex model=gpt effort=medium" "config default"
assert_eq "$("$BIN/ac-dispatch-select.sh" --rule 1)" "harness=grok model= effort=" "single-profile rule"

r1="$("$BIN/ac-dispatch-select.sh" --rule 2)"
r2="$("$BIN/ac-dispatch-select.sh" --rule 2)"
r3="$("$BIN/ac-dispatch-select.sh" --rule 2)"
assert_eq "$r1" "harness=claude model=sonnet effort=high" "round-robin first"
assert_eq "$r2" "harness=codex model=gpt effort=high" "round-robin second"
assert_eq "$r3" "$r1" "round-robin cycles"

list="$("$BIN/ac-dispatch-select.sh" --list)"
assert_contains "$list" "needs fresh web context" "list shows when clauses"
assert_contains "$list" "claude/codex (balanced)" "list summarizes balanced rules"

assert_fails "$BIN/ac-dispatch-select.sh" --rule 9
# repo-deep-review F23: --rule 0 must refuse, not silently resolve jq's
# negative-index wraparound (.rules[-1] = the LAST rule) - the top-level
# selector is the one path a chief uses for crewmate spawns, and both sibling
# selectors (--pane qa, --pane <k>) already refuse 0/non-numeric.
assert_fails "$BIN/ac-dispatch-select.sh" --rule 0
assert_fails "$BIN/ac-dispatch-select.sh" --rule bogus

# --pane against a config that has rules but NO panes block: still nothing.
# A dispatch table alone never speaks for a verification pane - the rules[]
# `when` clauses are prose a chief judges, and a pane agent cannot judge.
pane_absent codereview "rules but no panes block"

cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{
  "rules": [{"when": "anything", "use": {"harness": "grok"}}],
  "panes": {
    "codereview": {"harness": "claude", "model": "opus", "effort": "xhigh"},
    "qa": {"harness": "codex"},
    "broken": {"model": "opus"}
  },
  "default": {"harness": "codex"}
}
EOF
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane codereview)" \
  "harness=claude model=opus effort=xhigh" "panes entry resolves the whole triple"
# A profile is ATOMIC: an entry naming only a harness resolves with model and
# effort EMPTY, so the consumer launches the harness's own default instead of
# falling through to a claude-shaped one.
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane qa)" "harness=codex model= effort=" \
  "a harness-only entry keeps model and effort empty"
# A kind with no entry is ABSENT, not an error - the same fall-through as no block.
pane_absent learning "a kind with no entry"
# An entry that EXISTS but names no harness is fail-closed: it is a misconfigured
# profile, not an absent one, and silently ignoring it would launch the wrong thing.
assert_fails "$BIN/ac-dispatch-select.sh" --pane broken
assert_fails "$BIN/ac-dispatch-select.sh" --pane

# Routed QA is selected by the execution caller, never by the pane agent.
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{
  "rules": [{"when": "anything", "use": {"harness": "grok"}}],
  "panes": {
    "qa": {
      "rules": [
        {
          "when": "The round needs browser and visual evidence.",
          "use": {"harness": "opencode", "model": "openrouter/qwen/qwen3.7-plus"},
          "why": "Use an image-capable QA profile."
        },
        {
          "when": "The round spans stateful backend dependencies.",
          "use": {"harness": "opencode", "model": "openrouter/z-ai/glm-5.2"},
          "why": "Use a long-horizon backend QA profile."
        }
      ],
      "default": {"harness": "opencode", "model": "openrouter/qwen/qwen3.7-plus"}
    }
  },
  "default": {"harness": "codex"}
}
EOF
pane_absent qa "routed qa without an explicit caller selection"
qa_list="$("$BIN/ac-dispatch-select.sh" --pane qa --list)"
assert_contains "$qa_list" $'1\tThe round needs browser and visual evidence.' \
  "qa list exposes stable 1-based rule numbers and prose"
assert_contains "$qa_list" "openrouter/qwen/qwen3.7-plus" \
  "qa list renders the atomic browser profile"
assert_contains "$qa_list" "Use an image-capable QA profile." \
  "qa list carries the operator-visible why"
assert_contains "$qa_list" $'default\t\topencode openrouter/qwen/qwen3.7-plus\t' \
  "the bare default renders without synthetic when or why"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane qa --rule 2)" \
  "harness=opencode model=openrouter/z-ai/glm-5.2 effort=" \
  "a numbered qa selection resolves only its atomic use object"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane qa --rule default)" \
  "harness=opencode model=openrouter/qwen/qwen3.7-plus effort=" \
  "default is an explicit caller selection"
qa_receipt="$("$BIN/ac-dispatch-select.sh" --pane qa --receipt 1)"
assert_eq "$(jq -r '.rule' <<<"$qa_receipt")" "1" "numbered receipt binds the selector"
assert_eq "$(jq -r '.when' <<<"$qa_receipt")" \
  "The round needs browser and visual evidence." "numbered receipt binds when"
assert_eq "$(jq -r '.use.model' <<<"$qa_receipt")" \
  "openrouter/qwen/qwen3.7-plus" "numbered receipt binds atomic use"
assert_eq "$(jq -r '.why' <<<"$qa_receipt")" \
  "Use an image-capable QA profile." "numbered receipt binds why"
assert_eq "$(jq -r '.dispatch_sha256 | length' <<<"$qa_receipt")" "64" \
  "receipt binds the dispatch config hash"
qa_default_receipt="$("$BIN/ac-dispatch-select.sh" --pane qa --receipt default)"
assert_eq "$(jq -r 'has("when") or has("why")' <<<"$qa_default_receipt")" "false" \
  "default receipt invents no when or why"
assert_fails "$BIN/ac-dispatch-select.sh" --pane qa --rule 0
assert_fails "$BIN/ac-dispatch-select.sh" --pane qa --rule 9

# Static/routed mixing and round-robin QA profiles are invalid before a pane.
jq '.panes.qa.harness = "claude"' "$AC_HOME/config/crew-dispatch.json" \
  >"$AC_HOME/config/crew-dispatch.json.tmp"
mv "$AC_HOME/config/crew-dispatch.json.tmp" "$AC_HOME/config/crew-dispatch.json"
assert_fails "$BIN/ac-dispatch-select.sh" --pane qa --list
jq 'del(.panes.qa.harness) | .panes.qa.rules[0].use = [{"harness":"claude"}]' \
  "$AC_HOME/config/crew-dispatch.json" >"$AC_HOME/config/crew-dispatch.json.tmp"
mv "$AC_HOME/config/crew-dispatch.json.tmp" "$AC_HOME/config/crew-dispatch.json"
assert_fails "$BIN/ac-dispatch-select.sh" --pane qa --list

# --- gate, codereview, roomchief also get the routed `rules` form (captain
# ruling 2026-07-28, routed-pane-rules-for-gate-codereview-roomchief) - but,
# unlike panes.qa above, `default` is MANDATORY once routed, so a caller that
# passes no selector resolves it deterministically instead of dying. panes.qa
# itself stays untouched (asserted above, unaffected by anything below).
rm -f "$AC_HOME/config/crew-dispatch.json"
pane_absent gate "no config file (gate)"
pane_absent codereview "no config file (codereview)"
pane_absent roomchief "no config file (roomchief)"

cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{
  "panes": {
    "gate": {"harness": "codex", "model": "gpt", "effort": "high"},
    "codereview": {"harness": "claude", "model": "opus"},
    "roomchief": {"harness": "claude"}
  }
}
EOF
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane gate)" "harness=codex model=gpt effort=high" \
  "flat panes.gate resolves the whole triple, unchanged"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane codereview)" "harness=claude model=opus effort=" \
  "flat panes.codereview resolves unchanged"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane roomchief)" "harness=claude model= effort=" \
  "flat panes.roomchief resolves unchanged"
pane_absent learning "a kind with no entry stays absent, unaffected by the new kinds"
assert_fails "$BIN/ac-dispatch-select.sh" --pane gate --list
assert_fails "$BIN/ac-dispatch-select.sh" --pane gate --rule 1

# Validation REFUSES a routed panes.<kind> missing `default`, for each of the
# three new kinds.
for k in gate codereview roomchief; do
  cat >"$AC_HOME/config/crew-dispatch.json" <<EOF
{"panes": {"$k": {"rules": [
  {"when": "case one", "use": {"harness": "codex", "model": "m1", "effort": "high"}, "why": "w1"}
]}}}
EOF
  assert_fails "$BIN/ac-dispatch-select.sh" --pane "$k"
  assert_fails "$BIN/ac-dispatch-select.sh" --pane "$k" --list
done

cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{
  "panes": {
    "gate": {
      "rules": [
        {"when": "financial or irreversible risk",
         "use": {"harness": "codex", "model": "gpt-hi", "effort": "xhigh"},
         "why": "max reasoning"},
        {"when": "routine maintenance judgment",
         "use": {"harness": "claude", "model": "opus"},
         "why": "cheaper routine judge"}
      ],
      "default": {"harness": "codex", "model": "gpt-lo", "effort": "high"}
    },
    "codereview": {
      "rules": [
        {"when": "anything", "use": {"harness": "claude", "model": "opus", "effort": "xhigh"}, "why": "strong review"}
      ],
      "default": {"harness": "claude", "model": "sonnet", "effort": "high"}
    },
    "roomchief": {
      "rules": [
        {"when": "anything", "use": {"harness": "claude"}, "why": "n/a"}
      ],
      "default": {"harness": "codex", "model": "", "effort": ""}
    }
  }
}
EOF
# default is mandatory and present -> a lookup with NO selector resolves it
# deterministically instead of dying. This is exactly the shape a
# --system-initiated roomchief promote with no --harness needs
# (bin/ac-learn.sh:1583 - no agent anywhere in the loop to read a `when`).
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane gate)" "harness=codex model=gpt-lo effort=high" \
  "routed panes.gate with no selector resolves the mandatory default"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane codereview)" "harness=claude model=sonnet effort=high" \
  "routed panes.codereview with no selector resolves the mandatory default"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane roomchief)" "harness=codex model= effort=" \
  "routed panes.roomchief with no selector resolves the mandatory default"

gate_list="$("$BIN/ac-dispatch-select.sh" --pane gate --list)"
assert_contains "$gate_list" $'1\tfinancial or irreversible risk' "gate list exposes stable 1-based rule numbers and prose"
assert_contains "$gate_list" $'default\t\tcodex gpt-lo high\t' "gate list always renders the mandatory default"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane gate --rule 2)" "harness=claude model=opus effort=" \
  "a numbered gate selection resolves only its atomic use object"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane gate --rule default)" "harness=codex model=gpt-lo effort=high" \
  "an explicit default selection matches the no-selector fallback"
assert_fails "$BIN/ac-dispatch-select.sh" --pane gate --rule 0
assert_fails "$BIN/ac-dispatch-select.sh" --pane gate --rule 9
assert_fails "$BIN/ac-dispatch-select.sh" --pane gate --receipt 1

assert_eq "$("$BIN/ac-dispatch-select.sh" --pane codereview --rule 1)" "harness=claude model=opus effort=xhigh" \
  "a numbered codereview selection resolves"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane roomchief --rule 1)" "harness=claude model= effort=" \
  "a numbered roomchief selection resolves"

# ac-spawn refuses to guess the harness while dispatch rules exist.
repo="$(make_repo alpha)"
"$BIN/ac-brief.sh" t1 alpha --mode local-only >/dev/null
out="$("$BIN/ac-spawn.sh" t1 "$repo" 2>&1)" && fail "spawn must refuse without --harness under dispatch"
assert_contains "$out" "ac-dispatch-select" "refusal points at the resolver"

pass
