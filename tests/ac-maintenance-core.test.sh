#!/usr/bin/env bash
# ac-maintenance-core.test.sh - shared maintenance transaction and cadence
# primitives used by automatic Learning and Curate.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../bin/ac-lib.sh
. "$BIN/ac-lib.sh"
. "$BIN/ac-maintenance-lib.sh"
make_home

# Legacy cadence files remain readable and gain generation only on a write.
printf 'stows=4\nlast_run=10\n' >"$AC_HOME/state/.learn.meta"
assert_eq "$(ac_learn_due)" "4 8" "legacy Learning cadence remains readable"
ac_learn_tick
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "5" "legacy count survives the first generation-aware tick"
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" generation)" "0" "legacy cadence starts at generation zero"

# A reset is bound to the captured generation. A late tick belongs to the new
# generation and an older reset cannot erase it.
captured="$(ac_learn_generation)"
ac_learn_reset "$captured"
assert_eq "$(ac_learn_generation)" "1" "successful Learning reset advances generation"
ac_learn_tick
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "1" "late tick lands in the new generation"
if ac_learn_reset "$captured"; then
  fail "an old Learning generation must not reset newer cadence"
fi
assert_eq "$(ac_meta_get "$AC_HOME/state/.learn.meta" debriefs)" "1" "refused old reset preserves the late tick"

printf 'runs_since=3\n' >"$AC_HOME/state/.curate.meta"
assert_eq "$(ac_curate_due)" "3 5" "legacy Curate cadence remains readable"
ccaptured="$(ac_curate_generation)"
ac_curate_reset "$ccaptured"
ac_curate_tick
if ac_curate_reset "$ccaptured"; then
  fail "an old Curate generation must not reset newer cadence"
fi
assert_eq "$(ac_meta_get "$AC_HOME/state/.curate.meta" runs_since)" "1" "Curate late tick survives an old reset"

# Closed maintenance plans accept only the named schema, fields, operations,
# and contained relative paths.
run="$AC_HOME/data/learning-1"
mkdir -p "$run/staged/skills/example"
printf 'skill\n' >"$run/staged/skills/example/SKILL.md"
sha="$(ac_sha256_file "$run/staged/skills/example/SKILL.md")"
cat >"$run/manifest" <<'EOF'
kind: skill
name: example
===skill===
A candidate line that exists nowhere but inside this manifest.
EOF
manifest_sha="$(ac_sha256_file "$run/manifest")"
cat >"$run/plan.json" <<EOF
{"schema":"agentcrew.maintenance-plan/v1","mode":"learning","run_id":"learning-1","subject":"example","input_manifest_sha256":"$manifest_sha","actions":[{"op":"write-skill","target":"skills/example/SKILL.md","old_sha256":"-","new_sha256":"$sha","staged":"staged/skills/example/SKILL.md"}]}
EOF
ac_maintenance_plan_validate "$run/plan.json" "$run"

for bad in unknown absolute traversal nested-traversal glob shell; do
  case "$bad" in
    unknown) jq '.actions[0].op="execute-shell"' "$run/plan.json" >"$run/bad.json" ;;
    absolute) jq '.actions[0].target="/tmp/escape"' "$run/plan.json" >"$run/bad.json" ;;
    traversal) jq '.actions[0].target="../escape"' "$run/plan.json" >"$run/bad.json" ;;
    nested-traversal) jq '.actions[0].target="skills/example/../../../escape"' "$run/plan.json" >"$run/bad.json" ;;
    glob) jq '.actions[0].target="skills/*/SKILL.md"' "$run/plan.json" >"$run/bad.json" ;;
    shell) jq '.shell="rm anything"' "$run/plan.json" >"$run/bad.json" ;;
  esac
  if ac_maintenance_plan_validate "$run/bad.json" "$run" >/dev/null 2>&1; then
    fail "closed plan validator accepted $bad input"
  fi
done

# Only a closed, hash-bound maintenance receipt can authorize the plan.
plan_sha="$(ac_sha256_file "$run/plan.json")"
cat >"$run/decision.md" <<EOF
---
schema: "agentcrew.maintenance-gate/v1"
mode: "learning"
subject: "example"
decision: "continue"
authority: "second-chief"
engine: "codex"
model: "gate-model"
input_manifest_sha256: "$manifest_sha"
action_plan_sha256: "$plan_sha"
reviewed_at: "2026-07-26T00:00:00Z"
---
# Maintenance Gate Decision
## Decision
continue
## Grounds
The exact action is recoverable and supported.
## Inputs Read
- INPUT MANIFEST QUOTE: A candidate line that exists nowhere but inside this manifest.
- ACTION PLAN NEW SHA-256: $sha
- STAGED PAYLOAD QUOTE: skill
## Proposed Process
Apply the hash-bound maintenance plan.
EOF
assert_eq "$(ac_maintenance_receipt_validate "$run/decision.md" "$run/plan.json" "$run/manifest")" \
  "continue" "hash-bound maintenance receipt validates"
