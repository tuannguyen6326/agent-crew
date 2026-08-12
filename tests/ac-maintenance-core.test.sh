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
manifest_sha="$(printf 'manifest\n' | shasum -a 256 | awk '{print $1}')"
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
## Proposed Process
Apply the hash-bound maintenance plan.
EOF
printf 'manifest\n' >"$run/manifest"
assert_eq "$(ac_maintenance_receipt_validate "$run/decision.md" "$run/plan.json" "$run/manifest")" \
  "continue" "hash-bound maintenance receipt validates"
sed 's/action_plan_sha256: \".*\"/action_plan_sha256: \"bad\"/' \
  "$run/decision.md" >"$run/bad-decision.md"
if ac_maintenance_receipt_validate "$run/bad-decision.md" "$run/plan.json" "$run/manifest" >/dev/null 2>&1; then
  fail "a receipt with a mismatched action-plan hash must not authorize apply"
fi

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
