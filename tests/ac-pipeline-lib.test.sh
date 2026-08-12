#!/usr/bin/env bash
# ac-pipeline-lib.test.sh - the shared pipeline helper lib. Direct unit test of
# ac_yaml_get (the flat nested-scalar YAML subset reader owned here since the
# ship/qa yaml_get dedup): nested key resolution, quoted-value unquoting, and
# comment/blank-line skipping. The behavioral call-site coverage stays in
# tests/ac-ship.test.sh (config reads) and tests/ac-qa.test.sh (frozen config).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

lib() {
  # lib <body> - run a body with ac-pipeline-lib.sh sourced, nothing else.
  bash -c "set -euo pipefail; . '$BIN/ac-pipeline-lib.sh'; $1"
}

cfg="$TMP/config.yaml"
cat >"$cfg" <<'EOF'
# a leading comment, skipped

commands:
  test: "echo test-ok"
  lint: 'exit 3'

  # an indented comment inside a block, skipped
auto_fix:
  review: 0
  lint: 5
plain: bare-value
EOF

# Nested key resolves to its scalar.
assert_eq "$(lib "ac_yaml_get '$cfg' commands.test")" "echo test-ok" "nested key"
assert_eq "$(lib "ac_yaml_get '$cfg' auto_fix.lint")" "5" "nested numeric key"

# Quoted values are unquoted (double and single quotes).
assert_eq "$(lib "ac_yaml_get '$cfg' commands.lint")" "exit 3" "single-quoted value unquoted"

# Bare top-level scalar reads without quotes.
assert_eq "$(lib "ac_yaml_get '$cfg' plain")" "bare-value" "bare top-level value"

# Missing keys are empty (comment/blank lines never spuriously match).
assert_eq "$(lib "ac_yaml_get '$cfg' commands.format")" "" "missing key empty"
assert_eq "$(lib "ac_yaml_get '$cfg' nonesuch")" "" "missing top-level key empty"

# --- ac_yaml_keys: enumerate a block's IMMEDIATE children ---------------------
# ac_yaml_get cannot tell a PRESENT block from an ABSENT one, which is exactly
# the distinction scoped/flat mode detection turns on.
scoped="$TMP/scoped.yaml"
cat >"$scoped" <<'EOF'
qa:
  health_timeout: 900
  scopes:
    orchid:
      seed: "echo seed-orchid"
      apps:
        orchid-service:
          serve: "echo serve-orchid-service"
        orchid-worker:
          serve: "echo serve-orchid-worker"
    cedar:
      seed: "echo seed-cedar"
      apps:
        cedar-service:
          serve: "echo serve-cedar"
commands:
  test: "true"
EOF
assert_eq "$(lib "ac_yaml_keys '$scoped' qa.scopes" | tr '\n' ' ')" "orchid cedar " "block children in file order"
assert_eq "$(lib "ac_yaml_keys '$scoped' qa.scopes.orchid.apps" | tr '\n' ' ')" "orchid-service orchid-worker " "nested apps block"
assert_eq "$(lib "ac_yaml_keys '$scoped' qa.scopes.cedar.apps" | tr '\n' ' ')" "cedar-service " "a one-member apps block"
assert_eq "$(lib "ac_yaml_keys '$scoped' qa.health_timeout")" "" "a scalar has no children"
assert_eq "$(lib "ac_yaml_keys '$scoped' qa.nope")" "" "an absent key has no children"
assert_eq "$(lib "ac_yaml_keys '$cfg' qa.scopes")" "" "a FLAT file declares no scopes"

# --- ac_yaml_has: PRESENCE, which children cannot answer ---------------------
# An EMPTY block and an ABSENT one both have zero children, and they are not
# the same fact: `scopes:` lands before the first block under it, so reading
# the half-authored state as ABSENT is what drops a project to flat.
empty="$TMP/empty-block.yaml"
printf 'qa:\n  serve: "echo flat"\n  scopes:\n' >"$empty"
assert_eq "$(lib "ac_yaml_keys '$empty' qa.scopes")" "" "an EMPTY block has no children"
lib "ac_yaml_has '$empty' qa.scopes" || fail "...but it is PRESENT, and ac_yaml_has must say so"
lib "ac_yaml_has '$scoped' qa.scopes" || fail "a populated block is present"
assert_fails bash -c ". '$BIN/ac-pipeline-lib.sh'; ac_yaml_has '$cfg' qa.scopes"
assert_fails bash -c ". '$BIN/ac-pipeline-lib.sh'; ac_yaml_has '$scoped' qa.nope"
lib "ac_yaml_has '$scoped' qa.health_timeout" || fail "a scalar is present too"

