#!/usr/bin/env bash
# ac-self-task.sh - make a SMALL chief-side edit VISIBLE. The authoritative
# spec for the chief-self-but-visible mechanism.
#
# Usage: ac-self-task.sh start <id> <project-name-or-dir>
#        ac-self-task.sh log <id> '<progress line>'
#
# THE RULE IT SERVES (records/captain.md, "No invisible tasks; small tasks
# chief-self but herdr-visible", 2026-07-21): no task may be done invisibly,
# and a task the CREWCHIEF does itself is still a task. A chief editing a
# one-line doc or config used to leave no trace on herdr at all - `start` is
# the one command that fixes exactly that, and nothing else.
#
# WHAT IT IS NOT. This is VISIBILITY, not an execution engine. It launches no
# harness, reads no brief, seeds no crewmate instructions, opens no room, runs
# no gate, no review and no stage. There is no promote tier below room and no
# config knob here. The CHIEF does the work in the leased worktree with its own
# hands, and the whole mechanism is: a lease, a pane, a meta, a progress log.
# It is NOT a way around the prime directive either - real project work still
# goes to a crewmate in its own worktree. `start` cannot enforce "small"; the
# chief's charter does.
#
# start <id> <project>  - in this order, and all of it BEFORE the first edit:
#   0. THE BRANCH COLLISION REFUSAL (contract: bin/ac-spawn.sh header, same
#      block name): a self task also commits on crew/<id> and lands via
#      ac-merge-local.sh, so it carries the identical hazard a dead or
#      --force'd task leaving crew/<family> behind creates for a crewmate
#      spawn. Refuses when crew/<family> resolves in the project repo and no
#      in-flight family task owns it (ac_family_owned, bin/ac-lib.sh - the SAME
#      predicate ac-spawn.sh's own refusal calls). Fires before the status
#      seed, the lease and the pane, so a refusal leaves nothing half-open, and
#      never touches the ref.
#   1. seed state/<id>.status, the progress log (the pane needs a file to tail),
#   2. lease a pooled worktree in the project repo (bin/ac-tree.sh get, holder
#      self:<id>) - the same pool a crewmate leases from, so the editor
#      workspace and `ac-tree.sh list` see it like any other task,
#   3. open the labelled herdr tab and run `tail -f` on the progress log in it -
#      the pane's ONLY job is to show the chief's own progress,
#   4. write the COMPLETE state/<id>.meta with kind=self.
#   Until step 4 an EXIT trap gives the lease back, reaps the tab and removes
#   the partial meta, so a failure leaves nothing half-open. The trap covers a
#   window that is a few syscalls wide - there is no harness to boot here, so
#   ac-spawn.sh's pre-meta claim (which exists for its AC_SPAWN_SETTLE-wide gap)
#   would be machinery with no gap to protect.
#
# log <id> '<line>'     - append one timestamped line to the progress log. The
#   pane is tailing it, and ac-crew-state.sh reports the LAST line (prefixed
#   `status| `, F13: a bare captain marker in that line must not read as a
#   fresh one from whichever pane is running the fleet view), so every
#   fleet view (ac-dash.sh, ac-fleets.sh, ac-fleet-view.sh) shows what the chief
#   is doing right now. Refuses on any kind but self: the crew status log is the
#   fleet's own record and this verb is not a way to write into it by hand.
#
# LANDING is the EXISTING path, unchanged: the chief creates/continues
# crew/<id> in the leased worktree, commits there, then
#   bin/ac-merge-local.sh <id>   (needs no kind - it reads project_dir/worktree)
#   bin/ac-teardown.sh <id>      (kind=self takes the ordinary committing-task
#                                 landed proof, and returns the lease)
# Nothing in either script needed a self case.
#
# SUPERVISION. The meta is EXCLUDED FROM SUPERVISION, NEVER FROM ACCOUNTING -
# the authoritative contract is the SELF-TASK class block in bin/ac-lib.sh
# (ac_meta_is_self). Short version: no agent lives in this pane, so the fleet
# must not demand a watcher for it and the watcher must not wake the chief about
# the chief's own typing; every dashboard still lists it, which is the point.
#
# On success `start` prints:
#   self-task <id> kind=self project=<name> backend=<b> window=<target> worktree=<path>

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-backend.sh"
ac_require git

bin_dir="$(cd "$(dirname "$0")" && pwd -P)"

verb="${1:-}"
case "$verb" in
  start|log) shift ;;
  *) ac_die "usage: ac-self-task.sh start <id> <project> | ac-self-task.sh log <id> '<line>'" ;;
esac

id="${1:-}"
[ -n "$id" ] || ac_die "usage: ac-self-task.sh $verb <id> ..."
# A locale whose collation interleaves case (en_US.UTF-8: a,A,b,B,...,z,Z) makes
# a plain a-z range admit most uppercase letters through this glob - force C
# collation, the same idiom ac-spawn.sh and ac-brief.sh use for the id.
(LC_ALL=C; case "$id" in *[!a-z0-9-]*) exit 1 ;; esac) || ac_die "id must be [a-z0-9-]: $id"

state_dir="$(ac_state_dir)"
meta="$state_dir/$id.meta"
status_file="$(ac_task_status "$id")"