sed 's/action_plan_sha256: \".*\"/action_plan_sha256: \"bad\"/' \
  "$run/decision.md" >"$run/bad-decision.md"
if ac_maintenance_receipt_validate "$run/bad-decision.md" "$run/plan.json" "$run/manifest" >/dev/null 2>&1; then
  fail "a receipt with a mismatched action-plan hash must not authorize apply"
fi

# Hash agreement alone never authorizes: the gate prompt PRINTS both hashes, so
# a judge that never opened either input can echo them back. The receipt has to
# carry content of the inputs that the prompt never handed out.
receipt_variant() {
  # receipt_variant <out> <decision> <manifest-quote> <plan-sha> [<authority>]
  #   [<payload-quote>|none]
  # The staged payload of this run's one action holds the single line `skill`.
  {
    printf -- '---\nschema: "agentcrew.maintenance-gate/v1"\n'
    printf 'mode: "learning"\nsubject: "example"\ndecision: "%s"\n' "$2"
    printf 'authority: "%s"\nengine: "codex"\nmodel: "gate-model"\n' "${5:-second-chief}"
    printf 'input_manifest_sha256: "%s"\naction_plan_sha256: "%s"\n' "$manifest_sha" "$plan_sha"
    printf 'reviewed_at: "2026-07-26T00:00:00Z"\n---\n'
    printf '# Maintenance Gate Decision\n## Decision\n%s\n' "$2"
    printf '## Grounds\nThe exact action is recoverable and supported.\n'
    if [ -n "$3$4" ]; then
      printf '## Inputs Read\n- INPUT MANIFEST QUOTE: %s\n- ACTION PLAN NEW SHA-256: %s\n' "$3" "$4"
      [ "${6:-skill}" = none ] || printf -- '- STAGED PAYLOAD QUOTE: %s\n' "${6:-skill}"
    fi
    printf '## Proposed Process\nApply the hash-bound maintenance plan.\n'
  } >"$1"
}
good_quote='A candidate line that exists nowhere but inside this manifest.'

receipt_variant "$run/blind.md" continue "" ""
if ac_maintenance_receipt_validate "$run/blind.md" "$run/plan.json" "$run/manifest" >/dev/null 2>&1; then
  fail "correct hashes with no read-evidence must not authorize apply"
fi

for blind_decision in revise ask-captain; do
  receipt_variant "$run/blind-$blind_decision.md" "$blind_decision" "" ""
  if ac_maintenance_receipt_validate "$run/blind-$blind_decision.md" "$run/plan.json" \
    "$run/manifest" >/dev/null 2>&1; then
    fail "read-evidence binds every decision value, not only continue ($blind_decision)"
  fi
done

receipt_variant "$run/invented.md" continue \
  'A candidate line no reader of that manifest ever saw.' "$sha"
if ac_maintenance_receipt_validate "$run/invented.md" "$run/plan.json" "$run/manifest" >/dev/null 2>&1; then
  fail "a quote absent from the input it claims must not count as read-evidence"
fi

receipt_variant "$run/short.md" continue 'name: example' "$sha"
if ac_maintenance_receipt_validate "$run/short.md" "$run/plan.json" "$run/manifest" >/dev/null 2>&1; then
  fail "a quote whose only content is the prompt-supplied subject must not count as read-evidence"
fi

receipt_variant "$run/foreign-sha.md" continue "$good_quote" \
  "$(printf 'not this plan\n' | shasum -a 256 | awk '{print $1}')"
if ac_maintenance_receipt_validate "$run/foreign-sha.md" "$run/plan.json" "$run/manifest" >/dev/null 2>&1; then
  fail "a hash no action in the plan carries must not count as read-evidence"
fi

# An engine that wraps its evidence in backticks still read the files.
receipt_variant "$run/fenced.md" continue "\`$good_quote\`" "\`$sha\`"
assert_eq "$(ac_maintenance_receipt_validate "$run/fenced.md" "$run/plan.json" "$run/manifest")" \
  "continue" "backtick-wrapped read-evidence is still read-evidence"

