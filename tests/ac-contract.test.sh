#!/usr/bin/env bash
# ac-contract.test.sh - the DELIVERY-CONTRACT token group on a backlog row
# (delivery-contract-on-the-row): parsed by the ONE shared line parser
# (AC_DONELINE_AWK's f["contract"], ac-lib.sh), judged by the ONE value judge
# (ac_contract_lint), displayed - never enforced - by ac-ready.sh.
#
# Covers:
#   - EXTRACTION: the all-tokens-keyed discriminator against every existing
#     group class on a real-shaped row (provenance prose tag, [EPIC], [@held],
#     backtick-quoted mention, a group outside the leading run);
#   - LINT: each closed vocabulary, the two law-outlawed combinations
#     (staged+rev:no, crew-ship+rev:no), and silence on a clean contract;
#   - ac-ready: the contract rides the READY line as INFORMATION, an invalid
#     token WARNs but never stops the row, and a contract-less ledger renders
#     byte-identically to before the feature (additive grammar).

# Fail-closed sourcing: unsourced (suite run outside tests/), errexit is never
# armed and $AC_HOME is the operator's REAL fleet home - abort instead.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../bin/ac-lib.sh
. "$BIN/ac-lib.sh"

make_home

contract_of() {  # contract_of <line> -> f["contract"]
  awk "$AC_DONELINE_AWK"'{ ac_doneline($0, o); print o["contract"] }' <<<"$1"
}
field_of() {  # field_of <line> <field>
  awk -v fld="$2" "$AC_DONELINE_AWK"'{ ac_doneline($0, o); print o[fld] }' <<<"$1"
}

# --- extraction: the discriminator ------------------------------------------

line='- [ ] my-task [src:cap flow:direct mode:local-only rev:no qa:no] - do a thing (repo: x, since 2026-08-10)'
assert_eq "$(contract_of "$line")" "src:cap flow:direct mode:local-only rev:no qa:no" \
  "a leading-run all-kv group is the contract, returned as bare content"
assert_eq "$(field_of "$line" id)" "my-task" "the id is untouched beside it"

# Coexistence: provenance prose tag + contract + [@held], all in the leading
# run - each class keeps its own field.
line='- [ ] t2 [src:chief flow:staged mode:crew-ship rev:yes qa:yes] [@held] [CAPTAIN-ORDERED 2026-08-10 the full receipt prose] - body (repo: x)'
assert_eq "$(contract_of "$line")" "src:chief flow:staged mode:crew-ship rev:yes qa:yes" \
  "the contract coexists with a captain hold and a prose provenance tag"
assert_eq "$(field_of "$line" hold)" "1" "[@held] beside a contract still holds"

# [EPIC] at its fixed position + contract after it.
line='- [ ] ep1 [EPIC] [src:cap flow:staged mode:crew-ship rev:yes qa:no] - an epic stories: a,b (repo: x)'
assert_eq "$(field_of "$line" terminal)" "epic" "[EPIC] keeps its rp[2] semantics"
assert_eq "$(contract_of "$line")" "src:cap flow:staged mode:crew-ship rev:yes qa:no" \
  "... and the contract is still found behind it"

# A prose tag with kv-LOOKING pieces mixed with words is NOT a contract.
line='- [ ] t3 [MONITOR 2026-08-08 src:cap relayed by the chief] - body (repo: x)'
assert_eq "$(contract_of "$line")" "" "a prose tag containing a kv-shaped word is not all-kv - skipped"

# An unknown key disqualifies the whole group (closed key set).
line='- [ ] t4 [src:cap speed:fast] - body (repo: x)'
assert_eq "$(contract_of "$line")" "" "an unknown key disqualifies the group - the key set is closed"

# Outside the leading run: never the contract (position decides authority).
line='- [ ] t5 - prose then [src:cap flow:direct mode:local-only rev:no qa:no] later (repo: x)'
assert_eq "$(contract_of "$line")" "" "a contract-shaped group outside the leading run carries no authority"

# Backtick-quoted: a documentation mention, exactly as for hold.
line='- [ ] t6 `[src:cap flow:direct]` - a doc row QUOTING the grammar (repo: x)'
assert_eq "$(contract_of "$line")" "" "a backtick-quoted group is a mention, never a token"

# First one wins.
line='- [ ] t7 [src:cap flow:direct] [src:chief flow:staged] - body (repo: x)'
assert_eq "$(contract_of "$line")" "src:cap flow:direct" "the FIRST leading-run contract group wins"

# --- lint: the one value judge -----------------------------------------------