# --- ac_findings_normalize: fail-closed action + description fallback --------
# The findings-wire normalizer both pipelines' cmd_findings share. Reads a JSON
# array from stdin, writes the normalized array to the file given as $1.
# The auto-fix alias is RETIRED (audit-f7; no producer ever emitted it): it now
# rides the unknown-action arm and fails closed to ask-user like any other
# invented action, reaching the captain instead of a fixer.
norm="$TMP/norm.json"
printf '%s' '[{"action":""},
              {"action":"auto-fix","authority_class":"internal","authority":"tests/x.sh:1"},
              {"detail":"d"},{"title":"t"},{"action":"invented"}]' \
  | lib "ac_findings_normalize '$norm'"
assert_eq "$(jq -r '.[0].action' "$norm")" "ask-user" "empty action fails closed to ask-user"
assert_eq "$(jq -r '.[2].action' "$norm")" "ask-user" "missing action fails closed to ask-user"
assert_eq "$(jq -r '.[1].action' "$norm")" "ask-user" "retired auto-fix alias fails closed to ask-user"
assert_eq "$(jq -r '.[4].action' "$norm")" "ask-user" "unknown action fails closed to ask-user"
assert_eq "$(jq -r '.[2].description' "$norm")" "d" "description falls back to detail"
assert_eq "$(jq -r '.[3].description' "$norm")" "t" "description falls back to title"
assert_eq "$(jq -r '.[4].action' "$norm")" "ask-user" "unknown action fails closed to ask-user"
for i in 0 2 3 4; do
  assert_eq "$(jq -r ".[$i].question | type" "$norm")" "string" "normalized ask-user carries a question"
  assert_eq "$(jq -r ".[$i].options | length" "$norm")" "2" "normalized ask-user carries two relay options"
  assert_eq "$(jq -r ".[$i].tradeoffs | length" "$norm")" "2" "normalized ask-user carries option tradeoffs"
  assert_eq "$(jq -r ".[$i].recommendation | type" "$norm")" "string" "normalized ask-user carries a recommendation"
done

# --- ac_findings_normalize: the FINDING-AUTHORITY downgrade ------------------
# T1: a `fix` finding that names NO authority for its expected behaviour is
# downgraded to ask-user and marked. The three shapes an unauthorized finding
# actually arrives in: no keys at all (a legacy/forgetful emitter), a declared
# class with an EMPTY citation, and a class outside the closed enum.
auth="$TMP/auth.json"
printf '%s' '[{"id":"none","action":"fix","description":"d"},
              {"id":"empty","action":"fix","authority_class":"external","authority":"","description":"d"},
              {"id":"blank","action":"fix","authority_class":"external","authority":"   ","description":"d"},
              {"id":"bogus","action":"fix","authority_class":"hearsay","authority":"docs/x.md:12","description":"d"}]' \
  | lib "ac_findings_normalize '$auth'"
for i in 0 1 2 3; do
  id="$(jq -r ".[$i].id" "$auth")"
  assert_eq "$(jq -r ".[$i].action" "$auth")" "ask-user" "$id: unauthorized fix downgrades to ask-user"
  assert_eq "$(jq -r ".[$i].authority_downgraded" "$auth")" "true" "$id: the downgrade is marked"
  assert_eq "$(jq -r ".[$i].authority_class" "$auth")" "none" "$id: authority_class normalizes to none"
  assert_eq "$(jq -r ".[$i].question" "$auth")" "d" "$id: downgrade preserves description as captain question"
done

# T2: authority PRESENT passes through untouched - the guard against a
# normalizer that downgrades everything, floods the captain, and gets the rule
# switched off. `ask-user` and `no-op` are never touched either (§3.3: the
# downgrade binds action == fix alone).
ok="$TMP/auth-ok.json"
printf '%s' '[{"id":"int","action":"fix","authority_class":"internal","authority":"contract item 5, spec.md:41","description":"d"},
              {"id":"ext","action":"fix","authority_class":"external","authority":"docs/bmad/tech-spec.md:1004","description":"d"},
              {"id":"ask","action":"ask-user","description":"d"},
              {"id":"nop","action":"no-op","description":"d"}]' \
  | lib "ac_findings_normalize '$ok'"
assert_eq "$(jq -r '.[0].action' "$ok")" "fix" "internal + citation keeps action fix"
assert_eq "$(jq -r '.[1].action' "$ok")" "fix" "external + citation keeps action fix"
assert_eq "$(jq -r '.[0].authority_class' "$ok")" "internal" "a valid class survives normalization"
assert_eq "$(jq -r '.[1].authority' "$ok")" "docs/bmad/tech-spec.md:1004" "the citation survives normalization"
assert_eq "$(jq -r '[.[] | select(has("authority_downgraded"))] | length' "$ok")" "0" \
  "nothing authorized (or non-fix) is marked downgraded"
