#!/usr/bin/env bash
# ac-ship.test.sh - the crew-ship state machine: run lifecycle, step
# transitions, config reading from the fleet-home project store,
# deterministic command execution, findings fail-closed default, and the
# TDD attestation (attest-test by execution + test-step acceptance +
# the attest-check verifier query).

# FAIL-CLOSED SOURCING (this suite pushes): run from anywhere but tests/, the
# source below no-ops, errexit is never armed, every helper var stays EMPTY -
# and the push fixtures below then hit the REAL repo (incident 2026-07-20).
# Abort instead of running unsourced.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

repo="$(make_repo)"
cd "$repo" || fail "cd $repo"
mkdir -p "$AC_HOME/projects"
ship_cfg="$AC_HOME/projects/repo.yaml"
cat >"$ship_cfg" <<'EOF'
commands:
  test: "echo test-ok"
  lint: "exit 3"

auto_fix:
  review: 0
  lint: 5

# Legacy blocks below exercise many sequential review rounds; the
# review-round-convergence cap (default 3) gets its own dedicated section on a
# fresh repo at the end of this file.
review:
  max_rounds: 9
EOF

# Start a run with a skipped step; unknown skip names are rejected.
out="$("$BIN/ac-ship.sh" start --intent "ship the widget" --skip pr)"
assert_contains "$out" "started run" "start"
assert_fails "$BIN/ac-ship.sh" start --intent ""
assert_fails "$BIN/ac-ship.sh" start --intent "x" --skip bogus
assert_fails "$BIN/ac-ship.sh" start --intent "x" --skip ci   # removed step rejected

# F4 (captain-decided): intent and review can never be skipped via --skip -
# the header already promised "the intent-evidence pass is never skipped"
# and crew-ship review is always required (AGENTS.md section 5); this makes
# both a machine guard instead of resting on convention/prose alone.
assert_fails "$BIN/ac-ship.sh" start --intent "x" --skip intent
assert_fails "$BIN/ac-ship.sh" start --intent "x" --skip review
rc=0
out="$("$BIN/ac-ship.sh" start --intent "x" --skip intent,pr 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "--skip intent must refuse even combined with a legal skip target"
assert_contains "$out" "intent" "the refusal names the forbidden skip target"

st="$("$BIN/ac-ship.sh" status)"
assert_contains "$st" "intent=ship the widget" "intent recorded"
assert_contains "$st" "pr         skipped" "pr skipped"
assert_contains "$st" "config_sha256=" "run records the frozen config identity"

# Step transitions validate names and statuses.
"$BIN/ac-ship.sh" step intent running >/dev/null
"$BIN/ac-ship.sh" step intent completed >/dev/null
assert_fails "$BIN/ac-ship.sh" step bogus running
assert_fails "$BIN/ac-ship.sh" step review bogus
assert_contains "$("$BIN/ac-ship.sh" status)" "intent     completed" "step updated"

# Config keys resolve; missing keys are empty.
assert_eq "$("$BIN/ac-ship.sh" config commands.test)" "echo test-ok" "config commands.test"
assert_eq "$("$BIN/ac-ship.sh" config auto_fix.lint)" "5" "config auto_fix.lint"
assert_eq "$("$BIN/ac-ship.sh" config commands.format)" "" "missing key empty"

# cmd runs the configured command and propagates its exit code.
out="$("$BIN/ac-ship.sh" cmd test 2>/dev/null)"
assert_contains "$out" "test-ok" "cmd test output"
rc=0; "$BIN/ac-ship.sh" cmd lint >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "3" "cmd lint exit code"
rc=0; "$BIN/ac-ship.sh" cmd format >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "4" "unconfigured cmd exits 4"

# Findings default a missing OR EMPTY action to ask-user (fail closed),
# and normalize legacy title/detail into description.
out="$(printf '[{"id":"r1","severity":"error","title":"bug"}]' | "$BIN/ac-ship.sh" findings review)"
assert_contains "$out" "ask-user=1" "fail-closed action"
run_dir="$repo/.crew/ship/$(readlink "$repo/.crew/ship/current")"
assert_eq "$(jq -r '.[0].action' "$run_dir/findings/review.json")" "ask-user" "stored action"
assert_eq "$(jq -r '.[0].description' "$run_dir/findings/review.json")" "bug" "title normalized to description"
out="$(printf '[{"id":"r2","severity":"warning","action":""}]' | "$BIN/ac-ship.sh" findings review)"
assert_contains "$out" "ask-user=1" "empty action fails closed"
out="$(printf '[]' | "$BIN/ac-ship.sh" findings review)"
assert_eq "$out" "none" "empty findings summarize as none"

# --show is a READ form: prints the stored findings, writes nothing.
shown="$("$BIN/ac-ship.sh" findings review --show)"
assert_eq "$shown" "$(cat "$run_dir/findings/review.json")" "--show prints the stored findings"
sum_before="$(shasum -a 256 "$run_dir/findings/review.json")"
"$BIN/ac-ship.sh" findings review --show >/dev/null
assert_eq "$(shasum -a 256 "$run_dir/findings/review.json")" "$sum_before" "--show leaves the file byte-identical"

# --show on a step with no findings recorded dies clearly and writes nothing.
assert_no_file "$run_dir/findings/test.json" "no findings recorded yet for test step"
assert_fails "$BIN/ac-ship.sh" findings test --show
assert_no_file "$run_dir/findings/test.json" "--show on an unrecorded step still writes nothing"

# Ingest refuses a tty stdin instead of hanging then truncating (the old bug:
# `json="$(cat)"` blocked on a tty, and the normalizer's `>"$1"` had already
# zeroed the target the instant the shell opened it).
sum_before="$(shasum -a 256 "$run_dir/findings/review.json")"
rc=0
tty_out="$(run_on_tty "$BIN/ac-ship.sh" findings review 2>&1)" || rc=$?
assert_eq "$rc" "1" "ingest on a tty refuses instead of hanging"
assert_contains "$tty_out" "refusing a tty" "tty refusal names the reason"
assert_eq "$(shasum -a 256 "$run_dir/findings/review.json")" "$sum_before" "tty refusal leaves existing findings untouched"

# An INVALID ingest never destroys the previous findings - the core
# regression. `[1,2,3]` IS a JSON array (passes the early `type == "array"`
# gate) but its elements are not objects, so `.action = ...` fails INSIDE
# ac_findings_normalize itself - proving the fix is in the normalizer, not
# only the early check.
sum_before="$(shasum -a 256 "$run_dir/findings/review.json")"
assert_fails bash -c "printf '%s' '[1,2,3]' | '$BIN/ac-ship.sh' findings review"
assert_eq "$(shasum -a 256 "$run_dir/findings/review.json")" "$sum_before" \
  "invalid ingest (bad element shape) leaves previous findings intact"
leftover="$(find "$run_dir/findings" -name 'review.json.*' -print)"
assert_eq "$leftover" "" "no leftover temp file after a failed normalize"

# --- F9: a re-post to the review step must not silently erase a recorded
# `fix` finding with no re-review - only review-agent (the resolution) may.
# RF1 is left recorded here on purpose: the review-agent flow further below
# re-uses this SAME run and exercises the trusted bypass on this exact finding.
printf '[{"id":"RF1","severity":"error","action":"fix","authority_class":"internal","authority":"tests/ac-ship.test.sh:1","description":"real bug"}]' \
  | "$BIN/ac-ship.sh" findings review >/dev/null
sum_before="$(shasum -a 256 "$run_dir/findings/review.json")"
rc=0
out="$(printf '[]' | "$BIN/ac-ship.sh" findings review 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a re-post dropping a recorded fix finding must be refused"
assert_contains "$out" "RF1" "the refusal names the dropped fix finding"
assert_eq "$(shasum -a 256 "$run_dir/findings/review.json")" "$sum_before" \
  "the refused re-post leaves the recorded fix finding intact"
leftover="$(find "$run_dir/findings" -name '.review.json.*' -print)"
assert_eq "$leftover" "" "no leftover temp file after a refused drop"

# meta records the PR-body envelope.
out="$(printf '{"risk_level":"low","risk_rationale":"docs only"}' | "$BIN/ac-ship.sh" meta review)"
assert_contains "$out" "risk_level" "meta keys echoed"
assert_eq "$(jq -r '.risk_level' "$run_dir/findings/review.meta.json")" "low" "meta stored"
assert_fails bash -c "printf '[1]' | '$BIN/ac-ship.sh' meta review"

# meta has the same destructive-write shape cmd_findings had (891a4eb) - a
# tty stdin refuses instead of hanging, and a failing write never zeroes the
# previously recorded meta.
meta_f="$run_dir/findings/review.meta.json"
sum_before="$(shasum -a 256 "$meta_f")"
rc=0
tty_out="$(run_on_tty "$BIN/ac-ship.sh" meta review 2>&1)" || rc=$?
assert_eq "$rc" "1" "meta ingest on a tty refuses instead of hanging"
assert_contains "$tty_out" "refusing a tty" "meta tty refusal names the reason"
assert_eq "$(shasum -a 256 "$meta_f")" "$sum_before" "meta tty refusal leaves existing meta untouched"

# A write that fails AFTER the type gate passes (jq stubbed to fail only on
# the write-stage call) must leave the previously recorded meta byte-identical
# and never leave a temp file behind - the destructive-write regression itself
# (`>` truncates before jq produces a byte).
realjq="$(command -v jq)"
metajqstub="$TMP/metajqstub"; mkdir -p "$metajqstub"
cat >"$metajqstub/jq" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "." ]; then
  exit 1
fi
exec "$realjq" "\$@"
EOF
chmod +x "$metajqstub/jq"
sum_before="$(shasum -a 256 "$meta_f")"
# The stub must shadow jq for ac-ship.sh WITHOUT breaking the inner shell's own
# PATH: single-quoting the assignment leaves `$PATH` a literal directory name,
# `#!/usr/bin/env bash` then finds no bash, and an exit-status-only assertion
# passes on a 127 that never reached the script - so the reason is pinned here,
# not just the failure.
rc=0
stub_out="$(bash -c "printf '%s' '{\"risk_level\":\"high\"}' | PATH=\"$metajqstub:\$PATH\" '$BIN/ac-ship.sh' meta review" 2>&1)" || rc=$?
assert_eq "$rc" "1" "a write-stage jq failure refuses"
assert_contains "$stub_out" "meta review: write failed" \
  "the refusal names the failed write, not a broken harness"
assert_eq "$(shasum -a 256 "$meta_f")" "$sum_before" \
  "a failing write leaves the previous meta intact"
leftover="$(find "$run_dir/findings" -name 'review.meta.json.*' -print)"
assert_eq "$leftover" "" "no leftover temp file after a failed meta write"

# Auto-fix rounds are counted durably by `step <name> fixing`.
"$BIN/ac-ship.sh" step lint fixing >/dev/null
out="$("$BIN/ac-ship.sh" step lint fixing)"
assert_contains "$out" "auto-fix round 2" "fix round counter"
assert_contains "$("$BIN/ac-ship.sh" status)" "fix-rounds=2" "rounds in status"

# Review completion is fail-closed on independent-reviewer evidence. The
# crew-ship adapter invokes the exact-ref verifier once per round, never owns a
# reviewer session/pane, and carries only structured prior output forward.
assert_fails "$BIN/ac-ship.sh" step review completed
stub="$TMP/shipstub"; mkdir -p "$stub"
export VERIFY_LOG="$TMP/verify.log"
cat >"$stub/ac-verify" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$VERIFY_LOG"
[ "${1:-}" = codereview ] || exit 2
shift
output=""; ref=""; history=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift ;;
    --ref) ref="$2"; shift ;;
    --history) history="$2"; shift ;;
    --repo|--base|--family|--caller|--intent|--owner) shift ;;
    *) exit 2 ;;
  esac
  shift
done
[ -z "$history" ] || jq -e 'type == "array" and length > 0
  and all(.[]; (.round | type) == "number" and (.reviewed_ref | type) == "string"
    and (.verdict | type) == "string" and (.findings | type) == "array")' "$history" >/dev/null
# $RA_VERDICT selects the round's shape (default the landable one). A round
# whose verdict is `pass` FREEZES the tree, so the rounds below that are
# followed by another commit must report `fix` - that is what a fix round IS.
jq -n --arg ref "$ref" --arg v "${RA_VERDICT:-pass}" '{findings:[{id:"ra1",severity:"warning",action:(if $v == "fix" then "fix" else "no-op" end),description:"observed",authority_class:"internal",authority:"tests/ac-ship.test.sh"}],summary:"clean",risk_level:"low",risk_rationale:"bounded",reviewed_ref:$ref,verdict:$v}' >"$output"
cat "$output"
EOF
chmod +x "$stub/ac-verify"
defbranch="$(git -C "$repo" symbolic-ref --short HEAD)"
git -C "$repo" checkout -qb crew/ra
printf 'x\n' >>"$repo/f.txt" && git -C "$repo" add f.txt && git -C "$repo" commit -qm "change"
reviewed_ref="$(git -C "$repo" rev-parse HEAD)"
# S3 entry precondition (review-round-convergence): with neither a completed
# test step nor a fresh attestation, review-agent refuses BEFORE any verifier
# runs - a suite-catchable failure must never burn a review round.
rc=0
pre_out="$(AC_CREW_ID=ra-implement AC_VERIFY_BIN="$stub/ac-verify" "$BIN/ac-ship.sh" review-agent 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "review-agent must refuse without test evidence"
assert_contains "$pre_out" "without test evidence" "the refusal names the missing evidence"
assert_contains "$pre_out" "attest-test" "the refusal names the attestation remedy"
assert_no_file "$TMP/verify.log" "no verifier round was spent on the refusal"
"$BIN/ac-ship.sh" step test completed --note "suite green pre-review" >/dev/null
out="$(RA_VERDICT=fix AC_CREW_ID=ra-implement AC_VERIFY_BIN="$stub/ac-verify" "$BIN/ac-ship.sh" review-agent)"
assert_contains "$out" "review-agent round 1" "review-agent adapter runs"
assert_contains "$(cat "$VERIFY_LOG")" "codereview" "ship delegates to the verifier facade"
assert_contains "$(cat "$VERIFY_LOG")" "--ref $reviewed_ref" "ship passes the exact current ref"
assert_contains "$(cat "$VERIFY_LOG")" "--family ra" "ship derives the task family once"
assert_contains "$(cat "$VERIFY_LOG")" "--caller ra-implement" "ship names the execution caller"
case "$(cat "$VERIFY_LOG")" in *--resume*|*--replace-pane*) fail "ship must not own verifier session or pane lifecycle" ;; esac
run_dir2="$repo/.crew/ship/$(readlink "$repo/.crew/ship/current")"
assert_file "$run_dir2/review.agent" "independent review marker written"
assert_no_file "$run_dir2/review.session" "normal review no longer writes a session"
assert_no_file "$run_dir2/review.pane" "normal review no longer writes a pane"
assert_eq "$(jq -r '.[0].id' "$run_dir2/findings/review.json")" "ra1" "facade findings routed to review state"
# F9's trusted bypass: review-agent (the resolution) replaced review.json
# wholesale and dropped RF1's earlier `fix` finding with no refusal - the
# guard above binds only the plain CLI re-post path.
assert_eq "$(jq '[.[] | select(.id == "RF1")] | length' "$run_dir2/findings/review.json")" "0" \
  "review-agent may resolve/drop a recorded fix finding without the F9 refusal"
assert_eq "$(jq -r '.risk_level' "$run_dir2/findings/review.meta.json")" "low" "facade risk routed to review metadata"
assert_eq "$(sed -n 's/^reviewed_ref=//p' "$run_dir2/review.agent")" "$reviewed_ref" "review marker binds the exact ref"

# A source-changing fix opens a fresh verifier round and supplies only the
# immediately previous durable round result as history; old PASS authority and
# context are not reused.
printf 'y\n' >>"$repo/f.txt" && git -C "$repo" commit -qam "fix review"
assert_fails "$BIN/ac-ship.sh" step review completed
"$BIN/ac-ship.sh" step review fixing >/dev/null
fixed_ref="$(git -C "$repo" rev-parse HEAD)"
out="$(RA_VERDICT=fix AC_CREW_ID=ra-implement AC_VERIFY_BIN="$stub/ac-verify" "$BIN/ac-ship.sh" review-agent)"
assert_contains "$out" "review-agent round 2" "fix launches the next sequential review round"
last_call="$(tail -n 1 "$VERIFY_LOG")"
assert_contains "$last_call" "--ref $fixed_ref" "fresh round binds the fixed ref"
assert_contains "$last_call" "--history $run_dir2/logs/review-history-r2.json" "fresh round carries previous-round history"
case "$last_call" in *--resume*|*--replace-pane*) fail "fresh review rounds never resume or replace context" ;; esac
assert_eq "$(jq -r 'length' "$run_dir2/logs/review-history-r2.json")" "1" "round-2 ledger holds exactly the r1 entry"
assert_eq "$(jq -r '.[0].round' "$run_dir2/logs/review-history-r2.json")" "1" "ledger entry names its round"
assert_eq "$(jq -r '.[0].reviewed_ref' "$run_dir2/logs/review-history-r2.json")" "$reviewed_ref" "ledger entry binds r1's exact reviewed ref"
assert_eq "$(jq -r '.[0].findings[0].id' "$run_dir2/logs/review-history-r2.json")" "ra1" "ledger entry carries r1's structured findings"

