#!/usr/bin/env bash
# ac-ship.test.sh - the crew-ship state machine: run lifecycle, step
# transitions, config reading from the fleet-home project store,
# deterministic command execution, findings fail-closed default, and the
# TDD attestation (attest-test by execution + test-step acceptance +
# the attest-check verifier query).

# FAIL-CLOSED SOURCING (this suite pushes): run from anywhere but tests/sh/, the
# source below no-ops, errexit is never armed, every helper var stays EMPTY -
# and the push fixtures below then hit the REAL repo (incident 2026-07-20).
# Abort instead of running unsourced.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }
RBIN="$(make_retired_bin)"

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
printf '[{"id":"RF1","severity":"error","action":"fix","authority_class":"internal","authority":"tests/sh/ac-ship.test.sh:1","description":"real bug"}]' \
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

# A JSON passed as an argument is refused before stdin is read, like findings'
# stray word: the oracle ignored it and blocked on a stdin a harness may never
# close.
sum_before="$(shasum -a 256 "$run_dir/findings/review.meta.json")"
rc=0
out="$(printf '{"risk_level":"high"}' | "$BIN/ac-ship.sh" meta review '{"risk_level":"low"}' 2>&1)" || rc=$?
assert_eq "$rc" "1" "meta refuses a stray argument"
assert_contains "$out" "usage: ac-ship.sh meta <step>" "the refusal names meta's usage"
assert_eq "$(shasum -a 256 "$run_dir/findings/review.meta.json")" "$sum_before" \
  "a refused stray argument leaves the recorded meta untouched"

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
jq -n --arg ref "$ref" --arg v "${RA_VERDICT:-pass}" '{findings:[{id:"ra1",severity:"warning",action:(if $v == "fix" then "fix" else "no-op" end),description:"observed",authority_class:"internal",authority:"tests/sh/ac-ship.test.sh"}],summary:"clean",risk_level:"low",risk_rationale:"bounded",reviewed_ref:$ref,verdict:$v}' >"$output"
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
    jq -n --arg ref "$ref" '{findings:[{id:"same-fix",severity:"warning",action:"fix",file:"file.txt",class:"regression",description:"bug",authority_class:"internal",authority:"tests/sh/ac-ship.test.sh:1"}],summary:"s",risk_level:"low",risk_rationale:"r",reviewed_ref:$ref,verdict:"fix"}' >"$output" ;;
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
  {"id":"L1","severity":"error","action":"fix","file":"bin/x.sh","line":7,"description":"unquoted var","authority_class":"internal","authority":"the bin/ac-lint.sh shellcheck pass declares the quoting rule"},
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
assert_contains "$fr" "authority: the bin/ac-lint.sh shellcheck pass declares the quoting rule" "to-fix lines carry the authority"
assert_contains "$fr" "DECIDED: yes, rename to --force" "decided ask-user included"
assert_contains "$fr" "Parked - awaiting captain" "undecided parks"
assert_contains "$fr" "drop legacy path?" "parked item listed"
assert_contains "$fr" "NO AUTHORITY NAMED" "a downgraded finding is marked in the parked section"
case "$fr" in *"style nit"*) fail "no-op findings must be omitted" ;; esac
assert_contains "$fr" "Do NOT push" "contract present"
# FIX THE CLASS, NOT THE INSTANCE: the fixer's unit of work is the invariant
# a finding violates, closed at every sibling site in the changed area in the
# same round - and then SELF-TRACED, so the fix's own dead paths go with it.
# Both stay inside the no-refactor fence.
assert_contains "$fr" "INVARIANT a finding violates" "the contract names the invariant as the unit of work"
assert_contains "$fr" "every sibling site in the changed area" "the contract asks for the class's sibling sites"
assert_contains "$fr" "still no refactors, no unrelated scope" "the class rule keeps the no-refactor fence in the same sentence"
assert_contains "$fr" "SELF-TRACE" "the contract asks for a self-trace before verifying"
assert_contains "$fr" "deleting what the fix made unreachable" "the self-trace removes what the fix orphaned"
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

# A start over this branch's own still-running run used to repoint current
# silently, so a run HELD at the review cap restarted with a fresh ledger and
# three more rounds - the chief's cap decision skipped. It now refuses once
# that run has spent a review invocation; nothing spent, finished, or another
# branch's run (a reused pool slot) still starts.
rsrepo="$(make_repo restartrepo)"
cd "$rsrepo" || fail "cd restartrepo"
"$BIN/ac-ship.sh" start --intent "first" >/dev/null
first="$(readlink .crew/ship/current)"
"$BIN/ac-ship.sh" start --intent "no review spent yet" >/dev/null || fail "a run with no review invocation restarts"
second="$(readlink .crew/ship/current)"
[ "$first" != "$second" ] || fail "the restart made a new run"
printf '1\tdeadbeef\tcodereview\tok\n' >".crew/ship/$second/logs/review-invocations.tsv"
rc=0
out="$("$BIN/ac-ship.sh" start --intent "reset the cap" 2>&1)" || rc=$?
[ "$rc" -eq 1 ] || fail "a start over a running run with a spent review must refuse (rc=$rc)"
assert_contains "$out" "run $second" "the refusal names the running run"
assert_contains "$out" "ac-ship.sh finish cancelled" "the refusal names the sanctioned way out"
assert_eq "$(readlink .crew/ship/current)" "$second" "a refused start repoints nothing"
"$BIN/ac-ship.sh" finish cancelled >/dev/null
"$BIN/ac-ship.sh" start --intent "after cancel" >/dev/null || fail "a finished run never blocks a start"
printf '1\tdeadbeef\tcodereview\tok\n' >".crew/ship/$(readlink .crew/ship/current)/logs/review-invocations.tsv"
git switch -q -c crew/other-task
"$BIN/ac-ship.sh" start --intent "another branch" >/dev/null || fail "another branch's running run never blocks a start"
cd "$repo" || fail "cd back from restartrepo"

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
grep -qE "$re" <<<"$finish_out" || fail "finish checks-passed emits a line the chief wakes on"
grep -qE '^checks-passed: ' <<<"$finish_out" || fail "finish emits the anchored checks-passed: marker"
assert_eq "$(git -C "$repo" status --porcelain)" "" "repo stays clean"

# An ALREADY-GONE reviewer pane must not abort finish (mirrors ac-qa.sh's
# `|| true` guard on the same herdr close call, ac-qa.sh cmd_finish): a
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
( cd "$work" && grep -q up-to-date < <("$BIN/ac-ship.sh" push 2>&1) ) || fail "up-to-date detection"
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
# An orca fleet opens no board even with herdr on PATH: the board is a herdr
# tab, and an orca fleet's panes are not herdr's.
printf 'orca\n' >"$AC_HOME/config/backend"
: >"$WHLOG"
out="$(PATH="$stub:$PATH" AC_SHIP_WATCH=auto "$BIN/ac-ship.sh" start --intent "orca fleet")"
assert_contains "$out" "started run" "an orca fleet's ship run starts"
case "$(cat "$WHLOG")" in *"tab create"*) fail "an orca fleet must open no ship board: $(cat "$WHLOG")" ;; esac
assert_no_file "$wrepo/.crew/ship/$(readlink "$wrepo/.crew/ship/current")/watch.pane" "an orca fleet records no board pane"
rm -f "$AC_HOME/config/backend"
cd "$repo" || fail "cd back"

# The watch start also closes herdr's default "1" tabs of its OWN workspace,
# read from the session-wide tab list. Here the workspace-scoped list the tab
# opener sweeps is empty, so every close below is this sweep's.
sstub="$TMP/sweepstub"; mkdir -p "$sstub"
cat >"$sstub/herdr" <<'EOF'
#!/usr/bin/env bash
echo "herdr $*" >>"$WHLOG"
[ "${1:-}" = --session ] && shift 2
[ "$*" = "tab list" ] && { [ -z "${SWEEP_FAIL:-}" ] || exit 3; cat "$SWEEP_TABS"; exit 0; }
case "${1:-} ${2:-}" in
  "pane list") echo '{"result":{"panes":[]}}' ;;
  "workspace get") exit 1 ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wW"}}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"tW"},"root_pane":{"pane_id":"pW1"}}}' ;;
esac
exit 0
EOF
chmod +x "$sstub/herdr"
export SWEEP_TABS="$TMP/sweep-tabs.json"
srepo="$(make_repo sweeprepo)"
cd "$srepo" || fail "cd sweeprepo"
printf '%s' '{"result":{"tabs":[{"tab_id":"tJ","workspace_id":"wW","label":"1"},{"tab_id":"tO","workspace_id":"wO","label":"1"},{"tab_id":"tK","workspace_id":"wW","label":"keep"},{"tab_id":"tJ2","workspace_id":"wW","label":"1"}]}}' >"$SWEEP_TABS"
: >"$WHLOG"
PATH="$sstub:$PATH" AC_SHIP_WATCH=auto "$BIN/ac-ship.sh" start --intent "sweep" >/dev/null
assert_eq "$(sed -n 's/.* tab close //p' "$WHLOG" | paste -sd, -)" "tJ,tJ2" \
  "only this workspace's \"1\" tabs are closed, in list order"
PATH="$sstub:$PATH" "$BIN/ac-ship.sh" finish cancelled >/dev/null
printf 'not json' >"$SWEEP_TABS"
: >"$WHLOG"
rc=0
out="$(PATH="$sstub:$PATH" AC_SHIP_WATCH=auto "$BIN/ac-ship.sh" start --intent "sweep garbage" 2>&1)" || rc=$?
assert_eq "$rc" "0" "an unreadable tab list never fails the start"
assert_contains "$out" "started run" "the start still reports its run"
case "$out" in *$'\n'*) fail "an unreadable tab list must be swallowed without a word: $out" ;; esac
case "$(cat "$WHLOG")" in *"tab close"*) fail "an unreadable tab list closes nothing" ;; esac
PATH="$sstub:$PATH" "$BIN/ac-ship.sh" finish cancelled >/dev/null
rc=0
PATH="$sstub:$PATH" SWEEP_FAIL=1 AC_SHIP_WATCH=auto "$BIN/ac-ship.sh" start --intent "sweep down" >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "a failed tab list never fails the start"
PATH="$sstub:$PATH" "$BIN/ac-ship.sh" finish cancelled >/dev/null
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

# finish leaves the attestation in place - the chief's post-handback
# attest-check (task-lifecycle skill) is its reader, and only staleness may
# take it away.
"$BIN/ac-ship.sh" attest-test >/dev/null 2>&1 || fail "attest before finish"
attruns="$(grep -c run "$attlog")"
"$BIN/ac-ship.sh" start --intent "attestation survives finish" >/dev/null
printf '{"reviewer":"finish-survival"}' | "$BIN/ac-ship.sh" meta review >/dev/null
for s in intent rebase review test document lint push pr; do
  "$BIN/ac-ship.sh" step "$s" completed >/dev/null
done
"$BIN/ac-ship.sh" finish checks-passed >/dev/null
out="$("$BIN/ac-ship.sh" attest-check)" || fail "attest-check must stay fresh after finish"
assert_contains "$out" "attested: fresh @$(git -C "$arepo" rev-parse HEAD | cut -c1-12)" \
  "the chief reads the attestation after finish"
assert_eq "$(grep -c run "$attlog")" "$attruns" "the chief's attest-check never runs the suite"

# The post-finish query is run-independent in its CONFIG too. `current` still
# points at the finished run, so resolving that run's frozen snapshot would
# answer `fresh` for a command the project no longer configures.
cat >"$att_cfg" <<EOF
commands:
  test: "echo BRAND-NEW"
EOF
rc=0; out="$("$BIN/ac-ship.sh" attest-check)" || rc=$?
assert_eq "$rc" "1" "a changed project command stales the post-finish query"
assert_contains "$out" "commands.test changed since attestation" "the failing condition is named"
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

# Names git C-quotes even under core.quotepath=false (", \, TAB, LF) reach the
# scoped run verbatim, each as ONE argument naming a file that exists - a
# TRAILING LF too, which a bare $(...) around the escape would strip.
printf 'x\n' >"$screpo/q\"uote.txt"; printf 'x\n' >"$screpo/back\\slash.txt"
printf 'x\n' >"$screpo/tab$(printf '\t')name.txt"; printf 'x\n' >"$screpo/new
line.txt"; printf 'x\n' >"$screpo/trail
"
git -C "$screpo" add -A && git -C "$screpo" commit -qm "C-quoted names"
cat >"$TMP/each-file.sh" <<'EOF'
#!/bin/sh
for f in "$@"; do [ -f "$f" ] || { printf 'missing:%s\n' "$f"; exit 9; }; done
printf 'scoped-args=%s\n' "$#"
EOF
chmod +x "$TMP/each-file.sh"
cat >"$sc_cfg" <<EOF
commands:
  test: "echo full-ok"
  test-changed: "$TMP/each-file.sh {files}"
EOF
"$BIN/ac-ship.sh" start --intent "scoped quoted names" >/dev/null
out="$("$BIN/ac-ship.sh" cmd test 2>"$TMP/scoped-quote.err")" \
  || fail "the scoped run must receive every C-quotable name verbatim: $out"
assert_contains "$out" "scoped-args=7" "each changed name reaches the scoped run as ONE existing argument"
assert_contains "$(cat "$TMP/scoped-quote.err")" "(scoped test: 7 changed files)" \
  "the count names every changed file once"
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

# A --tdd run finishes passed-with-override, and a test step actually TAKEN
# retires the declaration (whichever way the step completes, the declaration
# is no longer the evidence).
"$BIN/ac-ship.sh" start --intent "gate tdd" --tdd >/dev/null
tddrun="$grepo/.crew/ship/$(readlink "$grepo/.crew/ship/current")"
printf '{"reviewer":"gate-test"}' | "$BIN/ac-ship.sh" meta review >/dev/null
for s in intent rebase review document lint push pr; do "$BIN/ac-ship.sh" step "$s" completed >/dev/null; done
out="$("$BIN/ac-ship.sh" finish checks-passed)" || fail "a --tdd run must finish"
assert_contains "$out" "passed-with-override: tdd-declared" "the finish receipt names the declaration"
assert_contains "$(cat "$tddrun/run.meta")" "attestation=passed-with-override:tdd-declared" \
  "the durable finish receipt carries the declaration"
"$BIN/ac-ship.sh" start --intent "gate tdd taken" --tdd >/dev/null
tddrun2="$grepo/.crew/ship/$(readlink "$grepo/.crew/ship/current")"
assert_file "$tddrun2/override" "declared at start"
"$BIN/ac-ship.sh" step test completed >/dev/null
assert_no_file "$tddrun2/override" "taking the test step clears the tdd-declared override"

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

# review-agent's ENTRY gate refuses a round without test evidence, yet the
# skill listed review before test and told the runner it could attest after
# review. A runner following the text burned an attempt on the refusal.
assert_contains "$(skill_step 3)" "attest-test" \
  "the review step names the test evidence review-agent's entry gate demands"
case "$(skill_step 4)" in *"or before this step"*) \
  fail "the test step must not advise attesting after review: the entry gate refuses that order" ;; esac

# The document step used to commit after the review round, but a 0-fix round
# freezes the tree and push/finish refuse any HEAD past reviewed_ref - so the
# doc commit moves before the reviewer, like the formatter's.
assert_contains "$(skill_step 3)" "agent-crew(document)" \
  "the review step lands the doc sweep before the reviewed ref"
case "$(skill_step 5)" in *"agent-crew(document)"*) \
  fail "the document step must not commit: it runs after the 0-fix freeze" ;; esac
assert_contains "$(skill_step 5)" "ask-user" \
  "a doc gap found after the freeze is parked for the captain, never committed"

# meta and findings read their JSON on stdin only; a JSON argv was silently
# ignored and the call waited on stdin.
skill_findings_model="$(awk '/^## Findings model/ { on = 1 } /^## The pipeline/ { exit } on' "$ship_skill")"
assert_contains "$skill_findings_model" "stdin to \`ac-ship.sh meta <step>\`" \
  "the skill says meta reads its JSON on stdin"
assert_contains "$skill_findings_model" "stdin to \`ac-ship.sh findings <step>\`" \
  "the skill says findings reads its JSON on stdin"

# A brief that lands by merging into another PR's head needs a start that
# reviews against that head and never pushes or opens a PR of its own.
skill_start="$(awk '/^Start: / { on = 1 } on && /^1\. \*\*/ { exit } on' "$ship_skill")"
assert_contains "$skill_start" "--skip push,pr" \
  "the Start paragraph documents landing into another PR's head"

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
# Omitted target: byte-compatible default-ref base - the one FROZEN at start
# too, although `current` still names the prelive run when this start begins
# (pooled worktrees keep .crew/ between leases).
out="$("$BIN/ac-ship.sh" start --intent 'default run')"
assert_contains "$out" "base=$(git rev-parse main | cut -c1-12)" \
  "no --target: the start line names the default-ref base, never the previous run's target"
grep -qx "base=$(git rev-parse main)" "$trepo/.crew/ship/$(readlink "$trepo/.crew/ship/current")/run.meta" \
  || fail "no --target: run.meta freezes the default-ref base, never the previous run's target"
assert_eq "$("$BIN/ac-ship.sh" base)" "$(git rev-parse main)" \
  "no --target: base stays the default-ref merge-base"
