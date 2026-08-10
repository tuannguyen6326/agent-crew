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

pass