# Round 3 carries only the immediately previous durable round result. Older
# findings resolved before r2 are history, not obligations to re-attest.
printf 'z\n' >>"$repo/f.txt" && git -C "$repo" commit -qam "fix review again"
"$BIN/ac-ship.sh" step review fixing >/dev/null
out="$(RA_VERDICT=fix AC_CREW_ID=ra-implement AC_VERIFY_BIN="$stub/ac-verify" "$BIN/ac-ship.sh" review-agent)"
assert_contains "$out" "review-agent round 3" "second fix launches round 3"
assert_contains "$(tail -n 1 "$VERIFY_LOG")" "--history $run_dir2/logs/review-history-r3.json" "round 3 carries its own ledger file"
assert_eq "$(jq -r 'length' "$run_dir2/logs/review-history-r3.json")" "1" "round-3 history holds only the r2 entry"
assert_eq "$(jq -r '.[0].round' "$run_dir2/logs/review-history-r3.json")" "2" "round-3 history names the previous round"
assert_eq "$(jq -r '.[0].reviewed_ref' "$run_dir2/logs/review-history-r3.json")" "$fixed_ref" "round-3 history binds r2's exact reviewed ref"

# A REJECTED round must leave the run exactly where it was, and a RETRY must be
# able to break out of it. This is the anti-regression half of the reviewed_ref
# deadlock: the failure mode was a verifier round dying on the handoff, so
# review.agent kept the PREVIOUS ref while HEAD moved and delivery refused
# forever. The loop is only self-sustaining while the rejection RECURS - and
# nothing may "fix" that by stamping review.agent on a rejected round, by
# burning the round counter, or by relaxing the staleness refusal.
printf 'w\n' >>"$repo/f.txt" && git -C "$repo" commit -qam "fix review a third time"
"$BIN/ac-ship.sh" step review fixing >/dev/null
ref_before="$(sed -n 's/^reviewed_ref=//p' "$run_dir2/review.agent" | tail -n 1)"
rounds_before="$(awk -F'\t' '$1 == "review" { print $3 + 0 }' "$run_dir2/steps.tsv")"
cat >"$stub/ac-verify-dead" <<'EOF'
#!/usr/bin/env bash
# The die_reaped shape: non-zero, and --output is never written.
exit 1
EOF
chmod +x "$stub/ac-verify-dead"
rc=0
out="$(AC_CREW_ID=ra-implement AC_VERIFY_BIN="$stub/ac-verify-dead" "$BIN/ac-ship.sh" review-agent 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a verifier round that produced no result must fail the adapter"
assert_contains "$out" "round 4" "the failed round names itself"
assert_eq "$(sed -n 's/^reviewed_ref=//p' "$run_dir2/review.agent" | tail -n 1)" "$ref_before" \
  "a rejected round never stamps the receipt onto a ref no reviewer verdicted"
assert_eq "$(awk -F'\t' '$1 == "review" { print $3 + 0 }' "$run_dir2/steps.tsv")" "$rounds_before" \
  "a rejected round does not burn the round counter, so the retry is the SAME round"
assert_no_file "$run_dir2/logs/review-agent-r4.json" "a rejected round writes no durable result"
rc=0; out="$("$BIN/ac-ship.sh" step review completed 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "the stale receipt must still refuse while no round has succeeded"
assert_contains "$out" "review receipt is stale" "the guard the deadlock rides on is untouched"
# The retry breaks the loop: same round, and the receipt rebinds to HEAD.
out="$(AC_CREW_ID=ra-implement AC_VERIFY_BIN="$stub/ac-verify" "$BIN/ac-ship.sh" review-agent)"
assert_contains "$out" "review-agent round 4" "the retry reruns the SAME round, not a new one"
assert_eq "$(sed -n 's/^reviewed_ref=//p' "$run_dir2/review.agent" | tail -n 1)" \
  "$(git -C "$repo" rev-parse HEAD)" "a succeeding retry rebinds the receipt to current HEAD"

"$BIN/ac-ship.sh" step review completed >/dev/null
git -C "$repo" checkout -q "$defbranch"

# Calling review-agent again on the exact latest durable reviewed_ref is always
# refused before verifier spend, regardless of whether the held verdict was
# pass, fix, or ask-user.
sameheadstub="$TMP/sameheadstub"; mkdir -p "$sameheadstub"
export SAMEHEAD_LOG="$TMP/samehead-verify.log"
cat >"$sameheadstub/ac-verify" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$SAMEHEAD_LOG"
[ "${1:-}" = codereview ] || exit 2
shift
output=""; ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift ;;
    --ref) ref="$2"; shift ;;
    --repo|--base|--family|--caller|--intent|--history|--owner) shift ;;
    *) exit 2 ;;
  esac
  shift
done
case "${SAMEHEAD_VERDICT:-pass}" in
  pass)
    jq -n --arg ref "$ref" '{findings:[{id:"same-pass",severity:"info",action:"no-op",description:"note"}],summary:"s",risk_level:"low",risk_rationale:"r",reviewed_ref:$ref,verdict:"pass"}' >"$output" ;;
  fix)
    jq -n --arg ref "$ref" '{findings:[{id:"same-fix",severity:"warning",action:"fix",file:"file.txt",class:"regression",description:"bug",authority_class:"internal",authority:"tests/ac-ship.test.sh:1"}],summary:"s",risk_level:"low",risk_rationale:"r",reviewed_ref:$ref,verdict:"fix"}' >"$output" ;;
  ask-user)
    jq -n --arg ref "$ref" '{findings:[{id:"same-ask",severity:"warning",action:"ask-user",description:"choose",question:"Which path?",options:["a","b"],tradeoffs:["A","B"],recommendation:"a"}],summary:"s",risk_level:"medium",risk_rationale:"r",reviewed_ref:$ref,verdict:"ask-user"}' >"$output" ;;
  *) exit 2 ;;
esac
cat "$output"
EOF
chmod +x "$sameheadstub/ac-verify"
samehead_calls() { [ -f "$SAMEHEAD_LOG" ] && wc -l <"$SAMEHEAD_LOG" || printf '0\n'; }
for verdict in pass fix ask-user; do
  shrepo="$(make_repo "samehead-$verdict")"
  cd "$shrepo" || fail "cd samehead $verdict"
  cat >"$AC_HOME/projects/samehead-$verdict.yaml" <<'EOF'
commands:
  test: "echo test-ok"

review:
  max_rounds: 9
EOF
  "$BIN/ac-ship.sh" start --intent "same-head $verdict" --skip pr >/dev/null
  git -C "$shrepo" checkout -qb "crew/samehead-$verdict"
  printf 'work\n' >>"$shrepo/file.txt" && git -C "$shrepo" commit -qam work
  "$BIN/ac-ship.sh" step test completed --note "suite green" >/dev/null
  SAMEHEAD_VERDICT="$verdict" AC_CREW_ID="samehead-$verdict-implement" \
    AC_VERIFY_BIN="$sameheadstub/ac-verify" "$BIN/ac-ship.sh" review-agent >/dev/null
  calls_before="$(samehead_calls)"
  rc=0
  out="$(SAMEHEAD_VERDICT="$verdict" AC_CREW_ID="samehead-$verdict-implement" \
    AC_VERIFY_BIN="$sameheadstub/ac-verify" "$BIN/ac-ship.sh" review-agent 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "same-HEAD review-agent retry after $verdict must refuse"
  assert_contains "$out" "already reviewed" "same-HEAD refusal after $verdict names the no-op retry"
  assert_eq "$(samehead_calls)" "$calls_before" "same-HEAD refusal after $verdict spends no verifier"
done
cd "$repo" || fail "cd back from samehead"

# fix-report renders the hold-and-fix handoff contract: to-fix = fix +
# captain-DECIDED ask-user; undecided ask-user parks; no-op omitted; round
# and cap from steps.tsv + auto_fix config; a view only (JSON stays truth).
# L5 is a fix finding with NO authority: the shared normalizer downgrades it,
# and the fixer must SEE why it is parked rather than wonder where it went.
printf '%s' '[
  {"id":"L1","severity":"error","action":"fix","file":"bin/x.sh","line":7,"description":"unquoted var","authority_class":"internal","authority":"bin/ac-lint.sh:12 declares the quoting rule"},
  {"id":"L2","severity":"warning","action":"ask-user","description":"rename flag?","decision":"yes, rename to --force"},
  {"id":"L3","severity":"warning","action":"ask-user","description":"drop legacy path?"},
  {"id":"L4","severity":"info","action":"no-op","description":"style nit"},
  {"id":"L5","severity":"error","action":"fix","description":"herdr should requeue"}
]' | "$BIN/ac-ship.sh" findings lint >/dev/null
assert_eq "$(jq -r '.[0].action' "$run_dir/findings/lint.json")" "fix" "a fix finding with authority passes through the normalizer"
fr="$("$BIN/ac-ship.sh" fix-report lint)"
assert_contains "$fr" "step lint (fix round 3/5)" "round and cap in header"
assert_contains "$fr" "Intent: ship the widget" "intent carried"
assert_contains "$fr" "## Findings to fix (2)" "to-fix count"
assert_contains "$fr" "bin/x.sh:7 - unquoted var (L1)" "file:line rendering"
assert_contains "$fr" "authority: bin/ac-lint.sh:12 declares the quoting rule" "to-fix lines carry the authority"
assert_contains "$fr" "DECIDED: yes, rename to --force" "decided ask-user included"
assert_contains "$fr" "Parked - awaiting captain" "undecided parks"
assert_contains "$fr" "drop legacy path?" "parked item listed"
assert_contains "$fr" "NO AUTHORITY NAMED" "a downgraded finding is marked in the parked section"
case "$fr" in *"style nit"*) fail "no-op findings must be omitted" ;; esac
assert_contains "$fr" "Do NOT push" "contract present"
assert_fails "$BIN/ac-ship.sh" fix-report push
assert_fails "$BIN/ac-ship.sh" fix-report bogus

# base recomputes; skip-remaining skips what's left.
assert_eq "$("$BIN/ac-ship.sh" base)" "$(git -C "$repo" rev-parse HEAD)" "fresh base"
"$BIN/ac-ship.sh" skip-remaining >/dev/null
assert_contains "$("$BIN/ac-ship.sh" status)" "push       skipped" "skip-remaining"

# F4: skip-remaining stays BYTE-IDENTICAL - it never goes through cmd_start's
# --skip name validation (a separate command entirely), so a run that calls
# it immediately still marks EVERY still-pending step skipped, intent and
# review included - proving the new --skip refusal gates only the start
# flag, never this empty-diff flow.
srrepo="$(make_repo skiprepo)"
cd "$srrepo" || fail "cd skiprepo"
"$BIN/ac-ship.sh" start --intent "skip-remaining still works" >/dev/null
"$BIN/ac-ship.sh" skip-remaining >/dev/null
srrun="$srrepo/.crew/ship/$(readlink "$srrepo/.crew/ship/current")"
assert_eq "$(awk -F'\t' '$1=="intent"{print $2}' "$srrun/steps.tsv")" "skipped" \
  "skip-remaining still skips a pending intent - unaffected by the F4 --skip refusal on start"
assert_eq "$(awk -F'\t' '$1=="review"{print $2}' "$srrun/steps.tsv")" "skipped" \
  "skip-remaining still skips a pending review - unaffected by the F4 --skip refusal on start"
cd "$repo" || fail "cd back from skiprepo"