# BOTH CALL SITES, not just the gate's write-time one: the settled bytes are
# re-checked here, so a receipt carrying only the two old proofs authorizes
# nothing either.
receipt_variant "$run/payload-blind.md" continue "$good_quote" "$sha" second-chief none
if ac_maintenance_receipt_validate "$run/payload-blind.md" "$run/plan.json" \
  "$run/manifest" >/dev/null 2>&1; then
  fail "a settled receipt blind to the staged payload must not authorize apply"
fi

# A repository-policy receipt has no engine to be blind: Curate mints it from
# the very files it just built, so it carries no engine read-evidence.
receipt_variant "$run/policy.md" continue "" "" repository-policy
assert_eq "$(ac_maintenance_receipt_validate "$run/policy.md" "$run/plan.json" "$run/manifest")" \
  "continue" "an engine-less repository-policy receipt needs no read-evidence"
receipt_variant "$run/unknown-authority.md" continue "" "" chief
if ac_maintenance_receipt_validate "$run/unknown-authority.md" "$run/plan.json" \
  "$run/manifest" >/dev/null 2>&1; then
  fail "only repository-policy is exempt; an unrecognised authority still owes read-evidence"
fi

# A plan that stages a byte-identical copy of its own manifest carries the
# prompt-printed manifest hash as one of its action hashes, so set membership
# alone would accept the one value the judge got for free.
selfrun="$AC_HOME/data/learning-self"
mkdir -p "$selfrun/staged"
cat >"$selfrun/manifest" <<'EOF'
kind: patch
name: example
===patch===
## A line long enough to prove someone opened this file.
EOF
cp "$selfrun/manifest" "$selfrun/staged/copy.md"
self_sha="$(ac_sha256_file "$selfrun/manifest")"
cat >"$selfrun/plan.json" <<EOF
{"schema":"agentcrew.maintenance-plan/v1","mode":"learning","run_id":"learning-self","subject":"example","input_manifest_sha256":"$self_sha","actions":[{"op":"append-archive","target":"records/learnings-archive/example.md","old_sha256":"-","new_sha256":"$self_sha","staged":"staged/copy.md"}]}
EOF
self_receipt() {
  {
    printf -- '---\nschema: "agentcrew.maintenance-gate/v1"\n'
    printf 'mode: "learning"\nsubject: "example"\ndecision: "continue"\n'
    printf 'authority: "second-chief"\nengine: "codex"\nmodel: "gate-model"\n'
    printf 'input_manifest_sha256: "%s"\naction_plan_sha256: "%s"\n' \
      "$self_sha" "$(ac_sha256_file "$selfrun/plan.json")"
    printf 'reviewed_at: "2026-07-26T00:00:00Z"\n---\n'
    printf '# Maintenance Gate Decision\n## Decision\ncontinue\n'
    printf '## Grounds\nThe exact action is recoverable and supported.\n'
    printf '## Inputs Read\n- INPUT MANIFEST QUOTE: %s\n- ACTION PLAN NEW SHA-256: %s\n' \
      '## A line long enough to prove someone opened this file.' "$1"
    printf '## Proposed Process\nApply the hash-bound maintenance plan.\n'
  } >"$selfrun/decision.md"
}
self_receipt "$self_sha"
if ac_maintenance_receipt_validate "$selfrun/decision.md" "$selfrun/plan.json" \
  "$selfrun/manifest" >/dev/null 2>&1; then
  fail "an action hash that equals the prompt-printed manifest hash proves nothing and must be refused"
fi

# The shortest content line a generated manifest emits still has to count: a
# floor above it would reject the very line the prompt tells the judge to pick.
jsonrun="$AC_HOME/data/curate-json"
mkdir -p "$jsonrun/staged"
cat >"$jsonrun/manifest.json" <<'EOF'
{
  "schema": "agentcrew.curate-subject-input/v1",
  "subject": "project-lab",
  "files": [
    {
      "path": "projects/lab",
      "sha256": "-"
    }
  ]
}
EOF
printf 'archived\n' >"$jsonrun/staged/projects.md"
json_new="$(ac_sha256_file "$jsonrun/staged/projects.md")"
cat >"$jsonrun/plan.json" <<EOF
{"schema":"agentcrew.maintenance-plan/v1","mode":"curate","run_id":"curate-json","subject":"project-lab","input_manifest_sha256":"$(ac_sha256_file "$jsonrun/manifest.json")","actions":[{"op":"rewrite-registry","target":"records/projects.md","old_sha256":"-","new_sha256":"$json_new","staged":"staged/projects.md"}]}
EOF
printf '## Inputs Read\n- INPUT MANIFEST QUOTE: "path": "projects/lab",\n- ACTION PLAN NEW SHA-256: %s\n- STAGED PAYLOAD QUOTE: archived\n' \
  "$json_new" | ac_maintenance_read_evidence "$jsonrun/manifest.json" "$jsonrun/plan.json" \
  || fail "a real path line of a JSON subject manifest must count as read-evidence"