if [ "$verb" = log ]; then
  line="${2:-}"
  [ -n "$line" ] || ac_die "usage: ac-self-task.sh log <id> '<line>'"
  [ -f "$meta" ] || ac_die "no self task for $id (start it first)"
  ac_meta_is_self "$meta" \
    || ac_die "$id is kind=$(ac_meta_get "$meta" kind), not self - only a self task's own progress log is written by hand"
  ac_status_append "$id" "$line"
  exit 0
fi

project="${2:-}"
[ -n "$project" ] || ac_die "usage: ac-self-task.sh start <id> <project-name-or-dir>"
[ -e "$meta" ] && ac_die "task $id already exists (see $meta); tear it down first"
project_dir="$(ac_project_dir "$project")" \
  || ac_die "project not found: $project (clone it into projects/ first)"
project_name="$(basename "$project_dir")"

# THE BRANCH COLLISION REFUSAL (contract: bin/ac-spawn.sh header, THE BRANCH
# COLLISION REFUSAL block). A self task commits on crew/<id> and lands via
# ac-merge-local.sh, the same as a crewmate spawn, so it carries the identical
# hazard: teardown deletes a crew branch only when it is MERGED, so a dead or
# --force'd task can leave crew/<family> behind for a later start to land onto
# by mistake. Resolved HERE, right after $project_dir resolves and before
# anything is created (the status seed, the lease, the pane), so a refusal
# leaves nothing half-open. ac_family_owned (bin/ac-lib.sh) is the SAME
# predicate ac-spawn.sh's own refusal calls - one shared home, not a copy.
crew_branch="$(ac_crew_branch "$id")"
crew_branch_sha="$(git -C "$project_dir" rev-parse --verify --quiet "refs/heads/$crew_branch" || true)"
if [ -n "$crew_branch_sha" ] && ! ac_family_owned "$id" "$state_dir"; then
  ac_die "$crew_branch already exists in $project_dir (${crew_branch_sha:0:12}) and NO task is in flight to own it - it outlived a dead or torn-down task (teardown deletes a crew branch only when it is MERGED), so starting $id would commit onto that foreign history and make its landing diff nonsense. Rename it or delete it - that is YOUR call, this start touches no ref:
  keep it:   git -C $project_dir branch -m $crew_branch $crew_branch-old
  drop it:   git -C $project_dir branch -D $crew_branch
then start again"
fi

AC_BACKEND="$(ac_config_read backend herdr)"
export AC_BACKEND
backend="$(ac_backend)"

window=""
self_cleanup() {
  "$bin_dir/ac-tree.sh" return "$worktree" --force >/dev/null 2>&1 || true
  rm -f "$meta"
  [ -z "$window" ] || backend_kill_window "$id" || true
}

# 1. The progress log, before the pane that tails it exists.
ac_status_append "$id" "working: self task started by the chief"

# 2. The lease.
worktree="$("$bin_dir/ac-tree.sh" get --repo "$project_dir" --id "$id" --holder "self:$id")"
trap self_cleanup EXIT

# 3. The pane. Refused rather than doubled when the backend cannot answer for an
# existing one - the three states are ac-backend.sh's (WINDOW LIVENESS).
alive_rc=0; backend_window_alive "$id" || alive_rc=$?
case "$alive_rc" in
  0) ac_die "window $(backend_target "$id") already exists" ;;
  2) ac_die "the BACKEND could not be READ for $id - whether $(backend_target "$id") still exists is UNKNOWN, so this is REFUSED rather than open a second window beside a possibly LIVE one; check the backend itself (herdr status server), then try again" ;;
esac
# A self task is the chief's own fleet-level work: its tail tab lives in the
# fleet ROOT workspace (AC_WINDOW_FAMILY set EMPTY = deliberately the root;
# ac-backend.sh FAMILY WORKSPACE GROUPING), never in a family's space.
AC_WINDOW_FAMILY="" backend_window_new "$id" "$worktree"
window="$(backend_target "$id")"
backend_send_line "$id" "tail -f $(printf '%q' "$status_file")" \
  || ac_warn "the pane may not have started tailing $status_file - peek it (bin/ac-peek.sh $id)"

# 4. The complete meta.
ac_meta_set "$meta" backend "$backend"
ac_meta_set "$meta" window "$window"
ac_meta_set "$meta" worktree "$worktree"
ac_meta_set "$meta" leases "$worktree"
ac_meta_set "$meta" lease_ids \
  "$(ac_meta_get "$project_dir/.crew/slots/$(basename "$worktree").meta" lease_id)"
ac_meta_set "$meta" project "$project_name"
ac_meta_set "$meta" project_dir "$project_dir"
ac_meta_set "$meta" kind "self"
# A self task lands with bin/ac-merge-local.sh, which is what local-only means;
# the project registry's default mode describes crewmate delivery, not this.
ac_meta_set "$meta" mode "local-only"
ac_meta_set "$meta" spawned_at "$(ac_iso)"
trap - EXIT

printf 'self-task %s kind=self project=%s backend=%s window=%s worktree=%s\n' \
  "$id" "$project_name" "$backend" "$window" "$worktree"