# evidence-dir: temp by default. A home config update does not change the
# running ship snapshot.
ev="$("$BIN/ac-ship.sh" evidence-dir)"
case "$ev" in */agent-crew-evidence/*) : ;; *) fail "expected temp evidence dir, got $ev" ;; esac
cat >>"$ship_cfg" <<'EOF'

test:
  evidence:
    store_in_repo: true
    dir: evidence
EOF
ev="$("$BIN/ac-ship.sh" evidence-dir)"
case "$ev" in */agent-crew-evidence/*) : ;; *) fail "running ship must keep its original config snapshot, got $ev" ;; esac

# Finish records the outcome (checks-passed is the agent stop point) and
# validate state never dirties the repo. Normal verifier pane lifecycle has
# already been closed by ac-verify, so ship owns no live pane at finish.
# The fail-closed finish gate needs every non-skipped step completed and no
# unresolved finding: lint is still `fixing` with fix/undecided-ask-user
# findings on record, so complete it and re-record a resolved set (only a
# no-op remains, as the reviewer's re-run would leave it).
"$BIN/ac-ship.sh" step lint completed >/dev/null
printf '[{"id":"L4","severity":"info","action":"no-op","description":"style nit"}]' \
  | "$BIN/ac-ship.sh" findings lint >/dev/null
# Back onto the run's own branch: the checkout above (line 220) parked HEAD on
# the default branch for the base/fix-report assertions, and finish binds the
# reviewed ref to HEAD (assert_review_current). A real run finishes where it
# was reviewed - on its crew branch - so restore that before finishing.
git -C "$repo" checkout -q crew/ra
finish_out="$("$BIN/ac-ship.sh" finish checks-passed)"
assert_contains "$(cat "$run_dir/run.meta")" "outcome=checks-passed" "outcome"
# checks-passed is the crew-ship completion signal: finish emits the anchored
# checks-passed: marker (AC_CAPTAIN_RE) so the chief wakes and stamps the pane
# as awaiting the captain's merge. A colon-anchored line-start marker.
re="$(bash -c ". '$BIN/ac-lib.sh'; printf '%s' \"\$AC_CAPTAIN_RE\"")"
printf '%s\n' "$finish_out" | grep -qE "$re" || fail "finish checks-passed emits a line the chief wakes on"
printf '%s\n' "$finish_out" | grep -qE '^checks-passed: ' || fail "finish emits the anchored checks-passed: marker"
assert_eq "$(git -C "$repo" status --porcelain)" "" "repo stays clean"

# An ALREADY-GONE reviewer pane must not abort finish (mirrors ac-qa.sh's
# `|| true` guard on the same herdr close call, ac-qa.sh:3818-3822): a
# pane-helper stub that fails on `close` still lets finish record the
# outcome and print its marker. cancelled/failed skip the fail-closed gate,
# so no step setup is needed for this run. Runs in its own repo - $repo's
# current run must stay the checks-passed one for the later watch assertions.
export CLLOG="$TMP/cl.log"
cat >"$stub/pane-helper-fail" <<'EOF'
#!/usr/bin/env bash
echo "helper $*" >>"$CLLOG"
exit 1
EOF
chmod +x "$stub/pane-helper-fail"
gonerepo="$(make_repo panegonerepo)"
git -C "$gonerepo" checkout -qb crew/gone
( cd "$gonerepo" \
  && out="$("$BIN/ac-ship.sh" start --intent "pane already gone")" \
  && assert_contains "$out" "started run" "gone-pane run starts" \
  && gonerun="$gonerepo/.crew/ship/$(readlink "$gonerepo/.crew/ship/current")" \
  && printf 'w9:pGone\n' >"$gonerun/review.pane" \
  && : >"$CLLOG" \
  && rc=0 \
  && { finish_out2="$(AC_PANE_AGENT="$stub/pane-helper-fail" "$BIN/ac-ship.sh" finish cancelled 2>&1)" || rc=$?; } \
  && { [ "$rc" -eq 0 ] || fail "finish must survive an already-gone reviewer pane, got rc=$rc: $finish_out2"; } \
  && assert_contains "$(cat "$CLLOG")" "helper close --pane w9:pGone" "finish still attempted the close" \
  && assert_contains "$(cat "$gonerun/run.meta")" "outcome=cancelled" "outcome recorded despite gone review pane" \
  && assert_contains "$(cat "$gonerun/run.meta")" "finished_at=" "finished_at recorded despite gone review pane" \
  && assert_no_file "$gonerun/review.pane" "review pane handle cleaned even when close fails" )

# A fresh run in another project snapshot reads its installed config without
# replacing the original repo's current run (later watch assertions inspect it).
erepo="$(make_repo evidrepo)"
cp "$ship_cfg" "$AC_HOME/projects/evidrepo.yaml"
git -C "$erepo" checkout -qb crew/widget
cd "$erepo" || fail "cd evidrepo"
"$BIN/ac-ship.sh" start --intent "configured evidence" >/dev/null
ev="$("$BIN/ac-ship.sh" evidence-dir)"
assert_eq "$ev" "$erepo/evidence/crew-widget" "fresh run reads the updated home config"
"$BIN/ac-ship.sh" finish cancelled >/dev/null
cd "$repo" || fail "cd back from evidrepo"

# push: guarded publication against a real origin.
origin_bare="$TMP/origin.git"
git init -q --bare "$origin_bare"
work="$TMP/pushwork"
git init -q -b main "$work"
git -C "$work" remote add origin "$origin_bare"
git -C "$work" config user.email test@test
git -C "$work" config user.name test
( cd "$work" \
  && printf 'base\n' >f.txt && git add -A && git commit -qm base \
  && git push -qu origin main 2>/dev/null \
  && git checkout -qb crew/p1 \
  && printf 'feature\n' >>f.txt && git commit -qam feature \
  && "$BIN/ac-ship.sh" start --intent "push test" >/dev/null \
  && "$BIN/ac-ship.sh" push >/dev/null 2>&1 ) || fail "guarded push of new branch"
assert_eq "$(git -C "$origin_bare" rev-parse refs/heads/crew/p1)" \
  "$(git -C "$work" rev-parse HEAD)" "new branch pushed"
( cd "$work" && "$BIN/ac-ship.sh" push 2>&1 | grep -q up-to-date ) || fail "up-to-date detection"
# Simulate an unincorporated remote commit: push must refuse (fail closed).
other="$TMP/pushother"
git clone -q "$origin_bare" "$other" 2>/dev/null
git -C "$other" config user.email o@test
git -C "$other" config user.name other
( cd "$other" && git checkout -q crew/p1 \
  && printf 'remote-only\n' >>f.txt && git commit -qam remote-only && git push -q origin crew/p1 2>/dev/null )
( cd "$work" && printf 'local-more\n' >g.txt && git add g.txt && git commit -qm local-more )
rc=0; ( cd "$work" && "$BIN/ac-ship.sh" push >/dev/null 2>&1 ) || rc=$?
[ "$rc" -ne 0 ] || fail "push must refuse unincorporated remote commits"
assert_eq "$(git -C "$origin_bare" rev-parse refs/heads/crew/p1)" \
  "$(git -C "$other" rev-parse HEAD)" "remote untouched after refusal"
# Incorporate (rebase onto the remote tip) - the guarded force push proceeds.
( cd "$work" && git fetch -q origin && git rebase -q origin/crew/p1 \
  && "$BIN/ac-ship.sh" push >/dev/null 2>&1 ) || fail "guarded push after incorporation"
assert_eq "$(git -C "$origin_bare" rev-parse refs/heads/crew/p1)" \
  "$(git -C "$work" rev-parse HEAD)" "lease push landed"
# The env-hardening reaches git: a wrapper that logs its environment then execs
# the real git proves cmd_push exports GIT_TERMINAL_PROMPT=0, so an
# uncached-credential remote fails closed instead of hanging at a username
# prompt. (A local bare origin never prompts, so the happy path above is blind
# to it - this is the assertion that would have caught a regression.)
realgit="$(command -v git)"
gitstub="$TMP/gitenvstub"; mkdir -p "$gitstub"
cat >"$gitstub/git" <<EOF
#!/usr/bin/env bash
printf 'TP=%s\n' "\${GIT_TERMINAL_PROMPT-unset}" >>"$TMP/gitenv.log"
exec "$realgit" "\$@"
EOF
chmod +x "$gitstub/git"
: >"$TMP/gitenv.log"
# TP=0 appears iff cmd_push's own git calls saw the export - no other function
# sets it. (The top-level `git rev-parse --show-toplevel` at script load runs
# before any command with TP=unset; that is fine - it is local and never hangs,
# so the log legitimately holds both values.)
( cd "$work" && PATH="$gitstub:$PATH" "$BIN/ac-ship.sh" push >/dev/null 2>&1 ) || true
assert_contains "$(cat "$TMP/gitenv.log")" "TP=0" "cmd_push exports GIT_TERMINAL_PROMPT=0 to git"
# Refusals: detached HEAD and the default branch.
( cd "$work" && git checkout -q main )
rc=0; ( cd "$work" && "$BIN/ac-ship.sh" push >/dev/null 2>&1 ) || rc=$?
[ "$rc" -ne 0 ] || fail "push must refuse the default branch"

# REBASE CARRY-FORWARD: a branch rebased THROUGH A CONFLICT must still push.
# Resolving a conflict rewrites the commit's diff, so its patch-id changes and
# `rev-list --cherry-pick` stops cancelling the pre-rebase commit - the guard
# then reads the branch's own superseded history as unincorporated remote work
# and refuses the most ordinary step of a multi-PR chain. The fixture builds the
# real thing (a genuine conflict, resolved) rather than editing a sha by hand.
cb_origin="$TMP/cborigin.git"
git init -q --bare "$cb_origin"
cbwork="$TMP/cbwork"
git init -q -b main "$cbwork"
git -C "$cbwork" remote add origin "$cb_origin"
git -C "$cbwork" config user.email test@test
git -C "$cbwork" config user.name test
( cd "$cbwork" \
  && printf 'l1\nl2\nl3\n' >f.txt && git add -A && git commit -qm base \
  && git push -qu origin main 2>/dev/null \
  && git checkout -qb crew/p2 \
  && printf 'l1\nFEATURE\nl3\n' >f.txt && git commit -qam feature \
  && "$BIN/ac-ship.sh" start --intent "carry-forward test" >/dev/null \
  && "$BIN/ac-ship.sh" push >/dev/null 2>&1 ) || fail "carry-forward fixture: first push"
cb_pushed="$(git -C "$cb_origin" rev-parse refs/heads/crew/p2)"
# main advances over the SAME line: the rebase below cannot avoid the conflict.
( cd "$cbwork" && git checkout -q main \
  && printf 'l1\nMAIN-ADVANCED\nl3\n' >f.txt && git commit -qam main-advance \
  && git push -q origin main 2>/dev/null && git checkout -q crew/p2 ) \
  || fail "carry-forward fixture: main advance"
( cd "$cbwork" && ! git rebase -q main >/dev/null 2>&1 ) \
  || fail "carry-forward fixture: the rebase was expected to conflict"
( cd "$cbwork" && printf 'l1\nFEATURE-ON-MAIN-ADVANCED\nl3\n' >f.txt && git add f.txt \
  && GIT_EDITOR=true git rebase --continue >/dev/null 2>&1 ) \
  || fail "carry-forward fixture: conflict resolution"
[ "$(git -C "$cbwork" rev-parse HEAD)" != "$cb_pushed" ] \
  || fail "carry-forward fixture: the rebase did not rewrite the commit"
rc=0; out="$( cd "$cbwork" && "$BIN/ac-ship.sh" push 2>&1 )" || rc=$?
[ "$rc" -eq 0 ] || fail "a branch rebased through a conflict must push: $out"
assert_eq "$(git -C "$cb_origin" rev-parse refs/heads/crew/p2)" \
  "$(git -C "$cbwork" rev-parse HEAD)" "the conflict-rebased branch landed on origin"
# THE OTHER DIRECTION: a stranger's commit moves the ref OFF the head this
# pipeline published, so it is not this branch's superseded history and the very
# next push - same run, same branch, record and all - must still refuse.
cbother="$TMP/cbother"
git clone -q "$cb_origin" "$cbother" 2>/dev/null
git -C "$cbother" config user.email o@test
git -C "$cbother" config user.name other
( cd "$cbother" && git checkout -q crew/p2 \
  && printf 'stranger\n' >g.txt && git add g.txt && git commit -qm stranger-work \
  && git push -q origin crew/p2 2>/dev/null ) || fail "carry-forward fixture: divergence"
cb_diverged="$(git -C "$cb_origin" rev-parse refs/heads/crew/p2)"
( cd "$cbwork" && printf 'more\n' >>f.txt && git commit -qam local-more ) \
  || fail "carry-forward fixture: local commit after divergence"
rc=0; out="$( cd "$cbwork" && "$BIN/ac-ship.sh" push 2>&1 )" || rc=$?
[ "$rc" -ne 0 ] || fail "a genuine divergence must still be refused: $out"
assert_contains "$out" "unincorporated" "the refusal is the incorporation guard"
assert_eq "$(git -C "$cb_origin" rev-parse refs/heads/crew/p2)" "$cb_diverged" \
  "the diverged remote is untouched by the refusal"
( cd "$cbwork" && "$BIN/ac-ship.sh" finish cancelled >/dev/null )

# Live dashboard: --once renders the run frame; start auto-opens the watch
# tab (stubbed herdr) and finish retires it; AC_SHIP_WATCH=off suppresses.
frame="$("$BIN/ac-ship-watch.sh" --repo "$repo" --once)"
assert_contains "$frame" "ac-ship" "watch renders header"
assert_contains "$frame" "intent: ship the widget" "watch shows intent"
assert_contains "$frame" "findings lint" "watch shows findings summary"
wrepo="$(make_repo watchrepo)"
export WHLOG="$TMP/wh.log"
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$WHLOG"
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "pane list") echo '{"result":{"panes":[]}}' ;;
  "workspace get") exit 1 ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wW"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tW"},"root_pane":{"pane_id":"pW1"}}}' ;;
esac
exit 0
EOF
chmod +x "$stub/herdr"
cd "$wrepo" || fail "cd wrepo"
out="$(PATH="$stub:$PATH" AC_SHIP_WATCH=auto "$BIN/ac-ship.sh" start --intent "watch me")"
assert_contains "$out" "started run" "start with watch"
wlog="$(cat "$WHLOG")"
assert_contains "$wlog" "tab create --workspace wW" "watch tab opened in the agents group"
assert_contains "$wlog" "pane rename pW1 ac-ship-watch" "watch pane labeled"
assert_contains "$wlog" "ac-ship-watch.sh" "watch script launched"
wrun="$wrepo/.crew/ship/$(readlink "$wrepo/.crew/ship/current")"
assert_eq "$(cat "$wrun/watch.pane")" "pW1" "watch pane recorded"
PATH="$stub:$PATH" "$BIN/ac-ship.sh" finish cancelled >/dev/null
assert_contains "$(cat "$WHLOG")" "pane close pW1" "finish retires the watch pane"
assert_no_file "$wrun/watch.pane" "watch pane handle cleaned"

# An ALREADY-GONE watch pane must not abort finish either: a herdr stub
# that fails on `pane close` still lets finish record the outcome.
cat >"$stub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$WHLOG"
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "pane list") echo '{"result":{"panes":[]}}' ;;
  "workspace get") exit 1 ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wW"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tW"},"root_pane":{"pane_id":"pW1"}}}' ;;
  "pane close") exit 1 ;;
esac
exit 0
EOF
chmod +x "$stub/herdr"
: >"$WHLOG"
out="$(PATH="$stub:$PATH" AC_SHIP_WATCH=auto "$BIN/ac-ship.sh" start --intent "watch gone")"
assert_contains "$out" "started run" "second watch run starts"
wrun2="$wrepo/.crew/ship/$(readlink "$wrepo/.crew/ship/current")"
assert_eq "$(cat "$wrun2/watch.pane")" "pW1" "watch pane recorded again"
rc=0
finish_out2="$(PATH="$stub:$PATH" "$BIN/ac-ship.sh" finish cancelled 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "finish must survive a watch-pane close failure, got rc=$rc: $finish_out2"
assert_contains "$(cat "$wrun2/run.meta")" "outcome=cancelled" "outcome recorded despite gone watch pane"
assert_contains "$(cat "$wrun2/run.meta")" "finished_at=" "finished_at recorded despite gone watch pane"
assert_no_file "$wrun2/watch.pane" "watch pane handle cleaned even when close fails"
: >"$WHLOG"
PATH="$stub:$PATH" AC_SHIP_WATCH=off "$BIN/ac-ship.sh" start --intent "quiet" >/dev/null
case "$(cat "$WHLOG")" in *"tab create"*) fail "AC_SHIP_WATCH=off must not open a tab" ;; esac
# An ACTIVE step transition re-ensures the dashboard (reopened runs / lost panes).
: >"$WHLOG"
PATH="$stub:$PATH" AC_SHIP_WATCH=auto "$BIN/ac-ship.sh" step intent running >/dev/null
assert_contains "$(cat "$WHLOG")" "tab create --workspace wW" "active step re-opens the watch"
# A reopened run (finished outcome but an active step) is not "finished".
PATH="$stub:$PATH" "$BIN/ac-ship.sh" step review fixing >/dev/null
frame="$("$BIN/ac-ship-watch.sh" --repo "$wrepo" --once)"
case "$frame" in *"run finished"*) fail "reopened run must not read as finished" ;; esac
assert_contains "$frame" "▶ review" "active step marked in reopened run"
# The board is embedded in the pane-run line as an ABSOLUTE path: the pane is
# created with --cwd "$repo", a DIFFERENT directory than the caller's, so a
# caller-relative "$(dirname "$0")" reaches it as a path that does not resolve
# there. `binlink` reproduces a chief's relative `bin/ac-ship.sh` invocation.
ln -s "$BIN" "$wrepo/binlink"
: >"$WHLOG"
PATH="$stub:$PATH" AC_SHIP_WATCH=auto binlink/ac-ship.sh start --intent "relative call" >/dev/null
wsp="$(sed -n "s/.*'\([^']*ac-ship-watch\.sh\)'.*/\1/p" "$WHLOG" | head -1)"
case "$wsp" in /*) ;; *) fail "watch board must be absolute in the pane command, got '$wsp'" ;; esac
cd "$repo" || fail "cd back"

# --- TDD attestation: attestation by execution, honored by the test step ---
arepo="$(make_repo attrepo)"
cd "$arepo" || fail "cd attrepo"
git -C "$arepo" checkout -qb crew/tdd
attlog="$TMP/att.log"
att_cfg="$AC_HOME/projects/attrepo.yaml"
cat >"$att_cfg" <<EOF
commands:
  test: "echo run >>$attlog && echo att-ok"
EOF

# Dirty tree refused BEFORE running anything; nothing is written or run.
printf 'dirty\n' >>"$arepo/file.txt"
rc=0; "$BIN/ac-ship.sh" attest-test >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "attest-test must refuse a dirty tree"
assert_no_file "$arepo/.crew/ship/attest-test.json" "no attestation from a dirty tree"
assert_no_file "$attlog" "dirty-tree refusal must not run the suite"
git -C "$arepo" checkout -q -- file.txt

# A failing test command propagates its exit code and writes NOTHING.
printf 'commands:\n  test: "exit 7"\n' >"$att_cfg"
rc=0; "$BIN/ac-ship.sh" attest-test >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "7" "attest-test propagates the test exit code"
assert_no_file "$arepo/.crew/ship/attest-test.json" "failed run writes no attestation"

# attest-check with no attestation on disk: exit 2.
rc=0; out="$("$BIN/ac-ship.sh" attest-check)" || rc=$?
assert_eq "$rc" "2" "attest-check exits 2 with no attestation"
assert_contains "$out" "no attestation" "attest-check names the absence"

# A green run writes the attestation with the exact branch/commit/tree/cmd.
cat >"$att_cfg" <<EOF
commands:
  test: "echo run >>$attlog && echo att-ok"
EOF
out="$("$BIN/ac-ship.sh" attest-test 2>/dev/null)"
assert_contains "$out" "attested: commands.test green" "attest-test reports"
af="$arepo/.crew/ship/attest-test.json"
assert_file "$af" "attestation written"
assert_eq "$(jq -r .commit "$af")" "$(git -C "$arepo" rev-parse HEAD)" "attested commit is HEAD"
assert_eq "$(jq -r .tree "$af")" "$(git -C "$arepo" rev-parse 'HEAD^{tree}')" "attested tree is HEAD tree"
assert_eq "$(jq -r .branch "$af")" "crew/tdd" "attested branch"
assert_eq "$(jq -r .cmd "$af")" "echo run >>$attlog && echo att-ok" "attested cmd verbatim"
assert_eq "$(grep -c run "$attlog")" "1" "attest run executed the suite once"

# attest-check on the exact attested tree: fresh, exit 0, names the sha.
out="$("$BIN/ac-ship.sh" attest-check)" || fail "attest-check must exit 0 on a fresh attestation"
assert_contains "$out" "attested: fresh @$(git -C "$arepo" rev-parse HEAD | cut -c1-12)" "attest-check names the attested sha"
assert_eq "$(grep -c run "$attlog")" "1" "attest-check never runs the suite"

# Fresh attestation: the test step completes WITHOUT invoking the suite.
"$BIN/ac-ship.sh" start --intent "tdd change" >/dev/null
"$BIN/ac-ship.sh" step test running >/dev/null
out="$("$BIN/ac-ship.sh" cmd test 2>&1)" || fail "cmd test with fresh attestation must exit 0"
assert_contains "$out" "TDD attestation accepted" "acceptance reported"
assert_eq "$(grep -c run "$attlog")" "1" "suite NOT re-run on a fresh attestation"
arun="$arepo/.crew/ship/$(readlink "$arepo/.crew/ship/current")"
assert_contains "$("$BIN/ac-ship.sh" status)" "test       completed" "test step completed via attestation"
assert_eq "$(jq 'length' "$arun/findings/test.json")" "0" "attested step records empty findings"
assert_contains "$(jq -r .testing_summary "$arun/findings/test.meta.json")" "TDD attestation @" "meta notes the sha"
assert_contains "$(jq -r .testing_summary "$arun/findings/test.meta.json")" "suite not re-run" "meta notes the skip"

# Stale commit (hold-and-fix moves HEAD): the suite RUNS.
printf 'fix\n' >>"$arepo/file.txt"
git -C "$arepo" commit -qam "fix round"
# attest-check after the new commit: stale, exit 1, names why.
rc=0; out="$("$BIN/ac-ship.sh" attest-check)" || rc=$?
assert_eq "$rc" "1" "attest-check exits 1 on a stale attestation"
assert_contains "$out" "stale: commit moved" "attest-check names the staleness"
out="$("$BIN/ac-ship.sh" cmd test 2>&1)" || fail "stale-attestation suite run"
assert_contains "$out" "attestation not accepted" "stale attestation explained"
assert_eq "$(grep -c run "$attlog")" "2" "stale attestation re-runs the suite"

# A home config change does not alter the running snapshot. A fresh run picks
# up the new command and rejects the old-command attestation.
"$BIN/ac-ship.sh" attest-test >/dev/null 2>&1 || fail "re-attest at the new HEAD"
att2log="$TMP/att2.log"
cat >"$att_cfg" <<EOF
commands:
  test: "echo run2 >>$att2log && echo att2-ok"
EOF
out="$("$BIN/ac-ship.sh" cmd test 2>&1)" || fail "running snapshot must remain valid"
assert_contains "$out" "TDD attestation accepted" "running ship ignores a concurrent config update"
assert_no_file "$att2log" "updated home command does not run in the existing ship run"
"$BIN/ac-ship.sh" start --intent "changed config snapshot" >/dev/null
out="$("$BIN/ac-ship.sh" cmd test 2>&1)" || fail "changed-cmd suite run"
assert_contains "$out" "attestation not accepted" "changed cmd explained"
assert_eq "$(grep -c run2 "$att2log")" "1" "changed cmd re-runs the suite"
cat >"$att_cfg" <<EOF
commands:
  test: "echo run >>$attlog && echo att-ok"
EOF

# test.attestation: ignore -> the suite RUNS even with a fresh attestation.
printf '\ntest:\n  attestation: ignore\n' >>"$att_cfg"
"$BIN/ac-ship.sh" start --intent "ignore attestation config" >/dev/null
out="$("$BIN/ac-ship.sh" cmd test 2>&1)" || fail "ignore-mode suite run"
assert_contains "$out" "test.attestation=ignore" "ignore mode explained"
assert_eq "$(grep -c run "$attlog")" "4" "ignore mode re-runs the suite"
cat >"$att_cfg" <<EOF
commands:
  test: "echo run >>$attlog && echo att-ok"
EOF

# FORGED attestation (hand-written, wrong tree, right commit): the suite RUNS.
"$BIN/ac-ship.sh" start --intent "forged attestation" >/dev/null
jq -n --arg branch crew/tdd --arg commit "$(git -C "$arepo" rev-parse HEAD)" \
  --arg cmd "echo run >>$attlog && echo att-ok" --arg at "2026-01-01T00:00:00Z" \
  '{branch: $branch, commit: $commit, tree: "0000000000000000000000000000000000000000", cmd: $cmd, at: $at}' >"$af"
out="$("$BIN/ac-ship.sh" cmd test 2>&1)" || fail "forged-attestation suite run"
assert_contains "$out" "attestation not accepted" "forged attestation explained"
assert_contains "$out" "tree mismatch" "forgery caught on the tree hash"
assert_eq "$(grep -c run "$attlog")" "5" "forged attestation re-runs the suite"

# Unknown test.attestation value fails CLOSED: the suite runs.
printf '\ntest:\n  attestation: never\n' >>"$att_cfg"
"$BIN/ac-ship.sh" start --intent "unknown attestation config" >/dev/null
out="$("$BIN/ac-ship.sh" cmd test 2>&1)" || fail "unknown-mode suite run"
assert_contains "$out" "failing closed" "unknown value fails closed with a warning"
assert_eq "$(grep -c run "$attlog")" "6" "unknown mode re-runs the suite"
cat >"$att_cfg" <<EOF
commands:
  test: "echo run >>$attlog && echo att-ok"
EOF

# Tampered attestation log: acceptance rejects on the output hash.
"$BIN/ac-ship.sh" start --intent "tampered attestation" >/dev/null
"$BIN/ac-ship.sh" attest-test >/dev/null 2>&1 || fail "re-attest for log-tamper case"
printf 'tampered\n' >>"$arepo/.crew/ship/attest-test.log"
out="$("$BIN/ac-ship.sh" cmd test 2>&1)" || fail "tampered-log suite run"
assert_contains "$out" "does not hash to output_sha256" "log tamper explained"
assert_eq "$(grep -c run "$attlog")" "8" "tampered log re-runs the suite (attest ran once more too)"

# A test command that MUTATES tracked files attests nothing (post-run check).
cat >"$att_cfg" <<EOF
commands:
  test: "echo mutate >>file.txt && echo mut-ok"
EOF
printf 'mutation case\n' >>"$arepo/file.txt"
git -C "$arepo" commit -qam "mutating command case"
rc=0; out="$("$BIN/ac-ship.sh" attest-test 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "attest-test must refuse a suite that dirties the tree"
assert_contains "$out" "left the worktree dirty" "post-run dirt explained"
[ "$(jq -r .commit "$af" 2>/dev/null)" != "$(git -C "$arepo" rev-parse HEAD)" ] \
  || fail "no attestation may be written for a mutating suite"
git -C "$arepo" checkout -q -- file.txt
cat >"$att_cfg" <<EOF
commands:
  test: "echo run >>$attlog && echo att-ok"
EOF

# finish retires the attestation (json + log) - a new run must attest afresh.
"$BIN/ac-ship.sh" attest-test >/dev/null 2>&1 || fail "attest before finish"
assert_file "$af" "attestation present before finish"
"$BIN/ac-ship.sh" finish cancelled >/dev/null
assert_no_file "$af" "finish retires the attestation"
assert_no_file "$arepo/.crew/ship/attest-test.log" "finish retires the attestation log"
cd "$repo" || fail "cd back from attrepo"

# --- SCOPED TEST: commands.test-changed prefers changed-file runs -------------
# The full base-to-HEAD changed set (deletions excluded) replaces {files},
# shell-quoted; a scoped green completes the step but its receipt is
# not-qualifies:scoped, never suite proof. Empty changed set falls back to the
# full suite; a template without {files} is refused loud.
screpo="$(make_repo scoperepo)"
cd "$screpo" || fail "cd scoperepo"
sc_cfg="$AC_HOME/projects/scoperepo.yaml"
sclog="$TMP/scoped.log"
cat >"$sc_cfg" <<EOF
commands:
  test: "echo full-suite >>$sclog && echo full-ok"
  test-changed: "printf 'arg=%s\n' {files} >>$sclog && echo scoped-ok"
EOF

# Empty changed set (crew branch, no commits past base): full suite runs.
git -C "$screpo" checkout -qb crew/sc
"$BIN/ac-ship.sh" start --intent "scoped test" >/dev/null
out="$("$BIN/ac-ship.sh" cmd test 2>/dev/null)"
assert_contains "$out" "full-ok" "empty changed set falls back to the full suite"
srun="$screpo/.crew/ship/$(readlink "$screpo/.crew/ship/current")"
assert_eq "$(sed -n 's/^qualification=//p' "$srun/test/receipt.env")" "qualifies" \
  "a full-suite fallback run still writes a qualifying receipt"

# Changed files present: the scoped command runs with the quoted changed set
# and the receipt is honest about the partial evidence.
printf 'a\n' >>"$screpo/file.txt"
printf 'b\n' >"$screpo/other file.txt"
git -C "$screpo" add -A && git -C "$screpo" commit -qm "scoped change"
: >"$sclog"
out="$("$BIN/ac-ship.sh" cmd test 2>/dev/null)" || fail "scoped green run must exit 0"
assert_contains "$out" "scoped-ok" "scoped command runs instead of the full suite"
assert_contains "$(cat "$sclog")" "arg=file.txt" "the scoped run receives each changed file"
assert_contains "$(cat "$sclog")" "arg=other file.txt" \
  "a space-carrying filename stays ONE argument (shell-quoted substitution)"
assert_eq "$(grep -c '^arg=' "$sclog")" "2" "exactly the changed set is passed, nothing else"
case "$(cat "$sclog")" in *full-suite*) fail "the full suite must not run when the scoped run covers the change" ;; esac
assert_eq "$(sed -n 's/^qualification=//p' "$srun/test/receipt.env")" "not-qualifies" \
  "a scoped green never qualifies as suite proof"
assert_eq "$(sed -n 's/^reason=//p' "$srun/test/receipt.env")" "scoped" \
  "the scoped receipt names its reason"
assert_eq "$(sed -n 's/^exit_code=//p' "$srun/test/receipt.env")" "0" "scoped receipt records the green exit"

# A red scoped run propagates its exit code and the receipt says non-zero.
# A started run freezes its config, so each variant gets its own run.
"$BIN/ac-ship.sh" finish cancelled >/dev/null
cat >"$sc_cfg" <<EOF
commands:
  test: "echo full-ok"
  test-changed: ": {files} && exit 9"
EOF
"$BIN/ac-ship.sh" start --intent "scoped red" >/dev/null
srun="$screpo/.crew/ship/$(readlink "$screpo/.crew/ship/current")"
rc=0; "$BIN/ac-ship.sh" cmd test >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "9" "scoped red run propagates its exit code"
assert_eq "$(sed -n 's/^reason=//p' "$srun/test/receipt.env")" "non-zero" "red scoped receipt says non-zero"

# A template without {files} names nothing to scope to: refused loud.
"$BIN/ac-ship.sh" finish cancelled >/dev/null
cat >"$sc_cfg" <<EOF
commands:
  test: "echo full-ok"
  test-changed: "echo missing-placeholder"
EOF
"$BIN/ac-ship.sh" start --intent "scoped invalid" >/dev/null
rc=0; out="$("$BIN/ac-ship.sh" cmd test 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "test-changed without {files} must refuse"
assert_contains "$out" "{files}" "the refusal names the missing placeholder"

# A fresh TDD attestation still beats the scoped run: full green is stronger.
"$BIN/ac-ship.sh" finish cancelled >/dev/null
cat >"$sc_cfg" <<EOF
commands:
  test: "echo attfull >>$sclog && echo att-ok"
  test-changed: "printf 'arg=%s\n' {files} >>$sclog && echo scoped-ok"
EOF
"$BIN/ac-ship.sh" start --intent "scoped attested" >/dev/null
srun="$screpo/.crew/ship/$(readlink "$screpo/.crew/ship/current")"
"$BIN/ac-ship.sh" attest-test >/dev/null 2>&1 || fail "attest-test green run"
: >"$sclog"
out="$("$BIN/ac-ship.sh" cmd test 2>&1)" || fail "cmd test with fresh attestation must exit 0"
assert_contains "$out" "TDD attestation accepted" "attestation accepted over the scoped run"
assert_eq "$(grep -c . "$sclog")" "0" "neither suite nor scoped command re-runs on a fresh attestation"
assert_eq "$(sed -n 's/^qualification=//p' "$srun/test/receipt.env")" "qualifies" \
  "the accepted attestation receipt qualifies"
"$BIN/ac-ship.sh" finish cancelled >/dev/null
cd "$repo" || fail "cd back from scoperepo"

# --- finish is FAIL CLOSED: no fresh/incomplete run may be marked passed ------
# The proven bypass was `start` then `finish checks-passed` minting a passed run
# with zero steps done. checks-passed|passed now gate on the EXISTING step +
# finding state; failed/cancelled stay always-allowed.
grepo="$(make_repo gaterepo)"
cd "$grepo" || fail "cd gaterepo"
gdef="$(git -C "$grepo" symbolic-ref --short HEAD)"
git -C "$grepo" checkout -qb crew/gate
printf 'change\n' >>"$grepo/file.txt" && git -C "$grepo" add -A \
  && git -C "$grepo" commit -qm "crew change"

# Bring the current run to a fully-validated state (every step completed, with
# the review step carrying its independent-reviewer evidence).
gate_validate() {
  local s
  printf '{"reviewer":"gate-test"}' | "$BIN/ac-ship.sh" meta review >/dev/null
  for s in intent rebase review test document lint push pr; do
    "$BIN/ac-ship.sh" step "$s" completed >/dev/null
  done
}

# RED: start then immediate finish checks-passed must DIE, naming the outstanding steps.
"$BIN/ac-ship.sh" start --intent "gate red" >/dev/null
rc=0; out="$("$BIN/ac-ship.sh" finish checks-passed 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "start-then-immediate finish checks-passed must fail closed"
assert_contains "$out" "not completed" "the refusal names the outstanding steps"
assert_contains "$out" "intent" "an outstanding step is named"
# passed is refused the same way on a fresh run.
rc=0; "$BIN/ac-ship.sh" finish passed >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "finish passed must fail closed on a fresh run"
# failed and cancelled are ALWAYS allowed, even on a fresh run.
"$BIN/ac-ship.sh" finish failed >/dev/null || fail "finish failed must stay allowed on a fresh run"
"$BIN/ac-ship.sh" start --intent "gate cancel" >/dev/null
"$BIN/ac-ship.sh" finish cancelled >/dev/null || fail "finish cancelled must stay allowed on a fresh run"

# GREEN: every non-skipped step completed + no unresolved finding -> succeeds.
"$BIN/ac-ship.sh" start --intent "gate green" >/dev/null
gate_validate
out="$("$BIN/ac-ship.sh" finish checks-passed 2>&1)" || fail "a fully-validated run must finish checks-passed"
assert_contains "$out" "checks-passed:" "the completion marker is emitted"

# Unresolved findings block finish and are NAMED.
"$BIN/ac-ship.sh" start --intent "gate findings" >/dev/null
gate_validate
# The authority keys keep it a genuine `fix` finding: without them the shared
# normalizer would downgrade it to ask-user and this would stop testing `fix`.
printf '[{"id":"F1","severity":"error","action":"fix","authority_class":"internal","authority":"file.txt:1","description":"real bug"}]' \
  | "$BIN/ac-ship.sh" findings test >/dev/null
rc=0; out="$("$BIN/ac-ship.sh" finish checks-passed 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "an unresolved fix finding must block finish"
assert_contains "$out" "F1" "the unresolved fix finding is named"
# an ask-user WITHOUT a captain decision also blocks.
printf '[{"id":"A1","severity":"warning","action":"ask-user","description":"decide?"}]' \
  | "$BIN/ac-ship.sh" findings test >/dev/null
rc=0; out="$("$BIN/ac-ship.sh" finish checks-passed 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "an undecided ask-user finding must block finish"
assert_contains "$out" "A1" "the undecided ask-user finding is named"
# a DECIDED ask-user and a no-op do NOT block.
printf '[{"id":"A1","action":"ask-user","description":"decide?","decision":"do it"},{"id":"N1","action":"no-op","description":"nit"}]' \
  | "$BIN/ac-ship.sh" findings test >/dev/null
"$BIN/ac-ship.sh" finish checks-passed >/dev/null || fail "decided ask-user + no-op must not block finish"

# --- FORMAT RUNS WHERE THE REVIEWER CAN SEE IT -------------------------------
# `format` is not one of the 8 fixed steps - the runner's procedure decides
# WHEN it fires - and it used to fire at step 7 (push). A formatter that
# produces a diff there manufactures a commit AFTER the reviewed ref, which
# assert_review_current then correctly refuses, buying a mandatory extra review
# round for a change the pipeline's own instruction scheduled. The instruction
# now sits inside the review step, before the reviewer is launched, so the
# reviewed ref is already formatted. Asserted BLOCK-SCOPED, never by line
# order: a stray earlier mention of the command must not read as compliance.
ship_skill="$ROOT/.agents/skills/crew-ship/SKILL.md"
skill_step() { awk -v n="$1" '$0 ~ "^"n"\\. \\*\\*" { on = 1; print; next }
                              on && /^[0-9]+\. \*\*/ { exit } on { print }' "$ship_skill"; }