assert_eq "$(jq -r '.[2].action' "$ok")" "ask-user" "an unauthorized ask-user is left alone"
assert_eq "$(jq -r '.[2].question' "$ok")" "d" "legacy ask-user is enriched for captain relay"
assert_eq "$(jq -r '.[3].action' "$ok")" "no-op" "an unauthorized no-op is left alone"

# --- ac_findings_normalize: the SEVERITY FLOOR -------------------------------
# T1: an `info` finding carrying `fix` contradicts its own severity - info
# means no action required - so it is downgraded to no-op and marked, the same
# style as the authority downgrade above. Authority is supplied so only the
# severity clause is under test.
sev="$TMP/severity.json"
printf '%s' '[{"id":"info-fix","severity":"info","action":"fix","authority_class":"internal","authority":"docs/x.md:1","description":"d"},
              {"id":"warning-fix","severity":"warning","action":"fix","authority_class":"internal","authority":"docs/x.md:1","description":"d"},
              {"id":"error-fix","severity":"error","action":"fix","authority_class":"internal","authority":"docs/x.md:1","description":"d"},
              {"id":"info-noop","severity":"info","action":"no-op","description":"d"},
              {"id":"info-ask","severity":"info","action":"ask-user","description":"d"}]' \
  | lib "ac_findings_normalize '$sev'"
assert_eq "$(jq -r '.[0].action' "$sev")" "no-op" "info+fix downgrades to no-op"
assert_eq "$(jq -r '.[0].severity_floored' "$sev")" "true" "the severity floor is marked"
assert_eq "$(jq -r '.[1].action' "$sev")" "fix" "warning+fix is unaffected by the severity floor"
assert_eq "$(jq -r '.[1] | has("severity_floored")' "$sev")" "false" "warning+fix carries no floor flag"
assert_eq "$(jq -r '.[2].action' "$sev")" "fix" "error+fix is unaffected by the severity floor"
assert_eq "$(jq -r '.[2] | has("severity_floored")' "$sev")" "false" "error+fix carries no floor flag"
assert_eq "$(jq -r '.[3].action' "$sev")" "no-op" "info+no-op is already no-op and stays untouched"
assert_eq "$(jq -r '.[3] | has("severity_floored")' "$sev")" "false" "an already no-op finding carries no floor flag"
assert_eq "$(jq -r '.[4].action' "$sev")" "ask-user" "info+ask-user is never floored - it is a captain decision"
assert_eq "$(jq -r '.[4] | has("severity_floored")' "$sev")" "false" "an ask-user finding carries no floor flag"

# T2: the PRECEDENCE interaction with the authority downgrade above - an
# info+fix finding that names NO authority still floors to no-op, not
# ask-user. The severity clause runs first (an info finding needs no action
# regardless of authority), so by the time the authority clause checks
# action == "fix" the action is already "no-op" and the clause never fires:
# no authority_downgraded, no captain escalation. This is a deliberate
# choice: once severity floors a finding to no-op nothing is ever
# assigned to a fixer, so the authority rule's purpose - stopping an
# unfounded fix from becoming a commit - no longer applies, and holding
# delivery for an unfounded no-op nit would cost more than the review
# loop this floor exists to remove.
noauth="$TMP/severity-noauth.json"
printf '%s' '[{"id":"info-fix-noauth","severity":"info","action":"fix","description":"stale citation"}]' \
  | lib "ac_findings_normalize '$noauth'"
assert_eq "$(jq -r '.[0].action' "$noauth")" "no-op" \
  "an info+fix finding with no authority still floors to no-op, not ask-user"
assert_eq "$(jq -r '.[0].severity_floored' "$noauth")" "true" \
  "the severity floor is marked even with no authority named"
assert_eq "$(jq -r '.[0] | has("authority_downgraded")' "$noauth")" "false" \
  "the authority clause never fires once severity has already floored the action"

# A decided ask-user finding is re-posted through the same shared wire.
# The optional captain decision must survive normalization for both ship and QA
# completion gates, and free text is scrubbed to a single durable JSON string.
decided="$TMP/decided.json"
printf '%s' '[{"id":"ask","action":"ask-user","description":"choose",
               "decision":"captain accepted option A\twith evidence\nrecorded"}]' \
  | lib "ac_findings_normalize '$decided'"
assert_eq "$(jq -r '.[0].decision' "$decided")" \
  "captain accepted option A with evidence recorded" \
  "the optional captain decision survives the shared normalizer and is scrubbed"