if printf '## Inputs Read\n- INPUT MANIFEST QUOTE: "subject": "project-lab",\n- ACTION PLAN NEW SHA-256: %s\n- STAGED PAYLOAD QUOTE: archived\n' \
  "$json_new" | ac_maintenance_read_evidence "$jsonrun/manifest.json" "$jsonrun/plan.json"; then
  fail "the subject line of a JSON subject manifest is prompt-supplied and must not count"
fi

# The plan's `new_sha256` proves the judge opened plan.json; it never proves it
# opened the STAGED BYTES that hash names, because the CALLER is the side that
# hashed them (ac_maintenance_plan_validate) before any pane opened. A third
# proof binds the quote to the staged file of the action whose hash was cited.
payrun="$AC_HOME/data/learning-payload"
mkdir -p "$payrun/staged/records" "$payrun/staged/skills/thin"
cat >"$payrun/manifest" <<'EOF'
kind: skill
name: payload
===skill===
A candidate line that exists nowhere but inside this manifest.
EOF
pay_manifest_sha="$(ac_sha256_file "$payrun/manifest")"
cat >"$payrun/staged/records/learnings.md" <<'EOF'
# Learning Ledger

## Distilled

- [distilled -> payload] sources=1 updated=2026-09-15 ([evidence](learnings-archive/payload.md))
EOF
printf 'thin\n' >"$payrun/staged/skills/thin/SKILL.md"
: >"$payrun/staged/records/empty.md"
pay_ledger="$(ac_sha256_file "$payrun/staged/records/learnings.md")"
pay_thin="$(ac_sha256_file "$payrun/staged/skills/thin/SKILL.md")"
pay_empty="$(ac_sha256_file "$payrun/staged/records/empty.md")"
cat >"$payrun/plan.json" <<EOF
{"schema":"agentcrew.maintenance-plan/v1","mode":"learning","run_id":"learning-payload","subject":"payload","input_manifest_sha256":"$pay_manifest_sha","actions":[{"op":"rewrite-ledger","target":"records/learnings.md","old_sha256":"-","new_sha256":"$pay_ledger","staged":"staged/records/learnings.md"},{"op":"write-skill","target":"skills/thin/SKILL.md","old_sha256":"-","new_sha256":"$pay_thin","staged":"staged/skills/thin/SKILL.md"},{"op":"append-archive","target":"records/empty.md","old_sha256":"-","new_sha256":"$pay_empty","staged":"staged/records/empty.md"}]}
EOF
ac_maintenance_plan_validate "$payrun/plan.json" "$payrun" \
  || fail "the staged-payload fixture plan must itself be valid"

pay_evidence() {
  # pay_evidence <cited-new-sha256> [<payload-quote-line>]
  {
    printf '## Inputs Read\n'
    printf -- '- INPUT MANIFEST QUOTE: A candidate line that exists nowhere but inside this manifest.\n'
    printf -- '- ACTION PLAN NEW SHA-256: %s\n' "$1"
    [ "$#" -lt 2 ] || printf -- '- STAGED PAYLOAD QUOTE: %s\n' "$2"
  } | ac_maintenance_read_evidence "$payrun/manifest" "$payrun/plan.json"
}

if pay_evidence "$pay_ledger"; then
  fail "a judge that copied a real new_sha256 but never opened the staged payload must be refused"
fi
pay_evidence "$pay_ledger" '# Learning Ledger' \
  || fail "a composed line of the cited action's own staged payload must count as read-evidence"
pay_evidence "$pay_ledger" '`# Learning Ledger`' \
  || fail "a backtick-wrapped staged-payload quote is still read-evidence"
if pay_evidence "$pay_ledger" 'A line that staged payload never held.'; then
  fail "a staged-payload quote absent from the file it claims must not count"