assert_contains "$(skill_step 3)" "ac-ship.sh cmd format" \
  "the review step runs the formatter before the reviewer, so the reviewed ref is the formatted one"
case "$(skill_step 7)" in *"cmd format"*) \
  fail "the push step must not run the formatter: its commit lands after review and voids reviewed_ref" ;; esac
pipeline_row7="$(grep -m1 '^| 7 | push |' "$ROOT/docs/validate-pipeline.md")"
[ -n "$pipeline_row7" ] || fail "the pipeline map lost its step-7 push row"
case "$pipeline_row7" in *"cmd format"*) \
  fail "docs/validate-pipeline.md still lists cmd format as part of step 7" ;; esac

# --- REVIEW CURRENCY: the reviewed ref must still be HEAD at delivery ---------
# `step review completed` proves review was current at THAT instant. Nothing
# re-checked it afterwards, so a fix commit landing after review could be
# pushed and recorded as validated with code no reviewer ever saw.
"$BIN/ac-ship.sh" start --intent "review currency" >/dev/null
gate_validate
grun="$grepo/.crew/ship/$(readlink "$grepo/.crew/ship/current")"
printf 'reviewer=ac-verify\nround=1\nreviewed_ref=%s\n' "$(git -C "$grepo" rev-parse HEAD)" >"$grun/review.agent"
"$BIN/ac-ship.sh" finish checks-passed >/dev/null \
  || fail "a run reviewed AT HEAD must still finish"

# The fix that lands after review: finish and push both refuse, and the
# refusal names both refs so the crewmate knows what to re-review.
"$BIN/ac-ship.sh" start --intent "review currency red" >/dev/null
gate_validate
grun="$grepo/.crew/ship/$(readlink "$grepo/.crew/ship/current")"
reviewed_at="$(git -C "$grepo" rev-parse HEAD)"
printf 'reviewer=ac-verify\nround=1\nreviewed_ref=%s\n' "$reviewed_at" >"$grun/review.agent"
printf 'late fix\n' >>"$grepo/file.txt"
git -C "$grepo" add -A && git -C "$grepo" commit -qm "fix after review"
rc=0; out="$("$BIN/ac-ship.sh" finish checks-passed 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a fix landing after review must not finish as validated"
assert_contains "$out" "HEAD moved since review" "the refusal states what happened"
assert_contains "$out" "${reviewed_at:0:12}" "the refusal names the reviewed ref"
rc=0; out="$("$BIN/ac-ship.sh" push 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a fix landing after review must not be pushed"
assert_contains "$out" "HEAD moved since review" "push refuses for the same reason"
# Re-reviewing at the new HEAD clears it.
printf 'reviewer=ac-verify\nround=2\nreviewed_ref=%s\n' "$(git -C "$grepo" rev-parse HEAD)" >"$grun/review.agent"
"$BIN/ac-ship.sh" finish checks-passed >/dev/null \
  || fail "a fresh review at the new HEAD must unblock finish"