# --- ac_findings_normalize: non-destructive write (tmp + mv) -----------------
# The old body opened `>"$1"` before jq ran, zeroing the target the instant
# the shell opened it - so even an ABORTED or invalid ingest destroyed it.
# `[1,2,3]` IS a JSON array (an earlier `type == "array"` gate would pass it)
# but its elements are not objects, so `.action = ...` fails INSIDE the
# normalizer itself - proving the fix here, not only at a caller's gate.
prev="$TMP/prev.json"
printf '%s' '[{"id":"kept","action":"fix"}]' >"$prev"
sum_before="$(shasum -a 256 "$prev")"
rc=0
printf '%s' '[1,2,3]' | lib "ac_findings_normalize '$prev'" 2>/dev/null || rc=$?
assert_eq "$rc" "1" "a normalizer failure returns non-zero"
assert_eq "$(shasum -a 256 "$prev")" "$sum_before" "a normalizer failure leaves the previous file byte-identical"
leftover="$(find "$TMP" -maxdepth 1 -name 'prev.json.*' -print)"
assert_eq "$leftover" "" "no leftover temp file after a failed normalize"

# A successful normalize still replaces the file (the happy path is unchanged).
printf '%s' '[{"id":"new","action":"fix"}]' | lib "ac_findings_normalize '$prev'"
assert_eq "$(jq -r '.[0].id' "$prev")" "new" "a successful normalize replaces the file"

# --- ac_findings_summary: "none" for [], action counts otherwise ------------
empty="$TMP/empty.json"; printf '[]' >"$empty"
assert_eq "$(lib "ac_findings_summary '$empty'")" "none" "empty array summarizes to none"
counts="$TMP/counts.json"
printf '%s' '[{"action":"fix"},{"action":"fix"},{"action":"ask-user"}]' >"$counts"
assert_eq "$(lib "ac_findings_summary '$counts'")" "ask-user=1 fix=2" "action counts grouped"

# --- ac_transcript_final: last assistant message from a JSONL transcript ----
# The reader both pipelines use to pull a pane agent's verdict from a Claude
# Code session transcript.
tr="$TMP/transcript.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"content":[{"type":"text","text":"hi"}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"first"}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"final answer"}]}}'
} >"$tr"
assert_eq "$(lib "ac_transcript_final '$tr'")" "final answer" "last assistant message extracted"

# --- ac_verdict_json: the JSON verdict object out of a prose-wrapped message --
# The reviewer is asked for JSON-only but often writes a human summary beside the
# verdict, so the verify harvest must pull the LAST top-level JSON object that
# parses, tolerating prose and code fences around it. Kept separate from
# ac_transcript_final, whose full prose the second-chief gate still needs.
vj="$TMP/verdict.txt"

# The real repro: prose, a blank line, then a BARE (unfenced) JSON object.
cat >"$vj" <<'EOF'
Đánh giá hoàn tất, cả hai test đều PASS. Tóm tắt: sạch, in-scope.

{"verdict":"pass","n":1}
EOF
assert_eq "$(lib "ac_verdict_json <'$vj'")" '{"verdict":"pass","n":1}' \
  "a bare JSON object after human prose is extracted"

# A fenced ```json block wrapped in prose (fence markers are just noise).
cat >"$vj" <<'EOF'
Prose before.

```json
{"v":2}
```

Trailing prose.
EOF
assert_eq "$(lib "ac_verdict_json <'$vj'")" '{"v":2}' \
  "a fenced JSON block wrapped in prose is extracted"

# Braces and escaped quotes INSIDE a string value must not truncate the object.
cat >"$vj" <<'EOF'
Prose.

{"d":"has {a} and \"q\" here","ok":true}
EOF
got="$(lib "ac_verdict_json <'$vj'")"
assert_eq "$(printf '%s' "$got" | jq -r .d)" 'has {a} and "q" here' \
  "braces and escaped quotes inside a string do not truncate the object"
assert_eq "$(printf '%s' "$got" | jq -r .ok)" 'true' "the whole object survives inner braces"

# The LAST top-level object wins when several are present.
cat >"$vj" <<'EOF'
{"first":1}
some prose
{"second":2}
EOF
assert_eq "$(lib "ac_verdict_json <'$vj'")" '{"second":2}' "the last top-level JSON object wins"

# A trailing non-JSON brace region does not shadow the real verdict.
cat >"$vj" <<'EOF'
{"real":true}

Follow-up: tweak {the thing} later.
EOF
assert_eq "$(lib "ac_verdict_json <'$vj'")" '{"real":true}' \
  "a trailing non-JSON brace region is skipped for the valid object"