# A mistyped target refuses loudly - never a silent default fallback.
assert_fails "$BIN/ac-ship.sh" start --intent x --target no-such-branch
# A retired target (its branch deleted once the epic landed) must not jam the
# next task leased into this worktree.
"$BIN/ac-ship.sh" start --intent 'pinned again' --target prelive >/dev/null
git branch -q -D prelive
out="$("$BIN/ac-ship.sh" start --intent 'after the target retired' 2>&1)" \
  || fail "a start without --target must not read the previous run's retired target: $out"
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
# start refuses on the same failure BEFORE creating anything: a run dir with no
# run.meta is invisible to ac-teardown.sh's run sweep.
rc=0; "$BIN/ac-ship.sh" start --intent 'refused at the merge-base' >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "1" "start refuses when the merge-base cannot be computed"
for d in "$urepo/.crew/ship"/*/; do
  [ -f "$d/run.meta" ] || fail "a start refused at the merge-base left a run dir with no run.meta: $d"
done
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
# A threaded path that no longer exists refuses too - never a verified none.
rc=0
err="$(env -u AC_HOME AC_FLEET_HOME_CHECKED=1 AC_FLEET_PROJECT_CONFIG="$TMP/gone.yaml" \
  "$BIN/ac-ship.sh" start --intent 'threaded file gone' 2>&1 1>/dev/null)" || rc=$?
assert_eq "$rc" "1" "start refuses a threaded config path that names a missing file"
assert_contains "$err" "names a missing file" "the refusal names the missing threaded file"
unread_cfg="$TMP/mode000.yaml"
: >"$unread_cfg"; chmod 000 "$unread_cfg"
rc=0
err="$(env -u AC_HOME AC_FLEET_HOME_CHECKED=1 AC_FLEET_PROJECT_CONFIG="$unread_cfg" \
  "$BIN/ac-ship.sh" start --intent 'threaded file mode 000' 2>&1 1>/dev/null)" || rc=$?
chmod 644 "$unread_cfg"
assert_eq "$rc" "1" "start refuses a config it cannot read"
assert_contains "$err" "unreadable" "the refusal names the unreadable config"
# No refusal may leave a run dir behind (no run.meta = invisible to
# ac-teardown.sh's run sweep).
for d in "$pinrepo/.crew/ship"/*/; do
  [ -f "$d/run.meta" ] || fail "a refused start must create nothing, yet left a run dir with no run.meta: $d"
done

# attest-test and attest-check read the SAME handover start trusts: bare, the
# pane's missing AC_HOME refused them, so the evidence-backed test skip never
# worked from a real crewmate pane.
printf 'commands:\n  test: "echo pin-green"\n' >>"$pin_cfg"
out="$(env -u AC_HOME AC_FLEET_HOME_CHECKED=1 AC_FLEET_PROJECT_CONFIG="$pin_cfg" \
  "$BIN/ac-ship.sh" attest-test 2>&1)" \
  || fail "a homeless crewmate pane attests through the threaded config: $out"
assert_contains "$out" "attested: commands.test green" "attest-test runs the threaded commands.test"
out="$(env -u AC_HOME AC_FLEET_HOME_CHECKED=1 AC_FLEET_PROJECT_CONFIG="$pin_cfg" \
  "$BIN/ac-ship.sh" attest-check 2>&1)" \
  || fail "attest-check judges against the threaded config, not a homeless miss: $out"
assert_contains "$out" "attested: fresh" "a fresh attestation reads fresh from a homeless pane"
# A threaded file deleted since spawn is no config for both verbs, never awk's
# exit 2 - which attest-check reserves for `no attestation`.
rc=0
out="$(env -u AC_HOME AC_FLEET_HOME_CHECKED=1 AC_FLEET_PROJECT_CONFIG="$TMP/gone.yaml" \
  "$BIN/ac-ship.sh" attest-check 2>&1)" || rc=$?
assert_eq "$rc" "1" "attest-check answers stale when the threaded config is gone"
assert_contains "$out" "stale: commands.test changed since attestation" \
  "a vanished config un-configures the attested command"
rc=0
out="$(env -u AC_HOME AC_FLEET_HOME_CHECKED=1 AC_FLEET_PROJECT_CONFIG="$TMP/gone.yaml" \
  "$BIN/ac-ship.sh" attest-test 2>&1)" || rc=$?
assert_eq "$rc" "4" "attest-test reports no config when the threaded config is gone"
assert_contains "$out" "(no config file)" "attest-test names the missing config"
cd "$repo" || fail "cd back from pinrepo"
# Before any run exists, the config verb falls back to the same handover.
prerepo="$(make_repo prerunrepo)"
printf 'review:\n  model: opus-prerun\n' >"$AC_HOME/projects/prerunrepo.yaml"
m="$(cd "$prerepo" && env -u AC_HOME AC_FLEET_HOME_CHECKED=1 \
  AC_FLEET_PROJECT_CONFIG="$AC_HOME/projects/prerunrepo.yaml" \
  "$BIN/ac-ship.sh" config review.model 2>/dev/null || true)"
assert_eq "$m" "opus-prerun" "before any run, the config verb reads the threaded handover too"
rc=0
(cd "$prerepo" && env -u AC_HOME AC_FLEET_HOME_CHECKED=1 AC_FLEET_PROJECT_CONFIG="$TMP/gone.yaml" \
  "$BIN/ac-ship.sh" config review.model >/dev/null 2>&1) || rc=$?
assert_eq "$rc" "1" "before any run, a vanished threaded config reads as no config"

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
# Both verbs stage their temp file BESIDE steps.tsv, so the cleanup is pinned
# in the run dir itself (a bare `mktemp` on macOS ignores TMPDIR, which made
# the leak unobservable while they staged there).
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
for f in "$lrd"/.steps.tsv.*; do
  [ ! -e "$f" ] || fail "a refused ledger write must not leak its staged temp file: $f"
done
assert_no_file "$lrd/.steps.lock" "skip-remaining releases the ledger lock before the refusal"
# Healthy path on the same run: with the ledger back, both verbs behave.
printf 'intent\tpending\t0\n' >"$lrd/steps.tsv"
printf 'push\tpending\t0\n' >>"$lrd/steps.tsv"
"$BIN/ac-ship.sh" step intent completed >/dev/null || fail "step still writes a readable ledger"
assert_contains "$("$BIN/ac-ship.sh" status)" "intent     completed" "the healthy step transition lands"
"$BIN/ac-ship.sh" skip-remaining >/dev/null || fail "skip-remaining still works on a readable ledger"
assert_contains "$("$BIN/ac-ship.sh" status)" "push       skipped" "the healthy skip lands"
cd "$repo" || fail "cd back from ledgerrepo"

# The ledger lock comes BEFORE the staged temp: taken after it, a lock timeout
# exited with the temp leaked. The temp is staged beside steps.tsv, so the swap
# is one rename the live readers (src/watch-dash.ts, ac-crew-state.sh) never
# catch half-written. skip-remaining is a ledger writer too, so it honours the
# same lock. `sleep` is stubbed so the 30s lock timeout costs nothing, and
# `mktemp` records every path it hands out.
realmktemp="$(command -v mktemp)"
lkstub="$TMP/ledgerlockstub"; mkdir -p "$lkstub"
lklog="$TMP/ledger-mktemp.log"
printf '#!/bin/sh\nexit 0\n' >"$lkstub/sleep"
cat >"$lkstub/mktemp" <<EOF
#!/bin/sh
p="\$("$realmktemp" "\$@")" || exit 1
printf '%s\n' "\$p" >>"$lklog"
printf '%s\n' "\$p"
EOF
chmod +x "$lkstub/sleep" "$lkstub/mktemp"
lkrepo="$(make_repo ledgerlockrepo)"
cd "$lkrepo" || fail "cd ledgerlockrepo"
"$BIN/ac-ship.sh" start --intent "ledger lock and staging" >/dev/null
lkrd="$lkrepo/.crew/ship/$(readlink "$lkrepo/.crew/ship/current")"
: >"$lklog"
PATH="$lkstub:$PATH" "$BIN/ac-ship.sh" step intent running >/dev/null || fail "step on a free lock"
[ -s "$lklog" ] || fail "the probe must see step stage its ledger"
while IFS= read -r p; do
  assert_eq "$(dirname "$p")" "$lkrd" "step stages the ledger beside steps.tsv, so the swap is one rename"
done <"$lklog"
mkdir "$lkrd/.steps.lock"; printf '%s\n' "$$" >"$lkrd/.steps.lock/pid"
: >"$lklog"
rc=0; out="$(PATH="$lkstub:$PATH" "$BIN/ac-ship.sh" step intent completed 2>&1)" || rc=$?
assert_eq "$rc" "1" "step refuses while a live owner holds the ledger lock"
assert_contains "$out" "lock timeout" "the refusal names the lock"
while IFS= read -r p; do
  assert_no_file "$p" "a lock timeout leaves no staged ledger behind"
done <"$lklog"
rc=0; out="$(PATH="$lkstub:$PATH" "$BIN/ac-ship.sh" skip-remaining 2>&1)" || rc=$?
assert_eq "$rc" "1" "skip-remaining waits for the ledger lock instead of writing under its holder"
assert_contains "$("$BIN/ac-ship.sh" status)" "intent     running" "the held ledger is left untouched"
rm -rf "$lkrd/.steps.lock"
: >"$lklog"
PATH="$lkstub:$PATH" "$BIN/ac-ship.sh" skip-remaining >/dev/null || fail "skip-remaining on a free lock"
[ -s "$lklog" ] || fail "the probe must see skip-remaining stage its ledger"
while IFS= read -r p; do
  assert_eq "$(dirname "$p")" "$lkrd" "skip-remaining stages the ledger beside steps.tsv"
done <"$lklog"
assert_no_file "$lkrd/.steps.lock" "skip-remaining releases the ledger lock"
cd "$repo" || fail "cd back from ledgerlockrepo"

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
assert_contains "$(cat "$rd_tdd/override")" "tdd-declared" \
  "a --tdd declaration is an override: the test step was declared, not run"
assert_no_file "$rd_lean/override" "a run that RUNS test carries no override"
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
# The QA boundary policy forbids QA from running a unit
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
  bash -c ". '$BIN/ac-lib.sh'; . '$RBIN/ac-qa-lib.sh'; ac_qa_ship_receipt_status '$1' '$2'"
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
# A captain ruling. A fresh repo so the round counter starts at zero and the
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

# Residual acceptance below the cap: refused while HEAD has MOVED past the
# last reviewed ref (the normal fix loop is not skippable) - the same-ref
# STUCK state is tested as the sanctioned roundless release further down.
AC_CREW_ID=cap-implement AC_VERIFY_BIN="$capstub/ac-verify" "$BIN/ac-ship.sh" review-agent >/dev/null
"$BIN/ac-ship.sh" step review fixing >/dev/null
printf 'r2\n' >>"$caprepo/f.txt"
git -C "$caprepo" commit -qam "fix r2"
assert_fails "$BIN/ac-ship.sh" review-residual accept --grounds "too early"

# Rounds 2 and 3 run inside the default cap (round 2 on the tick above).
out="$(AC_CREW_ID=cap-implement AC_VERIFY_BIN="$capstub/ac-verify" "$BIN/ac-ship.sh" review-agent)"
assert_contains "$out" "review-agent round 2" "round 2 runs inside the cap"
"$BIN/ac-ship.sh" step review fixing >/dev/null
printf 'r3\n' >>"$caprepo/f.txt"
git -C "$caprepo" commit -qam "fix r3"
out="$(AC_CREW_ID=cap-implement AC_VERIFY_BIN="$capstub/ac-verify" "$BIN/ac-ship.sh" review-agent)"
assert_contains "$out" "review-agent round 3" "round 3 runs inside the cap"
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
assert_contains "$(cat "$caprun/override")" "review-residual" \
  "acceptance writes the override marker on the run state"
assert_fails bash -c "'$BIN/ac-ship.sh' review-residual accept --grounds x" # nothing left to accept

# --final-round grants exactly once past the cap.
out="$(AC_CREW_ID=cap-implement AC_VERIFY_BIN="$capstub/ac-verify" "$BIN/ac-ship.sh" review-agent --final-round)"
assert_contains "$out" "review-agent round 4" "--final-round opens the one extra round"
assert_file "$caprun/review.final-round" "the grant is durable"
assert_no_file "$caprun/override" \
  "a fresh review round re-judges the residual, so it clears the override marker"
"$BIN/ac-ship.sh" step review fixing >/dev/null
printf 'r5\n' >>"$caprepo/f.txt" && git -C "$caprepo" commit -qam "fix r5"
rc=0
out="$(AC_CREW_ID=cap-implement AC_VERIFY_BIN="$capstub/ac-verify" "$BIN/ac-ship.sh" review-agent --final-round 2>&1)" || rc=$?
[ "$rc" -ne 0 ] || fail "a second --final-round must refuse"
assert_contains "$out" "already spent" "the refusal names the spent grant"
cd "$repo" || fail "cd back from caprepo"

# --- roundless release: same-ref STUCK below the cap (captain rule 6) --------
# Round 1 returns a fix finding the chief judges WRONG: nothing to commit, and
# one-ref-one-round forbids another round at this HEAD - review-residual accept
# must be reachable HERE (below the cap), with the critical carve-out intact.
stkrepo="$(make_repo stkrepo)"
cd "$stkrepo" || fail "cd $stkrepo"
cat >"$AC_HOME/projects/stkrepo.yaml" <<'YEOF'
commands:
  test: "echo test-ok"
YEOF
"$BIN/ac-ship.sh" start --intent "stuck exercise" --skip pr >/dev/null
git -C "$stkrepo" checkout -qb crew/stk
printf 'work\n' >>"$stkrepo/f.txt" && git -C "$stkrepo" add f.txt && git -C "$stkrepo" commit -qm work
"$BIN/ac-ship.sh" step test completed --note "suite green" >/dev/null
stkrun="$stkrepo/.crew/ship/$(readlink "$stkrepo/.crew/ship/current")"
AC_CREW_ID=stk-implement AC_VERIFY_BIN="$capstub/ac-verify" "$BIN/ac-ship.sh" review-agent >/dev/null
# Same HEAD as round 1's reviewed_ref, rounds=1 < cap: acceptance goes through.
out="$("$BIN/ac-ship.sh" review-residual accept --grounds "finding disputes a rule the code cites - chief judges it wrong")"
assert_contains "$out" "SELF-APPROVED: review-residual" "same-ref-stuck acceptance prints the receipt"
assert_eq "$(jq -r '.[0].action' "$stkrun/findings/review.json")" "no-op" "the disputed finding is now advisory"

# --- OVERRIDE MARKER: an accepted failure is attested passed-with-override ----
# Before this, nothing machine-readable told an accepted residual from a clean
# pass: residual_accepted lived on individual findings the finish gate never
# reads, run.meta got the same outcome=checks-passed, and the PR body's meta
# inputs were written before the acceptance. ONE marker on the run state now
# carries the kind, the receipt's sha and the reason, and every receipt a
# reader gates on copies it rather than reading clean green.
stk_receipt="$(printf '%s\n' "$out" | grep '^SELF-APPROVED:')"
assert_file "$stkrun/override" "residual acceptance writes the override marker"
assert_contains "$(cat "$stkrun/override")" "review-residual" "the marker names the override kind"
assert_contains "$(cat "$stkrun/override")" "$(printf '%s' "$stk_receipt" | shasum -a 256 | awk '{print $1}')" \
  "the marker binds the SELF-APPROVED receipt by its sha"
assert_contains "$(cat "$stkrun/override")" "finding disputes a rule" "the marker carries the reason"
assert_contains "$("$BIN/ac-ship.sh" status)" "override: review-residual" "status shows the override"
"$BIN/ac-ship.sh" step review completed >/dev/null
for s in intent rebase document push; do "$BIN/ac-ship.sh" step "$s" completed >/dev/null; done
out="$("$BIN/ac-ship.sh" finish checks-passed)" \
  || fail "a residual-accepted run still finishes - the acceptance IS the sanctioned release"
assert_contains "$out" "passed-with-override: review-residual" "the finish receipt names the override"
assert_contains "$(grep '^checks-passed:' <<<"$out")" "passed-with-override" \
  "the chief-facing marker line carries it - never clean green"
assert_contains "$(cat "$stkrun/run.meta")" "attestation=passed-with-override:review-residual" \
  "the durable finish receipt carries it"
cd "$repo" || fail "cd back from stkrepo"

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
      {id:"floor-new",severity:"warning",action:"fix",file:"r2-only.txt",class:"regression",description:"new late nit",authority_class:"internal",authority:"tests/x:1",suggested_fix:"s"},
      {id:"floor-utf8",severity:"warning",action:"fix",file:"đo-utf8.txt",class:"regression",description:"in-delta blocker on a UTF-8 path",authority_class:"internal",authority:"tests/x:1",suggested_fix:"s"}],
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
printf 'r3\n' >>"$floorrepo/f.txt"
printf 'r3\n' >"$floorrepo/đo-utf8.txt" && git -C "$floorrepo" add "đo-utf8.txt" f.txt && git -C "$floorrepo" commit -qm "fix r3"
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
assert_eq "$(jq -r '.[] | select(.id == "floor-utf8") | .action' "$floorrun/findings/review.json")" "fix" \
  "a NEW in-delta blocker on a UTF-8 path stays fix (the delta is read -z - C-quoted paths must not read as out-of-delta)"
assert_eq "$(jq -r '.verdict' "$floorrun/logs/review-agent-r3.json")" "fix" \
  "durable r3 verdict remains fix because the previous open id persists"
cd "$repo" || fail "cd back from floorrepo"