assert_eq "$(ac_contract_lint 'src:cap flow:direct mode:local-only rev:no qa:no')" "" \
  "a clean contract lints silent"
assert_contains "$(ac_contract_lint 'src:boss')" "src:boss invalid" "src vocabulary is closed"
assert_contains "$(ac_contract_lint 'flow:agile')" "flow:agile invalid" "flow vocabulary is closed"
assert_contains "$(ac_contract_lint 'mode:ship')" "mode:ship invalid" "mode wants the FULL registry names"
assert_contains "$(ac_contract_lint 'rev:maybe')" "rev:maybe invalid" "rev is yes|no"
assert_contains "$(ac_contract_lint 'qa:auto')" "qa:auto invalid" \
  "qa:auto is deliberately NOT a value - delegation-by-click was dropped when the captain named chief judgment as the error source"
assert_contains "$(ac_contract_lint 'promote:yes')" "promote:yes invalid" "promote is only ever written as no"
assert_contains "$(ac_contract_lint 'flow:staged rev:no')" "staged review is mandatory" \
  "the staged+rev:no contradiction is flagged (AGENTS.md section 5)"
assert_contains "$(ac_contract_lint 'mode:crew-ship rev:no')" "crew-ship review is mandatory" \
  "the crew-ship+rev:no contradiction is flagged"

# --- ac-ready: information, never a gate --------------------------------------

backlog="$AC_HOME/records/backlog.md"
cat >"$backlog" <<'EOF'
## In flight

## Queued
- [ ] plain-row - no contract at all (repo: x)
- [ ] tokened-row [src:cap flow:direct mode:local-only rev:no qa:no] - a clean contract (repo: x)
- [ ] bad-row [src:cap flow:staged mode:crew-ship rev:no qa:no] - contradicts the law (repo: x)

## Done
EOF
out="$("$BIN/ac-ready.sh")"
assert_contains "$out" "READY  plain-row" "a contract-less row schedules exactly as before - additive grammar"
assert_contains "$out" "READY  tokened-row [src:cap flow:direct mode:local-only rev:no qa:no]" \
  "the contract rides the READY line as information"
assert_contains "$out" "READY  bad-row" \
  "an INVALID contract never stops the row - display and lint, enforcement is ac-brief's"
assert_contains "$out" "WARN   bad-row contract: flow:staged with rev:no" \
  "... but its violation is named beside the report"
assert_contains "$out" "WARN   bad-row contract: mode:crew-ship with rev:no" \
  "... every violation, not just the first"
case "$out" in
  *"WARN   tokened-row"*) fail "a clean contract draws no WARN" ;;
esac

# --- THE ESCALATION GATE (ac-brief.sh) ---------------------------------------
# The captain's rule verbatim: "confirm với captain khi sử dụng các mode take
# time (staged, crew-ship, qa, code-reviewer)" + "đưa ra lý do khi chọn các
# mode take time" - and the "đã define trong backlog thì không cần hỏi" half.
# Cheap-path autonomy is the counter-invariant: direct/local-only/rev:no/qa:no
# must scaffold with no authority at all.

mkdir -p "$AC_HOME/projects/gproj" "$AC_HOME/records"
git init -q -b main "$AC_HOME/projects/gproj" 2>/dev/null || true
printf -- '- gproj - a gate fixture project (added 2026-08-10)\n' >"$AC_HOME/records/projects.md"

cat >"$backlog" <<'EOF'
## In flight

## Queued
- [ ] g-pinned [src:cap flow:staged mode:crew-ship rev:yes qa:yes] - fully pinned by the captain (repo: gproj)
- [ ] g-cheap - no contract at all (repo: gproj)
- [ ] g-bare - no contract either (repo: gproj)
- [ ] g-pinned-mode [src:cap mode:local-only] - mode pinned local (repo: gproj)

## Done
EOF

# G1: the CHEAP path stays autonomous - no pin, no declaration, scaffolds.
"$BIN/ac-brief.sh" g-cheap gproj --mode local-only >/dev/null \
  || fail "G1: direct+local-only+rev:no+qa:no must scaffold with no authority - cheap autonomy is the other half of the rule"

# G2: unpinned crew-ship REFUSES, and the refusal carries the ask contract:
# the reason requirement, both remedies, and that nothing was written.
out="$("$BIN/ac-brief.sh" g-bare gproj --mode crew-ship --review yes 2>&1)" \
  && fail "G2: unpinned crew-ship must refuse"