fi
if pay_evidence "$pay_ledger" thin; then
  fail "the payload proof is bound to the cited action: another action's payload must not count"
fi
if pay_evidence "$pay_ledger" '## Distilled'; then
  fail "a staged-payload quote under the floor must not count while the payload can bear it"
fi

# THE BEARING FLOOR. A staged payload is not always a composed artifact: a
# move-skill action stages a VERBATIM COPY of an arbitrary file of a skill
# package, so the floor a payload can bear is the floor this one actually
# holds - AC_MAINTENANCE_QUOTE_MIN only when its own best line reaches it.
pay_evidence "$pay_thin" thin \
  || fail "a payload too thin for the standard floor must still admit its own best line"
if pay_evidence "$pay_thin" '# Learning Ledger'; then
  fail "the bearing floor never unbinds the proof from the cited action"
fi

# THE WAIVER BELONGS TO THE PLAN, NEVER TO THE JUDGE. The judge picks which
# action it cites, so a waiver keyed only on the CITED payload would let it cite
# the one contentless action in a plan and skip the proof for every other one.
if pay_evidence "$pay_empty"; then
  fail "citing the one payload that can prove nothing must not waive a plan whose other payloads can"
fi
if pay_evidence "$pay_empty" '# Learning Ledger'; then
  fail "and quoting another action's payload does not rescue that citation either"
fi

# A plan whose payloads ALL prove nothing is the only thing the waiver covers:
# there is no better action for an honest judge to have cited.
barerun="$AC_HOME/data/learning-bare"
mkdir -p "$barerun/staged/records"
cp "$payrun/manifest" "$barerun/manifest"
: >"$barerun/staged/records/empty.md"
printf -- '---\n' >"$barerun/staged/records/punct.md"
bare_empty="$(ac_sha256_file "$barerun/staged/records/empty.md")"
bare_punct="$(ac_sha256_file "$barerun/staged/records/punct.md")"
cat >"$barerun/plan.json" <<EOF
{"schema":"agentcrew.maintenance-plan/v1","mode":"learning","run_id":"learning-bare","subject":"payload","input_manifest_sha256":"$(ac_sha256_file "$barerun/manifest")","actions":[{"op":"rewrite-ledger","target":"records/empty.md","old_sha256":"-","new_sha256":"$bare_empty","staged":"staged/records/empty.md"},{"op":"append-archive","target":"records/punct.md","old_sha256":"-","new_sha256":"$bare_punct","staged":"staged/records/punct.md"}]}
EOF
ac_maintenance_plan_validate "$barerun/plan.json" "$barerun" \
  || fail "the all-bare fixture plan must itself be valid"
{
  printf '## Inputs Read\n'
  printf -- '- INPUT MANIFEST QUOTE: A candidate line that exists nowhere but inside this manifest.\n'
  printf -- '- ACTION PLAN NEW SHA-256: %s\n' "$bare_empty"
} | ac_maintenance_read_evidence "$barerun/manifest" "$barerun/plan.json" \
  || fail "a plan whose every payload can carry no proof must not refuse an honest judge"

# ONE MEASURE for the quote and for the floor its payload can bear. Two that
# disagreed by a byte would let a payload set a floor no quote of it can reach -
# and this fleet's own records are written in Vietnamese, so the multibyte case
# is the live one, not a curiosity.
vnrun="$AC_HOME/data/curate-vietnamese"
mkdir -p "$vnrun/staged/records"
cp "$payrun/manifest" "$vnrun/manifest"
# MEASURED: this line scores 15 by the one measure both sides now take, and 10
# by the shell character count the quote used to take against a byte-measured
# floor of 12 - so it passes only while the two measures are one.
printf 'Ghi chú: đã gỡ.\n' >"$vnrun/staged/records/captain.md"
vn_new="$(ac_sha256_file "$vnrun/staged/records/captain.md")"
cat >"$vnrun/plan.json" <<EOF
{"schema":"agentcrew.maintenance-plan/v1","mode":"learning","run_id":"curate-vietnamese","subject":"payload","input_manifest_sha256":"$(ac_sha256_file "$vnrun/manifest")","actions":[{"op":"rewrite-registry","target":"records/captain.md","old_sha256":"-","new_sha256":"$vn_new","staged":"staged/records/captain.md"}]}
EOF
{
  printf '## Inputs Read\n'
  printf -- '- INPUT MANIFEST QUOTE: A candidate line that exists nowhere but inside this manifest.\n'
  printf -- '- ACTION PLAN NEW SHA-256: %s\n' "$vn_new"
  printf -- '- STAGED PAYLOAD QUOTE: Ghi chú: đã gỡ.\n'
} | ac_maintenance_read_evidence "$vnrun/manifest" "$vnrun/plan.json" \
  || fail "a non-ASCII payload must not set a floor its own best line cannot reach"