# core.quotepath=false stops quoting only bytes >= 0x80; git still C-quotes ",
# \ and control characters (git-config(1) core.quotePath), and a quoted delta
# name read as out-of-delta floored a NEW blocker on that very file. A newline
# cannot ride the newline-list AC_FINDINGS_DELTA at all, so such a round must
# floor nothing rather than guess.
qrepo="$(make_repo quoterepo)"
cd "$qrepo" || fail "cd $qrepo"
cat >"$AC_HOME/projects/quoterepo.yaml" <<'EOF'
commands:
  test: "echo test-ok"

review:
  max_rounds: 9
EOF
qstub="$TMP/quotestub"; mkdir -p "$qstub"
cat >"$qstub/ac-verify" <<'EOF'
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
jq --arg ref "$ref" '{findings: [.[] | . + {severity:"warning",action:"fix",class:"regression",description:"d",authority_class:"internal",authority:"tests/x:1",suggested_fix:"s"}],
  summary:"s",risk_level:"low",risk_rationale:"r",reviewed_ref:$ref,verdict:"fix"}' "$QUOTE_FINDINGS" >"$output"
EOF
chmod +x "$qstub/ac-verify"
qfind="$TMP/quote-findings.json"
qra() { QUOTE_FINDINGS="$qfind" AC_CREW_ID=quote-implement AC_VERIFY_BIN="$qstub/ac-verify" "$BIN/ac-ship.sh" review-agent; }
git checkout -qb crew/quote
"$BIN/ac-ship.sh" start --intent "quoted delta" --skip pr >/dev/null
qrun="$qrepo/.crew/ship/$(readlink "$qrepo/.crew/ship/current")"
qaction() { jq -r --arg id "$1" '.[] | select(.id == $id) | .action' "$qrun/findings/review.json"; }
printf 'work\n' >>file.txt && git commit -qam work
"$BIN/ac-ship.sh" step test completed --note "suite green" >/dev/null
jq -n '[{id:"q-r1",file:"file.txt"}]' >"$qfind"
qra >/dev/null
"$BIN/ac-ship.sh" step review fixing >/dev/null
printf 'x\n' >'q"uote.txt'; printf 'x\n' >'back\slash.txt'; printf 'x\n' >"tab$(printf '\t')name.txt"
git add -A && git commit -qm "fix touches C-quoted names"
jq -n --arg t "tab$(printf '\t')name.txt" '[{id:"q-r1",file:"file.txt"},
  {id:"q-dq",file:"q\"uote.txt"},{id:"q-bs",file:"back\\slash.txt"},{id:"q-tab",file:$t},
  {id:"q-out",file:"untouched.txt"}]' >"$qfind"
qra >/dev/null
assert_eq "$(qaction q-dq)" "fix" "a NEW in-delta blocker on a double-quoted name stays fix"
assert_eq "$(qaction q-bs)" "fix" "a NEW in-delta blocker on a backslashed name stays fix"
assert_eq "$(qaction q-tab)" "fix" "a NEW in-delta blocker on a TAB-carrying name stays fix"
assert_eq "$(qaction q-out)" "no-op" "the floor is still armed: a NEW out-of-delta finding floors"
"$BIN/ac-ship.sh" step review fixing >/dev/null
printf 'x\n' >'new
line.txt'
git add -A && git commit -qm "fix touches a newline name"
jq -n --arg n 'new
line.txt' '[{id:"q-r1",file:"file.txt"},{id:"q-lf",file:$n},{id:"q-out3",file:"untouched.txt"}]' >"$qfind"
qra >/dev/null
assert_eq "$(qaction q-lf)" "fix" "a NEW in-delta blocker on a newline-carrying name stays fix"
assert_eq "$(qaction q-out3)" "fix" \
  "a delta the newline-list wire cannot carry arms no floor at all - it fails toward reviewing"
cd "$repo" || fail "cd back from quoterepo"

# --- advisory-polish-loop A: a 0-fix verdict FREEZES the tree ------------------
# A captain ruling. A round returning ZERO `fix` findings makes the run
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
  '{findings:[{id:("f-" + $v),severity:"warning",action:(if $v == "fix" then "fix" else "no-op" end),file:"file.txt",class:"correctness",description:"nit",authority_class:"internal",authority:"tests/sh/ac-ship.test.sh:1",suggested_fix:"polish"}],
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
# A captain ruling. `round` used to be the steps.tsv `fixing` column + 1, and
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
  '{findings:[{id:"capb",severity:"warning",action:(if $v == "fix" then "fix" else "no-op" end),description:"nit",authority_class:"internal",authority:"tests/sh/ac-ship.test.sh:1"}],
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
# A captain ruling. One live family retried the SAME ref three and four times:
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
# A captain ruling, the slice they value most despite being the smallest.
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

# A multi-line goal is recorded VERBATIM: its later lines reach the readers,
# and a line shaped like a run.meta key never shadows the real one.
mlrepo="$(make_repo mlrepo)"
cd "$mlrepo" || fail "cd $mlrepo"
printf 'commands:\n  test: "echo test-ok"\n' >"$AC_HOME/projects/mlrepo.yaml"
"$BIN/ac-ship.sh" start --intent "$(printf 'ship the gadget\ntarget=no-such-branch\nkeep the API stable')" >/dev/null
assert_eq "$("$BIN/ac-ship.sh" base 2>&1)" "$(git -C "$mlrepo" rev-parse HEAD)" \
  "an intent line shaped like target= never becomes the review base"
printf '[]' | "$BIN/ac-ship.sh" findings lint >/dev/null
assert_contains "$("$BIN/ac-ship.sh" fix-report lint)" "keep the API stable" "the fix report carries the whole goal"
cd "$repo" || fail "cd back from mlrepo"

# BASE ATTRIBUTION (opt-in test.base_attribution: on): a failing full test
# run is re-run on the base in a throwaway checkout, so "pre-existing" is a
# measurement, never a claim; the step still fails either way.
barepo="$(make_repo barepo)"
cd "$barepo" || fail "cd $barepo"
git checkout -q -b crew/ba
printf 'x\n' >broken.txt && git add broken.txt && git commit -qm "the change under test"
printf 'commands:\n  test: "test ! -f broken.txt"\ntest:\n  base_attribution: "on"\n' >"$AC_HOME/projects/barepo.yaml"
"$BIN/ac-ship.sh" start --intent "attribution probe" >/dev/null
rc=0; out="$("$BIN/ac-ship.sh" cmd test 2>&1)" || rc=$?
assert_eq "$rc" "1" "a failing test step stays failed under attribution"
assert_contains "$out" "base attribution: the base passes" "a failure this change introduced is attributed to it"
assert_eq "$(git -C "$barepo" worktree list | wc -l | tr -d ' ')" "1" "the base checkout is removed again"
printf 'commands:\n  test: "exit 3"\ntest:\n  base_attribution: "on"\n' >"$AC_HOME/projects/barepo.yaml"
"$BIN/ac-ship.sh" start --intent "attribution probe 2" >/dev/null
out="$("$BIN/ac-ship.sh" cmd test 2>&1)" || true
assert_contains "$out" "base attribution: the base also fails (exit 3)" "a failure the base shares is attributed to the base"
printf 'commands:\n  test: "exit 3"\n' >"$AC_HOME/projects/barepo.yaml"
"$BIN/ac-ship.sh" start --intent "attribution probe 3" >/dev/null
out="$("$BIN/ac-ship.sh" cmd test 2>&1)" || true
case "$out" in *"base attribution"*) fail "attribution runs only when the project opts in" ;; esac
cd "$repo" || fail "cd back from barepo"

# --- differential: src/ship.ts against the frozen bash original ---------------
# DISPUTED: the implementation (tests/fixtures/ac-ship.sh under bash vs src/ship.ts through bin/ac-ship.sh)
# HELD-CONSTANT: ONE world path ($XW) rebuilt by the row's own setup before each pass - a home (projects/repo.yaml, config/), a repo at $XW/repo made under one git identity and one commit date so every sha matches, a bare origin at $XW/origin.git for a row that pushes; argv, env (AC_HOME=$XW/home, AC_SHIP_WATCH=off, AC_VERIFY_BIN and AC_PANE_AGENT the leg's stubs, TMPDIR=$XW/tmp, XSTUB=$XW/stub, unless a row names others); cwd ($XW/repo unless a row names another); stdin (/dev/null unless a call names a file); LC_ALL=C unless a row names en_US.UTF-8; PATH stubs on both sides - date answering one instant per format, sleep logging each call and returning at once, a logging herdr answering from files in the world, a scripted verifier replaying the world's verdict list, a logging pane agent, and git and mktemp logging every call (argv and GIT_TERMINAL_PROMPT, the template) - plus a row's own; the live bin/ beside each entry. Every call's exit, stdout and stderr compared whole once normalised (the k-th run id RUN<k>, either bin root ROOT, duration_s, a mktemp suffix XXXXXX), then the world: every path under the repo's .crew/, home/, tmp/ and stub/ with mode and bytes (a link: its target), the repo's refs, branch config, worktrees, info/exclude and FETCH_HEAD, and the origin's refs.
cd "$TMP" || fail "cd TMP"
xobin="$(make_oracle_bin ac-ship)"
cmp -s "$xobin/ac-ship.sh" "$ROOT/tests/fixtures/ac-ship.sh" || fail "the oracle bin holds the frozen original"
XW="$TMP/xw"; XSTUBS="$TMP/xstubs"; mkdir -p "$XSTUBS"
printf '[user]\n\tname = t\n\temail = t@t\n[init]\n\tdefaultBranch = main\n' >"$TMP/xgitconfig"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$TMP/xgitconfig" \
  GIT_AUTHOR_DATE='2026-01-01T00:00:00Z' GIT_COMMITTER_DATE='2026-01-01T00:00:00Z'
cat >"$XSTUBS/date" <<'STUB'
#!/bin/sh
case "$*" in
  *%Y-%m-%dT*) echo 2026-01-01T00:00:00Z ;;
  *%Y%m%d-%H%M%S*) echo 20260101-000000 ;;
  *) exec /bin/date "$@" ;;
esac
STUB
cat >"$XSTUBS/sleep" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >>"$XSTUB/sleep.log"
STUB
# herdr: every call logged; answers read from the world (panes.json, tabs.json
# for the session-wide list); HERDR_FAIL names the ops that fail.
cat >"$XSTUBS/herdr" <<'STUB'
#!/usr/bin/env bash
printf 'herdr %s\n' "$*" >>"$XSTUB/herdr.log"
[ "${1:-}" = --session ] && shift 2
fails=" ${HERDR_FAIL:-} "
if [ "$*" = "tab list" ]; then
  case "$fails" in *" tablist "*) exit 3 ;; esac
  cat "$XSTUB/tabs.json" 2>/dev/null
  exit 0
fi
case "${1:-} ${2:-}" in
  "pane list") case "$fails" in *" panelist "*) exit 1 ;; esac; cat "$XSTUB/panes.json" 2>/dev/null || echo '{"result":{"panes":[]}}' ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "workspace create") echo '{"result":{"workspace":{"workspace_id":"wW"}}}' ;;
  "tab create") case "$fails" in *" tabcreate "*) exit 1 ;; esac; echo '{"result":{"tab":{"tab_id":"tW"},"root_pane":{"pane_id":"pW1"}}}' ;;
  "tab list") echo '{"result":{"tabs":[]}}' ;;
  "pane rename") case "$fails" in *" rename "*) exit 1 ;; esac ;;
  "pane run") case "$fails" in *" run "*) exit 1 ;; esac ;;
  "pane close") case "$fails" in *" close "*) exit 1 ;; esac ;;
  "tab close") case "$fails" in *" tabclose "*) exit 1 ;; esac ;;
esac
exit 0
STUB
# The verifier facade: the n-th call answers the n-th line of the world's
# verdicts file (pass by default), its argv and any --history logged.
cat >"$XSTUBS/verify" <<'STUB'
#!/usr/bin/env bash
printf 'verify %s\n' "$*" >>"$XSTUB/verify.log"
output=""; ref=""; history=""
while [ $# -gt 0 ]; do
  case "$1" in --output) output="$2"; shift ;; --ref) ref="$2"; shift ;; --history) history="$2"; shift ;; esac
  shift
done
[ -z "$history" ] || { printf 'history: ' >>"$XSTUB/verify.log"; cat "$history" >>"$XSTUB/verify.log"; }
n="$(cat "$XSTUB/verify.n" 2>/dev/null || printf 0)"; n=$((n + 1)); printf '%s\n' "$n" >"$XSTUB/verify.n"
v="$(sed -n "${n}p" "$XSTUB/verdicts" 2>/dev/null)"
v="${v:-pass}"
if [ "$v" = slow ]; then
  : >"$XSTUB/verify.started"
  i=0; while [ ! -e "$XSTUB/verify.release" ] && [ "$i" -lt 600 ]; do /bin/sleep 0.1; i=$((i + 1)); done
  v=fix
fi
ok='{id:"n1",severity:"info",action:"no-op",description:"note",authority_class:"internal",authority:"a"}'
case "$v" in
  dead) exit 1 ;;
  deadout) printf '{"partial":' >"$output"; exit 3 ;;
  empty) : >"$output" ;;
  pass) jq -n --arg r "$ref" "{findings:[$ok],summary:\"s\",risk_level:\"low\",risk_rationale:\"r\",reviewed_ref:\$r,verdict:\"pass\"}" >"$output" ;;
  fix) jq -n --arg r "$ref" "{findings:[$ok,{id:\"f1\",severity:\"warning\",action:\"fix\",file:\"f.txt\",line:2,description:\"bug\",authority_class:\"internal\",authority:\"f.txt:1\"}],summary:\"\",risk_level:\"medium\",risk_rationale:\"r\",reviewed_ref:\$r,verdict:\"fix\"}" >"$output" ;;
  fixlate) jq -n --arg r "$ref" "{findings:[{id:\"f1\",severity:\"warning\",action:\"fix\",file:\"f.txt\",description:\"still\",authority_class:\"internal\",authority:\"f.txt:1\"},{id:\"f9\",severity:\"warning\",action:\"fix\",file:\"other.txt\",description:\"late\",authority_class:\"internal\",authority:\"other.txt:1\"},{id:\"f8\",severity:\"error\",action:\"fix\",class:\"security\",file:\"other.txt\",description:\"crit\",authority_class:\"internal\",authority:\"x\"}],risk_level:\"high\",risk_rationale:\"r\",reviewed_ref:\$r,verdict:\"fix\"}" >"$output" ;;
  fixcrit) jq -n --arg r "$ref" "{findings:[{id:\"c1\",severity:\"error\",action:\"fix\",class:\"correctness\",file:\"f.txt\",description:\"crit\",authority_class:\"internal\",authority:\"f.txt:1\"}],risk_level:\"high\",risk_rationale:\"r\",reviewed_ref:\$r,verdict:\"fix\"}" >"$output" ;;
  ask) jq -n --arg r "$ref" "{findings:[{id:\"q1\",severity:\"warning\",action:\"ask-user\",description:\"choose\"}],risk_level:\"low\",risk_rationale:\"r\",reviewed_ref:\$r,verdict:\"ask-user\"}" >"$output" ;;
  notobj) echo '[1]' >"$output" ;;
  noarr) jq -n --arg r "$ref" '{findings:{},reviewed_ref:$r,verdict:"pass",risk_level:"low",risk_rationale:"r"}' >"$output" ;;
  badref) jq -n '{findings:[],reviewed_ref:"0000000",verdict:"pass",risk_level:"low",risk_rationale:"r"}' >"$output" ;;
  badverdict) jq -n --arg r "$ref" '{findings:[],reviewed_ref:$r,verdict:"maybe",risk_level:"low",risk_rationale:"r"}' >"$output" ;;
  badrisk) jq -n --arg r "$ref" '{findings:[],reviewed_ref:$r,verdict:"pass",risk_level:"severe",risk_rationale:"r"}' >"$output" ;;
  badrat) jq -n --arg r "$ref" '{findings:[],reviewed_ref:$r,verdict:"pass",risk_level:"low",risk_rationale:7}' >"$output" ;;
  garbage) echo 'not json {' >"$output" ;;
esac
[ ! -f "$output" ] || cat "$output"
STUB
cat >"$XSTUBS/pane" <<'STUB'
#!/bin/sh
printf 'pane %s\n' "$*" >>"$XSTUB/pane.log"
exit "${PANE_RC:-0}"
STUB
# git and mktemp log every call into the world, so both sides must make the
# same git calls in the same order with the same environment for a push, and
# stage the same temp templates.
cat >"$XSTUBS/git" <<STUB
#!/bin/sh
printf 'git TP=%s %s\n' "\${GIT_TERMINAL_PROMPT-unset}" "\$*" >>"\$XSTUB/git.log"
exec "$(command -v git)" "\$@"
STUB
cat >"$XSTUBS/mktemp" <<STUB
#!/bin/sh
printf 'mktemp %s\n' "\$*" >>"\$XSTUB/mktemp.log"
exec "$(command -v mktemp)" "\$@"
STUB
chmod +x "$XSTUBS/date" "$XSTUBS/sleep" "$XSTUBS/herdr" "$XSTUBS/verify" "$XSTUBS/pane" "$XSTUBS/git" "$XSTUBS/mktemp"
XCFG_DEFAULT='commands:
  test: "echo test-ok"
  lint: "exit 3"
review:
  max_rounds: 9