# --- F8: the MANUAL reviewer path (`meta review` + `step review completed`,
# no review-agent) must bind reviewed_ref too, so a ref-changing fix after it
# is REFUSED like the review-agent path - not merely warned about.
"$BIN/ac-ship.sh" start --intent "manual review binds ref" >/dev/null
printf '{"reviewer":"gate-test"}' | "$BIN/ac-ship.sh" meta review >/dev/null
manual_reviewed_at="$(git -C "$grepo" rev-parse HEAD)"
"$BIN/ac-ship.sh" step review completed >/dev/null
mrun="$grepo/.crew/ship/$(readlink "$grepo/.crew/ship/current")"
assert_eq "$(jq -r '.reviewed_ref // ""' "$mrun/findings/review.meta.json")" "$manual_reviewed_at" \
  "manual review completion stamps reviewed_ref = HEAD at completion"
for s in intent rebase test document lint push pr; do
  "$BIN/ac-ship.sh" step "$s" completed >/dev/null
done
printf 'late manual fix\n' >>"$grepo/file.txt"
git -C "$grepo" add -A && git -C "$grepo" commit -qm "fix after manual review"
rc=0; out="$("$BIN/ac-ship.sh" push 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a fix after a manually-completed review must not be pushed"
assert_contains "$out" "HEAD moved since review" "the manual path refuses push like the review-agent path, not just warns"
rc=0; out="$("$BIN/ac-ship.sh" finish checks-passed 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a fix after a manually-completed review must not finish as validated"
assert_contains "$out" "HEAD moved since review" "the manual path refuses finish like the review-agent path, not just warns"

# --- F8b: a STALE agent receipt no longer strands the MANUAL reviewer path ---
# The branch used to be chosen by mere EXISTENCE of review.agent, so once an
# agent round had run, the manual channel this same function's no-evidence
# refusal names was unreachable for the rest of the run - precisely when a fix
# had landed and the verifier had become unusable. Selection is now by
# CURRENCY: a current agent receipt still wins; a STALE one is SUPERSEDED by an
# explicit manual record and retired, so assert_review_current - byte-unchanged
# - reads the manual receipt at push/finish instead of the stale agent one.
"$BIN/ac-ship.sh" start --intent "stale receipt, manual takeover" >/dev/null
srun="$grepo/.crew/ship/$(readlink "$grepo/.crew/ship/current")"
printf 'reviewer=ac-verify\nround=1\nreviewed_ref=%s\n' "$(git -C "$grepo" rev-parse HEAD)" >"$srun/review.agent"
printf 'fix after the agent round\n' >>"$grepo/file.txt"
git -C "$grepo" add -A && git -C "$grepo" commit -qm "fix after agent review"
# The negative twin, unchanged: a stale receipt ALONE still refuses.
rc=0; out="$("$BIN/ac-ship.sh" step review completed 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a stale agent receipt with no manual record must still refuse"
assert_contains "$out" "review receipt is stale" "the stale refusal is unchanged without a manual record"
printf '{"reviewer":"clean-context-subagent"}' | "$BIN/ac-ship.sh" meta review >/dev/null
"$BIN/ac-ship.sh" step review completed >/dev/null \
  || fail "an explicit manual reviewer record must reach the documented manual path"
stale_head="$(git -C "$grepo" rev-parse HEAD)"
assert_eq "$(jq -r '.reviewed_ref // ""' "$srun/findings/review.meta.json")" "$stale_head" \
  "the manual takeover stamps reviewed_ref = HEAD, so the receipt still binds"
assert_no_file "$srun/review.agent" "the superseded agent receipt no longer wins at push/finish"
assert_file "$srun/review.agent.superseded" "the superseded receipt is retired as evidence, never deleted"
# The half-fix guard: assert_review_current independently PREFERS review.agent
# and falls back only when its ref is EMPTY, so a cmd_step-only precedence
# change would complete review and then refuse push for the same stale ref.
for s in intent rebase test document lint push pr; do
  "$BIN/ac-ship.sh" step "$s" completed >/dev/null
done
"$BIN/ac-ship.sh" finish checks-passed >/dev/null \
  || fail "the manual takeover must clear delivery too, not just the review step"
# And the currency guard still bites on the NEXT commit.
printf 'later fix\n' >>"$grepo/file.txt"
git -C "$grepo" add -A && git -C "$grepo" commit -qm "fix after the manual takeover"
rc=0; out="$("$BIN/ac-ship.sh" push 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a fix after the manual takeover must not be pushed"
assert_contains "$out" "HEAD moved since review" "the takeover receipt is bound like any other"

# A SKIPPED review is a run that legitimately has none: never blocked.
"$BIN/ac-ship.sh" start --intent "review skipped" >/dev/null
printf '{"reviewer":"gate-test"}' | "$BIN/ac-ship.sh" meta review >/dev/null
for s in intent rebase test document lint push pr; do
  "$BIN/ac-ship.sh" step "$s" completed >/dev/null
done
"$BIN/ac-ship.sh" step review skipped >/dev/null
printf 'unreviewed\n' >>"$grepo/file.txt"
git -C "$grepo" add -A && git -C "$grepo" commit -qm "after a skipped review"
"$BIN/ac-ship.sh" finish checks-passed >/dev/null \
  || fail "a skipped review must not be bound to HEAD"

# --- LEGACY findings still finish: the finding-authority downgrade binds `fix`
# alone, so a run recorded by a pre-change emitter - no authority keys anywhere,
# every finding no-op or decided ask-user - reaches checks-passed exactly as it
# did before, with its actions untouched. This is the guard against the rule's
# real failure mode: a normalizer that downgrades everything.
"$BIN/ac-ship.sh" start --intent "gate legacy" >/dev/null
gate_validate
printf '[{"id":"L1","severity":"info","action":"no-op","description":"nit"},
        {"id":"L2","severity":"warning","action":"ask-user","description":"decide?","decision":"ok"}]' \
  | "$BIN/ac-ship.sh" findings test >/dev/null
legacy="$("$BIN/ac-ship.sh" findings test --show)"
assert_eq "$(jq -r '.[0].action' <<<"$legacy")" "no-op" "a legacy no-op keeps its action"
assert_eq "$(jq -r '.[1].action' <<<"$legacy")" "ask-user" "a legacy ask-user keeps its action"
assert_eq "$(jq -r '[.[] | select(has("authority_downgraded"))] | length' <<<"$legacy")" "0" \
  "no legacy finding is marked downgraded"
"$BIN/ac-ship.sh" finish checks-passed >/dev/null \
  || fail "a legacy findings run must still reach checks-passed"

# --- F32: a CORRUPT findings file must fail CLOSED, never read as zero
# unresolved findings - the one predicate in an otherwise fail-closed gate
# that used to fail open on a jq read failure.
"$BIN/ac-ship.sh" start --intent "gate corrupt findings" >/dev/null
gate_validate
corrupt_run="$grepo/.crew/ship/$(readlink "$grepo/.crew/ship/current")"
printf 'not valid json{{{' >"$corrupt_run/findings/test.json"
rc=0; out="$("$BIN/ac-ship.sh" finish checks-passed 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a corrupt findings file must block finish, not be read as zero unresolved findings"
assert_contains "$out" "test:" "the refusal names the step whose findings file is unreadable"
assert_contains "$out" "UNREADABLE" "the refusal states the file is unreadable, not merely empty"

# --- F33: `finish` must not claim a PR was raised when the pr step was
# SKIPPED (--skip pr here; skip-remaining marks pr the same way and is
# covered by the same steps.tsv-derived wording).
"$BIN/ac-ship.sh" start --intent "gate no pr" --skip pr >/dev/null
printf '{"reviewer":"gate-test"}' | "$BIN/ac-ship.sh" meta review >/dev/null
for s in intent rebase review test document lint push; do "$BIN/ac-ship.sh" step "$s" completed >/dev/null; done
out="$("$BIN/ac-ship.sh" finish checks-passed 2>&1)" || fail "a run with pr skipped must still finish checks-passed: $out"
assert_contains "$out" "checks-passed:" "the completion marker is still emitted"
assert_contains "$out" "no PR raised" "the wording states no PR was raised"
case "$out" in
  *"PR raised, awaiting"*) fail "finish must not claim a PR was raised when the pr step was skipped: $out" ;;
esac

# checks-passed vs passed = UNMERGED vs MERGED. On an unmerged branch passed is
# refused (no merge evidence) while checks-passed succeeds; once HEAD is merged
# into the default branch, passed succeeds.
"$BIN/ac-ship.sh" start --intent "gate merge" >/dev/null
gate_validate
rc=0; out="$("$BIN/ac-ship.sh" finish passed 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "passed must refuse an unmerged run"
assert_contains "$out" "not merged" "passed names the missing merge evidence"
"$BIN/ac-ship.sh" finish checks-passed >/dev/null || fail "checks-passed succeeds while unmerged"
git -C "$grepo" checkout -q "$gdef"
git -C "$grepo" merge --ff-only crew/gate >/dev/null
git -C "$grepo" checkout -q crew/gate
"$BIN/ac-ship.sh" start --intent "gate merged" >/dev/null
gate_validate
"$BIN/ac-ship.sh" finish passed >/dev/null || fail "passed succeeds once HEAD is merged into the default"
cd "$repo" || fail "cd back from gaterepo"

# --- start --target: the delivery-target base override -------------------------
# A run delivering into prelive must diff against prelive, not origin/HEAD
# (the PR #3856 class: 8 files reviewed instead of 145). Fixture topology:
# main = init; prelive = init+P1; feat = init+P1+F1 (checked out).
trepo="$(make_repo trepo)"
cd "$trepo" || fail "cd $trepo"
git checkout -qb prelive
printf 'p1\n' >p.txt && git add p.txt && git commit -qm P1
git checkout -qb feat
printf 'f1\n' >f.txt && git add f.txt && git commit -qm F1
out="$("$BIN/ac-ship.sh" start --intent 'target run' --target prelive)"
assert_contains "$out" "target=prelive" "start names the pinned target"
assert_eq "$("$BIN/ac-ship.sh" base)" "$(git rev-parse prelive)" \
  "target=prelive: base is the prelive merge-base, not the default's"
grep -q '^target=prelive$' "$trepo/.crew/ship/$(readlink "$trepo/.crew/ship/current")/run.meta" \
  || fail "target recorded in run.meta"
# Omitted target: byte-compatible default-ref base.
"$BIN/ac-ship.sh" start --intent 'default run' >/dev/null
assert_eq "$("$BIN/ac-ship.sh" base)" "$(git rev-parse main)" \
  "no --target: base stays the default-ref merge-base"
# A mistyped target refuses loudly - never a silent default fallback.
assert_fails "$BIN/ac-ship.sh" start --intent x --target no-such-branch
cd "$repo" || fail "cd back from trepo"

# --- fresh_base FAIL CLOSED on a genuine merge-base failure ---------------------
# Unrelated histories (no common ancestor) make `git merge-base` fail for real;
# the old fallback silently substituted HEAD, so every consumer computed a
# HEAD-vs-HEAD delta - a review or test run that inspected nothing, green.
# Start while the default ref (main) still shares history (base recorded
# fine), then force main to an orphan commit so a LATER `base` recompute -
# fresh_base is never trusted from the frozen start value - hits the failure.
urepo="$(make_repo urepo)"
cd "$urepo" || fail "cd $urepo"
git checkout -qb work
printf 'w1\n' >w.txt && git add w.txt && git commit -qm W1
"$BIN/ac-ship.sh" start --intent 'default ref goes unrelated later' >/dev/null
git checkout -q --orphan orphanbase
printf 'o1\n' >o.txt && git add o.txt && git commit -qm O1
orphan_sha="$(git rev-parse HEAD)"
git checkout -q work
git branch -f main "$orphan_sha"
out=""; rc=0
out="$("$BIN/ac-ship.sh" base 2>/dev/null)" || rc=$?
assert_eq "$rc" "1" "merge-base failure: base exits non-zero, not HEAD"
assert_eq "$out" "" "base prints nothing on merge-base failure, never HEAD"
cd "$repo" || fail "cd back from urepo"

# --- config verb on a config-less repo: quiet return, never a killer exit ------
# The exit4-noconfig class: `exit` inside $(...) kills the subshell BEFORE an
# `|| true` INSIDE the substitution can run, so a config-less repo silently
# killed set -e callers at the review.model read. The generic reader now
# returns 1 and every caller keeps deciding criticality itself.
nocfg="$(make_repo nocfg)"
cd "$nocfg" || fail "cd $nocfg"
rc=0; "$BIN/ac-ship.sh" config review.model >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "config-less repo: the config verb returns 1, not exit 4"
out="$(bash -c 'set -euo pipefail
  m="$('"$BIN"'/ac-ship.sh config review.model 2>/dev/null || true)"
  printf "survived:%s\n" "${m:-default}"')" || fail "the internal caller shape must survive under set -e"
assert_contains "$out" "survived:default" "caller degrades to defaults instead of dying silently"
# The cmd/test paths that REQUIRE config keep their loud exit-4 refusal.
"$BIN/ac-ship.sh" start --intent 'nocfg run' >/dev/null
rc=0; "$BIN/ac-ship.sh" cmd test >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "4" "cmd test still refuses loudly with exit 4 on a config-less repo"
cd "$repo" || fail "cd back from nocfg"

# --- the crewmate's own homeless environment: AC_HOME is unset, exactly the
# pane a crew-ship execution crewmate runs in (ac-spawn.sh header: a crewmate
# never carries AC_HOME). Bare ac_project_config_file there now REFUSES; it
# used to resolve the config-less distro checkout and could not tell that
# phantom miss apart from a project genuinely installed with none - silently dropping any key the
# captain pinned (ship-config-and-know-citation-blind-spots defect 1).
# ac-spawn.sh now resolves the config with its OWN real AC_HOME and threads
# the verified answer as AC_FLEET_HOME_CHECKED / AC_FLEET_PROJECT_CONFIG;
# start must trust that pair over its own homeless resolution. -----------------
pinrepo="$(make_repo pinrepo)"
cd "$pinrepo" || fail "cd $pinrepo"
pin_cfg="$AC_HOME/projects/pinrepo.yaml"
printf 'review:\n  model: opus-pinned\n' >"$pin_cfg"

# Checked + a resolved path: the pin SURVIVES a homeless start - this is the
# assertion that matters most, not merely that resolution succeeds.
out="$(env -u AC_HOME AC_FLEET_HOME_CHECKED=1 AC_FLEET_PROJECT_CONFIG="$pin_cfg" \
  "$BIN/ac-ship.sh" start --intent 'homeless crewmate, config threaded')"
assert_contains "$out" "started run" "start succeeds on a threaded config pair with no AC_HOME"
m="$(env -u AC_HOME AC_FLEET_HOME_CHECKED=1 AC_FLEET_PROJECT_CONFIG="$pin_cfg" \
  "$BIN/ac-ship.sh" config review.model 2>/dev/null || true)"
assert_eq "$m" "opus-pinned" \
  "a captain-pinned key survives a crewmate's homeless env when ac-spawn.sh threads the config"

# Checked, but no path (ac-spawn.sh looked with a REAL AC_HOME and genuinely
# found none): still no AC_HOME on this call, but NOT the ambiguous case - a
# verified absence, so start still succeeds and freezes empty, same as any
# ordinary config-less project.
out="$(env -u AC_HOME AC_FLEET_HOME_CHECKED=1 \
  "$BIN/ac-ship.sh" start --intent 'homeless crewmate, verified no config')"
assert_contains "$out" "started run" "start succeeds on a verified-none checked pair with no AC_HOME"
rc=0
env -u AC_HOME AC_FLEET_HOME_CHECKED=1 "$BIN/ac-ship.sh" config review.model >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "review.model resolves absent on a verified-none pair, same as any config-less project"

# NEITHER signal at all: the genuinely ambiguous case this defect is about - a
# phantom-home config_source=none indistinguishable from a verified absence.
# start now REFUSES LOUDLY instead of silently freezing empty and moving on.
rc=0
err="$(env -u AC_HOME "$BIN/ac-ship.sh" start --intent 'no signal at all' 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "1" "start refuses with no AC_HOME and no threaded config signal"
assert_contains "$err" "cannot resolve the project's pipeline config" \
  "the refusal names the exact ambiguity, not a generic failure"
cd "$repo" || fail "cd back from pinrepo"

# --- best-effort external calls DEGRADE; load-bearing ones stay fail-closed ---
# ship-finish-pane-gone (@a4bc17d) guarded the finish pane-close PAIR and left
# the rest of the file unaudited. Under set -e any external tool exiting
# non-zero aborts the step mid-way - correct for a push or a validation gate,
# wrong for a call whose only product is decoration or housekeeping.

# The watch dashboard's pane ops: the tab is already open when rename/run/close
# run, and its pane may be gone (or herdr wedged) by then. Every one of them
# aborted `start` SILENTLY - the run dir and `current` symlink already existed,
# so the caller saw rc=1 with no output and a half-started run.
gstub="$TMP/paneopstub"; mkdir -p "$gstub"
cat >"$gstub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$WHLOG"
[ "${1:-}" = --session ] && shift 2
case "${1:-} ${2:-}" in
  "pane list") echo '{"result":{"panes":[]}}' ;;
  "workspace get") exit 1 ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wW"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tW"},"root_pane":{"pane_id":"pW1"}}}' ;;
  "tab list") echo '{"result":{"tabs":[{"tab_id":"tJ","workspace_id":"wW","label":"1"}]}}' ;;
  "pane rename"|"pane run"|"tab close") exit 1 ;;
