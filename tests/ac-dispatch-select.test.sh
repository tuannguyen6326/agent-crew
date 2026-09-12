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
assert_eq "$("$BIN/ac-dispatch-select.sh")" $'harness=claude\tmodel=\teffort=' "fallback claude"
printf 'codex\n' >"$AC_HOME/config/crew-harness"
assert_eq "$("$BIN/ac-dispatch-select.sh")" $'harness=codex\tmodel=\teffort=' "fallback crew-harness"
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

assert_eq "$("$BIN/ac-dispatch-select.sh")" $'harness=codex\tmodel=gpt\teffort=medium' "config default"
assert_eq "$("$BIN/ac-dispatch-select.sh" --rule 1)" $'harness=grok\tmodel=\teffort=' "single-profile rule"

r1="$("$BIN/ac-dispatch-select.sh" --rule 2)"
r2="$("$BIN/ac-dispatch-select.sh" --rule 2)"
r3="$("$BIN/ac-dispatch-select.sh" --rule 2)"
assert_eq "$r1" $'harness=claude\tmodel=sonnet\teffort=high' "round-robin first"
assert_eq "$r2" $'harness=codex\tmodel=gpt\teffort=high' "round-robin second"
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
  $'harness=claude\tmodel=opus\teffort=xhigh' "panes entry resolves the whole triple"
# A profile is ATOMIC: an entry naming only a harness resolves with model and
# effort EMPTY, so the consumer launches the harness's own default instead of
# falling through to a claude-shaped one.
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane qa)" $'harness=codex\tmodel=\teffort=' \
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
  $'harness=opencode\tmodel=openrouter/z-ai/glm-5.2\teffort=' \
  "a numbered qa selection resolves only its atomic use object"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane qa --rule default)" \
  $'harness=opencode\tmodel=openrouter/qwen/qwen3.7-plus\teffort=' \
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
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane gate)" $'harness=codex\tmodel=gpt\teffort=high' \
  "flat panes.gate resolves the whole triple, unchanged"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane codereview)" $'harness=claude\tmodel=opus\teffort=' \
  "flat panes.codereview resolves unchanged"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane roomchief)" $'harness=claude\tmodel=\teffort=' \
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
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane gate)" $'harness=codex\tmodel=gpt-lo\teffort=high' \
  "routed panes.gate with no selector resolves the mandatory default"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane codereview)" $'harness=claude\tmodel=sonnet\teffort=high' \
  "routed panes.codereview with no selector resolves the mandatory default"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane roomchief)" $'harness=codex\tmodel=\teffort=' \
  "routed panes.roomchief with no selector resolves the mandatory default"

gate_list="$("$BIN/ac-dispatch-select.sh" --pane gate --list)"
assert_contains "$gate_list" $'1\tfinancial or irreversible risk' "gate list exposes stable 1-based rule numbers and prose"
assert_contains "$gate_list" $'default\t\tcodex gpt-lo high\t' "gate list always renders the mandatory default"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane gate --rule 2)" $'harness=claude\tmodel=opus\teffort=' \
  "a numbered gate selection resolves only its atomic use object"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane gate --rule default)" $'harness=codex\tmodel=gpt-lo\teffort=high' \
  "an explicit default selection matches the no-selector fallback"
assert_fails "$BIN/ac-dispatch-select.sh" --pane gate --rule 0
assert_fails "$BIN/ac-dispatch-select.sh" --pane gate --rule 9
assert_fails "$BIN/ac-dispatch-select.sh" --pane gate --receipt 1

assert_eq "$("$BIN/ac-dispatch-select.sh" --pane codereview --rule 1)" $'harness=claude\tmodel=opus\teffort=xhigh' \
  "a numbered codereview selection resolves"
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane roomchief --rule 1)" $'harness=claude\tmodel=\teffort=' \
  "a numbered roomchief selection resolves"

# ac-spawn refuses to guess the harness while dispatch rules exist.
repo="$(make_repo alpha)"
"$BIN/ac-brief.sh" t1 alpha --mode local-only >/dev/null
out="$("$BIN/ac-spawn.sh" t1 "$repo" 2>&1)" && fail "spawn must refuse without --harness under dispatch"
assert_contains "$out" "ac-dispatch-select" "refusal points at the resolver"

# --- LANES: a kind whose entry runs EVERY profile, not one of them ----------
# The third pane shape. A routed `rules[]` picks ONE profile by judgment and a
# flat entry IS one; `lanes` is the opposite instruction - run all of them,
# in the order written - which is why it gets its own key rather than reusing
# the `use[]` list form that means round-robin at the top level.
cat >"$AC_HOME/config/crew-dispatch.json" <<'EOF'
{
  "rules": [{"when": "anything", "use": {"harness": "grok"}}],
  "panes": {
    "codereview": {"harness": "claude", "model": "opus"},
    "codereview-scout": {
      "lanes": [
        {"harness": "codex", "model": "gpt-5.6-sol", "effort": "xhigh"},
        {"harness": "opencode", "model": "qwen3.7-plus"},
        {"harness": "claude", "model": "claude-sonnet-5"}
      ]
    }
  }
}
EOF
lanes="$("$BIN/ac-dispatch-select.sh" --pane codereview-scout --lanes)"
assert_eq "$(printf '%s\n' "$lanes" | wc -l | tr -d ' ')" "3" "one line per lane"
assert_eq "$(printf '%s\n' "$lanes" | sed -n 1p)" $'harness=codex\tmodel=gpt-5.6-sol\teffort=xhigh' "lane 1 resolves its whole triple"
assert_eq "$(printf '%s\n' "$lanes" | sed -n 2p)" $'harness=opencode\tmodel=qwen3.7-plus\teffort=' "lane 2 keeps effort empty"
assert_eq "$(printf '%s\n' "$lanes" | sed -n 3p)" $'harness=claude\tmodel=claude-sonnet-5\teffort=' "lanes come back in the order written"