'
xworld() {  # xworld [<branch>] - a fresh world: the home and its project config ($XCFG), a repo with one commit on main, and <branch> checked out with one more
  rm -rf "$XW"; mkdir -p "$XW/home/projects" "$XW/home/config" "$XW/home/state" "$XW/tmp" "$XW/stub"
  git init -q "$XW/repo"
  printf 'base\n' >"$XW/repo/f.txt"; git -C "$XW/repo" add f.txt; git -C "$XW/repo" commit -qm base
  printf '%s' "${XCFG-$XCFG_DEFAULT}" >"$XW/home/projects/repo.yaml"
  [ -z "${1:-}" ] || { git -C "$XW/repo" checkout -qb "$1"; printf 'work\n' >>"$XW/repo/f.txt"; git -C "$XW/repo" commit -qam work; }
}
xorigin() {  # xorigin - a bare origin holding main
  git init -q --bare "$XW/origin.git"
  git -C "$XW/repo" remote add origin "$XW/origin.git"
  git -C "$XW/repo" push -q origin main 2>/dev/null
}
xcommit() { printf '%s\n' "$1" >>"$XW/repo/${2:-f.txt}"; git -C "$XW/repo" add -A; git -C "$XW/repo" commit -qm "$1"; }
xput() { mkdir -p "$(dirname "$XW/$1")"; printf '%s' "$2" >"$XW/$1"; }   # xput <path under the world> <bytes>
xrd() { printf '%s/repo/.crew/ship/%s' "$XW" "$(readlink "$XW/repo/.crew/ship/current")"; }   # the current run dir
XLC=C; XENV=(); XCWD=repo; XIN=/dev/null; XWATCH=off; XPATH=""; XHOME=1; XPASS=o; XALT=(o); XCALL=0; XTTY=""
xc() {  # xc <args...> - one ship call in the world by this pass's side for the call (on a pty with XTTY=1), its transcript appended
  local side bin="$BIN" rc=0 x path="$XSTUBS:$PATH" cur
  side="${XALT[$((XCALL % ${#XALT[@]}))]}"; XCALL=$((XCALL + 1))
  [ "$side" = n ] || bin="$xobin"
  [ -z "$XPATH" ] || path="$XPATH"
  local e=("LC_ALL=$XLC" "PATH=$path" "TMPDIR=$XW/tmp" "XSTUB=$XW/stub" "AC_SHIP_WATCH=$XWATCH" "AC_VERIFY_BIN=$XSTUBS/verify" "AC_PANE_AGENT=$XSTUBS/pane")
  [ -z "$XHOME" ] || e+=("AC_HOME=$XW/home")
  for x in ${XENV[@]+"${XENV[@]}"}; do e+=("$x"); done
  local cmd=(env -u AC_HOME -u AC_FLEET_STATE -u AC_SCOPE -u AC_SOLO -u AC_FLEET_SCOPE -u AC_CREW_ID
    -u AC_FLEET_HOME_CHECKED -u AC_FLEET_PROJECT_CONFIG -u AC_HERDR_SESSION -u AC_BACKEND -u CDPATH
    -u AC_FINDINGS_ROUND -u AC_FINDINGS_DELTA -u AC_FINDINGS_PRIOR_OPEN -u AC_LOCK_STALE_GRACE
    -u GIT_TERMINAL_PROMPT -u GIT_OPTIONAL_LOCKS "${e[@]}" "$bin/ac-ship.sh" "$@")
  if [ -n "$XTTY" ]; then (cd "$XW/$XCWD" && run_on_tty "${cmd[@]}") >"$TMP/x.out" 2>"$TMP/x.err" || rc=$?
  else (cd "$XW/$XCWD" && exec "${cmd[@]}") <"$XIN" >"$TMP/x.out" 2>"$TMP/x.err" || rc=$?; fi
  { printf '== %s\nrc=%s\n-- out\n' "$*" "$rc"; cat "$TMP/x.out"; printf '%s\n' '-- err'; cat "$TMP/x.err"; } >>"$TMP/xt.$XPASS"
  for x in "$XW"/*/.crew/ship/current; do
    cur="$(readlink "$x" 2>/dev/null || true)"
    [ -z "$cur" ] || grep -qxF -- "$cur" "$TMP/xids.$XPASS" || printf '%s\n' "$cur" >>"$TMP/xids.$XPASS"
  done
  # A start line names its run id, so the override row's digest of it is
  # matched to the side's own printed line.
  grep '^started run ' "$TMP/x.out" | while IFS= read -r x; do printf '%s' "$x" | shasum -a 256 | cut -d' ' -f1; done >>"$TMP/xshas.$XPASS" || true
}
xnorm() {  # xnorm <file> <pass> - the k-th run id RUN<k>, either bin root ROOT, duration_s N, a mktemp suffix XXXXXX
  local e=() k=0 id
  while IFS= read -r id; do [ -z "$id" ] || { k=$((k + 1)); e+=(-e "s/$id/RUN$k/g"); }; done <"$TMP/xids.$2"
  k=0; while IFS= read -r id; do [ -z "$id" ] || { k=$((k + 1)); e+=(-e "s/$id/STARTSHA$k/g"); }; done <"$TMP/xshas.$2"
  LC_ALL=C sed -E ${e[@]+"${e[@]}"} -e "s#$TMP/oracle-ac-ship#ROOT#g" -e "s#$ROOT#ROOT#g" \
    -e 's/"duration_s": [0-9]+/"duration_s": N/' \
    -e 's#(\.steps\.tsv|\.review\.meta|\.review\.residual|\.receipt|\.meta\.json|/override|/\.review-agent-r[0-9]+|/findings/\.[a-z]+)\.[A-Za-z0-9]{6}#\1.XXXXXX#g' \
    -e 's#(\.XXXXXX)\.[A-Za-z0-9]{6}#\1.XXXXXX#g' -e 's#/\.attest-[A-Za-z0-9]{6}#/.attest-XXXXXX#g' "$1"
}
xsnap() {  # xsnap <pass> - the world as one listing
  local n f
  (cd "$XW" && find ./*/.crew home tmp stub -print 2>/dev/null || true) | sed 's#^\./##' >"$TMP/xnames"
  xnorm "$TMP/xnames" "$1" | paste - "$TMP/xnames" | LC_ALL=C sort | while IFS=$'\t' read -r n f; do
    if [ -L "$XW/$f" ]; then printf '== %s -> %s\n' "$n" "$(readlink "$XW/$f")"; continue; fi
    printf '== %s %s\n' "$n" "$(stat -f %Sp "$XW/$f")"
    [ -d "$XW/$f" ] || { cat "$XW/$f" 2>/dev/null || printf '<unreadable>'; printf '\n'; }
  done >"$TMP/xw.$1"
  { printf -- '-- refs\n'; git -C "$XW/repo" for-each-ref --format='%(refname) %(objectname)'
    printf -- '-- branch config\n'; git -C "$XW/repo" config --get-regexp '^branch\.' || true
    printf -- '-- worktrees\n'; git -C "$XW/repo" worktree list --porcelain
    printf -- '-- exclude\n'; cat "$XW/repo/.git/info/exclude" 2>/dev/null || true
    printf -- '-- FETCH_HEAD\n'; cat "$XW/repo/.git/FETCH_HEAD" 2>/dev/null || true
    printf -- '-- origin\n'; [ ! -d "$XW/origin.git" ] || git -C "$XW/origin.git" for-each-ref --format='%(refname) %(objectname)'
  } >>"$TMP/xw.$1"
}
xpass() {  # xpass <pass> <setup> <body> <side>... - rebuild the world, then the body's calls by the sides in turn (<setup> may carry its words)
  XPASS="$1"; : >"$TMP/xt.$1"; : >"$TMP/xids.$1"; : >"$TMP/xshas.$1"; XCALL=0; XALT=("${@:4}")
  $2; $3; xsnap "$1"
  xnorm "$TMP/xt.$1" "$1" >"$TMP/xt2.$1"; xnorm "$TMP/xw.$1" "$1" >"$TMP/xw2.$1"
}
xrow() { printf '%s' "${BASH_LINENO[${#BASH_LINENO[@]}-2]}"; }   # the leg's own line that started this comparison
xcmp() {  # xcmp <pass> <pass> - transcripts and worlds identical
  cmp -s "$TMP/xt2.$1" "$TMP/xt2.$2" || fail "ship differential calls differ ($1 vs $2) at line $(xrow): $(diff -a "$TMP/xt2.$1" "$TMP/xt2.$2" | head -n 14)"
  cmp -s "$TMP/xw2.$1" "$TMP/xw2.$2" || fail "ship differential world differs ($1 vs $2) at line $(xrow): $(diff -a "$TMP/xw2.$1" "$TMP/xw2.$2" | head -n 14)"
}
xsame() { xpass o "$1" "$2" o; xpass n "$1" "$2" n; xcmp o n; }   # xsame <setup> <body> - the oracle alone, then the port alone
xcont() {  # xcont <setup> <body> - the oracle alone, then the two sides alternating call by call, either side first
  xpass o "$1" "$2" o; xpass a "$1" "$2" o n; xpass b "$1" "$2" n o; xcmp o a; xcmp o b
}
xt() { cat "$TMP/xt2.${1:-n}"; }
xhas() { assert_contains "$(xt "${2:-n}")" "$1" "ship differential at line $(xrow)"; }   # xhas <text> [<pass>] - the normalised transcript holds <text>
xlacks() { case "$(xt "${2:-n}")" in *"$1"*) fail "ship differential at line $(xrow): '$1' found" ;; esac; }
xwhas() { assert_contains "$(cat "$TMP/xw2.${2:-n}")" "$1" "ship differential world at line $(xrow)"; }
xnone() { :; }
xpushworld() { xworld crew/p; xorigin; }
xverdicts() { printf '%s\n' "$@" >"$XW/stub/verdicts"; }   # xverdicts <verdict>... - the verifier's answers in call order
xrevworld() { xworld crew/fam1-implement; }
xin() { printf '%b' "$1" >"$XW/stub/in"; XIN="$XW/stub/in"; }   # xin <printf %b bytes> - the next calls' stdin
xcfg() { printf '%b' "$1" >"$XW/home/projects/repo.yaml"; }   # xcfg <printf %b yaml> - the installed config
xwithout() {  # xwithout <tool> - the leg's stubs and PATH with every dir holding <tool> mirrored without it
  local dirs d f key mirror out=""
  IFS=: read -r -a dirs <<<"$XSTUBS:$PATH"
  for d in "${dirs[@]}"; do
    [ -n "$d" ] || continue
    if [ -x "$d/$1" ]; then
      key="$(cd "$d" && pwd -P)"; mirror="$TMP/no$1$(printf '%s' "$key" | tr -c 'A-Za-z0-9' '_')"
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

# -- leg 1: preamble ------------------------------------------------------------
# USAGE HEADER (named): no verb, -h or an unknown verb print the spec header,
# exit 2 - the original's own, the port's src/ship.ts one.
x1() { xc; xc -h; xc bogus; }
xpass o xworld x1 o; xpass n xworld x1 n
for xp in o n; do
  [ "$(grep -c '^rc=2$' "$TMP/xt2.$xp")" = 3 ] || fail "usage exits 2 on side $xp"
  [ "$(grep -c '^-- err$' "$TMP/xt2.$xp")" = 3 ] && ! grep -q '^ERROR' "$TMP/xt2.$xp" || fail "usage writes no stderr on side $xp"
done
assert_contains "$(xt o)" $'-- out\nac-ship.sh - state machine + deterministic runner for the crew-ship' "the oracle prints its own header"
assert_contains "$(xt n)" $'-- out\nship.ts - the crew-ship pipeline\'s state machine' "the port prints src/ship.ts's header"
[ "$(sed -n '/^== -h$/,/^-- err$/p' "$TMP/xt2.n" | sed '1,3d;$d')" = "$(awk '!/^\/\//{exit} {sub(/^\/\/ ?/, ""); print}' "$ROOT/src/ship.ts")" ] \
  || fail "the port's usage is the module's whole leading comment block"
x1b(){ XCWD=tmp; xc status; XCWD=repo; }
xsame xworld x1b
xhas $'rc=1\n-- out\n-- err\nERROR: not inside a git repo'
x1c() { XENV=(AC_BACKEND=tmux); xc; xc status; XENV=(); }
xsame xworld x1c
xhas "ERROR: unsupported backend 'tmux' (valid backends: herdr, orca; tmux/wezterm were removed 2026-07-17)"
# BUN (named): without bun the shim refuses before anything, where the
# original ran every verb.
x1d() { XPATH="$(xwithout bun)"; xc status; xc start --intent nobun; XPATH=""; }
xpass o xworld x1d o; xpass n xworld x1d n
xhas $'rc=1\n-- out\n-- err\nERROR: required tool not found: bun\n' n
xhas 'started run RUN1 branch=main' o

# A jq on PATH that is a file but not executable, and no other: the original's
# `command -v` took it (and failed at its first jq), the port's Bun.which
# refuses it up front (named).
mkdir -p "$TMP/xjqnoexec"; : >"$TMP/xjqnoexec/jq"; chmod 644 "$TMP/xjqnoexec/jq"
x1e() { XPATH="$TMP/xjqnoexec:$(xwithout jq)"; xc status; XPATH=""; }
xpass o xworld x1e o; xpass n xworld x1e n
xhas $'rc=1\n-- out\n-- err\nERROR: no active crew-ship run; ac-ship.sh start first' o
xhas $'rc=1\n-- out\n-- err\nERROR: required tool not found: jq' n

# -- leg 2: start -----------------------------------------------------------------
x2a() {
  xc start --intent 'ship the widget'
  xc start --intent 'lint on' --lint
  xc start --intent 'tdd' --tdd
  xc start --intent both --lint --tdd
  xc start --intent skips --skip pr,push
  xc start --intent leading --skip ,pr
  xc start --intent spaced --skip 'pr test'
  xc start --intent 'first' --intent $'second line one\nline two' --skip doc --skip pr
  xc start --intent explicit --lint --skip lint
  xc status
}
xsame xworld x2a
xhas 'started run RUN3 branch=main base='"$(git -C "$XW/repo" rev-parse HEAD | cut -c1-12)"' (lint skip-by-default: pass --lint to run it) (test skipped: --tdd declares the implement covered it)'
xwhas $'intent=second line one\nbranch=main'
xwhas $'second line one\nline two\n'
xwhas $'intent\tpending\t0\nrebase\tpending\t0\nreview\tpending\t0\ntest\tpending\t0\ndocument\tpending\t0\nlint\tskipped\t0\npush\tpending\t0\npr\tpending\t0'
xwhas 'tdd-declared	2026-01-01T00:00:00Z	'
# W20 (named, SHELL-OWN): a value flag as the last word dies on bash's own
# `$2: unbound variable`; the port exits 1 with no line. Nothing is created.
x2b() { xc start --intent; xc start --intent x --skip; xc start --intent x --target; }
xpass o xworld x2b o; xpass n xworld x2b n
assert_eq "$(grep -c '^rc=1$' "$TMP/xt2.o"):$(grep -c '^rc=1$' "$TMP/xt2.n")" "3:3" "a valueless flag exits 1 on both sides"
assert_contains "$(xt o)" 'line 572: $2: unbound variable' "the original dies on the shell's own line"
assert_eq "$(grep -cv '^\(== \|rc=\|-- \)' "$TMP/xt2.n")" "0" "the port prints nothing for a valueless flag"
cmp -s "$TMP/xw2.o" "$TMP/xw2.n" || fail "a valueless flag creates nothing on either side"
x2c() {
  xc start --bogus; xc start --intent x --skip bogus; xc start --intent x --skip intent; xc start --intent x --skip review
  xc start --intent x --skip pr,intent; xc start --intent x --skip ci; xc start --intent ''; xc start --skip pr
}
xsame xworld x2c
xhas 'ERROR: unknown flag: --bogus'
xhas 'ERROR: --skip intent is refused: intent can never be skipped (the intent-evidence pass is never skipped; crew-ship review is always required, AGENTS.md section 5)'
xhas 'ERROR: --intent is required (pass the captain'"'"'s goal verbatim)'
# The skip list is word-split and globbed against the caller's cwd.
x2d() {
  : >"$XW/repo/pr"; : >"$XW/repo/push"
  xc start --intent glob --skip 'pu*'
  xc start --intent glob --skip '*'
  xc start --intent glob --skip 'q*'
  xc start --intent glob --skip 'p[r]'
  XCWD=tmp; xc start --intent elsewhere --skip 'p*'; XCWD=repo
}
xsame xworld x2d
xhas $'== start --intent glob --skip pu*\nrc=0'
xhas 'ERROR: unknown --skip step: f.txt'
xhas 'ERROR: unknown --skip step: q*'
xhas 'ERROR: not inside a git repo'
x2e() {
  git -C "$XW/repo" branch rel
  xc start --target nope
  xc start --intent t --target main
  xc start --intent t --target rel
  xc start --intent t --target ''
  xc status
}
x2e_world() { xworld crew/t; xorigin; }
xsame x2e_world x2e
xhas 'ERROR: start: --target branch not found (neither origin/nope nor nope): nope'
xhas ' target=origin/main'
xhas ' target=rel'
x2f() {
  chmod 600 "$XW/home/projects/repo.yaml"; xc start --intent homed; chmod 644 "$XW/home/projects/repo.yaml"
  XHOME=""; XENV=("AC_FLEET_HOME_CHECKED=1" "AC_FLEET_PROJECT_CONFIG=$XW/home/projects/repo.yaml"); xc start --intent threaded
  XENV=("AC_FLEET_HOME_CHECKED=1"); xc start --intent checked-none
  XENV=(); xc start --intent neither
  XENV=("AC_FLEET_HOME_CHECKED=1" "AC_FLEET_PROJECT_CONFIG=$XW/home/gone.yaml"); xc start --intent gone
  XENV=("AC_FLEET_HOME_CHECKED=1" "AC_FLEET_PROJECT_CONFIG=$XW/home/projects"); xc start --intent dir
  chmod 000 "$XW/home/projects/repo.yaml"
  XENV=("AC_FLEET_HOME_CHECKED=1" "AC_FLEET_PROJECT_CONFIG=$XW/home/projects/repo.yaml"); xc start --intent mode000
  chmod 644 "$XW/home/projects/repo.yaml"
  XENV=("AC_FLEET_HOME_CHECKED=1" "AC_FLEET_PROJECT_CONFIG="); xc start --intent empty-path
  XENV=(); XHOME=1
  xc config review.max_rounds
}
xsame xworld x2f
xwhas 'config_source=none'
xwhas $'== repo/.crew/ship/RUN1/config.yaml -rw-------\n'
xhas "ERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one
ERROR: cannot resolve the project's pipeline config: AC_HOME is unset"
xhas "ERROR: AC_FLEET_PROJECT_CONFIG names a missing file: $XW/home/gone.yaml"
xhas "ERROR: the project's pipeline config is unreadable: $XW/home/projects/repo.yaml"
# W3 (at parity): a RETIRED legacy config beside the canonical one prints its
# refusal and the run freezes an EMPTY config.
x2g() {
  mkdir -p "$XW/home/config/projects"; printf 'commands:\n  test: "echo legacy"\n' >"$XW/home/config/projects/repo.yaml"
  xc start --intent legacy; xc config review.max_rounds; xc cmd test; xc attest-test
}
xsame xworld x2g
xhas 'ERROR: project config for '"'repo'"' found at the RETIRED legacy path'
xhas $'== cmd test\nrc=4\n-- out\n-- err\n(no config file)'
# A merge-base that fails creates nothing; an unrelated target is one.
x2h() {
  git -C "$XW/repo" checkout -q --orphan lone; git -C "$XW/repo" commit -qm lone
  git -C "$XW/repo" checkout -q main
  xc start --intent unrelated --target lone
  git -C "$XW/repo" checkout -q lone
  xc start --intent 'lone default'
}
xsame xworld x2h
xhas "ERROR: fresh_base: merge-base against 'lone' failed - refusing to fall back to HEAD"
xhas "ERROR: fresh_base: merge-base against 'main' failed - refusing to fall back to HEAD"
# ensure_crew_excluded degrades to a WARN: info/ a file, a common dir git
# cannot name (no /info at the filesystem root either way), an exclude line
# already there.
mkdir -p "$TMP/xgitcd"
cat >"$TMP/xgitcd/git" <<STUB
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = --git-common-dir ] && exit 1; done
exec "$(command -v git)" "\$@"
STUB
chmod +x "$TMP/xgitcd/git"
x2i() {
  rm -rf "$XW/repo/.git/info"; : >"$XW/repo/.git/info"
  xc start --intent 'info a file'
  rm -f "$XW/repo/.git/info"
  XPATH="$TMP/xgitcd:$XSTUBS:$PATH"; xc start --intent 'no common dir'; XPATH=""
  mkdir -p "$XW/repo/.git/info"; printf 'x\n.crew/\n' >"$XW/repo/.git/info/exclude"
  xc start --intent 'already excluded'
}
xsame xworld x2i
xhas 'WARN: could not add .crew/ to info/exclude - it stays visible in git status'
[ ! -e /info/exclude ] || fail "no start addressed /info at the filesystem root"
# HOME RESOLUTION (named): an AC_HOME cd cannot enter - the original printed
# cd's own line, the port names the variable; both freeze no config and go on.
x2j() { XHOME=""; XENV=("AC_HOME=$XW/nohome"); xc start --intent nohome; xc config commands.test; XENV=(); XHOME=1; }
xpass o xworld x2j o; xpass n xworld x2j n
assert_contains "$(xt o)" "cd: $XW/nohome: No such file or directory" "the original prints cd's own line"
assert_contains "$(xt n)" "ERROR: AC_HOME is not a readable directory: $XW/nohome" "the port names the variable"
assert_eq "$(grep -c '^started run RUN1 ' "$TMP/xt2.o"):$(grep -c '^started run RUN1 ' "$TMP/xt2.n")" "1:1" "both start with no config"
cmp -s "$TMP/xw2.o" "$TMP/xw2.n" || fail "an unenterable home leaves identical worlds: $(diff "$TMP/xw2.o" "$TMP/xw2.n" | head)"
xwhas 'git TP=unset rev-parse --show-toplevel'