# Applying a validated plan is backup-first, journaled, atomic, and idempotent.
ac_maintenance_apply "$run/plan.json" "$run"
assert_eq "$(cat "$AC_HOME/skills/example/SKILL.md")" "skill" "validated write-skill action applied"
journal="$AC_HOME/state/.maintenance-transactions/learning-1-example/journal"
assert_contains "$(cat "$journal")" "complete" "transaction journal reaches complete"
backup="$(sed -n 's/^backup=//p' "$journal" | tail -1)"
assert_file "$backup" "transaction records a pre-mutation backup"
before="$(cat "$journal")"
ac_maintenance_apply "$run/plan.json" "$run"
assert_eq "$(cat "$journal")" "$before" "replaying a complete transaction is idempotent"

# move-skill is a closed recoverable move, not a generic file rewrite: its live
# source is inferred from the reserved archive target, copied and hash-checked
# first, then removed. The sidecar rides in the same journaled plan.
move_run="$AC_HOME/data/curate-move"
mkdir -p "$AC_HOME/skills/movable" \
  "$move_run/staged/skills/skills-archive/movable"
printf 'movable skill\n' >"$AC_HOME/skills/movable/SKILL.md"
printf 'seeded_count=4\n' >"$AC_HOME/skills/movable/.usage.meta"
cp "$AC_HOME/skills/movable/SKILL.md" \
  "$move_run/staged/skills/skills-archive/movable/SKILL.md"
cp "$AC_HOME/skills/movable/.usage.meta" \
  "$move_run/staged/skills/skills-archive/movable/.usage.meta"
move_skill_sha="$(ac_sha256_file "$AC_HOME/skills/movable/SKILL.md")"
move_usage_sha="$(ac_sha256_file "$AC_HOME/skills/movable/.usage.meta")"
cat >"$move_run/plan.json" <<EOF
{"schema":"agentcrew.maintenance-plan/v1","mode":"curate","run_id":"curate-move","subject":"skill-movable","input_manifest_sha256":"$manifest_sha","actions":[{"op":"move-skill","target":"skills/skills-archive/movable/SKILL.md","old_sha256":"-","new_sha256":"$move_skill_sha","staged":"staged/skills/skills-archive/movable/SKILL.md"},{"op":"move-skill","target":"skills/skills-archive/movable/.usage.meta","old_sha256":"-","new_sha256":"$move_usage_sha","staged":"staged/skills/skills-archive/movable/.usage.meta"}]}
EOF
ac_maintenance_plan_validate "$move_run/plan.json" "$move_run"
ac_maintenance_apply "$move_run/plan.json" "$move_run"
assert_no_file "$AC_HOME/skills/movable" "move-skill removes the live directory only after archived files verify"
assert_eq "$(cat "$AC_HOME/skills/skills-archive/movable/SKILL.md")" \
  "movable skill" "move-skill preserves skill bytes"
assert_eq "$(ac_meta_get "$AC_HOME/skills/skills-archive/movable/.usage.meta" seeded_count)" \
  "4" "move-skill preserves usage telemetry"
move_journal="$AC_HOME/state/.maintenance-transactions/curate-move-skill-movable/journal"
move_before="$(cat "$move_journal")"
ac_maintenance_apply "$move_run/plan.json" "$move_run"
assert_eq "$(cat "$move_journal")" "$move_before" "completed move-skill replay is idempotent after the source is absent"

jq '.actions[0].target="skills/not-the-reserved-archive/movable/SKILL.md"' \
  "$move_run/plan.json" >"$move_run/bad-move.json"
if ac_maintenance_plan_validate "$move_run/bad-move.json" "$move_run" >/dev/null 2>&1; then
  fail "move-skill must refuse a target outside the reserved skills archive"
fi

# --- an INCOMPLETE transaction is nameable, resumable and droppable ----------
#
# The apply loop is sequential with NO atomicity across actions: whatever ran
# before a failure stays on disk. And an incomplete journal makes
# ac_maintenance_incomplete_other refuse EVERY other Learning/Curate
# transaction - so a crash between the status write and the final `complete`,
# or a plan whose second action fails, used to wedge the whole
# knowledge-maintenance loop forever: nothing named the wedged transaction and
# no CLI could perform the replay the header promises.
txroot="$AC_HOME/state/.maintenance-transactions"

