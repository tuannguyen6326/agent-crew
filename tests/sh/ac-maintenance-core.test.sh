#!/usr/bin/env bash
# ac-maintenance-core.test.sh - the maintenance surface that is still live in
# bash: the cadence readers and the incomplete-transaction reader in
# bin/ac-maintenance-lib.sh, which bin/ac-session-start.sh sources, and the
# `ac-learn.sh maintenance` verbs that settle a held transaction. The writer
# that SEEDS a transaction held mid-plan is maintenanceApply
# (src/lib-curate.ts), the one Learning and Curate call.
. "$(dirname "$0")/helpers.sh" \
  || { printf 'run this suite from tests/sh/ (helpers.sh not found)\n' >&2; exit 1; }

# shellcheck source=../../bin/ac-lib.sh
. "$BIN/ac-lib.sh"
. "$BIN/ac-maintenance-lib.sh"
make_home

printf 'stows=4\nlast_run=10\n' >"$AC_HOME/state/.learn.meta"
assert_eq "$(ac_learn_due)" "4 8" "legacy Learning cadence remains readable"
printf 'runs_since=3\n' >"$AC_HOME/state/.curate.meta"
assert_eq "$(ac_curate_due)" "3 5" "legacy Curate cadence remains readable"

run="$AC_HOME/data/learning-1"
mkdir -p "$run"
cat >"$run/manifest" <<'EOF'
kind: skill
name: example
===skill===
A candidate line that exists nowhere but inside this manifest.
EOF
manifest_sha="$(ac_sha256_file "$run/manifest")"

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
(cd "$ROOT" && bun --no-env-file -e "const L = await import('./src/lib-curate.ts'); process.exit(L.maintenanceApply(process.argv[1], process.argv[2]) ? 0 : 1);" "$part_run/plan.json" "$part_run") >/dev/null 2>&1 \
  && fail "the seed must leave the transaction held, not complete"

# It is WEDGED for everyone else while it sits there - the state F18 names.
part_journal="$txroot/learning-partial-pair/journal"
assert_eq "$(ac_meta_get "$part_journal" status)" "applying" "the held transaction stays claimed"
assert_eq "$(ac_meta_get "$part_journal" held_committed)" "1" "the hold records the one action already committed"

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
out="$("$BIN/ac-learn.sh" maintenance status)"
assert_contains "$out" "learning-crashed-subject" "status names the wedged transaction"
"$BIN/ac-learn.sh" maintenance abandon learning-crashed-subject >/dev/null \
  || fail "abandon must settle a transaction that cannot be resumed"
assert_eq "$(ac_meta_get "$txroot/learning-crashed-subject/journal" status)" "abandoned" \
  "abandon records the decision instead of deleting the record"
assert_eq "$(ac_maintenance_incomplete "$txroot")" "" "and is no longer named as incomplete"
assert_contains "$("$BIN/ac-learn.sh" maintenance status)" "no incomplete" \
  "a clean loop SAYS so - silence is indistinguishable from a broken query"

# --- a plan that rewrites records/backlog.md takes the ledger lock too ------
# bug-shaped-rows.md's W5 remainder (src/curate.ts header): the automatic
# Learning/Curate run commits records/backlog.md through maintenanceApply,
# so it must exclude a live records/.backlog.md.lock holder exactly as every
# other ledger writer does (ac-task.sh/ac-domain.sh/deputy.ts/
# `backlog --apply`) - never let the hash-checked mv land underneath a
# concurrent ac-task.sh move.
bl_run="$AC_HOME/data/learning-backlog"
mkdir -p "$bl_run/staged/records"
printf '## In flight\n\n## Queued\n\n## Done\n' >"$AC_HOME/records/backlog.md"
bl_old="$(ac_sha256_file "$AC_HOME/records/backlog.md")"
printf '## In flight\n\n## Queued\n\n## Done\n\n- [x] curated-row\n' >"$bl_run/staged/records/backlog.md"
bl_new="$(ac_sha256_file "$bl_run/staged/records/backlog.md")"
cat >"$bl_run/plan.json" <<EOF
{"schema":"agentcrew.maintenance-plan/v1","mode":"curate","run_id":"learning-backlog","subject":"bl","input_manifest_sha256":"$manifest_sha","actions":[{"op":"rewrite-ledger","target":"records/backlog.md","old_sha256":"$bl_old","new_sha256":"$bl_new","staged":"staged/records/backlog.md"}]}
EOF
bl_before="$(cat "$AC_HOME/records/backlog.md")"
mkdir "$AC_HOME/records/.backlog.md.lock"; printf '%s\n' "$$" >"$AC_HOME/records/.backlog.md.lock/pid"
(cd "$ROOT" && AC_TASK_LOCK_TIMEOUT=1 bun --no-env-file -e "const L = await import('./src/lib-curate.ts'); process.exit(L.maintenanceApply(process.argv[1], process.argv[2]) ? 0 : 1);" "$bl_run/plan.json" "$bl_run") >/dev/null 2>&1 \
  && fail "a live records/.backlog.md.lock holder must refuse the transaction, not let it write backlog.md"