# -- leg 3: step / skip-remaining ----------------------------------------------
x3a() {
  xc step intent running; xc start --intent steps
  xc step intent running; xc step intent completed; xc step bogus running; xc step review bogus
  xc step; xc step intent; xc step lint fixing; xc step lint fixing; xc step 'intent rebase' running
  xc step test completed --note 'suite green'; xc step pr running extra --note x; xc step intent failed --note
  xc step document awaiting_approval --note ''; xc status
}
xsame xworld x3a
xhas $'== step intent running\nrc=1\n-- out\n-- err\nERROR: no active crew-ship run; ac-ship.sh start first'
xhas 'lint -> fixing (auto-fix round 2)'
xhas 'ERROR: usage: ac-ship.sh step <name> <status> [--note <text>]'
xhas $'intent rebase -> running\n'
xwhas ' step=test status=completed note=suite green'
xwhas "mktemp $XW/repo/.crew/ship/RUN1/.steps.tsv.XXXXXX"
# review completed: a current agent receipt passes; a manual reviewer record
# is stamped with HEAD and retires a stale agent receipt; else it refuses.
x3b() {
  xc start --intent review
  xc step review completed
  xcommit two
  printf 'reviewer=ac-verify\nreviewed_ref=%s\n' "$(git -C "$XW/repo" rev-parse HEAD~1)" >"$(xrd)/review.agent"
  xc step review completed
  printf 'reviewer=ac-verify\nround=1\nreviewed_ref=%s\n' "$(git -C "$XW/repo" rev-parse HEAD)" >>"$(xrd)/review.agent"
  xc step review completed
  xcommit three
  XIN="$XW/stub/meta.json"; printf '{"reviewer":"subagent","risk_level":"low"}' >"$XIN"; xc meta review; XIN=/dev/null
  xc step review completed
  xc step review completed
  xc push
}
xsame 'xworld crew/r' x3b
xhas 'ERROR: review has no independent-reviewer evidence: run ac-ship.sh review-agent, or record meta review with a "reviewer" field after a clean-context subagent reviewed'
xhas 'ERROR: review receipt is stale: reviewed '"$(git -C "$XW/repo" rev-parse HEAD~2)"', current HEAD '
xwhas 'review.agent.superseded'
xwhas '"reviewed_ref": "'"$(git -C "$XW/repo" rev-parse HEAD)"'"'
x3b2() {
  xc start --intent 'manual no reviewer'
  XIN="$XW/stub/meta.json"; printf '{"risk_level":"low"}' >"$XIN"; xc meta review; XIN=/dev/null
  xc step review completed
  printf 'not json' >"$(xrd)/findings/review.meta.json"
  xc step review completed
}
xsame 'xworld crew/r' x3b2
xhas 'parse error'
# The ledger lock: a live holder times out after 30 PATH sleeps, a dead one is
# reclaimed; a missing ledger refuses and releases the lock.
x3c() {
  xc start --intent locks
  mkdir "$(xrd)/.steps.lock"; printf '%s\n' "$$" >"$(xrd)/.steps.lock/pid"
  xc step intent running; xc skip-remaining
  printf '999999\n' >"$(xrd)/.steps.lock/pid"
  xc step intent running
  rm -f "$(xrd)/steps.tsv"
  xc step intent completed; xc skip-remaining
  printf 'intent\tpending\t0\npush\trunning\t2\n' >"$(xrd)/steps.tsv"
  xc skip-remaining; xc status
}
xsame xworld x3c
xhas 'ERROR: steps ledger lock timeout'
xhas "ERROR: step: could not update the steps ledger ($XW/repo/.crew/ship/RUN1/steps.tsv) - failing closed"
xhas "ERROR: skip-remaining: could not update the steps ledger ($XW/repo/.crew/ship/RUN1/steps.tsv) - failing closed"
[ "$(grep -c '^1$' "$XW/stub/sleep.log")" = 60 ] || fail "the lock waits 30 PATH sleeps per refused writer"
# step test completed clears only the tdd-declared override row.
x3d() {
  xc start --intent tdd --tdd
  xc step test completed
  xc start --intent tdd2 --tdd
  printf 'review-residual\tT\tS\tgrounds\n' >>"$(xrd)/override"
  xc step test completed; xc status
}
xsame xworld x3d
xhas $'override: review-residual at=T receipt_sha256=S reason=grounds\nsteps:'
# W17 (at parity): a dangling `current` passes require_run.
x3e() {
  xc start --intent dangling
  rm -rf "$(xrd)"
  xc status; xc step intent running; xc findings review --show; xc base
}
xsame xworld x3e
xhas $'run: RUN1\n-- err\nsed: '
xhas 'ERROR: steps ledger lock timeout'
# ... and finish dies on its run.meta append: bash's own redirection line
# (SHELL-OWN, named), both exit 1.
x3f() { xc start --intent dangling; rm -rf "$(xrd)"; xc finish cancelled; }
xpass o xworld x3f o; xpass n xworld x3f n
assert_contains "$(xt o)" $'== finish cancelled\nrc=1\n-- out\n-- err\n' "the original dies on the run.meta append"
assert_contains "$(xt o)" 'run.meta: No such file or directory' "the original's own redirection line"
assert_contains "$(xt n)" $'== finish cancelled\nrc=1\n-- out\n-- err' "the port dies at the same point"
assert_eq "$(sed -n '/^== finish cancelled$/,$p' "$TMP/xt2.n" | wc -l | tr -d ' ')" "4" "the port prints no line of the shell's"
cmp -s "$TMP/xw2.o" "$TMP/xw2.n" || fail "a dangling finish leaves identical worlds"

# -- leg 4: findings / meta --------------------------------------------------------
mkdir -p "$TMP/xjqdot"
cat >"$TMP/xjqdot/jq" <<STUB
#!/bin/sh
[ "\$1" = . ] && exit 1
exec "$(command -v jq)" "\$@"
STUB
chmod +x "$TMP/xjqdot/jq"
x4a() {
  xc findings review; xc start --intent findings
  XTTY=1; xc findings review; xc meta review; XTTY=""
  xin '{'; xc findings review
  xin '{}'; xc findings review
  xin ''; xc findings review
  xin '[1,2,3]'; xc findings review
  xin '[{"id":"r1","severity":"error","title":"bug"},{"id":"r2","action":"","detail":"d"},{"id":"r3","action":"fix","severity":"info","authority_class":"internal","authority":"a"}]\0\n\n'
  xc findings review; xc findings review --show; xc findings review extra; xc findings bogus; xc findings; xc findings test --show
  xin '[{"id":"F1","severity":"error","action":"fix","authority_class":"internal","authority":"f.txt:1","description":"real"},{"severity":"error","action":"fix","authority_class":"internal","authority":"a","description":"x"},{"severity":"error","action":"fix","authority_class":"internal","authority":"a","description":"y"}]'
  xc findings review
  xin '[]'; xc findings review
  xin '[{"id":"F1","severity":"error","action":"fix","authority_class":"internal","authority":"f.txt:1","description":"real"},{"severity":"error","action":"fix","authority_class":"internal","authority":"a","description":"x"}]'
  xc findings review
  xin '[{"id":"q","action":"ask-user","description":"pick","decision":"a\\tb\\nc","options":["x"],"axis":"bogus","decider":"  "},{"id":"e","action":"fix","severity":"error","authority_class":"weird","authority":"  "}]'
  xc findings lint
  XENV=(AC_FINDINGS_ROUND=2 'AC_FINDINGS_PRIOR_OPEN=[]' AC_FINDINGS_DELTA=f.txt)
  xin '[{"id":"o","action":"fix","severity":"warning","file":"other.txt","authority_class":"internal","authority":"a"},{"id":"i","action":"fix","severity":"warning","file":"f.txt","authority_class":"internal","authority":"a"}]'
  xc findings document; XENV=()
  xin '[1]'; xc meta review
  xin '{"risk_level":"low"}\0\n'; xc meta review
  xin '{"risk_level":"high","risk_rationale":"r"}'; XPATH="$TMP/xjqdot:$XSTUBS:$PATH"; xc meta review; XPATH=""
  xc meta bogus; XIN=/dev/null; xc status
}
xsame xworld x4a
xhas 'ERROR: findings review reads a JSON array on stdin - refusing a tty (pipe JSON in, or use --show to view)'
xhas 'ERROR: meta review reads a JSON object on stdin - refusing a tty'
xhas 'ERROR: findings must be a JSON array'
xhas 'ERROR: findings review: normalize failed'
xhas 'ERROR: findings review refused (fail-closed): re-post drops fix finding(s) [F1, ?, ?] with no resolution'
xhas $'== findings review\nrc=0\n-- out\nfix=2\n'
xhas 'ERROR: meta review: write failed'
xwhas '"round_floored": true'
xwhas '"decision": "a b c"'
# T1: the temps the findings path stages are findings/.<step>.XXXXXX and the
# normalizer's .<step>.XXXXXX.XXXXXX - none survives a refusal, on either side.
for xp in o n; do
  ! grep -qE '^== repo/\.crew/ship/RUN[0-9]+/findings/(\.review\.|review\.meta\.json\.)' "$TMP/xw2.$xp" \
    || fail "a findings or meta refusal leaked its temp on side $xp"
done
grep -q '^mktemp .*/findings/\.review\.XXXXXX\.XXXXXX$' "$TMP/xw2.n" || fail "the leak check watched the normalizer's own temp name"

# TRUSTED RE-POST (named): the original's drop guard read _ac_findings_trusted
# from the caller's environment too; the port trusts only review-agent's call.
x4b() {
  xc start --intent trusted
  xin '[{"id":"F1","severity":"error","action":"fix","authority_class":"internal","authority":"f.txt:1","description":"real"}]'; xc findings review
  xin '[]'; XENV=(_ac_findings_trusted=1); xc findings review; XENV=(); XIN=/dev/null
}
xpass o xworld x4b o; xpass n xworld x4b n
xlacks 're-post drops fix finding' o
xhas 'ERROR: findings review refused (fail-closed): re-post drops fix finding(s) [F1] with no resolution'

# -- leg 5: config / base / evidence-dir ---------------------------------------------
x5a() {
  xc config review.max_rounds
  XHOME=""; xc config review.max_rounds; XHOME=1
  XHOME=""; XENV=("AC_FLEET_HOME_CHECKED=1" "AC_FLEET_PROJECT_CONFIG=$XW/home/projects/repo.yaml"); xc config commands.test; XENV=(); XHOME=1
  xc start --intent cfg
  printf 'commands:\n  test: "echo changed"\n' >"$XW/home/projects/repo.yaml"
  xc config commands.test; xc config commands.nope; xc config commands; xc config review.max_rounds
  XHOME=""; XENV=("AC_FLEET_HOME_CHECKED=1"); xc start --intent empty-freeze; XENV=(); XHOME=1
  xc config commands.test; xc cmd test
}
xsame xworld x5a
xlacks 'echo changed'
xhas $'== config commands.nope\nrc=0\n-- out\n-- err'
xhas $'== config review.max_rounds\nrc=0\n-- out\n9'
xhas $'== cmd test\nrc=4\n-- out\n-- err\n(no config file)'
# W20 (named, SHELL-OWN): `config` with no key, a config present - the
# original's `1: dotted key required` line, the port silent, both exit 1.
x5b() { xc config; xc start --intent k; xc config ''; rm -f "$XW/home/projects/repo.yaml"; : >"$(xrd)/config.yaml"; xc config; }
xpass o xworld x5b o; xpass n xworld x5b n
assert_contains "$(xt o)" '1: dotted key required' "the original dies on the shell's own line"
case "$(xt n)" in *'dotted key required'*) fail "the port prints no line of the shell's" ;; esac
assert_eq "$(grep -c '^rc=1$' "$TMP/xt2.o"):$(grep -c '^rc=1$' "$TMP/xt2.n")" "3:3" "config with no key exits 1 on both sides"
cmp -s "$TMP/xw2.o" "$TMP/xw2.n" || fail "config with no key leaves identical worlds"
# W10 (at parity): an invalid byte in a value at or before the key aborts the
# reader under a UTF-8 locale (exit 2), not under C.
xbadbyte() { xworld; printf 'doc: "caf\351"\ncommands:\n  test: "echo t"\n# caf\351 comment\n' >"$XW/home/projects/repo.yaml"; }
x5c() { xc config commands.test; xc start --intent bytes; xc config commands.test; xc cmd test; xc config doc; }
xsame xbadbyte x5c
xhas $'== config commands.test\nrc=0\n-- out\necho t'
XLC=en_US.UTF-8
xsame xbadbyte x5c
xhas 'towc: multibyte conversion failure'
xhas $'== cmd test\nrc=2'
XLC=C
x5d() {
  xc base
  xc start --intent b
  xc base
  git -C "$XW/repo" branch rel HEAD~1
  xc start --intent b --target rel; xc base
  printf 'x\n' >"$XW/repo/g.txt"; git -C "$XW/repo" add g.txt; git -C "$XW/repo" commit -qm g
  xc base
  mv "$(xrd)/run.meta" "$(xrd)/run.meta.gone"; xc base; mv "$(xrd)/run.meta.gone" "$(xrd)/run.meta"
  git -C "$XW/repo" checkout -q --orphan lone; git -C "$XW/repo" commit -qm lone; xc base
}
xsame 'xworld crew/b' x5d
xhas $'== base\nrc=1\n-- out\n-- err\n=='
xhas "ERROR: fresh_base: merge-base against 'rel' failed - refusing to fall back to HEAD"
x5e() {
  xc evidence-dir
  xc start --intent ev
  xc evidence-dir
  printf 'test:\n  evidence:\n    store_in_repo: true\n' >"$XW/home/projects/repo.yaml"; xc start --intent ev; xc evidence-dir
  printf 'test:\n  evidence:\n    store_in_repo: true\n    dir: /abs\n' >"$XW/home/projects/repo.yaml"; xc start --intent ev; xc evidence-dir
  printf 'test:\n  evidence:\n    store_in_repo: true\n    dir: a/../b\n' >"$XW/home/projects/repo.yaml"; xc start --intent ev; xc evidence-dir
  printf 'test:\n  evidence:\n    store_in_repo: true\n    dir: ev\n' >"$XW/home/projects/repo.yaml"; printf 'ev\n' >"$XW/repo/.gitignore"; xc start --intent ev; xc evidence-dir
  rm -f "$XW/repo/.gitignore"; xc start --intent ev; xc evidence-dir
  git -C "$XW/repo" checkout -q --detach HEAD; xc start --intent ev; xc evidence-dir
  XENV=("TMPDIR=$XW/tmp/"); printf 'x: y\n' >"$XW/home/projects/repo.yaml"; xc start --intent ev; xc evidence-dir; XENV=()
}
xsame 'xworld crew/slash/ev' x5e
xhas "$XW/tmp/agent-crew-evidence/RUN1"
xhas 'WARN: evidence dir unsafe (/abs); using temp'
xhas 'WARN: evidence dir unsafe (a/../b); using temp'
xhas 'WARN: evidence dir is gitignored (ev); using temp'
xhas "$XW/repo/ev/crew-slash-ev"
xhas "$XW/repo/.agent-crew/evidence/crew-slash-ev"
xhas "$XW/repo/ev/detached"
xhas "$XW/tmp//agent-crew-evidence/RUN"