# FACE 1 - the PARTIAL apply. Action 2's target already holds bytes matching
# neither its planned old_sha256 ("-": must not exist) nor its new_sha256, so
# the precondition refuses mid-plan with action 1 already committed.
part_run="$AC_HOME/data/learning-partial"
mkdir -p "$part_run/staged/skills/first" "$part_run/staged/skills/second"
printf 'first skill\n' >"$part_run/staged/skills/first/SKILL.md"
printf 'second skill\n' >"$part_run/staged/skills/second/SKILL.md"
first_sha="$(ac_sha256_file "$part_run/staged/skills/first/SKILL.md")"
second_sha="$(ac_sha256_file "$part_run/staged/skills/second/SKILL.md")"
mkdir -p "$AC_HOME/skills/second"
printf 'unexpected local edit\n' >"$AC_HOME/skills/second/SKILL.md"
cat >"$part_run/plan.json" <<EOF
{"schema":"agentcrew.maintenance-plan/v1","mode":"learning","run_id":"learning-partial","subject":"pair","input_manifest_sha256":"$manifest_sha","actions":[{"op":"write-skill","target":"skills/first/SKILL.md","old_sha256":"-","new_sha256":"$first_sha","staged":"staged/skills/first/SKILL.md"},{"op":"write-skill","target":"skills/second/SKILL.md","old_sha256":"-","new_sha256":"$second_sha","staged":"staged/skills/second/SKILL.md"}]}
EOF
held="$(ac_maintenance_apply "$part_run/plan.json" "$part_run" 2>&1)" \
  && fail "an action whose precondition fails must not report success"
assert_eq "$(cat "$AC_HOME/skills/first/SKILL.md")" "first skill" \
  "the first action IS committed - the apply has no atomicity across actions"
assert_contains "$held" "HELD" "a partial apply SAYS it is partial, never returns silently"
assert_contains "$held" "1 of its 2 action(s)" "and says exactly how much of the plan landed"
assert_contains "$held" "maintenance resume learning-partial-pair" "naming the exact resume command"
assert_contains "$held" "maintenance abandon learning-partial-pair" "and the exact drop command"

# It is WEDGED for everyone else while it sits there - the state F18 names.
part_journal="$txroot/learning-partial-pair/journal"
assert_eq "$(ac_meta_get "$part_journal" status)" "applying" "the held transaction stays claimed"
ac_maintenance_incomplete_other "$txroot" "$txroot/some-other-txn" \
  || fail "an incomplete transaction must block another one - that is what makes it wedging"

# ...and it is NAMED, which is what the session-start digest reads.
inc="$(ac_maintenance_incomplete "$txroot")"
assert_contains "$inc" "learning-partial-pair" "the incomplete transaction is enumerable by name"
assert_contains "$inc" "applying" "with the status that wedges the loop"

# RESUME replays the hash-bound plan: the committed action is skipped by hash
# and only the remaining one runs, once its cause is fixed.
rm -f "$AC_HOME/skills/second/SKILL.md"
"$BIN/ac-learn.sh" maintenance resume learning-partial-pair >/dev/null \
  || fail "resume must complete a held transaction whose cause is fixed"
assert_eq "$(cat "$AC_HOME/skills/second/SKILL.md")" "second skill" "the remaining action applied on resume"
assert_eq "$(ac_meta_get "$part_journal" status)" "complete" "and the transaction reached complete"
assert_eq "$(ac_maintenance_incomplete "$txroot")" "" "a completed transaction is no longer named"

# FACE 2 - the INTERRUPTED apply: a journal left at `applying` by a SIGKILL or
# a reboot, with no plan of its own left to finish. It wedges every other
# transaction until it is settled, and `abandon` is the settle-without-replay
# verb the fleet had no way to express.
mkdir -p "$txroot/learning-crashed-subject"
printf 'plan_sha256=deadbeef\nstatus=applying\n' >"$txroot/learning-crashed-subject/journal"
ac_maintenance_incomplete_other "$txroot" "$txroot/some-other-txn" \
  || fail "a crashed journal blocks every other transaction"