assert_eq "$(cat "$AC_HOME/records/backlog.md")" "$bl_before" "backlog.md is untouched while the ledger lock is held"
bl_journal="$txroot/learning-backlog-bl/journal"
assert_eq "$(ac_meta_get "$bl_journal" status)" "applying" "...and the transaction is HELD, not completed, so it can be resumed"
assert_contains "$(ac_meta_get "$bl_journal" held_reason)" ".backlog.md.lock" "...HELD for the ledger lock specifically, not some other cause"
assert_eq "$(cat "$AC_HOME/records/.backlog.md.lock/pid")" "$$" "...and the ledger lock's own holder is left as it was"
rm -rf "$AC_HOME/records/.backlog.md.lock"
(cd "$ROOT" && bun --no-env-file -e "const L = await import('./src/lib-curate.ts'); process.exit(L.maintenanceApply(process.argv[1], process.argv[2]) ? 0 : 1);" "$bl_run/plan.json" "$bl_run") >/dev/null \
  || fail "the unlocked retry must complete once the ledger lock clears"
assert_eq "$(cat "$AC_HOME/records/backlog.md")" "$(cat "$bl_run/staged/records/backlog.md")" "...and backlog.md is rewritten once the lock clears"
assert_eq "$(ac_meta_get "$bl_journal" status)" "complete" "...with the transaction reaching complete"
[ ! -e "$AC_HOME/records/.backlog.md.lock" ] || fail "maintenanceApply releases records/.backlog.md.lock itself on success too, not leaves it for process exit"

# The lock must come back off on a HOLD too, not only on success - it is
# released by maintenanceApply itself (never left for process exit, since
# Learning keeps running after a HELD call returns false).
blh_run="$AC_HOME/data/learning-backlog-hold"
mkdir -p "$blh_run/staged/records" "$blh_run/staged/skills/ghost"
printf '## In flight\n\n## Queued\n\n## Done\n' >"$AC_HOME/records/backlog.md"
blh_old="$(ac_sha256_file "$AC_HOME/records/backlog.md")"
printf '## In flight\n\n## Queued\n\n## Done\n\n- [x] another-row\n' >"$blh_run/staged/records/backlog.md"
blh_new="$(ac_sha256_file "$blh_run/staged/records/backlog.md")"
printf 'ghost skill\n' >"$blh_run/staged/skills/ghost/SKILL.md"
ghost_sha="$(ac_sha256_file "$blh_run/staged/skills/ghost/SKILL.md")"
cat >"$blh_run/plan.json" <<EOF
{"schema":"agentcrew.maintenance-plan/v1","mode":"curate","run_id":"learning-backlog-hold","subject":"blh","input_manifest_sha256":"$manifest_sha","actions":[{"op":"rewrite-ledger","target":"records/backlog.md","old_sha256":"$blh_old","new_sha256":"$blh_new","staged":"staged/records/backlog.md"},{"op":"write-skill","target":"skills/ghost/SKILL.md","old_sha256":"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef","new_sha256":"$ghost_sha","staged":"staged/skills/ghost/SKILL.md"}]}
EOF
(cd "$ROOT" && bun --no-env-file -e "const L = await import('./src/lib-curate.ts'); process.exit(L.maintenanceApply(process.argv[1], process.argv[2]) ? 0 : 1);" "$blh_run/plan.json" "$blh_run") >/dev/null 2>&1 \
  && fail "the second action's stale old_sha256 must hold the transaction"
assert_eq "$(cat "$AC_HOME/records/backlog.md")" "$(cat "$blh_run/staged/records/backlog.md")" "the first action (backlog.md) still committed before the second held"
assert_eq "$(ac_meta_get "$txroot/learning-backlog-hold-blh/journal" status)" "applying" "the transaction is HELD on the second action"
[ ! -e "$AC_HOME/records/.backlog.md.lock" ] || fail "the ledger lock is released on a HOLD too, not left until process exit"
pass