# -- leg 6: cmd / attestation / receipt -----------------------------------------------
x6a() {
  xc cmd test; xc start --intent cmds
  xc cmd test; xc cmd lint; xc cmd format; xc cmd bogus; xc cmd
  xcfg 'commands:\n  test: "echo out; echo err >&2; exit 5"\n'; xc start --intent red; xc cmd test
  xcfg 'commands:\n  test: "printf \\"no newline\\""\n'; xc start --intent nl; xc cmd test
  xc status
}
xsame xworld x6a
xhas $'== cmd lint\nrc=3'
xhas $'== cmd format\nrc=4\n-- out\n-- err\n(no commands.format configured)'
xhas $'out\nerr\n-- err\n$ echo out; echo err >&2; exit 5'
xwhas $'qualification=not-qualifies\nreason=non-zero'
xwhas $'qualification=qualifies\nreason=executed'
# A suite a signal ends: 143 and a non-zero receipt on both sides; the shell's
# own `Terminated` notice in the log is SHELL-OWN (named) - it names the port's
# helper shell - so the log and its digest are compared with that line masked.
x6c() { xcfg 'commands:\n  test: "echo before; kill -TERM $$"\n'; xc start --intent term; xc cmd test; }
xpass o xworld x6c o; xpass n xworld x6c n
for xp in o n; do
  sed -E -e 's/^.*Terminated: 15.*$/NOTICE/' -e 's/^output_sha256=[0-9a-f]{64}$/output_sha256=SHA/' "$TMP/xt2.$xp" >"$TMP/xt3.$xp"
  sed -E -e 's/^.*Terminated: 15.*$/NOTICE/' -e 's/^output_sha256=[0-9a-f]{64}$/output_sha256=SHA/' "$TMP/xw2.$xp" >"$TMP/xw3.$xp"
done
cmp -s "$TMP/xt3.o" "$TMP/xt3.n" || fail "a signalled suite: calls differ: $(diff "$TMP/xt3.o" "$TMP/xt3.n" | head)"
cmp -s "$TMP/xw3.o" "$TMP/xw3.n" || fail "a signalled suite: worlds differ: $(diff "$TMP/xw3.o" "$TMP/xw3.n" | head)"
assert_contains "$(cat "$TMP/xt3.n")" $'== cmd test\nrc=143\n-- out\nbefore\nNOTICE' "the signalled suite exits 143 and leaves the notice in the log"
xwhas 'cmd=test exit=143'
x6d() {
  printf '%s\n' 'commands:' '  test: echo full' "  test-changed: printf '[%s]\\n' {files}" >"$XW/home/projects/repo.yaml"
  xc start --intent scoped; xc cmd test
  printf 'q\n' >"$XW/repo/it's.txt"; printf 's\n' >"$XW/repo/a b.txt"; printf 'n\n' >"$XW/repo/"$'l\nf.txt'; printf 't\n' >"$XW/repo/"$'tr\n'
  printf 'd\n' >"$XW/repo/del.txt"; git -C "$XW/repo" add -A; git -C "$XW/repo" commit -qm files
  git -C "$XW/repo" rm -q del.txt; git -C "$XW/repo" commit -qm del
  xc cmd test
  xcfg 'commands:\n  test: "echo full"\n  test-changed: "echo no placeholder"\n'; xc start --intent noph; xc cmd test
  xc status
}
xsame 'xworld crew/s' x6d
xhas '(scoped test: 5 changed files)'
xhas "[it's.txt]"
xhas 'ERROR: commands.test-changed must carry a {files} placeholder'
xwhas $'qualification=not-qualifies\nreason=scoped'
# W13 (at parity): scoped with a merge-base that fails - fresh_base's refusal,
# then git's own `ambiguous argument` and its 128; the receipt stays incomplete.
x6e() {
  xcfg 'commands:\n  test: "echo full"\n  test-changed: "echo {files}"\n'
  xc start --intent w13
  git -C "$XW/repo" checkout -q --orphan lone; git -C "$XW/repo" commit -qm lone; xc cmd test
}
xsame 'xworld crew/w' x6e
xhas $'rc=128'
xhas "ERROR: fresh_base: merge-base against 'main' failed - refusing to fall back to HEAD"
xwhas $'reason=incomplete'
# The attestation: accepted, ignored, an unknown mode, forged, tampered, stale,
# and one written before started_at/completed_at existed.
x6f() {
  xcfg 'commands:\n  test: "echo green"\n'
  xc attest-test; xc start --intent att; xc cmd test; xc status; xc attest-check
  xcfg 'commands:\n  test: "echo green"\ntest:\n  attestation: ignore\n'; xc start --intent ign; xc cmd test
  xcfg 'commands:\n  test: "echo green"\ntest:\n  attestation: maybe\n'; xc start --intent unk; xc cmd test
  xcfg 'commands:\n  test: "echo green"\n'
  printf 'tampered\n' >>"$XW/repo/.crew/ship/attest-test.log"; xc start --intent tamper; xc cmd test; xc attest-check
  rm -f "$XW/repo/.crew/ship/attest-test.log"; xc attest-check
  jq '.tree = "0000000000000000"' "$XW/repo/.crew/ship/attest-test.json" >"$XW/stub/a.json"; cp "$XW/stub/a.json" "$XW/repo/.crew/ship/attest-test.json"
  xc start --intent forged; xc cmd test; xc attest-check
  xc attest-test
  jq 'del(.started_at) | del(.completed_at)' "$XW/repo/.crew/ship/attest-test.json" >"$XW/stub/a.json"; cp "$XW/stub/a.json" "$XW/repo/.crew/ship/attest-test.json"
  xc start --intent legacy; xc cmd test
  xcommit moved; xc attest-check; xc start --intent stale; xc cmd test
  git -C "$XW/repo" checkout -q -b other; xc attest-check
  xcfg 'commands:\n  test: "echo other"\n'; git -C "$XW/repo" checkout -q crew/a; git -C "$XW/repo" reset -q --hard HEAD~1; xc attest-check
  printf '{' >"$XW/repo/.crew/ship/attest-test.json"; xc attest-check
  rm -f "$XW/repo/.crew/ship/attest-test.json"; xc attest-check
  xc attest-test; XHOME=""; xc attest-check; xc attest-test; XHOME=1
}
xsame 'xworld crew/a' x6f
xhas 'test: TDD attestation accepted @'
xwhas $'qualification=qualifies\nreason=execution-attestation'
xhas 'test attestation present but test.attestation=ignore - running the suite'
xhas 'test.attestation=maybe is not accept|ignore - failing closed, running the suite'
xhas 'attestation not accepted: attestation log missing or does not hash to output_sha256 - running the suite'
xhas 'attestation not accepted: tree mismatch (attested 000000000000, HEAD tree '
xwhas $'qualification=not-qualifies\nreason=invalid'
xhas 'stale: commit moved (attested '
xhas 'stale: branch moved (attested crew/a, on other)'
xhas 'stale: commands.test changed since attestation'
xhas 'stale: unreadable or incomplete attestation file'
xhas $'== attest-check\nrc=2\n-- out\nno attestation'
xhas $'ERROR: AC_HOME is not set'
xhas $'== attest-test\nrc=4\n-- out\n-- err\nERROR: AC_HOME is not set - set AC_HOME=<fleet home> (the directory holding state/ data/ records/ config/ projects/); the distro checkout is not one\n(no config file)'
# attest-test's refusals: no command, a dirty tree before and after the
# suite, a red suite, an attest-test.json directory, a status git cannot read
# before and after the suite (the counting git, two status calls exactly).
mkdir -p "$TMP/xgitst"
cat >"$TMP/xgitst/git" <<STUB
#!/bin/sh
for a in "\$@"; do
  if [ "\$a" = status ]; then
    n=\$(cat "\$XSTUB/status.n" 2>/dev/null || printf 0); n=\$((n + 1)); printf '%s\n' "\$n" >"\$XSTUB/status.n"
    [ "\$n" -ge "\${FAIL_STATUS_FROM:-999}" ] && exit 128
  fi
done
exec "$XSTUBS/git" "\$@"
STUB
chmod +x "$TMP/xgitst/git"
x6h() {
  xcfg 'x: y\n'; xc attest-test
  xcfg 'commands:\n  test: "echo mutate >>f.txt"\n'; xc attest-test
  git -C "$XW/repo" checkout -q -- f.txt
  xcfg 'commands:\n  test: "echo run >>../stub/ran; exit 7"\n'; xc attest-test
  xcfg 'commands:\n  test: "echo run >>../stub/ran"\n'
  printf 'dirty\n' >>"$XW/repo/f.txt"; xc attest-test; git -C "$XW/repo" checkout -q -- f.txt
  mkdir -p "$XW/repo/.crew/ship/attest-test.json"; xc attest-test; rmdir "$XW/repo/.crew/ship/attest-test.json"
  XPATH="$TMP/xgitst:$XSTUBS:$PATH"
  XENV=(FAIL_STATUS_FROM=1); rm -f "$XW/stub/status.n"; xc attest-test
  XENV=(FAIL_STATUS_FROM=2); rm -f "$XW/stub/status.n"; xc attest-test
  XENV=(); rm -f "$XW/stub/status.n"; xc attest-test; XPATH=""
}
xsame 'xworld crew/h' x6h
xhas '(no commands.test configured - nothing to attest)'
xhas 'ERROR: attest-test: the test run left the worktree dirty - refusing to attest (does commands.test mutate tracked files?)'
xhas $'rc=7\n-- out\n-- err\n$ echo run >>../stub/ran; exit 7\nattest-test: test command failed (exit 7) - no attestation written'
xhas 'ERROR: attest-test: worktree has uncommitted changes - an attestation must describe the COMMITTED state; commit first'
xhas "ERROR: attest-test: $XW/repo/.crew/ship/attest-test.json is a directory - remove it first"
xhas 'ERROR: attest-test: cannot read the worktree state (failing closed)'
[ "$(cat "$XW/stub/status.n")" = 2 ] || fail "attest-test reads git status exactly twice"
# Base attribution, opt-in: a red full suite re-run on the base.
x6g() {
  xcfg 'commands:\n  test: "test ! -f broken.txt"\ntest:\n  base_attribution: "on"\n'
  printf 'x\n' >"$XW/repo/broken.txt"; git -C "$XW/repo" add broken.txt; git -C "$XW/repo" commit -qm broken
  xc start --intent ba; xc cmd test
  xcfg 'commands:\n  test: "exit 3"\ntest:\n  base_attribution: "on"\n'; xc start --intent ba2; xc cmd test
  mkdir -p "$(xrd)/base-tree/x"; xc cmd test
  xcfg 'commands:\n  test: "exit 3"\n'; xc start --intent ba3; xc cmd test
}
xsame 'xworld crew/ba' x6g
xhas 'base attribution: the base passes @'
xhas 'base attribution: the base also fails (exit 3) @'
xhas 'base attribution: could not check out the base '

# -- leg 7: push --------------------------------------------------------------------
xother() {  # xother <file> <line> - a stranger's commit pushed onto origin's crew/p
  [ -d "$XW/other" ] || git clone -q "$XW/origin.git" "$XW/other" 2>/dev/null
  git -C "$XW/other" fetch -q origin 2>/dev/null; git -C "$XW/other" checkout -q -B crew/p origin/crew/p
  printf '%s\n' "$2" >>"$XW/other/$1"; git -C "$XW/other" add -A; git -C "$XW/other" commit -qm "$2"; git -C "$XW/other" push -q origin crew/p 2>/dev/null
}
x7a() {
  xc push; xc start --intent push
  xc push; xc push; xcommit more; xc push
  xother g.txt stranger; xcommit local h.txt; xc push
  git -C "$XW/repo" fetch -q origin 2>/dev/null; git -C "$XW/repo" rebase -q origin/crew/p; xc push
  xc status
}
xsame xpushworld x7a
xhas "branch 'crew/p' set up to track 'origin/crew/p'."
xhas 'pushed new branch crew/p'
xhas 'up-to-date: origin/crew/p == HEAD'
xhas 'pushed crew/p with lease '
xhas $'push: origin/crew/p has commits not incorporated by this branch:\n'
xhas 'ERROR: push: refusing to force-push over unincorporated remote commits'
xwhas "git TP=0 -C $XW/repo ls-remote origin refs/heads/crew/p"
x7b() {
  xc start --intent refusals
  git -C "$XW/repo" checkout -q --detach; xc push; git -C "$XW/repo" checkout -q main; xc push
  git -C "$XW/repo" checkout -q -b rel; git -C "$XW/repo" push -q origin rel 2>/dev/null; git -C "$XW/repo" checkout -q crew/p
  xc start --intent target --target rel; git -C "$XW/repo" checkout -q rel; xc push; git -C "$XW/repo" checkout -q crew/p
  git -C "$XW/repo" remote remove origin; xc start --intent noorigin; xc push
}
xsame xpushworld x7b
xhas 'ERROR: push: refusing from a detached HEAD'
xhas 'ERROR: push: refusing to push the default branch'
xhas 'ERROR: push: refusing to push the delivery target branch (rel)'
xhas 'ERROR: push: no origin remote'
# The published-head excuse: a branch rebased through a conflict pushes; a
# stranger moving the ref off the published head is still refused.
x7d() {
  xc start --intent chain; xc push
  git -C "$XW/repo" checkout -q main; printf 'MAIN\n' >"$XW/repo/f.txt"; git -C "$XW/repo" commit -qam main-advance; git -C "$XW/repo" push -q origin main 2>/dev/null
  git -C "$XW/repo" checkout -q crew/p
  git -C "$XW/repo" rebase -q main >/dev/null 2>&1 || { printf 'RESOLVED\n' >"$XW/repo/f.txt"; git -C "$XW/repo" add f.txt; GIT_EDITOR=true git -C "$XW/repo" rebase --continue >/dev/null 2>&1; }
  xc push
  xother g.txt stranger; xcommit more; xc push
}
xsame xpushworld x7d
xhas 'push: origin/crew/p is the head this pipeline published ('
xhas 'ERROR: push: refusing to force-push over unincorporated remote commits'
# Remote reads that fail close the push; W15 (at parity): ls-remote matches a
# ref's tail, so a sibling ref named .../refs/heads/crew/q is read as ours - an
# up-to-date that never pushed, then two shas no check can read.
mkdir -p "$TMP/xgitnet"
cat >"$TMP/xgitnet/git" <<STUB
#!/bin/sh
for a in "\$@"; do
  case " \${GIT_FAIL:-} " in *" \$a "*) printf 'git: %s refused\n' "\$a" >&2; exit 128 ;; esac