assert_contains "$out" "mode:crew-ship" "G2: names WHICH mode needs confirming"
assert_contains "$out" "REASON" "G2: the ask must carry the reason (đưa ra lý do)"
assert_contains "$out" "PIN the answer" "G2: names the durable remedy"
assert_contains "$out" "--captain-requested" "G2: and the per-call remedy"
assert_no_file "$AC_HOME/data/g-bare/brief.md" "G2: a refused escalation scaffolds nothing"

# G3: unpinned staged refuses the same way.
out="$("$BIN/ac-brief.sh" g-bare-spec gproj --mode local-only --stage spec 2>&1)" \
  && fail "G3: unpinned staged must refuse"
assert_contains "$out" "flow:staged" "G3: names the staged escalation"

# G4: the ROW PIN is pre-consent - the fully pinned row scaffolds a staged
# crew-ship brief with no per-call declaration at all.
"$BIN/ac-brief.sh" g-pinned gproj --stage implement >/dev/null \
  || fail "G4: a pinned row must scaffold without asking - đã define trong backlog thì không cần hỏi"
assert_contains "$(cat "$AC_HOME/data/g-pinned/implement/brief.md")" "Mode: crew-ship" \
  "G4: the pinned mode reaches the brief"

# G5: --captain-requested is the per-call authority for the same escalations.
"$BIN/ac-brief.sh" g-bare gproj --mode crew-ship --review yes \
  --captain-requested 'captain 2026-08-10: ship this one through the pipeline' \
  --reason 'behavioral surface: the change rewrites the merge gate' >/dev/null \
  || fail "G5: a declared captain word must authorize the escalation"
# The ref rides the Review line only on the OPTIONAL-raise path; a crew-ship
# review is mandatory, so the brief records the mode and the obligation - the
# declaration's job here was passing the gate, which the scaffold existing proves.
assert_contains "$(cat "$AC_HOME/data/g-bare/brief.md")" "Mode: crew-ship" \
  "G5: the authorized crew-ship brief scaffolds with its mode"
assert_contains "$(cat "$AC_HOME/data/g-bare/brief.md")" "Review: yes" \
  "G5: ... and its mandatory review obligation"

# G6: a --mode CONTRADICTING the row's pin refuses - the pin is the captain's
# recorded word, and a chief flag may not silently override it.
out="$("$BIN/ac-brief.sh" g-pinned-mode gproj --mode crew-ship --review yes \
  --captain-requested 'x' 2>&1)" && fail "G6: a flag contradicting the pin must refuse"
assert_contains "$out" "contradicts the row's pinned mode" "G6: the refusal names the contradiction"

# G7: mode has NO registry default any more - unspecified refuses, naming both
# the flag and the pin path.
out="$("$BIN/ac-brief.sh" g-nomode gproj 2>&1)" && fail "G7: unspecified mode must refuse"
assert_contains "$out" "mode unspecified" "G7: the refusal says what is missing"
assert_contains "$out" "no registry default" "G7: ... and that the registry rung is gone by captain order"

# G8: a SCOUT resolves no mode and passes no gate - report-only work spends
# nothing.
"$BIN/ac-brief.sh" g-scout gproj --scout >/dev/null \
  || fail "G8: a scout brief needs no mode and no authority"

# G9: ac-spawn READS the brief's Mode record and refuses a contradicting
# flag - two resolvers for one decision is how the brief said local-only
# while spawn re-derived crew-ship from the retired registry fallback.
"$BIN/ac-brief.sh" g-spawncheck gproj --mode local-only >/dev/null
out="$("$BIN/ac-spawn.sh" g-spawncheck "$AC_HOME/projects/gproj" --harness fake --mode direct-pr 2>&1)" \
  && fail "G9: a spawn flag contradicting the brief's Mode must refuse"
assert_contains "$out" "contradicts the brief's recorded Mode" "G9: the refusal names the record"

# G11: the declared path must carry the chief's STATED REASON (captain's
# rule: 'đưa ra lý do khi chọn các mode take time') - required WITH
# --captain-requested, recorded on the brief's Escalation: line; a row pin
# needs none (no ask happened - the pin is the captain's own act), and an
# idle --reason documents an ask that never happened.
out="$("$BIN/ac-brief.sh" g-noreason gproj --mode crew-ship \
  --captain-requested 'captain: pipeline please' 2>&1)" \
  && fail "G11: a declared escalation without --reason must refuse"
assert_contains "$out" "--reason" "G11: the refusal names the missing reason"
[ ! -e "$AC_HOME/data/g-noreason" ] || fail "G11: nothing scaffolded on the refusal"
"$BIN/ac-brief.sh" g-reason gproj --mode crew-ship \
  --captain-requested 'captain: pipeline please' \
  --reason 'financial surface: the change moves settlement math' >/dev/null \
  || fail "G11: authority + reason together must pass"