esac
exit 0
EOF
chmod +x "$gstub/herdr"
prepo="$(make_repo paneopsrepo)"
cd "$prepo" || fail "cd paneopsrepo"
: >"$WHLOG"
rc=0
out="$(PATH="$gstub:$PATH" AC_SHIP_WATCH=auto "$BIN/ac-ship.sh" start --intent "pane ops fail" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "start must survive failing watch pane ops, got rc=$rc: $out"
assert_contains "$out" "started run" "start still reports the run when every pane op fails"
prun="$prepo/.crew/ship/$(readlink "$prepo/.crew/ship/current")"
# Recorded, not abandoned: a `return 0` on the failed rename would LEAK the tab
# that was already created - finish retires it through this handle.
assert_eq "$(cat "$prun/watch.pane")" "pW1" "the opened pane is still recorded so finish can retire it"
assert_contains "$(cat "$WHLOG")" "pane run pW1" "the dashboard launch was still attempted after the failed rename"
: >"$WHLOG"
rc=0
PATH="$gstub:$PATH" AC_SHIP_WATCH=auto "$BIN/ac-ship.sh" step intent running >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "an active step transition re-ensures the dashboard without aborting on it"
# Guarded PER CASE, never blanket: the fail-closed finish gate right next to
# the guards is untouched - a fresh run still cannot mint a validated outcome.
rc=0
out="$(PATH="$gstub:$PATH" "$BIN/ac-ship.sh" finish checks-passed 2>&1)" || rc=$?
assert_eq "$rc" "1" "the pane-op guards must not leak into the finish gate"
assert_contains "$out" "fail-closed" "a fresh run still cannot mint checks-passed"

# The .crew/ exclude write is cosmetic housekeeping (it keeps .crew/ out of
# `git status`; the pool manager normally wrote it already). An info/ that
# cannot hold the exclude file must WARN and continue, not kill the run.
xrepo="$(make_repo exclrepo)"
cd "$xrepo" || fail "cd exclrepo"
xcommon="$(git -C "$xrepo" rev-parse --path-format=absolute --git-common-dir)"
rm -rf "$xcommon/info"
: >"$xcommon/info"          # a FILE where info/ belongs: mkdir -p fails for any user
rc=0
out="$("$BIN/ac-ship.sh" start --intent "unwritable exclude" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "start must survive an unwritable info/exclude, got rc=$rc: $out"
assert_contains "$out" "started run" "start completes despite the failed exclude write"
assert_contains "$out" "WARN" "the failed exclude write is reported, never swallowed"
# Degrading the housekeeping is NOT a licence to attest an unclean tree: the
# load-bearing dirty-worktree refusal in the same function's caller still bites.
cp "$ship_cfg" "$AC_HOME/projects/exclrepo.yaml"
printf 'dirty\n' >>"$xrepo/file.txt"
rc=0
out="$("$BIN/ac-ship.sh" attest-test 2>&1)" || rc=$?
assert_eq "$rc" "1" "attest-test still refuses a dirty worktree"
assert_contains "$out" "uncommitted changes" "the dirty-tree refusal stays fail-closed"
cd "$repo" || fail "cd back from exclrepo"

# The FIRST step failing is the case that must not fall through. errexit is
# suppressed inside any non-final command of an AND-OR list and the subshell
# INHERITS that suppression, so a bare sequence runs on with an empty $common -
# addressing /info/exclude at FILESYSTEM ROOT, which on a writable-root box
# (root, container, CI image) SUCCEEDS, exits 0, and never warns. The && chain
# short-circuits instead. Both assertions below catch that fall-through: the
# path check bites as an ordinary user (the /info attempt lands on stderr), the
# WARN check bites wherever / is writable.
gitstub="$TMP/gitstub"; mkdir -p "$gitstub"
realgit="$(command -v git)"
cat >"$gitstub/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" = --git-common-dir ] && exit 1
done
exec "$realgit" "\$@"
EOF
chmod +x "$gitstub/git"
crepo="$(make_repo commondirrepo)"
cd "$crepo" || fail "cd commondirrepo"
rc=0
out="$(PATH="$gitstub:$PATH" "$BIN/ac-ship.sh" start --intent "no common dir" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "start must survive an unresolvable git common dir, got rc=$rc: $out"
assert_contains "$out" "started run" "start completes when the common dir cannot be resolved"
assert_contains "$out" "WARN" "an unresolvable common dir warns instead of silently falling through"
case "$out" in
  */info/exclude*|*"mkdir: /info"*)
    fail "a failed rev-parse must short-circuit, never address /info at filesystem root: $out" ;;
esac
assert_no_file "/info/exclude" "the fall-through never wrote outside the repo"
cd "$repo" || fail "cd back from commondirrepo"

# --- fail-OPEN sites: a load-bearing failure must ABORT, never be swallowed ---
# The mirror image of the section above: a guard that CANNOT FIRE because the
# failure reaches a shape that reads as success, so a broken external call
# silently produces a wrong decision instead of a refusal.
#
# Two of the audited sites turned out NOT to be fail-open, and both are pinned
# below rather than argued: their correctness rests entirely on the `set -euo
# pipefail` at the top of the script, ~460 lines from the guard it rescues. That
# is an invisible dependency a refactor can drop without touching either line -
# and it already misled one audit - so it gets an executable proof.

# cmd_push: `$(git ls-remote | awk ...)`. Under plain errexit the substitution
# would take AWK's status, leaving an EMPTY remote_sha that falls into the "new
# branch" arm with the `|| ac_die "failing closed"` next to it never running.
# pipefail is what makes the leftmost failure the status the guard sees.
realgit="$(command -v git)"
lsstub="$TMP/lsremotestub"; mkdir -p "$lsstub"
cat >"$lsstub/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  [ "\$a" = ls-remote ] && exit 128
done
exec "$realgit" "\$@"
EOF
chmod +x "$lsstub/git"
lsorigin="$TMP/lsorigin.git"; git init -q --bare "$lsorigin"
lswork="$TMP/lswork"; git init -q -b main "$lswork"
git -C "$lswork" remote add origin "$lsorigin"
git -C "$lswork" config user.email test@test
git -C "$lswork" config user.name test
( cd "$lswork" \
  && printf 'base\n' >f.txt && git add -A && git commit -qm base \
  && git push -qu origin main 2>/dev/null \
  && git checkout -qb crew/lsr \
  && printf 'feature\n' >>f.txt && git commit -qam feature \
  && "$BIN/ac-ship.sh" start --intent "ls-remote fail-open" >/dev/null ) \
  || fail "ls-remote fixture setup"
rc=0
out="$( cd "$lswork" && PATH="$lsstub:$PATH" "$BIN/ac-ship.sh" push 2>&1 )" || rc=$?
assert_eq "$rc" "1" "a failing ls-remote ABORTS the push instead of reading as a new branch"
assert_contains "$out" "cannot read the remote" "the documented fail-closed guard actually fires"
lsrc=0; git -C "$lsorigin" rev-parse --verify --quiet refs/heads/crew/lsr >/dev/null 2>&1 || lsrc=$?
assert_eq "$lsrc" "1" "nothing reached the remote behind the dead guard"
# The healthy path is untouched: with a readable remote the same push lands.
( cd "$lswork" && "$BIN/ac-ship.sh" push >/dev/null 2>&1 ) || fail "the healthy push still lands"
assert_eq "$(git -C "$lsorigin" rev-parse refs/heads/crew/lsr)" \
  "$(git -C "$lswork" rev-parse HEAD)" "new branch pushed once the remote is readable"

# cmd_attest_test: `[ -z "$(git status --porcelain)" ] || ac_die` reads a FAILED
# status as a CLEAN tree, so the refusal that makes an attestation mean anything
# fails open. Both call sites are checked - the pre-run one and the post-run
# "did the suite mutate tracked files?" one - with a counting stub that fails
# from the Nth status onward, so each site is isolated.
stcount="$TMP/statusn"
ststub="$TMP/statusstub"; mkdir -p "$ststub"
cat >"$ststub/git" <<EOF
#!/usr/bin/env bash
for a in "\$@"; do
  if [ "\$a" = status ]; then
    n=\$(cat "$stcount" 2>/dev/null || printf 0); n=\$((n + 1)); printf '%s\n' "\$n" >"$stcount"
    [ "\$n" -ge "\${FAIL_STATUS_FROM:-1}" ] && exit 128
  fi
done
exec "$realgit" "\$@"
EOF
chmod +x "$ststub/git"
strepo="$(make_repo statusrepo)"
stlog="$TMP/statusrun.log"
cat >"$AC_HOME/projects/statusrepo.yaml" <<EOF
commands:
  test: "echo run >>$stlog && echo st-ok"
EOF
cd "$strepo" || fail "cd statusrepo"
: >"$stlog"
printf 0 >"$stcount"
rc=0
out="$(PATH="$ststub:$PATH" FAIL_STATUS_FROM=1 "$BIN/ac-ship.sh" attest-test 2>&1)" || rc=$?
assert_eq "$rc" "1" "an unreadable worktree state ABORTS attest-test"
assert_contains "$out" "cannot read the worktree state" "the pre-run dirty check fails closed"
assert_no_file "$strepo/.crew/ship/attest-test.json" "no attestation from an unreadable tree"
assert_eq "$(grep -c run "$stlog" || true)" "0" "the suite never ran behind the dead pre-run guard"
# Second site: the pre-run check passes, the suite runs, and the post-run check
# is the one that cannot read the tree. Swallowed, it attests a run whose effect
# on tracked files is UNKNOWN.
printf 0 >"$stcount"
rc=0
out="$(PATH="$ststub:$PATH" FAIL_STATUS_FROM=2 "$BIN/ac-ship.sh" attest-test 2>&1)" || rc=$?
assert_eq "$rc" "1" "an unreadable post-run worktree state ABORTS attest-test"
assert_contains "$out" "cannot read the worktree state" "the post-run mutation check fails closed"
assert_eq "$(grep -c run "$stlog" || true)" "1" "the failure is the POST-run check: the suite did run"
assert_no_file "$strepo/.crew/ship/attest-test.json" "no attestation once the post-run state is unknown"
# Healthy path: with a readable status the same repo attests normally.
"$BIN/ac-ship.sh" attest-test >/dev/null 2>&1 || fail "attest-test still works on a readable tree"
assert_file "$strepo/.crew/ship/attest-test.json" "the healthy attestation is unaffected"
cd "$repo" || fail "cd back from statusrepo"

# cmd_evidence_dir: `symbolic-ref | tr || printf 'detached'`. DEGRADE is right
# here (the slug is a directory label, not a decision), but only to the literal
# the code names. Under plain errexit the fallback would be unreachable - `tr`
# SUCCEEDS on the empty input a detached HEAD produces - and every detached run
# would write into the shared evidence root instead of its own subdir. pipefail
# again: it is what fails the pipeline so the `|| printf` arm is taken.
dtrepo="$(make_repo detachedrepo)"
cat >"$AC_HOME/projects/detachedrepo.yaml" <<'EOF'
test:
  evidence:
    store_in_repo: true
    dir: evidence
EOF
cd "$dtrepo" || fail "cd detachedrepo"
git -C "$dtrepo" checkout -qb crew/slash/name
"$BIN/ac-ship.sh" start --intent "branch slug" >/dev/null
assert_eq "$("$BIN/ac-ship.sh" evidence-dir)" "$dtrepo/evidence/crew-slash-name" \
  "a branch slug still has its slashes flattened"
"$BIN/ac-ship.sh" finish cancelled >/dev/null
git -C "$dtrepo" checkout -q --detach HEAD
"$BIN/ac-ship.sh" start --intent "detached slug" >/dev/null
assert_eq "$("$BIN/ac-ship.sh" evidence-dir)" "$dtrepo/evidence/detached" \
  "a detached HEAD reaches the 'detached' fallback instead of an empty slug"
"$BIN/ac-ship.sh" finish cancelled >/dev/null
cd "$repo" || fail "cd back from detachedrepo"

# cmd_step / cmd_skip_remaining: `awk ... >"$tmp" && mv "$tmp" steps.tsv` is a
# non-final AND-OR element, which errexit EXEMPTS - a failing awk left the step
# ledger (the state machine's truth) unchanged, leaked the temp file, and
# reported success. skip-remaining is the sharper of the two: it printed
# "remaining steps skipped" and exited 0 having skipped nothing.
#
# The staged temp file each verb also stops leaking is deliberately NOT
# asserted here: both stage through a bare `mktemp`, and BSD mktemp resolves
# that against _CS_DARWIN_USER_TEMP_DIR, IGNORING TMPDIR - so the obvious
# `TMPDIR=<empty dir>` assertion is vacuous on macOS (verified: it survives
# deleting the cleanup). Diffing the real per-user temp dir instead would race
# every other process sharing it. The cleanup is measured out of band; only the
# refusal itself is pinned.
ledrepo="$(make_repo ledgerrepo)"
cd "$ledrepo" || fail "cd ledgerrepo"
"$BIN/ac-ship.sh" start --intent "ledger write fails" >/dev/null
lrd="$ledrepo/.crew/ship/$(readlink "$ledrepo/.crew/ship/current")"
rm -f "$lrd/steps.tsv"
rc=0
out="$("$BIN/ac-ship.sh" step intent running 2>&1)" || rc=$?
assert_eq "$rc" "1" "a failing ledger write ABORTS the step transition"
assert_contains "$out" "could not update the steps ledger" "step names the ledger refusal"
assert_no_file "$lrd/.steps.lock" "the ledger lock is released before the refusal, never wedged"
rc=0
out="$("$BIN/ac-ship.sh" skip-remaining 2>&1)" || rc=$?
assert_eq "$rc" "1" "a failing ledger write ABORTS skip-remaining"
assert_contains "$out" "could not update the steps ledger" "skip-remaining names the ledger refusal"
case "$out" in
  *"remaining steps skipped"*) fail "skip-remaining must never report success on an unwritten ledger: $out" ;;
esac
# Healthy path on the same run: with the ledger back, both verbs behave.
printf 'intent\tpending\t0\n' >"$lrd/steps.tsv"
printf 'push\tpending\t0\n' >>"$lrd/steps.tsv"
"$BIN/ac-ship.sh" step intent completed >/dev/null || fail "step still writes a readable ledger"
assert_contains "$("$BIN/ac-ship.sh" status)" "intent     completed" "the healthy step transition lands"
"$BIN/ac-ship.sh" skip-remaining >/dev/null || fail "skip-remaining still works on a readable ledger"
assert_contains "$("$BIN/ac-ship.sh" status)" "push       skipped" "the healthy skip lands"
cd "$repo" || fail "cd back from ledgerrepo"

# --- lint opt-in + test skip-if-TDD + start notes (crew-ship-lean-pipeline) ---
# Both conditional steps FAIL TOWARD RUNNING: lint is skip-by-default (opt-in via
# --lint), test runs by default (opt-out via --tdd). The start line must SAY when
# either defaulted skipped, so a green run is never read as a linted/tested one.
out="$("$BIN/ac-ship.sh" start --intent "lean default")"
assert_contains "$out" "lint skip-by-default" "start announces the lint opt-in default"
case "$out" in *"test skipped"*) fail "no --tdd must not announce a test skip" ;; esac
rd_lean="$repo/.crew/ship/$(readlink "$repo/.crew/ship/current")"
assert_eq "$(awk -F'\t' '$1=="lint"{print $2}' "$rd_lean/steps.tsv")" "skipped" "lint starts skipped without --lint"
assert_eq "$(awk -F'\t' '$1=="test"{print $2}' "$rd_lean/steps.tsv")" "pending" "test RUNS by default - fail closed, only --tdd skips it"

# --lint opts lint IN; the note is gone.
out="$("$BIN/ac-ship.sh" start --intent "lean lint on" --lint)"
case "$out" in *"skip-by-default"*) fail "--lint must not print the skip-by-default note" ;; esac
rd_on="$repo/.crew/ship/$(readlink "$repo/.crew/ship/current")"
assert_eq "$(awk -F'\t' '$1=="lint"{print $2}' "$rd_on/steps.tsv")" "pending" "--lint makes lint runnable (pending)"

# --tdd opts test OUT: the implement declares its TDD run is the evidence, and
# the start line says so. lint is unaffected (still its own default).
out="$("$BIN/ac-ship.sh" start --intent "lean tdd" --tdd)"
assert_contains "$out" "test skipped" "start announces the --tdd test skip"
rd_tdd="$repo/.crew/ship/$(readlink "$repo/.crew/ship/current")"
assert_eq "$(awk -F'\t' '$1=="test"{print $2}' "$rd_tdd/steps.tsv")" "skipped" "--tdd skips test"
assert_eq "$(awk -F'\t' '$1=="lint"{print $2}' "$rd_tdd/steps.tsv")" "skipped" "--tdd leaves lint on its own default (skipped without --lint)"

# The two flags are independent: --lint runs lint, --tdd skips test, same run.
"$BIN/ac-ship.sh" start --intent "lean both" --lint --tdd >/dev/null
rd_both="$repo/.crew/ship/$(readlink "$repo/.crew/ship/current")"
assert_eq "$(awk -F'\t' '$1=="lint"{print $2}' "$rd_both/steps.tsv")" "pending" "--lint runs lint regardless of --tdd"
assert_eq "$(awk -F'\t' '$1=="test"{print $2}' "$rd_both/steps.tsv")" "skipped" "--tdd skips test regardless of --lint"

# An explicit --skip still wins for either step, so nothing contradicts.
"$BIN/ac-ship.sh" start --intent "lean skip wins" --lint --skip lint >/dev/null
rd_skip="$repo/.crew/ship/$(readlink "$repo/.crew/ship/current")"
assert_eq "$(awk -F'\t' '$1=="lint"{print $2}' "$rd_skip/steps.tsv")" "skipped" "--skip lint overrides --lint"