done
exec "$XSTUBS/git" "\$@"
STUB
chmod +x "$TMP/xgitnet/git"
x7e() {
  xc start --intent net
  XPATH="$TMP/xgitnet:$XSTUBS:$PATH"; XENV=(GIT_FAIL=ls-remote); xc push
  XENV=(); xc push; xcommit more
  XENV=(GIT_FAIL=fetch); xother g.txt stranger; xc push; XENV=(); XPATH=""
  git -C "$XW/repo" push -q origin HEAD:refs/heads/x/refs/heads/crew/q 2>/dev/null; git -C "$XW/repo" checkout -q -b crew/q
  xc start --intent sibling; xc push
  git -C "$XW/repo" push -q origin crew/q 2>/dev/null; xcommit q; xc push
}
xsame xpushworld x7e
xhas 'ERROR: push: cannot read the remote (failing closed)'
xhas 'ERROR: push: fetch of refs/heads/crew/p failed (failing closed)'
xhas 'up-to-date: origin/crew/q == HEAD'
xhas 'ERROR: push: incorporation check failed (failing closed)'
# W7 (at parity): the remote calls carry no time bound - a slow ls-remote is
# waited out on both sides.
mkdir -p "$TMP/xgitslow"
cat >"$TMP/xgitslow/git" <<STUB
#!/bin/sh
for a in "\$@"; do [ "\$a" = ls-remote ] && /bin/sleep 2; done
exec "$XSTUBS/git" "\$@"
STUB
chmod +x "$TMP/xgitslow/git"
x7f() { xc start --intent slow; XPATH="$TMP/xgitslow:$XSTUBS:$PATH"; xc push; XPATH=""; }
xsame xpushworld x7f
xhas 'pushed new branch crew/p'
# A pre-push hook that refuses; review currency: a commit after the stamped
# review refuses, a receipt with no reviewed_ref only warns.
x7h() {
  printf '#!/bin/sh\necho hook says no >&2\nexit 1\n' >"$XW/repo/.git/hooks/pre-push"; chmod +x "$XW/repo/.git/hooks/pre-push"
  xc start --intent hook; xc push; rm -f "$XW/repo/.git/hooks/pre-push"
  xin '{"reviewer":"subagent"}'; xc meta review; XIN=/dev/null
  xc step review completed; xcommit after-review; xc push
  printf '{"reviewer":"legacy"}\n' >"$(xrd)/findings/review.meta.json"; xc push
}
xsame xpushworld x7h
xhas 'hook says no'
xhas 'ERROR: push: plain push of new branch failed'
xhas 'ERROR: push refused (fail-closed): HEAD moved since review - reviewed '
xhas 'WARN: push: the review receipt records no reviewed_ref - review currency is UNPROVEN for this run'
# W14 (named): far past 64 KiB of unincorporated shas (8000 here) the original's
# `printf | head -10` died of SIGPIPE - exit 141, the header and ten shas, no
# refusal line; the port prints the refusal and exits 1.
x7g() {
  xc start --intent many; xc push
  { printf 'reset refs/heads/crew/p\nfrom %s\n' "$(git -C "$XW/repo" rev-parse HEAD)"
    i=0; while [ "$i" -lt 8000 ]; do i=$((i + 1)); printf 'commit refs/heads/crew/p\ncommitter s <s@s> 1767225600 +0000\ndata 2\n%s\n\nM 644 inline s.txt\ndata 2\n%s\n\n' "$((i % 10))" "$((i % 10))"; done
  } | git -C "$XW/origin.git" fast-import --quiet
  xcommit local; xc push
}
xpass o xpushworld x7g o; xpass n xpushworld x7g n
assert_contains "$(xt o)" $'== push\nrc=141\n-- out\n-- err\npush: origin/crew/p has commits not incorporated by this branch:\n' "the original dies of SIGPIPE"
case "$(xt o)" in *'refusing to force-push'*) fail "the original printed no refusal past the pipe buffer" ;; esac
assert_contains "$(xt n)" $'== push\nrc=1\n-- out\n-- err\npush: origin/crew/p has commits not incorporated by this branch:\n' "the port refuses with 1"
assert_eq "$(awk '/^== push$/ { b = "" } { b = b $0 "\n" } END { printf "%s", b }' "$TMP/xt2.n" | grep -cE '^[0-9a-f]{40}$')" "10" "the port names ten shas"
assert_contains "$(xt n)" 'ERROR: push: refusing to force-push over unincorporated remote commits' "the port prints the refusal"
cmp -s "$TMP/xw2.o" "$TMP/xw2.n" || fail "W14 leaves identical worlds: $(diff "$TMP/xw2.o" "$TMP/xw2.n" | head)"

# -- leg 8: review-agent ---------------------------------------------------------------
x8a() {
  xc review-agent; xc start --intent 'review me'
  xc review-agent
  xc attest-test; xc review-agent
  xc review-agent
}
xsame xrevworld x8a
xhas 'ERROR: review-agent refuses to open without test evidence (no attestation): complete the test step first'
xhas $'review-agent round 1: no-op=1 risk=low reviewed_ref='
xhas 'ERROR: review-agent refuses to re-open: round 1 already reviewed current HEAD '
xwhas $'verify codereview --repo '"$XW"'/repo --ref '
xwhas ' --family fam1 --caller fam1-implement --intent '
x8b() {
  xc start --intent ladder; xc step test completed
  XENV=(AC_CREW_ID=x-implement AC_FLEET_SCOPE=scope); xverdicts fix; xc review-agent
  XENV=(AC_CREW_ID=DETACHED); xc review-agent
  XENV=(AC_CREW_ID=Foo-implement); xc review-agent
  XENV=(AC_CREW_ID=bad_id); xc review-agent; XENV=()
  git -C "$XW/repo" checkout -q main; xc review-agent
  git -C "$XW/repo" checkout -q --detach; xc start --intent detached; xc step test completed; xc review-agent
}
xsame xrevworld x8b
xwhas ' --family scope --caller x-implement '
xhas "ERROR: review-agent needs AC_CREW_ID from ac-spawn (got 'DETACHED')"
xhas "ERROR: review-agent needs AC_CREW_ID from ac-spawn (got 'Foo-implement')"
xhas "ERROR: review-agent needs AC_CREW_ID from ac-spawn (got 'empty')"
# W9 (named): the caller grammar is read per its text; bash 3.2's bracket
# ranges under a UTF-8 locale admitted an uppercase letter.
x8b2() { xc start --intent w9; xc step test completed; XENV=(AC_CREW_ID=Foo-implement); xc review-agent; XENV=(); }
XLC=en_US.UTF-8; xpass o xrevworld x8b2 o; xpass n xrevworld x8b2 n; XLC=C
assert_contains "$(xt o)" 'review-agent round 1: no-op=1 risk=low' "the original accepts Foo under a UTF-8 locale"
assert_contains "$(xt n)" "ERROR: review-agent needs AC_CREW_ID from ac-spawn (got 'Foo-implement')" "the port refuses Foo by its text"
# One ref, one round, per verdict; a PASS freezes the tree against the
# caller's own polish, while a merge from upstream, a rewrite and an
# unresolvable ref each open the round.
x8c() {
  for v in pass fix ask; do
    xc start --intent "same $v"; xc step test completed
    xverdicts "$v"; rm -f "$XW/stub/verify.n"; xc review-agent; xc review-agent; xcommit "after-$v"; xc finish cancelled
  done
}
xsame xrevworld x8c
xhas 'with verdict pass - complete delivery at this ref'
xhas 'with verdict fix - apply the blocking fix and commit it'
xhas 'with verdict ask-user - record the captain decision'
# RUNNING RESTART (named): a start over this branch's running run that spent a
# review invocation repoints current on the original, and refuses on the port.
x8c2() { xc start --intent spent; xc step test completed; xverdicts fix; xc review-agent; xc start --intent restart; }
xpass o xrevworld x8c2 o; xpass n xrevworld x8c2 n
assert_contains "$(xt o)" 'started run RUN2 branch=crew/fam1-implement' "the original restarts over the spent run"
assert_contains "$(xt n)" 'ERROR: start refused: run RUN1 on crew/fam1-implement is still running and has spent 1 review invocation(s)' "the port refuses the restart"
case "$(xt n)" in *'started run RUN2'*) fail "the refused start makes no run" ;; esac
x8d() {
  xc start --intent freeze; xc step test completed
  xverdicts pass pass pass pass; xc review-agent
  xcommit polish; xc review-agent
  git -C "$XW/repo" checkout -q main; xcommit upstream g.txt; git -C "$XW/repo" checkout -q crew/fam1-implement
  git -C "$XW/repo" merge -q --no-edit main; xc review-agent
  git -C "$XW/repo" reset -q --hard HEAD~1; xcommit rewritten h.txt; xc review-agent
  jq '.reviewed_ref = "zzz"' "$(xrd)/logs/review-agent-r3.json" >"$XW/stub/r.json"; cp "$XW/stub/r.json" "$(xrd)/logs/review-agent-r3.json"
  xcommit more i.txt; xc review-agent
}
xsame xrevworld x8d
xhas 'returned a PASS verdict (zero fix findings) at '
xhas 'review-agent round 2: no-op=1'
xhas 'review-agent round 3: no-op=1'
xhas 'review-agent round 4: no-op=1'
# A verifier that dies, writes half a result, writes none, or answers what the
# adapter refuses: the outcome stamped, the result renamed .rejected, and on
# the third attempt at one ref the brake names both.
x8e() {
  xcfg 'commands:\n  test: "echo t"\nreview:\n  max_rounds: 20\n'
  xc start --intent fails; xc step test completed
  xverdicts dead deadout empty notobj noarr badref badverdict badrisk badrat garbage garbage
  xc review-agent; xc review-agent; xc review-agent
  for i in 1 2 3 4 5 6 7 8; do xcommit "c$i"; xc review-agent; done
  xc review-agent; XENV=("AC_FLEET_STATE=$XW/home/state"); xc review-agent; XENV=()
  xc status
}
xsame xrevworld x8e
xhas 'ERROR: independent review round 1 failed; inspect the verifier round evidence under data/fam1/verify/codereview (under the fleet home)'
xhas 'ERROR: review-agent refuses a THIRD invocation on ref '
xhas ' - attempt 1 (round 1, 2026-01-01T00:00:00Z) dead-pane; attempt 2 (round 1, 2026-01-01T00:00:00Z) dead-pane. A repeated failure'
xhas 'ERROR: independent review round 1 returned no durable result'
xhas 'failed check: not-a-json-object; the verdict is kept at '
xhas 'failed check: findings-not-an-array (object)'
xhas 'failed check: reviewed_ref-does-not-bind-HEAD (0000000)'
xhas 'failed check: verdict-not-in-enum (maybe)'
xhas 'failed check: risk_level-not-in-enum (severe)'
xhas 'failed check: risk_rationale-not-a-string (number)'
xhas 'failed check: unparseable-json'
xhas "under $XW/home/data/fam1/verify/codereview (transcript.jsonl"
xwhas 'review-agent-r1.json.rejected'
# The cap counts invocations: past review.max_rounds the loop holds, one
# --final-round is granted and then spent.
x8f() {
  xcfg 'commands:\n  test: "echo t"\nreview:\n  max_rounds: 1\n'
  xc start --intent cap; xc step test completed; xverdicts fix fix fix
  xc review-agent; xcommit c1; xc review-agent; xc review-agent --final-round; xcommit c2; xc review-agent --final-round; xc finish cancelled
  xcfg 'commands:\n  test: "echo t"\nreview:\n  max_rounds: 00\n'; xc start --intent zeros; xc step test completed; xc review-agent
}
xsame xrevworld x8f
xhas 'ERROR: review-agent: verifier invocation 2 exceeds review.max_rounds=1 - the loop HOLDs'
xhas 'review-agent round 2: fix=1 no-op=1'
xhas 'ERROR: review-agent: the one --final-round is already spent (granted_at_round=2 at=2026-01-01T00:00:00Z)'
xhas 'ERROR: review-agent: verifier invocation 1 exceeds review.max_rounds=00'
# The late-finding floor: round 2 floors a NEW out-of-delta fix, keeps the
# carried-over one and the critical carve-out; a delta name holding a newline
# arms no floor.
x8g() {
  xc start --intent floor; xc step test completed; xverdicts fix fixlate fixlate
  xc review-agent; xcommit fixed; xc review-agent
  printf 'n\n' >"$XW/repo/"$'odd\nname'; git -C "$XW/repo" add -A; git -C "$XW/repo" commit -qm odd; xc review-agent
  xc fix-report review; xc status
}
xsame xrevworld x8g
xhas 'review-agent round 2: fix=2 no-op=1'
xhas 'review-agent round 3: fix=3'
xwhas '"round_floored": true'
xwhas $'history: [{"round":1,"reviewed_ref":"'
# An unexecutable facade; and W12 (named): the outcome rewrite's temp. The
# original staged it at the predictable logs/review-invocations.tsv.tmp and
# wrote through a link planted there; the port's temp is exclusive.
x8h() {
  xc start --intent facade; xc step test completed
  XENV=("AC_VERIFY_BIN=$XW/stub/nope"); xc review-agent; XENV=()
  : >"$XW/stub/victim"; xverdicts dead
  mkdir -p "$(xrd)/logs"; ln -s "$XW/stub/victim" "$(xrd)/logs/review-invocations.tsv.tmp"; xc review-agent
}
xpass o xrevworld x8h o; xpass n xrevworld x8h n
for xp in o n; do assert_contains "$(xt "$xp")" "ERROR: verifier facade is not executable: $XW/stub/nope" "an unexecutable facade refuses ($xp)"; done
assert_contains "$(cat "$TMP/xw2.o")" $'== stub/victim -rw-r--r--\n2026-01-01T00:00:00Z\t1\t' "the original wrote the ledger through the planted link"
assert_contains "$(cat "$TMP/xw2.o")" '== repo/.crew/ship/RUN1/logs/review-invocations.tsv -> ' "the original left its ledger a link"
assert_contains "$(cat "$TMP/xw2.n")" $'== stub/victim -rw-r--r--\n\n' "the port never wrote through the planted link"
assert_contains "$(cat "$TMP/xw2.n")" $'== repo/.crew/ship/RUN1/logs/review-invocations.tsv -rw-r--r--\n2026-01-01T00:00:00Z\t1\t'"$(git -C "$XW/repo" rev-parse HEAD)"$'\tdead-pane' "the port stamped its own ledger"

# -- leg 9: review-residual -------------------------------------------------------------
x9a() {
  xc review-residual; xc start --intent residual
  xc review-residual; xc review-residual reject; xc review-residual accept; xc review-residual accept --grounds
  xc review-residual accept --bogus x; xc review-residual accept --grounds ''; xc review-residual accept --grounds g
  xc step test completed; xverdicts fix fixcrit pass
  xc review-agent; xcommit moved; xc review-residual accept --grounds 'moving head'
  git -C "$XW/repo" reset -q --hard HEAD~1; xc review-residual accept --grounds $'stuck\tat\nref'
  xc status; xc fix-report review
  xcommit c2; xc review-agent; xc review-residual accept --grounds crit
  xcommit c3; xc review-agent; xc review-residual accept --grounds none
  xc finish checks-passed
}
xsame xrevworld x9a
xhas "ERROR: usage: ac-ship.sh review-residual accept --grounds '<text>'"
xhas 'ERROR: --grounds needs a value'
xhas 'ERROR: review-residual: unknown argument --bogus'
xhas 'ERROR: review-residual: --grounds is required'
xhas 'ERROR: review-residual: no review findings recorded'
xhas 'ERROR: review-residual: acceptance is only for a loop AT the cap (rounds=1, review.max_rounds=9) or STUCK at an already-reviewed HEAD'
xhas $'review-residual: 1 finding(s) accepted as advisory - post this receipt to the family room:\nSELF-APPROVED: review-residual r1 - decision: accepted - grounds: stuck\tat\nref'
xhas $'override: review-residual at=2026-01-01T00:00:00Z receipt_sha256='
xhas 'reason=stuck at ref'
xhas 'ERROR: review-residual: the residual holds 1 critical correctness/security/data-loss finding(s) - acceptance is refused'
xhas 'ERROR: review-residual: no fix residual to accept - complete the review step normally'
x9b() {
  xcfg 'commands:\n  test: "echo t"\nreview:\n  max_rounds: 1\n'
  xc start --intent atcap; xc step test completed; xverdicts fix
  xc review-agent; xcommit moved; xc review-residual accept --grounds 'at the cap'
  git -C "$XW/repo" reset -q --hard HEAD~1
  for s in intent rebase review document push pr; do xc step "$s" completed; done
  xc finish checks-passed; xc status
}
xsame xrevworld x9b
xhas 'run RUN1: checks-passed (passed-with-override: review-residual)'
xhas 'checks-passed: RUN1 PR raised, awaiting the captain'"'"'s merge - passed-with-override: review-residual'
xwhas 'attestation=passed-with-override:review-residual'
# W11 (named): the override reason's `tr` under a UTF-8 locale cut the grounds
# at an invalid byte with `tr: Illegal byte sequence`; the port keeps every
# byte it was handed - argv arrives decoded, so the byte is U+FFFD (BYTES).
x9c() { xc start --intent w11; xc step test completed; xverdicts fix; xc review-agent; xc review-residual accept --grounds $'caf\351 then\tmore'; }
XLC=en_US.UTF-8; xpass o xrevworld x9c o; xpass n xrevworld x9c n; XLC=C
assert_contains "$(xt o)" 'tr: Illegal byte sequence' "the original's tr gave up at the byte"
assert_contains "$(cat "$TMP/xw2.o")" $'\tcaf\n\n== ' "the original cut the reason"
assert_contains "$(cat "$TMP/xw2.n")" $'\tcaf\xef\xbf\xbd then more\n\n== ' "the port keeps the rest of the reason"