# No JSON object at all yields empty output (the harvest then fails closed).
printf 'just prose, no verdict here\n' >"$vj"
assert_eq "$(lib "ac_verdict_json <'$vj'")" '' "no JSON object yields empty output"

# --- ac_findings_normalize: the LATE-FINDING (round) floor -------------------
# review-round-convergence (captain 2026-08-05): a round>=2 `fix` finding whose
# file lies OUTSIDE the fix-delta is churn on code this task never touched -
# floored to no-op (round_floored), advisory kept. Carve-out, non-overridable:
# severity=error WITH class correctness|security|data-loss keeps fix anywhere,
# any round. Fail directions: absent round metadata => NO floor (reviews too
# much); unclassifiable (error severity, no class) => NOT floored (fixes).
# Round + delta ride env (AC_FINDINGS_ROUND, AC_FINDINGS_DELTA) so the QA
# pipeline's calls - which set neither - are byte-identical to before.
rf="$TMP/roundfloor.json"
rf_in='[{"id":"late-warning","severity":"warning","action":"fix","file":"src/other.ts","class":"regression","authority_class":"internal","authority":"docs/x.md:1","description":"d","suggested_fix":"s"},
        {"id":"late-in-delta","severity":"warning","action":"fix","file":"src/fixed.ts","authority_class":"internal","authority":"docs/x.md:1","description":"d"},
        {"id":"late-bomb","severity":"error","action":"fix","file":"src/other.ts","class":"security","authority_class":"internal","authority":"docs/x.md:1","description":"d"},
        {"id":"late-error-regression","severity":"error","action":"fix","file":"src/other.ts","class":"regression","authority_class":"internal","authority":"docs/x.md:1","description":"d"},
        {"id":"late-error-unclassified","severity":"error","action":"fix","file":"src/other.ts","authority_class":"internal","authority":"docs/x.md:1","description":"d"},
        {"id":"late-no-file","severity":"warning","action":"fix","class":"regression","authority_class":"internal","authority":"docs/x.md:1","description":"d"},
        {"id":"late-noop","severity":"warning","action":"no-op","file":"src/other.ts","description":"d"}]'
printf '%s' "$rf_in" | lib "AC_FINDINGS_ROUND=2 AC_FINDINGS_DELTA='src/fixed.ts
lib/helper.ts' ac_findings_normalize '$rf'"
assert_eq "$(jq -r '.[0].action' "$rf")" "no-op" "r2 warning fix outside the delta floors to no-op"
assert_eq "$(jq -r '.[0].round_floored' "$rf")" "true" "the round floor is marked"
assert_eq "$(jq -r '.[0].suggested_fix' "$rf")" "s" "the floored finding keeps its advisory"
assert_eq "$(jq -r '.[1].action' "$rf")" "fix" "r2 fix INSIDE the delta keeps fix"
assert_eq "$(jq -r '.[2].action' "$rf")" "fix" "carve-out: error+security keeps fix outside the delta"
assert_eq "$(jq -r '.[2] | has("round_floored")' "$rf")" "false" "the carve-out carries no floor flag"
assert_eq "$(jq -r '.[3].action' "$rf")" "no-op" "error+regression outside the delta floors (not in the bomb set)"
assert_eq "$(jq -r '.[4].action' "$rf")" "fix" "error with NO class is unclassifiable - fails toward fixing"
assert_eq "$(jq -r '.[5].action' "$rf")" "fix" "a fix with NO file cannot be located - fails toward fixing"
assert_eq "$(jq -r '.[6].action' "$rf")" "no-op" "an already-no-op finding is untouched"
assert_eq "$(jq -r '.[6] | has("round_floored")' "$rf")" "false" "...and carries no floor flag"

# Round 1 (or absent metadata) floors nothing - byte-identical prior behavior.
rf1="$TMP/roundfloor-r1.json"
printf '%s' "$rf_in" | lib "AC_FINDINGS_ROUND=1 AC_FINDINGS_DELTA='src/fixed.ts' ac_findings_normalize '$rf1'"
assert_eq "$(jq -r '[.[] | select(has("round_floored"))] | length' "$rf1")" "0" "round 1 floors nothing"
rf0="$TMP/roundfloor-r0.json"
printf '%s' "$rf_in" | lib "ac_findings_normalize '$rf0'"
assert_eq "$(jq -r '[.[] | select(has("round_floored"))] | length' "$rf0")" "0" "absent round metadata floors nothing"
assert_eq "$(jq -r '.[0].action' "$rf0")" "fix" "absent metadata keeps every authorized fix"

pass