out="$("$BIN/ac-learn.sh" maintenance status)"
assert_contains "$out" "learning-crashed-subject" "status names the wedged transaction"
"$BIN/ac-learn.sh" maintenance abandon learning-crashed-subject >/dev/null \
  || fail "abandon must settle a transaction that cannot be resumed"
assert_eq "$(ac_meta_get "$txroot/learning-crashed-subject/journal" status)" "abandoned" \
  "abandon records the decision instead of deleting the record"
if ac_maintenance_incomplete_other "$txroot" "$txroot/some-other-txn"; then
  fail "an abandoned transaction must stop blocking the loop"
fi
assert_eq "$(ac_maintenance_incomplete "$txroot")" "" "and is no longer named as incomplete"
assert_contains "$("$BIN/ac-learn.sh" maintenance status)" "no incomplete" \
  "a clean loop SAYS so - silence is indistinguishable from a broken query"

# --- AC-1.4: ac_records_backup reaches crewdomain packages -------------------
# A crewdomain package holds mutable truth (its backlog and its projects detail)
# OUTSIDE records/, so without this it sits outside the reversibility floor.
# Extending the ONE shared function is what makes assign/unassign/learn/curate
# all inherit coverage. The package is built by hand here: this file tests the
# function's contract, not the verb that happens to create the layout.

mkdir -p "$AC_HOME/crewdomains/payments/records" "$AC_HOME/crewdomains/payments/projects"
mkdir -p "$AC_HOME/projects/alpha" "$AC_HOME/crewdeputies/demo"
printf 'clone content that must never be swallowed\n' >"$AC_HOME/projects/alpha/BIG.txt"
printf 'deputy private\n' >"$AC_HOME/crewdeputies/demo/secret.txt"
printf '# Backlog: payments\n' >"$AC_HOME/crewdomains/payments/records/backlog.md"
printf '# Projects: payments\n' >"$AC_HOME/crewdomains/payments/records/projects.md"
printf 'domain instructions\n' >"$AC_HOME/crewdomains/payments/CREWMATE.md"
ln -s "../../../projects/alpha" "$AC_HOME/crewdomains/payments/projects/alpha"
# A foreign directory under crewdomains/ needs no skip rule: the members are
# PATH-SPECIFIC, so one without the member paths simply contributes nothing.
mkdir -p "$AC_HOME/crewdomains/notapackage"

arc="$(ac_records_backup domaincover)"
assert_file "$arc" "AC-1.4: the backup archive is written"
for m in crewdomains/payments/records/backlog.md crewdomains/payments/records/projects.md \
         crewdomains/payments/CREWMATE.md; do
  tar -tzf "$arc" | grep -q "$m" || fail "AC-1.4: $m is inside the reversibility floor"
done

# The tar must NOT gain -h: projects/ is stored as LINKS, so a backup can never
# swallow a whole clone. This is the constraint that actually bites - the
# archive would otherwise grow by every repo in every domain's scope.
if tar -tzf "$arc" | grep -q 'BIG.txt'; then
  fail "AC-1.4: clone CONTENT leaked in - the tar dereferenced a projects/ symlink"
fi

# A crewdeputy home is a SEPARATE home with its own records/ and its own clones;
# it backs itself up against its own $AC_HOME and must never be dragged in here.
if tar -tzf "$arc" | grep -q 'crewdeputies/'; then
  fail "AC-1.4: the backup reached into \$AC_HOME/crewdeputies/"
fi

# CR-006 - the projects/ VIEW is authoritative membership state and the registry
# deliberately does not duplicate it, so an archive without it restores a domain
# that no longer knows which projects it may work.
tar -tzf "$arc" | grep -q 'crewdomains/payments/projects/alpha' \
  || fail "AC-1.4: the projects/ view is inside the reversibility floor"

# Members are home-relative, so a restore stays `tar -xzf <arc> -C <home>`.
rm -f "$AC_HOME/crewdomains/payments/CREWMATE.md"
tar -xzf "$arc" -C "$AC_HOME"
assert_eq "$(cat "$AC_HOME/crewdomains/payments/CREWMATE.md")" "domain instructions" \
  "AC-1.4: restoring the archive recreates the package member"
# ... and the view comes back as a LINK to the same clone, not as a copy of it.
rm -f "$AC_HOME/crewdomains/payments/projects/alpha"
tar -xzf "$arc" -C "$AC_HOME"
[ -L "$AC_HOME/crewdomains/payments/projects/alpha" ] \
  || fail "AC-1.4: the restored view entry is a SYMLINK, not a materialised clone"

pass