# -- leg 10: fix-report / status renders -----------------------------------------------
x10a() {
  xc fix-report lint; xc start --intent $'first line\nsecond line' --lint
  xc fix-report lint; xc fix-report bogus; xc fix-report
  xin '[{"id":"L1","severity":"error","action":"fix","file":"bin/x.sh","line":7,"description":"unquoted","authority_class":"internal","authority":"the lint pass"},{"id":"L2","severity":"warning","action":"ask-user","description":"rename?","decision":"yes"},{"id":"L3","action":"ask-user","description":"drop?","file":"a.txt","line":""},{"id":"L4","severity":"info","action":"no-op","description":"nit"},{"id":"L5","severity":"error","action":"fix","description":"no authority"},{"severity":"warning","action":"fix","file":"z","line":null,"description":"no id","authority_class":"external","authority":"https://x"}]'
  xc findings lint; XIN=/dev/null
  xcfg 'auto_fix:\n  lint: 5\n'; xc step lint fixing; xc step lint fixing; xc fix-report lint
  xin '{"testing_summary":"s","tested":[],"artifacts":[]}'; xc meta test; XIN=/dev/null
  printf '[]' >"$(xrd)/findings/.hidden.json"; printf '[]' >"$(xrd)/findings/zz.json"
  printf 'tdd-declared\tA\tB\treason one\nreview-residual\tC\tD\treason two\n' >"$(xrd)/override"
  xc status
  mv "$(xrd)/run.meta" "$(xrd)/meta.gone"; rm -f "$(xrd)/intent"; xc fix-report lint
}
xsame xrevworld x10a
xhas $'# Fix report: repo - run RUN1, step lint (fix round 3/-)\n\nIntent: first line\nsecond line\nBranch: crew/fam1-implement @ '
xhas '- [error] bin/x.sh:7 - unquoted (L1) - authority: the lint pass'
xhas '- [warning] rename? (L2) - DECIDED: yes'
xhas $'## Parked - awaiting captain (do NOT act on these)\n- [info] a.txt - drop?\n- [error] no authority - NO AUTHORITY NAMED (downgraded from fix)'
xhas $'- When done print: done: fixed 3 findings\n- The run stays HELD at lint and re-runs on your diff'
xhas $'override: tdd-declared at=A receipt_sha256=B reason=reason one\noverride: review-residual at=C receipt_sha256=D reason=reason two\nsteps:'
xhas '  lint       fixing             fix-rounds=2'
xhas $'findings lint: ask-user=3 fix=2 no-op=1\nmeta test: artifacts tested testing_summary\nfindings zz: none'
xhas $'== fix-report lint\nrc=1\n-- out\n-- err\nsed: '
# SHELL-OWN (named): a step listed twice makes the fix round `$((rounds + 1))`
# an arithmetic error - the original's own `syntax error in expression` line,
# the port silent, both exit 1 before printing the report.
x10b() {
  xc start --intent twice --lint; xin '[]'; xc findings lint; XIN=/dev/null
  printf 'lint\tfixing\t2\n' >>"$(xrd)/steps.tsv"; xc fix-report lint
}
xpass o xrevworld x10b o; xpass n xrevworld x10b n
assert_contains "$(xt o)" 'syntax error in expression' "the original dies on bash's arithmetic line"
assert_contains "$(xt n)" $'== fix-report lint\nrc=1\n-- out\n-- err' "the port exits 1 at the same point"
assert_eq "$(sed -n '/^== fix-report lint$/,$p' "$TMP/xt2.n" | wc -l | tr -d ' ')" "4" "the port prints no line of the shell's"
cmp -s "$TMP/xw2.o" "$TMP/xw2.n" || fail "a doubled step row leaves identical worlds"

# -- leg 11: finish -------------------------------------------------------------------
x11a() {
  xc finish checks-passed; xc start --intent fin
  xc finish; xc finish bogus; xc finish checks-passed; xc finish passed
  for s in intent rebase test document push pr; do xc step "$s" completed; done; xc step review skipped
  : >"$(xrd)/findings/empty.json"; printf '{}' >"$(xrd)/findings/obj.json"
  xc finish checks-passed
  printf 'null' >"$(xrd)/findings/null.json"; printf '[{' >"$(xrd)/findings/bad.json"
  printf '[{"id":"a","action":"fix"},{"action":"ask-user"},{"id":"d","action":"ask-user","decision":"yes"}]' >"$(xrd)/findings/lint.json"
  xc finish checks-passed
  rm -f "$(xrd)/findings/null.json" "$(xrd)/findings/bad.json" "$(xrd)/findings/lint.json"
  : >"$(xrd)/steps.tsv"; xc finish checks-passed; xc finish failed; xc finish cancelled
}
xsame xrevworld x11a
xhas 'ERROR: usage: ac-ship.sh finish <checks-passed|passed|failed|cancelled>'
xhas 'ERROR: finish checks-passed refused (fail-closed): pipeline steps not completed: intent(pending) rebase(pending) review(pending) test(pending) document(pending) push(pending) pr(pending) - complete or --skip them'
xhas 'ERROR: finish checks-passed refused (fail-closed): unresolved findings - bad: UNREADABLE (bad findings file is corrupt or not valid JSON); lint: a[fix], ?[ask-user]; null: UNREADABLE (null findings file is corrupt or not valid JSON)'
xhas 'checks-passed: RUN1 validated, no PR raised (pr step ) - awaiting the captain'
xhas 'checks-passed: RUN1 PR raised, awaiting the captain'"'"'s merge'
x11b() {
  git -C "$XW/repo" branch rel main
  xc start --intent merged --target rel
  for s in intent rebase review test document push pr; do xc step "$s" skipped; done
  xc finish passed
  git -C "$XW/repo" checkout -q rel; git -C "$XW/repo" merge -q --ff-only crew/fam1-implement; xc finish passed
  git -C "$XW/repo" checkout -q crew/fam1-implement; xc start --intent default
  for s in intent rebase review test document push pr; do xc step "$s" skipped; done
  xc finish passed; git -C "$XW/repo" checkout -q main; xc finish passed
  git -C "$XW/repo" checkout -q crew/fam1-implement; xcommit c
  xin '{"reviewer":"sub"}'; xc start --intent cur; xc meta review; XIN=/dev/null
  for s in intent rebase review test document push pr; do xc step "$s" completed; done
  xcommit after; xc finish checks-passed
}
xsame xrevworld x11b
xhas 'ERROR: finish passed refused (fail-closed): HEAD is not merged into rel - use checks-passed for a raised-but-unmerged PR; passed records a MERGED run'
xhas 'run RUN1: passed'
xhas 'ERROR: finish passed refused (fail-closed): HEAD is not merged into main'
xhas 'ERROR: finish checks-passed refused (fail-closed): HEAD moved since review - reviewed '
# The legacy review.pane and the board's watch.pane are retired by finish:
# the pane agent only when executable, herdr only when on PATH (the file kept
# otherwise), the session from AC_HERDR_SESSION, else config/herdr-session.
mkdir -p "$TMP/xnoexec"; printf '#!/bin/sh\nexit 0\n' >"$TMP/xnoexec/pane"
x11c() {
  xc start --intent panes
  printf 'w9:pGone\n' >"$(xrd)/review.pane"; printf 'pW7\n' >"$(xrd)/watch.pane"; xc finish cancelled
  printf 'w9:pGone\n' >"$(xrd)/review.pane"; printf 'pW7\n' >"$(xrd)/watch.pane"
  XENV=("AC_PANE_AGENT=$TMP/xnoexec/pane" AC_HERDR_SESSION=s1); xc finish failed
  printf 'pW8\n' >"$(xrd)/watch.pane"; printf 's2\n' >"$XW/home/config/herdr-session"; XENV=(PANE_RC=3); xc finish failed
  printf 'pW9\n' >"$(xrd)/watch.pane"; XPATH="$(xwithout herdr)"; XENV=(); xc finish cancelled; XPATH=""
}
xsame xrevworld x11c
xwhas 'pane close --pane w9:pGone'
xwhas 'herdr --session default pane close pW7'
xwhas 'herdr --session s1 pane close pW7'
xwhas 'herdr --session s2 pane close pW8'
xwhas $'== repo/.crew/ship/RUN1/watch.pane -rw-r--r--\npW9'
x11d() {
  xc start --intent kinds --tdd; xc step test completed
  xc start --intent kinds2 --tdd
  printf 'review-residual\tT\tS\tg\n' >>"$(xrd)/override"
  for s in intent rebase document push pr; do xc step "$s" completed; done; xc step review skipped
  xc finish checks-passed; xc finish checks-passed; xc finish passed; xc status
}
xsame xrevworld x11d
xhas 'run RUN2: checks-passed (passed-with-override: tdd-declared,review-residual)'
xhas 'checks-passed: RUN2 PR raised, awaiting the captain'"'"'s merge - passed-with-override: tdd-declared,review-residual'

# -- leg 12: the live board -------------------------------------------------------------
xtabs() { printf '%s' '{"result":{"tabs":[{"tab_id":"tJ","workspace_id":"wW","label":"1"},{"tab_id":"tO","workspace_id":"wO","label":"1"},{"tab_id":"tK","workspace_id":"wW","label":"keep"},{"tab_id":"tJ2","workspace_id":"wW","label":"1"}]}}' >"$XW/stub/tabs.json"; }
x12a() {
  xtabs; XWATCH=auto
  xc start --intent board; xc step intent running; xc step review fixing; xc step intent completed; xc finish cancelled
  XENV=(AC_FLEET_SCOPE=fam9 'AC_SCOPE=a b'); xc start --intent scoped
  XENV=(AC_HERDR_SESSION=s1); xc start --intent s1
  printf 's2\n' >"$XW/home/config/herdr-session"; XENV=(); xc start --intent s2
  XWATCH=off
}
xsame xrevworld x12a
xwhas 'herdr --session default tab create --workspace wW --label ac-ship-watch-crew-fam1-implement --cwd '"$XW"'/repo --no-focus'
xwhas 'herdr --session default pane rename pW1 ac-ship-watch'
xwhas "herdr --session default pane run pW1 'ROOT/bin/ac-ship-watch.sh' --repo '$XW/repo' --self-pane pW1"
xwhas $'herdr --session default tab close tJ\nherdr --session default tab close tJ2\n'
xwhas 'herdr --session default pane close pW1'
xwhas 'herdr workspace create --label home · fam9 --no-focus'
xwhas 'herdr --session s1 pane list'
xwhas 'herdr workspace list --session s2'
# Nothing opens: AC_SHIP_WATCH=off, an orca fleet, no herdr on PATH, any pane
# labelled ac-ship-watch anywhere in the session (W6, at parity), a tab create
# that fails; a failing rename, run, list or close never fails the start.
x12b() {
  xtabs; XWATCH=auto
  XWATCH=off; xc start --intent off; XWATCH=auto
  printf 'orca\n' >"$XW/home/config/backend"; xc start --intent orca; rm -f "$XW/home/config/backend"
  XPATH="$(xwithout herdr)"; xc start --intent noherdr; XPATH=""
  printf '%s' '{"result":{"panes":[{"pane_id":"pX","label":"ac-ship-watch"}]}}' >"$XW/stub/panes.json"; xc start --intent foreign; rm -f "$XW/stub/panes.json"
  XENV=(HERDR_FAIL=tabcreate); xc start --intent nocreate
  XENV=('HERDR_FAIL=rename run tabclose'); xc start --intent opsfail
  XENV=('HERDR_FAIL=tablist panelist'); xc start --intent listfail
  printf 'not json' >"$XW/stub/tabs.json"; XENV=(); xc start --intent garbage
  XWATCH=off; xc status
}
xsame xrevworld x12b
xhas $'== start --intent garbage\nrc=0\n-- out\nstarted run RUN8 '
[ "$(grep -c 'tab create' "$XW/stub/herdr.log")" = 4 ] || fail "only the nocreate, opsfail, listfail and garbage starts reached a tab create"
# W16 (at parity): the launch line single-quotes the repo path raw.
xquoteworld() {
  xworld; git init -q "$XW/q'r"; printf 'b\n' >"$XW/q'r/f.txt"; git -C "$XW/q'r" add f.txt; git -C "$XW/q'r" commit -qm b
  cp "$XW/home/projects/repo.yaml" "$XW/home/projects/q'r.yaml"
}
x12c() { XWATCH=auto; XCWD="q'r"; xc start --intent quoted; XCWD=repo; XWATCH=off; }
xsame xquoteworld x12c
xwhas "--repo '$XW/q'r' --self-pane pW1"

# -- leg 13: signals and continuation ------------------------------------------------
xsig() {  # xsig <signal> <marker> <args...> - one ship call in the background; once the world holds <marker>, <signal> to its pid alone
  local sig="$1" mark="$2" side bin="$BIN" rc=0 pid i=0 x; shift 2
  side="${XALT[$((XCALL % ${#XALT[@]}))]}"; XCALL=$((XCALL + 1))
  [ "$side" = n ] || bin="$xobin"
  local e=("LC_ALL=$XLC" "PATH=$XSTUBS:$PATH" "TMPDIR=$XW/tmp" "XSTUB=$XW/stub" "AC_SHIP_WATCH=off" "AC_VERIFY_BIN=$XSTUBS/verify" "AC_PANE_AGENT=$XSTUBS/pane" "AC_HOME=$XW/home")
  for x in ${XENV[@]+"${XENV[@]}"}; do e+=("$x"); done
  # Job control gives the job its own group with SIGINT at its default - a
  # plain `&` job of a non-interactive shell starts with SIGINT ignored.
  {
    set -m
    (cd "$XW/repo" && exec env -u AC_FLEET_STATE -u AC_SCOPE -u AC_CREW_ID -u GIT_TERMINAL_PROMPT -u GIT_OPTIONAL_LOCKS "${e[@]}" "$bin/ac-ship.sh" "$@") </dev/null >"$TMP/x.out" 2>"$TMP/x.err" &
    pid=$!
    set +m
    while [ ! -e "$XW/$mark" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
    kill -"$sig" "$pid"
    wait "$pid" || rc=$?
  } 2>/dev/null
  # The original's children outlive it; read the call once they are done.
  i=0; while [ ! -e "$XW/stub/slow-done" ] && [ "$i" -lt 400 ]; do sleep 0.05; i=$((i + 1)); done
  sleep 0.3
  { printf '== %s %s\nrc=%s\n-- out\n' "$sig" "$*" "$rc"; cat "$TMP/x.out"; printf '%s\n' '-- err'; cat "$TMP/x.err"; } >>"$TMP/xt.$XPASS"
}
xslow() { xcfg 'commands:\n  test: "touch ../stub/started; echo slow; /bin/sleep 1; echo after; touch ../stub/slow-done"\n'; }
x13a() { xslow; xc start --intent term; xsig TERM stub/started cmd test; xc status; }
xsame xrevworld x13a
xhas $'== TERM cmd test\nrc=143\n-- out\nslow\nafter\n-- err\n$ touch'
xwhas $'reason=incomplete'
x13b() { xslow; xc start --intent hup; xsig HUP stub/started cmd test; }
xsame xrevworld x13b
xhas $'== HUP cmd test\nrc=129'
# W2 (at parity): TERM to the pid alone during the verifier leaves its RAW
# result, which the next round reads as durable while nothing else was written.
x13c() {
  xc start --intent w2; xc step test completed; xverdicts slow
  ( while [ ! -e "$XW/stub/verify.started" ]; do sleep 0.05; done; sleep 0.2; : >"$XW/stub/verify.release"
    while [ ! -s "$(xrd)/logs/review-agent-r1.json" ]; do sleep 0.05; done; sleep 0.2; : >"$XW/stub/slow-done" ) &
  xsig TERM stub/verify.started review-agent; wait
  xc review-agent; xc step review completed; xc review-residual accept --grounds g; xc status
}
xsame xrevworld x13c
xhas $'== TERM review-agent\nrc=143'
xhas 'ERROR: review-agent refuses to re-open: round 1 already reviewed current HEAD '
xhas 'ERROR: review-residual: no review findings recorded'
xwhas $'\t1\t'"$(git -C "$XW/repo" rev-parse HEAD)"$'\topened\n'
# W19 (named): SIGINT to the pid alone - the original, waiting on its suite,
# completed (rc 0); the port ends at once with 130, its suite finishing alone.
x13d() { xslow; xc start --intent int; xsig INT stub/started cmd test; }
xpass o xrevworld x13d o; xpass n xrevworld x13d n
assert_contains "$(xt o)" $'== INT cmd test\nrc=0\n-- out\nslow\nafter\n' "the original swallowed SIGINT while its suite ran"
assert_contains "$(cat "$TMP/xw2.o")" $'qualification=qualifies\nreason=executed' "the original wrote its receipt"
assert_contains "$(xt n)" $'== INT cmd test\nrc=130\n-- out\nslow\nafter\n' "the port ended at once"
assert_contains "$(cat "$TMP/xw2.n")" $'reason=incomplete' "the port left the receipt incomplete"
# A run started by one side and continued by the other, call by call, either
# side first, ends in the world the original alone leaves.
x13e() {
  xc start --intent 'the whole pipeline'; xc step intent running; xc step intent completed; xc step rebase completed
  xc cmd test; xc step test completed; xverdicts fix pass
  xc review-agent; xin '[{"id":"lint1","severity":"warning","action":"fix","authority_class":"internal","authority":"a"}]'; xc findings lint; XIN=/dev/null
  xc step lint fixing; xc fix-report lint; xin '[]'; xc findings lint; XIN=/dev/null; xc step lint completed
  xcommit fixed; xc step review fixing; xc review-agent; xc step review completed
  xc step document skipped; xc push; xc push; xc step push completed; xc step pr completed; xc status
  xc finish checks-passed; xc attest-test; xc attest-check; xc evidence-dir; xc base
}
xcont xpushworld x13e
xhas 'checks-passed: RUN1 PR raised, awaiting the captain'"'"'s merge' a
xhas 'review-agent round 2: no-op=1 risk=low' b

pass