# --- SHIP TEST RECEIPT: the run-scoped exact-SHA record QA may only READ ---------
# The QA boundary policy (captain 2026-07-25) forbids QA from running a unit
# suite, so unit-suite health reaches a QA round ONLY through this receipt. It
# is written by execution and never by a claim.
rcp_repo="$(make_repo shiprcp)"
cd "$rcp_repo" || fail "cd shiprcp"
git -C "$rcp_repo" checkout -qb crew/receipt
rcp_log="$TMP/rcp.log"
rcp_cfg="$AC_HOME/projects/shiprcp.yaml"
printf 'commands:\n  test: "echo ran >>%s && echo green"\n' "$rcp_log" >"$rcp_cfg"
receipt_of() { sed -n "s/^$2=//p" "$1" | head -n1; }

# A green managed execution qualifies, and binds the exact HEAD it ran on.
"$BIN/ac-ship.sh" start --intent "receipt green" >/dev/null
rcp_run="$rcp_repo/.crew/ship/$(readlink "$rcp_repo/.crew/ship/current")"
"$BIN/ac-ship.sh" cmd test >/dev/null 2>&1
rcp="$rcp_run/test/receipt.env"
assert_file "$rcp" "cmd test publishes a run-scoped receipt"
assert_eq "$(receipt_of "$rcp" schema)" "agentcrew.ship-test-receipt/v1" "the closed schema"
assert_eq "$(receipt_of "$rcp" qualification)" "qualifies" "a zero-exit execution qualifies"
assert_eq "$(receipt_of "$rcp" reason)" "executed" "and names execution as the reason"
assert_eq "$(receipt_of "$rcp" source_sha)" "$(git -C "$rcp_repo" rev-parse HEAD)" \
  "the receipt binds the exact delivered SHA"
assert_eq "$(receipt_of "$rcp" exit_code)" "0" "a qualifying receipt exited zero"
[ -n "$(receipt_of "$rcp" started_at)" ] && [ -n "$(receipt_of "$rcp" completed_at)" ] \
  || fail "a qualifying receipt records its real execution window"

# ac_qa_ship_receipt_status is the ONE reader both the freeze and the gate use.
status_of() {
  bash -c ". '$BIN/ac-lib.sh'; . '$BIN/ac-qa-lib.sh'; ac_qa_ship_receipt_status '$1' '$2'"
}
assert_eq "$(status_of "$rcp" "$(git -C "$rcp_repo" rev-parse HEAD)")" "qualifies:executed" \
  "the reader accepts a real green execution"
assert_eq "$(status_of "$rcp" 0000000000000000000000000000000000000000)" "not-qualifies:stale" \
  "a receipt for another commit is stale, never proof"
assert_eq "$(status_of "$TMP/no-such-receipt.env" abc)" "not-qualifies:absent" \
  "an absent receipt is a NOT-qualifying answer, never an error"

# A SECOND attempt invalidates the earlier success BEFORE the command runs, so
# an interruption can never leave a stale pass current.
printf 'commands:\n  test: "echo ran >>%s && exit 3"\n' "$rcp_log" >"$rcp_cfg"
"$BIN/ac-ship.sh" start --intent "receipt red" >/dev/null
rcp_run2="$rcp_repo/.crew/ship/$(readlink "$rcp_repo/.crew/ship/current")"
rc=0; "$BIN/ac-ship.sh" cmd test >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "3" "a failing suite propagates its exit code"
assert_eq "$(receipt_of "$rcp_run2/test/receipt.env" qualification)" "not-qualifies" \
  "a non-zero execution does not qualify"
assert_eq "$(receipt_of "$rcp_run2/test/receipt.env" reason)" "non-zero" "and names why"

# An INTERRUPTED attempt leaves `incomplete`, not the previous success: the
# receipt is replaced before the command is even invoked.
printf 'commands:\n  test: "kill -TERM $$"\n' >"$rcp_cfg"
"$BIN/ac-ship.sh" start --intent "receipt interrupted" >/dev/null
rcp_run3="$rcp_repo/.crew/ship/$(readlink "$rcp_repo/.crew/ship/current")"
"$BIN/ac-ship.sh" cmd test >/dev/null 2>&1 || true
assert_eq "$(receipt_of "$rcp_run3/test/receipt.env" qualification)" "not-qualifies" \
  "an interrupted attempt never qualifies"

# An ACCEPTED execution attestation copies its exact identity into the receipt.
printf 'commands:\n  test: "echo ran >>%s && echo green"\n' "$rcp_log" >"$rcp_cfg"
"$BIN/ac-ship.sh" attest-test >/dev/null 2>&1
att="$rcp_repo/.crew/ship/attest-test.json"
[ -n "$(jq -r '.started_at // ""' "$att")" ] && [ -n "$(jq -r '.completed_at // ""' "$att")" ] \
  || fail "attest-test records the append-only execution window"
"$BIN/ac-ship.sh" start --intent "receipt attested" >/dev/null
rcp_run4="$rcp_repo/.crew/ship/$(readlink "$rcp_repo/.crew/ship/current")"
"$BIN/ac-ship.sh" cmd test >/dev/null 2>&1
assert_eq "$(receipt_of "$rcp_run4/test/receipt.env" reason)" "execution-attestation" \
  "an accepted attestation qualifies as execution evidence"
assert_eq "$(receipt_of "$rcp_run4/test/receipt.env" output_sha256)" \
  "$(jq -r .output_sha256 "$att")" "and copies the attestation's exact output identity"

# A DECLARATION creates no receipt: --tdd skips the step, and nothing is written.
printf 'declare\n' >>"$rcp_repo/file.txt"
git -C "$rcp_repo" commit -qam "declare change"
"$BIN/ac-ship.sh" start --intent "receipt declared" --tdd >/dev/null
rcp_run5="$rcp_repo/.crew/ship/$(readlink "$rcp_repo/.crew/ship/current")"
assert_no_file "$rcp_run5/test/receipt.env" "a --tdd declaration mints no execution receipt"
cd "$repo" || fail "cd back from shiprcp"

# --- review-round-convergence: cap, chief-decide residual, --final-round ------
# Captain 2026-08-05. A fresh repo so the round counter starts at zero and the
# DEFAULT cap (3, no review.max_rounds key) is what is under test.
caprepo="$(make_repo caprepo)"
cd "$caprepo" || fail "cd $caprepo"
cat >"$AC_HOME/projects/caprepo.yaml" <<'EOF'
commands:
  test: "echo test-ok"
EOF
capstub="$TMP/capstub"; mkdir -p "$capstub"
cat >"$capstub/ac-verify" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = codereview ] || exit 2
shift
output=""; ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift ;;
    --ref) ref="$2"; shift ;;
    --repo|--base|--family|--caller|--intent|--history|--owner) shift ;;
    *) exit 2 ;;
  esac
  shift
done
# Every round reports a genuine in-current-delta fix so this cap fixture stays
# in the fix loop even after durable round results are round-normalized.
jq -n --arg ref "$ref" '{findings:[{id:"resid",severity:"warning",action:"fix",file:"f.txt",class:"regression",description:"late nit",authority_class:"internal",authority:"tests/x:1",suggested_fix:"s"}],summary:"nit",risk_level:"low",risk_rationale:"r",reviewed_ref:$ref,verdict:"fix"}' >"$output"
cat "$output"
EOF
chmod +x "$capstub/ac-verify"
"$BIN/ac-ship.sh" start --intent "cap exercise" --skip pr >/dev/null
git -C "$caprepo" checkout -qb crew/cap
printf 'work\n' >>"$caprepo/f.txt" && git -C "$caprepo" add f.txt && git -C "$caprepo" commit -qm work
"$BIN/ac-ship.sh" step test completed --note "suite green" >/dev/null
caprun="$caprepo/.crew/ship/$(readlink "$caprepo/.crew/ship/current")"

# Residual acceptance is REFUSED below the cap - the normal loop is not skippable.
AC_CREW_ID=cap-implement AC_VERIFY_BIN="$capstub/ac-verify" "$BIN/ac-ship.sh" review-agent >/dev/null
assert_fails "$BIN/ac-ship.sh" review-residual accept --grounds "too early"

# Rounds 2 and 3 run inside the default cap (each after a fixing tick).
for r in 2 3; do
  "$BIN/ac-ship.sh" step review fixing >/dev/null
  printf 'r%s\n' "$r" >>"$caprepo/f.txt"
  git -C "$caprepo" commit -qam "fix r$r"
  out="$(AC_CREW_ID=cap-implement AC_VERIFY_BIN="$capstub/ac-verify" "$BIN/ac-ship.sh" review-agent)"
  assert_contains "$out" "review-agent round $r" "round $r runs inside the cap"
done
assert_eq "$(jq -r '.[0].action' "$caprun/findings/review.json")" "fix" "cap rounds keep a genuine in-delta fix finding"

# Round 4 exceeds the default cap: HOLD naming both chief options, no verifier run.
"$BIN/ac-ship.sh" step review fixing >/dev/null
printf 'r4\n' >>"$caprepo/f.txt" && git -C "$caprepo" commit -qam "fix r4"
rc=0
out="$(AC_CREW_ID=cap-implement AC_VERIFY_BIN="$capstub/ac-verify" "$BIN/ac-ship.sh" review-agent 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "round 4 must HOLD at the default cap"
assert_contains "$out" "review.max_rounds=3" "the hold names the cap"
assert_contains "$out" "review-residual accept" "the hold names the acceptance path"
assert_contains "$out" "--final-round" "the hold names the one final-round grant"

# The carve-out blocks acceptance: plant a critical security fix finding.
jq '. + [{"id":"bomb","severity":"error","action":"fix","class":"security","file":"untouched.txt","description":"real bomb","authority_class":"internal","authority":"tests/x:1"}]' \
  "$caprun/findings/review.json" >"$caprun/findings/.tmp" && mv "$caprun/findings/.tmp" "$caprun/findings/review.json"
rc=0
out="$("$BIN/ac-ship.sh" review-residual accept --grounds "sweep it" 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a critical carve-out finding must refuse residual acceptance"
assert_contains "$out" "carve-out" "the refusal names the carve-out"
# Drop the bomb again (as if the final round fixed it) and accept the residual.
jq '[.[] | select(.id != "bomb")
     | if .id == "resid" then .action = "fix" else . end]' \
  "$caprun/findings/review.json" >"$caprun/findings/.tmp" && mv "$caprun/findings/.tmp" "$caprun/findings/review.json"
out="$("$BIN/ac-ship.sh" review-residual accept --grounds "advisory nit, backlogged")"
assert_contains "$out" "SELF-APPROVED: review-residual r3" "acceptance prints the room receipt"
assert_eq "$(jq -r '.[0].action' "$caprun/findings/review.json")" "no-op" "the residual finding is now advisory"
assert_eq "$(jq -r '.[0].residual_accepted' "$caprun/findings/review.json")" "true" "the acceptance is marked"
assert_eq "$(jq -r '.[0].residual_grounds' "$caprun/findings/review.json")" "advisory nit, backlogged" "the grounds ride the wire"
assert_fails bash -c "'$BIN/ac-ship.sh' review-residual accept --grounds x" # nothing left to accept

# --final-round grants exactly once past the cap.
out="$(AC_CREW_ID=cap-implement AC_VERIFY_BIN="$capstub/ac-verify" "$BIN/ac-ship.sh" review-agent --final-round)"
assert_contains "$out" "review-agent round 4" "--final-round opens the one extra round"
assert_file "$caprun/review.final-round" "the grant is durable"
"$BIN/ac-ship.sh" step review fixing >/dev/null
printf 'r5\n' >>"$caprepo/f.txt" && git -C "$caprepo" commit -qam "fix r5"
rc=0
out="$(AC_CREW_ID=cap-implement AC_VERIFY_BIN="$capstub/ac-verify" "$BIN/ac-ship.sh" review-agent --final-round 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a second --final-round must refuse"
assert_contains "$out" "already spent" "the refusal names the spent grant"
cd "$repo" || fail "cd back from caprepo"

# --- review-round floor: round 3 uses round 2's reviewed_ref ------------------
# A warning fix on a file changed in round 2 but untouched in round 3 floors only
# when it is a NEW id. The same previous-round open id must stay fix even though
# it is outside the r2..r3 delta.
floorrepo="$(make_repo floorrepo)"
cd "$floorrepo" || fail "cd $floorrepo"
cat >"$AC_HOME/projects/floorrepo.yaml" <<'EOF'
commands:
  test: "echo test-ok"

review:
  max_rounds: 9
EOF
floorstub="$TMP/floorstub"; mkdir -p "$floorstub"
cat >"$floorstub/ac-verify" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = codereview ] || exit 2
shift
output=""; ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift ;;
    --ref) ref="$2"; shift ;;
    --repo|--base|--family|--caller|--intent|--history|--owner) shift ;;
    *) exit 2 ;;
  esac
  shift
done
case "${FLOOR_STAGE:-carried}" in
  r3)
    jq -n --arg ref "$ref" '{findings:[
      {id:"floor-carried",severity:"warning",action:"fix",file:"r2-only.txt",class:"regression",description:"carried blocker",authority_class:"internal",authority:"tests/x:1",suggested_fix:"s"},
      {id:"floor-new",severity:"warning",action:"fix",file:"r2-only.txt",class:"regression",description:"new late nit",authority_class:"internal",authority:"tests/x:1",suggested_fix:"s"}],
      summary:"nit",risk_level:"low",risk_rationale:"r",reviewed_ref:$ref,verdict:"fix"}' >"$output" ;;
  *)
    jq -n --arg ref "$ref" '{findings:[
      {id:"floor-carried",severity:"warning",action:"fix",file:"r2-only.txt",class:"regression",description:"carried blocker",authority_class:"internal",authority:"tests/x:1",suggested_fix:"s"}],
      summary:"nit",risk_level:"low",risk_rationale:"r",reviewed_ref:$ref,verdict:"fix"}' >"$output" ;;
esac
cat "$output"
EOF
chmod +x "$floorstub/ac-verify"
"$BIN/ac-ship.sh" start --intent "floor exercise" --skip pr >/dev/null
git -C "$floorrepo" checkout -qb crew/floor
printf 'work\n' >>"$floorrepo/f.txt" && git -C "$floorrepo" add f.txt && git -C "$floorrepo" commit -qm work
"$BIN/ac-ship.sh" step test completed --note "suite green" >/dev/null
floorrun="$floorrepo/.crew/ship/$(readlink "$floorrepo/.crew/ship/current")"
FLOOR_STAGE=carried AC_CREW_ID=floor-implement AC_VERIFY_BIN="$floorstub/ac-verify" "$BIN/ac-ship.sh" review-agent >/dev/null
"$BIN/ac-ship.sh" step review fixing >/dev/null
printf 'r2\n' >>"$floorrepo/r2-only.txt" && git -C "$floorrepo" add r2-only.txt && git -C "$floorrepo" commit -qm "fix r2"
FLOOR_STAGE=carried AC_CREW_ID=floor-implement AC_VERIFY_BIN="$floorstub/ac-verify" "$BIN/ac-ship.sh" review-agent >/dev/null
"$BIN/ac-ship.sh" step review fixing >/dev/null
printf 'r3\n' >>"$floorrepo/f.txt" && git -C "$floorrepo" commit -qam "fix r3"
out="$(FLOOR_STAGE=r3 AC_CREW_ID=floor-implement AC_VERIFY_BIN="$floorstub/ac-verify" "$BIN/ac-ship.sh" review-agent)"
assert_contains "$out" "review-agent round 3" "floor fixture reaches round 3"
assert_eq "$(jq -r '.[] | select(.id == "floor-new") | .action' "$floorrun/findings/review.json")" "no-op" \
  "r3 new previous-round-untouched warning fix floors to no-op"
assert_eq "$(jq -r '.[] | select(.id == "floor-new") | .round_floored' "$floorrun/findings/review.json")" "true" \
  "the new-id previous-round floor is marked on the wire"
assert_eq "$(jq -r '.[] | select(.id == "floor-carried") | .action' "$floorrun/findings/review.json")" "fix" \
  "r3 prior-open id remains fix even outside the delta"
assert_eq "$(jq -r '.[] | select(.id == "floor-carried") | has("round_floored")' "$floorrun/findings/review.json")" "false" \
  "the prior-open id carries no round floor flag"
assert_eq "$(jq -r '.verdict' "$floorrun/logs/review-agent-r3.json")" "fix" \
  "durable r3 verdict remains fix because the previous open id persists"
cd "$repo" || fail "cd back from floorrepo"

# --- advisory-polish-loop A: a 0-fix verdict FREEZES the tree ------------------
# Captain 2026-08-06. A round returning ZERO `fix` findings makes the run
# landable; polishing one of its advisories afterwards kills the receipt (the
# bare-SHA re-check, no docs-only exemption) and buys a whole fresh verifier
# round - four such rounds ran in one hour on one live family, every verdict a
# PASS. The law lives in the seeded crewmate layer; this is the guard behind it.
# THE FAIL DIRECTION IS PINNED: refuse only a DECIDABLY caller-own delta;
# anything undecidable OPENS the round, because a crewmate jammed after a
# genuine rebase is the worse failure. Assertions here are round-NUMBER
# agnostic on purpose - what the numbering counts is the cap section's subject.
frzrepo="$(make_repo frzrepo)"
cd "$frzrepo" || fail "cd $frzrepo"
cat >"$AC_HOME/projects/frzrepo.yaml" <<'EOF'
commands:
  test: "echo test-ok"