assert_contains "$(cat "$AC_HOME/data/g-reason/brief.md")" \
  "Escalation: mode:crew-ship rev:yes - captain-requested: captain: pipeline please - reason: financial surface: the change moves settlement math" \
  "G11: the brief records what was spent, on whose word, and why"
out="$("$BIN/ac-brief.sh" g-idlereason gproj --mode local-only \
  --reason 'no ask happened' 2>&1)" \
  && fail "G11: --reason without --captain-requested must refuse"
assert_contains "$out" "ask that never happened" "G11: the idle-reason refusal names its ground"
# G10: pins live on the FAMILY row - a staged call's id is <family>-<stage>,
# and the gate must resolve the family's contract for it (the live demo
# caught the exact-id-only lookup reading a pinned family as unpinned; the
# G-fixture rows had masked it by pinning stage ids directly).
printf -- '- [ ] g-fampin [src:cap flow:staged mode:crew-ship rev:yes qa:no] - family-pinned staged work (repo: gproj)\n' \
  >>"$AC_HOME/records/backlog.md"
"$BIN/ac-brief.sh" g-fampin-spec gproj --stage spec >/dev/null \
  || fail "G10: the family row's pin must authorize the stage call (nothing re-asked)"
"$BIN/ac-brief.sh" g-fampin gproj --stage implement >/dev/null \
  || fail "G10: the family pin authorizes the implement stage too"
assert_contains "$(cat "$AC_HOME/data/g-fampin/implement/brief.md")" "Mode: crew-ship" \
  "G10: the recorded mode comes from the family pin"
assert_contains "$(cat "$AC_HOME/data/g-fampin/implement/brief.md")" "Review: yes" \
  "G10: staged review rides the pin's authority"

# ...and the pin needs NO --reason either (G11's counterpart): no ask
# happened - the pin is the captain's own act, the row is its record.
"$BIN/ac-brief.sh" g-fampin-arch gproj --stage architecture >/dev/null \
  || fail "G10: a pinned row scaffolds with neither declaration nor reason"

# --- differential: the TS twin extracts byte-identically ----------------------
# bin/dashboard.ts parseBacklogLine().contract is the browser-side twin of
# AC_DONELINE_AWK's f["contract"] - one grammar, two hosts. Drive BOTH parsers
# over the same fixture lines and demand byte-identical answers, so the twins
# cannot drift apart silently. Skips cleanly when bun is absent (house style:
# a missing tool never reads as a failure - tests/dashboard.test.sh).
if command -v bun >/dev/null 2>&1; then
  diff_lines="$AC_HOME/contract-diff-lines.txt"
  cat >"$diff_lines" <<'LINES'
- [ ] t1 [src:cap flow:direct mode:local-only rev:no qa:no] - do it (repo: alpha)
- [ ] t2 [EPIC 3 stories] [src:cap] - x
- [ ] t3 [@held] [mode:direct-pr] - x
- [ ] t4 [CAPTAIN-ORDERED 2026-07-30] - x
- [ ] t5 - text mentions [mode:local-only] later
- [ ] t6 `[src:cap]` - quoted mention
- [ ] t7 [src:cap] [mode:crew-ship] - first wins
- [ ] t8 [src:cap bogus:v] - unknown key breaks the group
- [x] t9 [flow:staged mode:crew-ship rev:yes qa:yes] - heavy row (repo: beta) (merged 2026-08-09)
- [ ] t10 [] - empty group
- [ ] t11 [PROSE 2026-08-08, verbatim "a -> b - c"] [src:cap rev:no] - text after a dash-carrying prose group
prose that is not a task line [src:cap]
LINES
  awk_out="$(awk "$AC_DONELINE_AWK"'
    { ac_doneline($0, o); print o["contract"]; delete o }
  ' "$diff_lines")"
  ts_out="$(bun -e '
    const { parseBacklogLine } = await import(process.argv[1]);
    const fs = await import("fs");
    const lines = fs.readFileSync(process.argv[2], "utf8").split("\n");
    if (lines[lines.length - 1] === "") lines.pop();
    for (const l of lines) console.log(parseBacklogLine(l).contract);
  ' "$ROOT/bin/dashboard.ts" "$diff_lines")"
  assert_eq "$ts_out" "$awk_out" "the TS twin and AC_DONELINE_AWK extract the contract byte-identically"
else
  printf 'SKIP: bun not available - the awk/TS contract differential skipped\n'
fi

pass