# A MODEL NAME MAY CARRY SPACES - some harnesses put the reasoning tier inside
# the name rather than on an --effort axis - so the field separator on this wire
# is a TAB. On the space-delimited wire this replaced, every caller's
# `read -r h m e` truncated such a name at its first word and launched a
# different model than the fleet declared, silently.
spacey='Gemini 3.8 Flash (High)'
cat >"$AC_HOME/config/crew-dispatch.json" <<EOF
{
  "panes": {
    "codereview": {"harness": "agy", "model": "$spacey"},
    "codereview-scout": {"lanes": [{"harness": "agy", "model": "$spacey"}]}
  }
}
EOF
for form in "--pane codereview" "--pane codereview-scout --lanes"; do
  # shellcheck disable=SC2086
  line="$("$BIN/ac-dispatch-select.sh" $form)"
  IFS=$'\t' read -r f_h f_m f_e <<EOF
$line
EOF
  assert_eq "${f_h#harness=}" "agy" "$form: the harness survives a TAB split"
  assert_eq "${f_m#model=}" "$spacey" "$form: a model name keeps every space it was declared with"
  assert_eq "${f_e#effort=}" "" "$form: the field AFTER the spaced name is still its own field"
done

# ABSENT stays the OFF switch, exactly as for every other kind: no block, no
# entry, nothing printed, exit 0. Deleting the entry disables the lanes.
rc=0; out="$("$BIN/ac-dispatch-select.sh" --pane learning --lanes 2>/dev/null)" || rc=$?
assert_eq "$rc" "0" "a kind with no entry exits 0 under --lanes"
assert_eq "$out" "" "...and prints nothing - absent is the off switch"

# A lanes entry has no single profile to resolve, so the judgment-free form
# must refuse rather than pick one.
assert_fails_with "lanes" -- "$BIN/ac-dispatch-select.sh" --pane codereview-scout
# ...and the converse: --lanes on a flat entry is a caller asking the wrong
# question of the wrong kind.
assert_fails_with "lanes" -- "$BIN/ac-dispatch-select.sh" --pane codereview --lanes

# Fail-closed schema, same posture as every other pane shape: a misconfigured
# entry dies rather than degrading to something that launches.
lanes_cfg() { jq ".panes[\"codereview-scout\"] = $1" "$AC_HOME/config/crew-dispatch.json" >"$TMP/d.json" && mv "$TMP/d.json" "$AC_HOME/config/crew-dispatch.json"; }
lanes_cfg '{"lanes": []}'
assert_fails "$BIN/ac-dispatch-select.sh" --pane codereview-scout --lanes
lanes_cfg '{"lanes": [{"model": "opus"}]}'
assert_fails "$BIN/ac-dispatch-select.sh" --pane codereview-scout --lanes
lanes_cfg '{"lanes": {"harness": "codex"}}'
assert_fails "$BIN/ac-dispatch-select.sh" --pane codereview-scout --lanes
lanes_cfg '{"lanes": [{"harness": "codex"}], "harness": "claude"}'
assert_fails_with "cannot mix" -- "$BIN/ac-dispatch-select.sh" --pane codereview-scout --lanes
lanes_cfg '{"lanes": [{"harness": "codex"}], "rules": [{"when": "x", "why": "y", "use": {"harness": "claude"}}]}'
assert_fails_with "cannot mix" -- "$BIN/ac-dispatch-select.sh" --pane codereview-scout --lanes

# TWO LANES THAT ARE THE SAME LANE: paying twice for one blind spot is a
# configuration mistake, and the resolver is where it is cheapest to catch.
lanes_cfg '{"lanes": [{"harness": "codex", "model": "gpt-5.6-sol"}, {"harness": "codex", "model": "gpt-5.6-sol"}]}'
# Named, not just detected: the refusal says WHICH lane is doubled, and
# asserting the name is also what keeps a bash error whose text happens to
# contain "duplicate lane" from passing as this check.
assert_fails_with "duplicate lane (codex model gpt-5.6-sol)" -- "$BIN/ac-dispatch-select.sh" --pane codereview-scout --lanes
lanes_cfg '{"lanes": [{"harness": "codex"}, {"harness": "codex"}]}'
assert_fails_with "duplicate lane (codex)" -- "$BIN/ac-dispatch-select.sh" --pane codereview-scout --lanes
# The same harness at a DIFFERENT model is two real perspectives, and passes.
lanes_cfg '{"lanes": [{"harness": "codex", "model": "gpt-5.6-sol"}, {"harness": "codex", "model": "gpt-5.5"}]}'
assert_eq "$("$BIN/ac-dispatch-select.sh" --pane codereview-scout --lanes | wc -l | tr -d ' ')" "2" \
  "same harness, different model is not a duplicate"

pass