# High enough that the round cap never interferes here - it has its own section.
review:
  max_rounds: 9
EOF
frzstub="$TMP/frzstub"; mkdir -p "$frzstub"
export FRZ_LOG="$TMP/frz-verify.log"
cat >"$frzstub/verdict" <<'EOF'
#!/usr/bin/env bash
# $VERDICT selects the shape: `pass` (advisory-only, landable) or `fix`.
set -euo pipefail
printf '%s\n' "$*" >>"$FRZ_LOG"
[ "${1:-}" = codereview ] || exit 2
shift
output=""; ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift ;;
    --ref) ref="$2"; shift ;;
    --repo|--base|--family|--caller|--intent|--history|--owner) shift ;;
    *) exit 2 ;;
  esac
  shift
done
jq -n --arg ref "$ref" --arg v "${VERDICT:-pass}" \
  '{findings:[{id:("f-" + $v),severity:"warning",action:(if $v == "fix" then "fix" else "no-op" end),file:"file.txt",class:"correctness",description:"nit",authority_class:"internal",authority:"tests/ac-ship.test.sh:1",suggested_fix:"polish"}],
    summary:"s",risk_level:"low",risk_rationale:"r",reviewed_ref:$ref,verdict:$v}' >"$output"
cat "$output"
EOF
chmod +x "$frzstub/verdict"
frz() { AC_CREW_ID=frz-implement AC_VERIFY_BIN="$frzstub/verdict" "$BIN/ac-ship.sh" review-agent "$@"; }
frz_calls() { [ -f "$FRZ_LOG" ] && wc -l <"$FRZ_LOG" || printf '0\n'; }
frz_head() { git -C "$frzrepo" rev-parse HEAD; }
frz_opens() {
  # frz_opens <what> [verdict] - the round must actually RUN, at current HEAD.
  # Captured rather than bare so a wrong guard reports which case it jammed
  # instead of aborting the suite on errexit with a raw refusal.
  local rc=0 out
  out="$(VERDICT="${2:-pass}" frz 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || fail "$1: the round must open, got: $out"
  assert_contains "$out" "reviewed_ref=$(frz_head)" "$1"
}
"$BIN/ac-ship.sh" start --intent "freeze exercise" --skip pr >/dev/null
git -C "$frzrepo" checkout -qb crew/frz
printf 'work\n' >>"$frzrepo/file.txt" && git -C "$frzrepo" commit -qam work
"$BIN/ac-ship.sh" step test completed --note "suite green" >/dev/null
frzrun="$frzrepo/.crew/ship/$(readlink "$frzrepo/.crew/ship/current")"

# NO PRIOR PASS = UNCHANGED. A `fix` verdict is the normal loop: the fix commit
# that follows it must still open the next round.
frz_opens "the first round reviews HEAD" fix
printf 'repair\n' >>"$frzrepo/file.txt" && git -C "$frzrepo" commit -qam "fix the finding"
frz_opens "a fix verdict leaves the next round untouched"
passed_ref="$(frz_head)"

# THE LOOP: a post-pass polish commit is REFUSED, and no verifier round is spent.
printf 'polish\n' >>"$frzrepo/file.txt" && git -C "$frzrepo" commit -qam "polish an advisory"
calls_before="$(frz_calls)"
rc=0
out="$(VERDICT=pass frz 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a post-pass polish round must be refused"
assert_contains "$out" "FREEZES the tree" "the refusal names the law"
assert_contains "$out" "${passed_ref:0:12}" "the refusal names the ref that passed"
assert_contains "$out" "follow-up task" "the refusal names the remedy"
assert_eq "$(frz_calls)" "$calls_before" "the refused round spends no verifier"

# A GENUINE REBASE STILL OPENS: upstream commits in the delta are not the
# caller's own polish, so the round runs (fail toward reviewing).
git -C "$frzrepo" checkout -q main
printf 'upstream\n' >>"$frzrepo/upstream.txt" && git -C "$frzrepo" add upstream.txt \
  && git -C "$frzrepo" commit -qm "upstream moved"
git -C "$frzrepo" checkout -q crew/frz
git -C "$frzrepo" merge -q --no-edit main
frz_opens "an upstream-containing delta opens the round"

# ...and so does a REWRITTEN history, where the passed ref is no longer an
# ancestor of HEAD - the shape an amend or a rebase leaves. Deliberately with
# the base held STILL, so this case can only pass through the ancestor check:
# a rebase onto a MOVED base is already caught by the upstream-delta case above,
# which makes it the weaker fixture of the two.
# `--no-edit` would be a no-op inside the same second (same tree, parents,
# message and timestamp = the same SHA), so change the message: the point of
# this fixture is that the passed ref is no longer reachable.
git -C "$frzrepo" commit -q --amend -m "rewritten history"
frz_opens "a rewritten history opens the round"

# UNDECIDABLE FAILS TOWARD OPENING: an unreadable prior reviewed_ref cannot
# prove the delta is polish, so the round runs rather than jamming the crewmate.
frzlast="$(ls "$frzrun"/logs/review-agent-r*.json | tail -n 1)"
jq '.reviewed_ref = "0000000000000000000000000000000000000000"' "$frzlast" >"$frzrun/logs/.frz" \
  && mv "$frzrun/logs/.frz" "$frzlast"
calls_before="$(frz_calls)"
frz_opens "an unresolvable passed ref opens the round"
[ "$(frz_calls)" -gt "$calls_before" ] || fail "the undecidable case must actually spend a round"
cd "$repo" || fail "cd back from frzrepo"
# --- advisory-polish-loop B: the cap counts verifier SPEND, not fixing ticks ---
# Captain 2026-08-06. `round` used to be the steps.tsv `fixing` column + 1, and
# nothing but an explicit `step review fixing` ever ticks that column - so a run
# whose rounds never tick it read round 1 forever while the invocations piled up
# (measured live: 4 invocations at counter 1, 11 at counter ~2). The cap was
# blind to exactly the spend it exists to bound. NO FIXING TICK IS EVER MARKED
# in this section - that absence is the whole discriminator - and a REJECTED
# attempt still consumes its slot, because a dead pane costs the same.
capbrepo="$(make_repo capbrepo)"
cd "$capbrepo" || fail "cd $capbrepo"
cat >"$AC_HOME/projects/capbrepo.yaml" <<'EOF'
commands:
  test: "echo test-ok"
EOF
capbstub="$TMP/capbstub"; mkdir -p "$capbstub"
export CAPB_LOG="$TMP/capb-verify.log"
cat >"$capbstub/verdict" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$CAPB_LOG"
[ "${1:-}" = codereview ] || exit 2
shift
output=""; ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift ;;
    --ref) ref="$2"; shift ;;
    --repo|--base|--family|--caller|--intent|--history|--owner) shift ;;
    *) exit 2 ;;
  esac
  shift
done
# No `file` on the finding: the late-finding floor can only floor what it can
# locate, so the fix residual below survives to the acceptance assertion.
jq -n --arg ref "$ref" --arg v "${CAPB_VERDICT:-pass}" \
  '{findings:[{id:"capb",severity:"warning",action:(if $v == "fix" then "fix" else "no-op" end),description:"nit",authority_class:"internal",authority:"tests/ac-ship.test.sh:1"}],
    summary:"s",risk_level:"low",risk_rationale:"r",reviewed_ref:$ref,verdict:$v}' >"$output"
cat "$output"
EOF
chmod +x "$capbstub/verdict"
cat >"$capbstub/invalid" <<'EOF'
#!/usr/bin/env bash
# A COMPLETED round whose verdict the CALLER rejects: findings is not an array.
set -euo pipefail
printf '%s\n' "$*" >>"$CAPB_LOG"
output=""; ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift ;;
    --ref) ref="$2"; shift ;;
    *) ;;
  esac
  shift
done
jq -n --arg ref "$ref" '{findings:"not-an-array",summary:"s",risk_level:"low",risk_rationale:"r",reviewed_ref:$ref,verdict:"pass"}' >"$output"
EOF
chmod +x "$capbstub/invalid"
capb() { AC_CREW_ID=capb-implement AC_VERIFY_BIN="$capbstub/${2:-verdict}" "$BIN/ac-ship.sh" review-agent; }
capb_calls() { [ -f "$CAPB_LOG" ] && wc -l <"$CAPB_LOG" || printf '0\n'; }
"$BIN/ac-ship.sh" start --intent "cap-by-spend exercise" --skip pr >/dev/null
git -C "$capbrepo" checkout -qb crew/capb
printf 'work\n' >>"$capbrepo/file.txt" && git -C "$capbrepo" commit -qam work
"$BIN/ac-ship.sh" step test completed --note "suite green" >/dev/null
capbrun="$capbrepo/.crew/ship/$(readlink "$capbrepo/.crew/ship/current")"

# Invocation 1: a landable PASS round, no fixing tick.
out="$(CAPB_VERDICT=pass capb)"
assert_contains "$out" "review-agent round 1" "the first invocation is round 1"

# Invocation 2 is REJECTED by the caller. It burns no round number (the retry is
# the same round) but it DID spend a verifier - the distinction the cap has to
# get right. Its result is retired rather than kept, or the rejected verdict
# would count as a durable round and the retry would skip a number.
git -C "$capbrepo" checkout -q main
printf 'upstream\n' >>"$capbrepo/upstream.txt" && git -C "$capbrepo" add upstream.txt \
  && git -C "$capbrepo" commit -qm "upstream moved"
git -C "$capbrepo" checkout -q crew/capb
git -C "$capbrepo" merge -q --no-edit main
rc=0
capb x invalid >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "the rejected verifier round must fail the adapter"
assert_no_file "$capbrun/logs/review-agent-r2.json" "a rejected verdict is no durable round result"
assert_file "$capbrun/logs/review-agent-r2.json.rejected" "the rejected verdict is retired, not deleted"

# Invocation 3 retries the SAME round and succeeds - round 2, with zero fixing
# ticks anywhere in this run. Under the old derivation this reads round 1.
out="$(CAPB_VERDICT=fix capb)"
assert_contains "$out" "review-agent round 2" "the round number counts durable rounds, not fixing ticks"
assert_eq "$(awk -F'\t' '$1 == "review" { print $3 + 0 }' "$capbrun/steps.tsv")" "0" \
  "no fixing tick was ever marked - the cap below cannot be reading that column"

# Invocation 4 exceeds review.max_rounds=3 (default) and HOLDs, even though the
# round counter only reached 2: the dead attempt spent a slot too.
printf 'repair\n' >>"$capbrepo/file.txt" && git -C "$capbrepo" commit -qam "repair the finding"
calls_before="$(capb_calls)"
rc=0
out="$(CAPB_VERDICT=fix capb 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "the 4th verifier invocation must HOLD at the default cap"
assert_contains "$out" "review.max_rounds=3" "the hold names the cap"
assert_contains "$out" "review-residual accept" "the hold names the acceptance path"
assert_contains "$out" "--final-round" "the hold names the one final-round grant"
assert_eq "$(capb_calls)" "$calls_before" "the held invocation spends no verifier"

# The OTHER review.max_rounds reader must count the same thing: acceptance is
# for a loop AT the cap, and with zero fixing ticks the old reader saw zero.
out="$("$BIN/ac-ship.sh" review-residual accept --grounds "advisory nit, backlogged")"
assert_contains "$out" "SELF-APPROVED: review-residual r3" \
  "residual acceptance counts invocations too, or the cap and its release disagree"
cd "$repo" || fail "cd back from capbrepo"
# --- advisory-polish-loop C: the same-ref retry brake --------------------------
# Captain 2026-08-06. One live family retried the SAME ref three and four times:
# one pane died mid-write, the rest were completed verdicts the caller rejected,
# and every retry was silent. A repeated failure on ONE ref is an infrastructure
# or validator signal - more model spend never fixes it - so the third
# invocation on a ref HOLDs and hands the chief both prior outcomes and the
# places to read them.
brkrepo="$(make_repo brkrepo)"
cd "$brkrepo" || fail "cd $brkrepo"
cat >"$AC_HOME/projects/brkrepo.yaml" <<'EOF'
commands:
  test: "echo test-ok"

# The D cases below add invocations; the cap has its own section.
review:
  max_rounds: 9
EOF
brkstub="$TMP/brkstub"; mkdir -p "$brkstub"
export BRK_LOG="$TMP/brk-verify.log"
cat >"$brkstub/dead" <<'EOF'
#!/usr/bin/env bash
# A pane that died mid-write: non-zero, --output never written.
printf '%s\n' "$*" >>"$BRK_LOG"
exit 1
EOF
cat >"$brkstub/invalid" <<'EOF'
#!/usr/bin/env bash
# A COMPLETED round whose verdict the caller rejects: findings is not an array.
set -euo pipefail
printf '%s\n' "$*" >>"$BRK_LOG"
output=""; ref=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift ;;
    --ref) ref="$2"; shift ;;
    *) ;;
  esac
  shift
done
jq -n --arg ref "$ref" '{findings:"not-an-array",summary:"s",risk_level:"low",risk_rationale:"r",reviewed_ref:$ref,verdict:"pass"}' >"$output"
EOF
chmod +x "$brkstub/dead" "$brkstub/invalid"
brk() { AC_CREW_ID=brk-implement AC_VERIFY_BIN="$brkstub/$1" "$BIN/ac-ship.sh" review-agent; }
brk_calls() { [ -f "$BRK_LOG" ] && wc -l <"$BRK_LOG" || printf '0\n'; }
"$BIN/ac-ship.sh" start --intent "retry brake exercise" --skip pr >/dev/null
git -C "$brkrepo" checkout -qb crew/brk
printf 'work\n' >>"$brkrepo/file.txt" && git -C "$brkrepo" commit -qam work
"$BIN/ac-ship.sh" step test completed --note "suite green" >/dev/null
brkref="$(git -C "$brkrepo" rev-parse HEAD)"
brkrun="$brkrepo/.crew/ship/$(readlink "$brkrepo/.crew/ship/current")"

# Two failed attempts on ONE ref, each failing a different way.
rc=0; brk dead >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "the dead attempt must fail"
rc=0; brk invalid >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "the rejected-verdict attempt must fail"

# --- advisory-polish-loop D: a rejected verdict says WHICH check failed --------
# Captain 2026-08-06, the slice they value most despite being the smallest.
# Three completed same-ref verdicts were rejected and silently re-run, and to
# this day nobody knows why: the refusal covers "invalid or does not bind
# current HEAD" alike and leaves no trace. One line per rejection, in the run
# log that already exists, naming the check that actually failed.
assert_contains "$(cat "$brkrun/logs/run.log")" "findings-not-an-array" \
  "the caller's rejection names the check that actually failed"

# The third refuses, and hands over everything needed to diagnose it.
calls_before="$(brk_calls)"
rc=0
# AC_FLEET_STATE is what ac-spawn threads into every crew pane, and it is the
# only thing that can resolve the verifier's evidence dir - the helpers unset it
# for the suite, so set it here or the pointer degrades to its relative form.
out="$(AC_FLEET_STATE="$TMP/fleet/state" brk invalid 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a third invocation on the same ref must be refused"
assert_contains "$out" "${brkref:0:12}" "the refusal names the ref that keeps failing"
assert_contains "$out" "dead-pane" "the refusal names the first attempt's outcome"
assert_contains "$out" "rejected-verdict" "the refusal names the second attempt's outcome"
assert_contains "$out" "transcript.jsonl" "the refusal names the verifier evidence to read"
assert_contains "$out" "pane-result.ndjson" "the refusal names the pane result to read"
assert_contains "$out" "run.log" "the refusal names the caller's own rejection log"
assert_contains "$out" "$TMP/fleet/data/brk/verify/codereview" \
  "the evidence pointer resolves THIS family's verify dir, not an empty path"
assert_contains "$out" "dead-pane; attempt 2" "both attempts read as one list, not one run-on token"
assert_eq "$(brk_calls)" "$calls_before" "the braked invocation spends no verifier"

# A DIFFERENT ref is a different question: the brake never blocks new work.
printf 'more\n' >>"$brkrepo/file.txt" && git -C "$brkrepo" commit -qam "move the ref"
rc=0; brk dead >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "the fixture's dead stub still fails"
[ "$(brk_calls)" -gt "$calls_before" ] || fail "a new ref must still reach the verifier"

# A DIFFERENT check fails here, and the line must say so - one that named the
# same thing every time would diagnose nothing.
cat >"$brkstub/badref" <<'EOF'
#!/usr/bin/env bash
# A well-formed verdict bound to some OTHER commit.
set -euo pipefail
printf '%s\n' "$*" >>"$BRK_LOG"
output=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) output="$2"; shift ;;
    *) ;;
  esac
  shift
done
jq -n '{findings:[],summary:"s",risk_level:"low",risk_rationale:"r",reviewed_ref:"0000000000000000000000000000000000000000",verdict:"pass"}' >"$output"
EOF
chmod +x "$brkstub/badref"
printf 'again\n' >>"$brkrepo/file.txt" && git -C "$brkrepo" commit -qam "move the ref again"
rc=0; brk badref >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "a verdict bound to another commit must be rejected"
runlog="$(cat "$brkrun/logs/run.log")"
assert_contains "$runlog" "reviewed_ref-does-not-bind-HEAD" "the line names the bind check"
assert_eq "$(printf '%s\n' "$runlog" | grep -c 'verdict REJECTED')" "2" \
  "one line per rejection - both are on record, neither repeated"
cd "$repo" || fail "cd back from brkrepo"

pass
