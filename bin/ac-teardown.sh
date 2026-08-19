#!/usr/bin/env bash
# ac-teardown.sh - fail-closed teardown of a finished crewmate.
#
# Usage: ac-teardown.sh <id> [--force]
#
# Refuses to destroy evidence of unlanded work. Without --force it requires:
# - scout tasks: the report exists (report.md in the task's data dir - flat
#   data/<id>/ or the nested staged dir ac_task_dir resolves; a merged
#   `--stage design` scout instead proves ANY of its sub-stage reports at
#   data/<family>/{spec,arch,plan}/report.md, since it keeps only ONE brief at
#   design/ and writes no design/report.md), AND any crew/<id>
#   branch the scout created is landed (same containment proof as ship
#   tasks) - a scout steered mid-flight into writing code cannot have its
#   committed work silently discarded; ac-promote.sh <id> converts it to a
#   ship task instead - and when it created NO branch, its worktree is clean
#   (the ship sibling's rule, mirrored: uncommitted work dies just as silently
#   at the pool return);
# - ship tasks: the work is landed - the crew/<id> branch head is contained in
#   the default branch (local or origin), reachable from any remote branch, or
#   the recorded PR was merged (pr_merged=1 in the meta) - and the worktree is
#   clean.
# --force means "the captain explicitly discards this work".
#
# On success: archives the task's state files under state/archive/<id>/, kills
# the backend window, ends the pane agents/verifiers the task started, returns
# every leased worktree to the in-repo pool, deletes a merged crew/<id> branch,
# and tears down any qa infra. A direct verifier teardown skips the ship landed
# proof: it archives verifier identity first, reaps its exact pane handle, and
# returns only leases named by that verifier record. Both paths call the
# shared reap_watcher_stamps: the watcher polls and stamps EVERY meta including
# verify-* ones (excluded from ACCOUNTING, never from SUPERVISION), so a
# verifier accumulates the same .change-<id>/.hash-<id>/etc litter a crewmate
# does - the verifier branch's early exit used to skip removing them entirely.
#
# VERIFIER SWEEP: modern verifier records bind ownership with caller=<task-id>;
# family fallback is accepted only for a legacy record with no caller. This
# prevents one execution task from reaping a same-family co-tenant. Execution
# teardown preflights incomplete QA after the landed proof and before archiving
# its own meta - both sides are the contract: verdict,
# relay report, and run-state must already be complete, or teardown first writes
# a durable incomplete-run artifact with verifier metadata and any recoverable
# partial evidence. Only then may it archive/reap the linked verifier.
#
# PANE-AGENT SWEEP (the authoritative contract): teardown ENDS the pane agents
# the task started and kills its qa serve process group. The ship reviewer's
# <run>/review.pane, the ship/qa dashboards' <run>/watch.pane, the qa agent's
# .crew/qa/agent-<task>.pane and the qa server's <run>/serve.pid are otherwise
# retired ONLY by ac-ship.sh / ac-qa.sh finish - and a crewmate killed by
# backend_kill_window never reaches finish, so those panes and that process
# survived the teardown (captain-caught twice). Same premise as the qa-infra
# step below: traps do not fire when a pane is killed, so teardown owns it.
# ORDER: the sweep runs BEFORE the lease goes back. A pool worktree is RESET and
# REUSED, never deleted (bin/ac-tree.sh), and its reset rm -rf's .crew/qa - so
# after the return there is no record left to reap from, and ac-pane-agent.sh
# reap's dead-cwd predicate can never fire for a torn-down task either. Only
# `reap-pane --pane <id>`, run while the run dirs are still readable, can do it.
# ATTRIBUTION: run dirs are keyed by run id, not by task, so a qa run is claimed
# by task= and a ship run by branch=crew/<id> in its run.meta. A run naming
# ANOTHER task is left alone; a run naming NO ONE is WARNED by pane id AND path,
# never reaped - over-reaping a co-tenant's pane is worse than the leak this
# closes, and silence is what let the leak recur.
# Every step is best-effort and layered like ac-learn.sh's scout reap: an absent
# herdr, a stale pane id or a dead pid degrades to a warning, and none of it can
# change teardown's exit status or its fail-closed landed-work gate. TWO
# different failures are warned SEPARATELY, because reap-pane always exits 0 and
# its status therefore carries no outcome (ac-pane-agent.sh REAP OUTCOME): being
# unable to ATTEMPT, and an attempt that did NOT take (`"closed":false`). The
# second one was swallowed, which is why orphaned pane agents were found by a
# captain rather than reported by the sweep that ran over them.
#
# ORDER GUARANTEE - the state archive is the FIRST durable act of teardown
# proper, run after the landed proof - only the verifier evidence preflight
# (VERIFIER SWEEP above, itself now inside the gate) sits between them, and it
# destroys nothing - and BEFORE the pane-kill. The pane-kill step has ended
# this script three times on record (exit 144, no output, at the kill step and
# at the qa-infra step); while the archive ran last, such a death left
# state/<id>.meta and state/<id>.status behind, so the fleet survey kept listing
# a torn-down task, the monitor raised crew-signal-stale, and the meta had to be
# moved by hand. Archiving first makes the fleet's durable INDEX correct before
# anything that can kill the run. Trapping the signal is still NOT the fix and
# never replaced ordering: no trap survives a SIGKILL and the killer behind the
# recorded 144s is undiagnosed, so ORDER stays the only signal-agnostic
# guarantee. What the qa-infra step now carries is an EVIDENCE trap (below), and
# only that - the claim that a SIGURG trap "changes nothing" was falsified on
# this host (bash 3.2 runs a URG handler; tests/ac-spawn-teardown.test.sh
# delivers the signal and proves it), so a signal at that step names itself
# instead of ending the run in silence.
# The gate is unaffected: nothing durable happens on the refusal path.
# What a death AFTER the archive leaves - the worktree lease (visible as
# `leased <id>` in ac-tree.sh list, reclaimed with ac-tree.sh return <wt>
# --force), a merged crew/<id> branch (git branch -d), and any qa stack
# (ac-qa.sh infra down --task <id>). All three are inspectable and reclaimable
# with the pool's own verbs, and none of them fakes a live crewmate. Re-running
# teardown then refuses with "no crewmate meta" - safe, never double-acting,
# but it no longer finishes a partial run: the residue above is the recovery.
#
# QA-INFRA SWEEP (the last step, bounded): the sweep runs under a watchdog
# (default 30s; AC_TEARDOWN_QA_TIMEOUT is a test-only shortener, not a config
# knob), so an unusable OR HUNG docker degrades to skip+warn instead of parking
# the run before the completion line and the roomchief advisory. A docker that
# merely FAILS is no longer swallowed either - ac-qa.sh `infra down` returns the
# compose status - so a broken docker warns instead of passing for a clean
# sweep, at the cost of one WARN line on a box whose docker daemon is simply
# off. The warning always names the reclaim command; the killed child's docker
# grandchild is orphaned, not reaped. Signals at this step are trapped for
# EVIDENCE only: the handler names the signal and the step, then restores the
# default disposition and re-raises it, so the death itself is unchanged.
#
# ROOMCHIEF DEMOTE - who counts as family. The demote refuses while any member
# of <fam> is in flight, and membership is AUTHORITATIVE, never an id PREFIX:
# ac_family_of_id (the fleet's grammar owner, over the CLOSED stage/revision
# suffix set) OR the pane's own fleet_scope, recorded at spawn - the same pair
# ac-watch.sh's skip_family decides by, and the rule AGENTS.md states for epic
# membership. An open `<fam>-*` glob made an UNRELATED family whose id merely
# starts with this one block the demote (the distro's own fixed `learning` room
# against a `learning-curate-automation` epic - reachable by construction, not
# by unlucky naming), and the cascade - room unclosable, stuck in HANDBACK,
# turn-end guard refusing - took a --force on a family with nothing unlanded.
# Still fail-closed: a real member blocks, and fleet_scope catches an epic
# story whose id matches no suffix rule at all.
#
# Demoting a roomchief also prints one ADVISORY line naming the next queued
# family (ac-ready.sh queued), because archiving the chief meta is what frees
# a room-parallel slot (cap contract: the ac-spawn.sh header). Advisory only -
# it never spawns; the crewchief stays the scheduler.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-backend.sh"
ac_require git

bin_dir="$(cd "$(dirname "$0")" && pwd -P)"

id="${1:-}"; force=0
[ -n "$id" ] || ac_die "usage: ac-teardown.sh <id> [--force]"
[ "${2:-}" = "--force" ] && force=1

state_dir="$(ac_state_dir)"
meta="$(ac_task_meta "$id")"
[ -f "$meta" ] || ac_die "no crewmate meta for $id"

kind="$(ac_meta_get "$meta" kind)"
worktree="$(ac_meta_get "$meta" worktree)"
# Every lease the task took (grammar: the LEASES block in ac-spawn.sh). Read
# here, with the rest of the meta - it is archived long before the return.
leases="$(ac_meta_get "$meta" leases)"
[ -n "$leases" ] || leases="$worktree"   # pre-leases meta: worktree= is the list
# One acquisition identity per lease, same order (grammar: the LEASES block in
# ac-spawn.sh). Empty for a meta or a pool that predates it, and then the
# return stays unconditional exactly as before.
lease_ids="$(ac_meta_get "$meta" lease_ids)"
project_dir="$(ac_meta_get "$meta" project_dir)"
branch="$(ac_crew_branch "$id")"
AC_BACKEND="$(ac_task_backend "$id")"; export AC_BACKEND

crew_branch_head() {
  # Tip of crew/<id>: the project repo first, else the task worktree (the
  # branch may only exist there). Prints empty when it was never created.
  local h
  h="$(git -C "$project_dir" rev-parse --verify --quiet "refs/heads/$branch" || true)"
  if [ -z "$h" ] && [ -d "$worktree" ]; then
    h="$(git -C "$worktree" rev-parse --verify --quiet "refs/heads/$branch" || true)"
  fi
  printf '%s\n' "$h"
}

scout_report_present() {
  # scout_report_present <id> <task_dir> - does the scout's report exist?
  # A plain scout writes report.md in its own dir. A merged `--stage design`
  # scout keeps its ONE brief at <family>/design/ but writes each sub-stage
  # report at <family>/{spec,arch,plan}/report.md - never design/report.md -
  # so its delivery proof is ANY of those sub-stage reports. Mirrors the
  # brief-side resolution in ac-gate.sh (one owner per side of the layout).
  local id="$1" dir="$2" fam s
  [ -f "$dir/report.md" ] && return 0
  case "$id" in
    *-design | *-design-r[0-9] | *-design-r[0-9][0-9])
      fam="$(dirname "$dir")"   # data/<family>/design[-rN] -> data/<family>
      for s in spec arch plan; do
        [ -f "$fam/$s/report.md" ] && return 0
      done ;;
  esac
  return 1
}

head_landed() {
  # head_landed <sha> - the ONE landed-containment proof, shared by every
  # kind that can hold commits on crew/<id>: the recorded PR merged
  # (pr_merged=1), the head contained in the default branch - LOCAL or
  # origin, either one is proof - or reachable from any remote branch.
  #
  # Both refs count because the delivery mode decides WHERE landed work
  # lives: a local-only project never pushes, so its landing is a ff-merge
  # into LOCAL <branch> that leaves origin/<branch> stale; push-mode
  # projects (crew-ship, direct-pr) land on origin. Checking only the
  # freshest ref (ac_default_ref: origin wins) reported a local-only
  # project's fully merged work as unlanded.
  local head="$1" ref eb ebranch
  [ "$(ac_meta_get "$meta" pr_merged)" = "1" ] && return 0
  for ref in "$(ac_default_branch "$project_dir")" "$(ac_default_ref "$project_dir")"; do
    if git -C "$project_dir" merge-base --is-ancestor "$head" "$ref" 2>/dev/null; then
      return 0
    fi
  done
  # Epic-target landing (epic-branch-mech): a story lands into its epic's
  # recorded integration branch, which on a local-only repo exists ONLY
  # locally - containment there is landed proof exactly like the default's,
  # or every epic-landed story becomes an "unlanded" --force trap.
  if eb="$(ac_epic_base_for "$id" "$(basename "$project_dir")" 2>/dev/null)"; then
    ebranch="${eb%% *}"
    for ref in "refs/heads/$ebranch" "refs/remotes/origin/$ebranch"; do
      if git -C "$project_dir" merge-base --is-ancestor "$head" "$ref" 2>/dev/null; then
        return 0
      fi
    done
  fi
  [ -n "$(git -C "$project_dir" branch -r --contains "$head" 2>/dev/null)" ] && return 0
  return 1
}

landed_proof() {
  if [ "$kind" = roomchief ]; then
    # Demotion requires the family to be fully landed first.
    local fam other m2
    fam="${id%-chief}"
    for m2 in "$state_dir"/*.meta; do
      [ -e "$m2" ] || continue
      # A VERIFICATION agent is not crew (ac_meta_is_verify owns the class):
      # nobody tears one down, so counting it would strand the roomchief
      # undemotable and its room unclosable.
      ac_meta_is_verify "$m2" && continue
      other="$(basename "$m2" .meta)"
      [ "$other" = "$id" ] && continue
      # Membership is AUTHORITATIVE, never an id prefix (the ROOMCHIEF DEMOTE
      # block in this header owns the rule and why): the closed suffix grammar
      # OR the pane's own fleet_scope.
      if [ "$(ac_family_of_id "$other")" = "$fam" ] \
        || [ "$(ac_meta_get "$m2" fleet_scope)" = "$fam" ]; then
        printf 'family %s still has crew in flight: %s\n' "$fam" "$other" >&2
        return 1
      fi
    done
    return 0
  fi
  if [ "$kind" = crewdeputy ]; then
    # A crewdeputy's home must not hold crew in flight.
    if ls "$worktree/state/"*.meta >/dev/null 2>&1; then
      printf 'crewdeputy home still has crew in flight: %s/state/*.meta\n' "$worktree" >&2
      return 1
    fi
    return 0
  fi
  if [ "$kind" = scout ]; then
    # Staged-flow scouts nest under their family (ac_task_dir resolves both).
    # The resolver's ambiguity die exits the substitution, not this function
    # (landed_proof runs errexit-suppressed) - propagate it as a refusal.
    local task_dir shead
    task_dir="$(ac_task_dir "$id")" || return 1
    if ! scout_report_present "$id" "$task_dir"; then
      printf 'scout report missing: no report.md at %s (nor merged-design sub-stage reports)\n' "$task_dir" >&2
      return 1
    fi
    # Backstop: a scout steered mid-flight into writing code may hold
    # committed work on crew/<id>; the report alone must not land that.
    shead="$(crew_branch_head)"
    if [ -n "$shead" ] && ! head_landed "$shead"; then
      printf 'scout created %s with unlanded work; promote it (ac-promote.sh %s) or --force to discard\n' \
        "$branch" "$id" >&2
      return 1
    fi
    # The ship sibling's rule, mirrored: work the scout EDITED but never
    # committed dies just as silently at the pool return.
    if [ -z "$shead" ] && [ -d "$worktree" ] \
      && [ -n "$(git -C "$worktree" status --porcelain 2>/dev/null)" ]; then
      printf 'worktree is dirty and no %s branch exists\n' "$branch" >&2
      return 1
    fi
    return 0
  fi
  # Ship task: landed proof on the crew branch head, plus a clean worktree.
  local head
  head="$(crew_branch_head)"
  if [ -z "$head" ]; then
    # No branch was created; a clean worktree at default HEAD holds nothing.
    if [ -d "$worktree" ] && [ -n "$(git -C "$worktree" status --porcelain 2>/dev/null)" ]; then
      printf 'worktree is dirty and no %s branch exists\n' "$branch" >&2
      return 1
    fi
    return 0
  fi
  head_landed "$head" && return 0
  printf 'branch %s (%s) is not landed: not in %s (local or origin), no containing remote branch, no merged PR\n' \
    "$branch" "${head:0:12}" "$(ac_default_branch "$project_dir")" >&2
  if [ -d "$worktree" ] && [ -n "$(git -C "$worktree" status --porcelain 2>/dev/null)" ]; then
    printf 'worktree also has uncommitted changes\n' >&2
  fi
  return 1
}

reap_watcher_stamps() {
  # reap_watcher_stamps <id> - remove the watcher's per-id state files. Shared
  # by BOTH teardown paths (the verifier branch below, and the normal
  # crewmate/roomchief path further down): the watcher polls and stamps every
  # meta INCLUDING verify-* ones (ac_meta_is_verify excludes a verifier from
  # ACCOUNTING, never from SUPERVISION - contract: ac-lib.sh), so a verifier
  # accumulates the same .change-<id>/.hash-<id>/etc stamps a crewmate does,
  # and until this existed nothing ever removed them for a verifier - 11
  # orphan .change-* stamps observed live, every one a verify-codereview id.
  # The stamp SET is ac_task_stamps' one list (ac-lib.sh, audit-f4): the hand
  # copy that used to sit here had already drifted a second time, missing
  # .seen-hash-/.report-hash-/.superseded- entirely.
  local tid="$1" s
  while IFS= read -r s; do rm -f "$s"; done \
    < <(ac_task_stamps "$state_dir" "$tid")
}

reap_pane_file() {
  # reap_pane_file <file> - close the pane a run recorded, then drop the
  # record. reap-pane is best-effort and always exits 0 (ac-pane-agent.sh), so
  # its EXIT STATUS carries no outcome and two different failures have to be
  # surfaced separately: being unable to ATTEMPT at all - warned by pane id and
  # path, with the record kept so a later attempt still has it - and an attempt
  # that did NOT take, which the helper reports as `"closed":false` (contract:
  # ac-pane-agent.sh REAP OUTCOME) and which is warned by pane id and the exact
  # command to finish the job by hand. Swallowing that second one is why
  # orphaned pane agents went unnoticed until a captain found them.
  local f="$1" p out
  [ -f "$f" ] || return 0
  # Verifier handles publish "<pane> <tab>" atomically; historical run-local
  # pane files contain only the pane. The first field is the shared grammar.
  if p="$(awk 'NR == 1 { print $1 }' "$f" 2>/dev/null)"; then
    # A file with no first field is a normal, nothing-to-reap state (distinct
    # from a file that could not be read, which now warns below) - stay silent.
    [ -n "$p" ] || { rm -f "$f"; return 0; }
  else
    ac_warn "could not read $f: the pane could not be identified, it may be orphaned"
    return 0
  fi
  if [ -x "$bin_dir/ac-pane-agent.sh" ] && command -v herdr >/dev/null 2>&1; then
    out="$("$bin_dir/ac-pane-agent.sh" reap-pane --pane "$p" 2>/dev/null)" || true
    case "$out" in
      *'"closed":false'*)
        ac_warn "pane $p ($f) did not close - it is orphaned in the pane-agent workspace; retire it by hand: ac-pane-agent.sh reap-pane --pane $p" ;;
    esac
    rm -f "$f"
  else
    ac_warn "could not reap pane $p ($f): herdr or ac-pane-agent.sh unavailable"
  fi
  return 0
}

kill_serve_pid() {
  # kill_serve_pid <file> - end the qa server's PROCESS GROUP. serve runs under
  # `set -m`, so pgid == the recorded pid (ac-qa.sh cmd_serve); killing only the
  # wrapper leaves the real server orphaned. kill -0 first: never signal a
  # recycled pid.
  local f="$1" pid
  [ -f "$f" ] || return 0
  if pid="$(cat "$f" 2>/dev/null)"; then
    if [ -z "$pid" ]; then
      :  # an empty pid file is a normal, nothing-to-retire state (distinct
         # from a file that could not be read, which now warns below) - silent.
    elif kill -0 "$pid" 2>/dev/null; then
      kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null \
        || ac_warn "could not kill qa serve pid $pid ($f)"
    else
      ac_warn "qa serve pid $pid already gone ($f)"
    fi
    rm -f "$f"
  else
    ac_warn "could not read $f: a qa serve process may still be running and could not be identified"
  fi
  return 0
}

warn_unattributed() {
  # warn_unattributed <run-dir> - a run whose meta names no task/branch cannot
  # be proved OURS, so nothing in it is reaped; say what was left and where.
  local rd="$1" f
  for f in review.pane watch.pane serve.pid; do
    [ -f "$rd/$f" ] || continue
    ac_warn "not reaping $(cat "$rd/$f" 2>/dev/null) - run $rd is attributed to no task ($rd/$f)"
  done
  return 0
}

sanitize_task() {
  # The qa agent pane file is keyed agent-<sanitized-task>.pane; ac-qa.sh
  # sanitize_compose owns that grammar (docker compose project-name charset).
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-'
}

verifier_owned_by_task() {
  # verifier_owned_by_task <meta> - modern records bind caller= exactly.
  # Family fallback is legacy-only: use it only when caller is absent, never
  # to reap a co-tenant that explicitly names another execution caller.
  local vm="$1" caller family task_family
  caller="$(ac_meta_get "$vm" caller)"
  [ "$caller" = "$id" ] && return 0
  [ -z "$caller" ] || return 1
  family="$(ac_meta_get "$vm" family)"
  task_family="$(ac_family_of_id "$id")"
  [ -n "$family" ] && [ "$family" = "$task_family" ]
}

qa_verifier_evidence_complete() {
  local vm="$1" evidence
  evidence="$(ac_meta_get "$vm" evidence)"
  [ -n "$evidence" ] \
    && [ -s "$evidence/verdict.json" ] \
    && [ -s "$evidence/relay-report.md" ] \
    && [ -d "$evidence/run-state" ]
}

preserve_incomplete_qa_verifier() {
  # Explicit teardown may clean an incomplete QA verifier only after producing
  # a durable caller-visible artifact. Normal ac-verify retry remains stricter
  # and refuses to reap incomplete evidence.
  local vm="$1" vid="$2" evidence family output pane_result tree current run tmp
  [ "$(ac_meta_get "$vm" kind)" = verify-qa ] || return 0
  qa_verifier_evidence_complete "$vm" && return 0
  family="$(ac_meta_get "$vm" family)"
  evidence="$(ac_meta_get "$vm" evidence)"
  [ -n "$evidence" ] || evidence="$(ac_data_dir)/${family:-unknown}/verification/$vid-incomplete-$(ac_now)"
  mkdir -p "$evidence" \
    || ac_die "cannot preserve incomplete QA verifier $vid at $evidence"
  cp "$vm" "$evidence/verifier.meta" \
    || ac_die "cannot preserve verifier meta for incomplete QA $vid"
  output="$(ac_meta_get "$vm" output)"
  pane_result="$(ac_meta_get "$vm" pane_result)"
  [ ! -f "$output" ] || cp "$output" "$evidence/verdict.partial.json"
  [ ! -f "$pane_result" ] || cp "$pane_result" "$evidence/pane-result.ndjson"
  tree="$(ac_meta_get "$vm" worktree)"
  current="$tree/.crew/qa/current"
  run=""
  if [ -L "$current" ]; then
    run="$tree/.crew/qa/$(readlink "$current")"
  elif [ -d "$current" ]; then
    run="$current"
  fi
  if [ -n "$run" ] && [ -d "$run" ] && [ ! -d "$evidence/run-state" ]; then
    mkdir -p "$evidence/run-state"
    cp -R "$run/." "$evidence/run-state/" \
      || ac_die "cannot preserve QA run state for incomplete verifier $vid"
  fi
  tmp="$evidence/incomplete-run.md.tmp.$$"
  {
    printf '# Incomplete QA verifier teardown\n\n'
    printf 'Verifier: %s%s%s\n\n' '`' "$vid" '`'
    printf 'Family: %s%s%s\n\n' '`' "${family:-unknown}" '`'
    printf 'Preserved at: %s%s%s\n\n' '`' "$(ac_iso)" '`'
    printf 'This verifier was explicitly torn down before verdict, relay report, and run-state export were all complete. Inspect the preserved metadata and partial artifacts before retrying QA.\n'
  } >"$tmp" || ac_die "cannot write incomplete QA artifact for $vid"
  mv "$tmp" "$evidence/incomplete-run.md"
}

archive_and_reap_verifier() {
  # archive_and_reap_verifier <meta> - verifier cleanup has no ship landed
  # proof. It archives identity first, reaps the exact pane handle, then returns
  # only leases named by the verifier record.
  local vm="$1" vid pane_file varchive leases_v lease_v rest_v ids_v id_v family_v kind_v
  vid="$(basename "$vm" .meta)"
  pane_file="$state_dir/.pane-$vid"
  varchive="$state_dir/archive/$vid"
  if [ -e "$varchive/meta" ]; then
    mkdir -p "$varchive"
    varchive="$(mktemp -d "$varchive/$(ac_now).XXXXXX")"
  else
    mkdir -p "$varchive"
  fi
  mv "$vm" "$varchive/meta"
  reap_pane_file "$pane_file"
  leases_v="$(ac_meta_get "$varchive/meta" leases)"
  [ -n "$leases_v" ] || leases_v="$(ac_meta_get "$varchive/meta" worktree)"
  # lease_ids= is popped in LOCKSTEP with leases= (same order, ac-spawn.sh owns
  # the grammar), so each return is bound to the acquisition it belongs to.
  ids_v="$(ac_meta_get "$varchive/meta" lease_ids)"
  rest_v="$leases_v"
  while [ -n "$rest_v" ]; do
    case "$rest_v" in *:*) lease_v=${rest_v%%:*}; rest_v=${rest_v#*:} ;; *) lease_v=$rest_v; rest_v="" ;; esac
    case "$ids_v" in *:*) id_v=${ids_v%%:*}; ids_v=${ids_v#*:} ;; *) id_v=$ids_v; ids_v="" ;; esac
    [ -n "$lease_v" ] || continue   # no lease recorded for this slot - normal, stay silent
    if [ ! -d "$lease_v" ]; then
      # Same defect class as @9b39f00's twin, one loop over: the lease record
      # and the disk have DIVERGED, and continuing in silence is what let the
      # sweep and return this iteration owed simply never run unremarked.
      ac_warn "skipping vanished verifier lease $lease_v: directory no longer exists"
      continue
    fi
    if [ -n "$id_v" ]; then
      "$bin_dir/ac-tree.sh" return "$lease_v" --force --if-lease-id "$id_v" >/dev/null 2>&1 \
        || ac_warn "could not return verifier worktree $lease_v (it may have been re-leased); inspect $varchive/meta"
    else
      "$bin_dir/ac-tree.sh" return "$lease_v" --force >/dev/null 2>&1 \
        || ac_warn "could not return verifier worktree $lease_v; inspect $varchive/meta"
    fi
  done
  family_v="$(ac_meta_get "$varchive/meta" family)"
  kind_v="$(ac_meta_get "$varchive/meta" kind)"; kind_v="${kind_v#verify-}"
  rmdir "$state_dir/.verify-$family_v-$kind_v.lock.d" 2>/dev/null || true
}

prepare_task_verifiers() {
  local vm vid
  for vm in "$state_dir"/*.meta; do
    [ -f "$vm" ] || continue
    [ "$vm" != "$meta" ] || continue
    ac_meta_is_verify "$vm" || continue
    verifier_owned_by_task "$vm" || continue
    vid="$(basename "$vm" .meta)"
    preserve_incomplete_qa_verifier "$vm" "$vid"
  done
}

sweep_task_verifiers() {
  local vm
  for vm in "$state_dir"/*.meta; do
    [ -f "$vm" ] || continue
    ac_meta_is_verify "$vm" || continue
    verifier_owned_by_task "$vm" || continue
    archive_and_reap_verifier "$vm"
  done
}

qa_infra_timeout() {
  # Bound for the qa-infra sweep, in seconds. AC_TEARDOWN_QA_TIMEOUT exists so
  # a hanging-docker test need not sit for the production bound; a non-numeric
  # value falls back (the ac-sync.sh sync_timeout shape).
  local t="${AC_TEARDOWN_QA_TIMEOUT:-30}"
  case "$t" in
    '' | *[!0-9]*) t=30 ;;
  esac
  printf '%s\n' "$t"
}

qa_infra_down_bounded() {
  # qa_infra_down_bounded <secs> - the task's qa stack torn down under a
  # watchdog (the fetch_bounded shape, bin/ac-sync.sh:55-75): the child is
  # killed once <secs> elapse (TERM, short grace, KILL). Returns the sweep's
  # own status, or 124 on timeout. The child's docker grandchild is orphaned,
  # not reaped - bounding TEARDOWN is the point, and the stack stays
  # reclaimable with the command the caller's warning names.
  local secs="$1" pid start
  ( cd "$project_dir" && "$bin_dir/ac-qa.sh" infra down --task "$id" >/dev/null 2>&1 ) &
  pid=$!
  start=$SECONDS
  while kill -0 "$pid" 2>/dev/null; do
    if [ $((SECONDS - start)) -ge "$secs" ]; then
      kill "$pid" 2>/dev/null || true
      sleep 0.5
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 0.2
  done
  wait "$pid"
}

sweep_pane_agents() {
  # sweep_pane_agents <leased-tree> - end this task's pane agents and qa server
  # inside one leased worktree (contract: PANE-AGENT SWEEP in the header).
  local dir="$1" m rd attr
  reap_pane_file "$dir/.crew/qa/agent-$(sanitize_task "$id").pane"
  for m in "$dir"/.crew/qa/*/run.meta; do
    [ -f "$m" ] || continue
    rd="${m%/run.meta}"
    [ -L "$rd" ] && continue           # the `current` symlink aliases a run dir
    attr="$(sed -n 's/^task=//p' "$m" | head -n1)"
    case "$attr" in
      "$id") reap_pane_file "$rd/watch.pane"; kill_serve_pid "$rd/serve.pid" ;;
      "") warn_unattributed "$rd" ;;
    esac
  done
  for m in "$dir"/.crew/ship/*/run.meta; do
    [ -f "$m" ] || continue
    rd="${m%/run.meta}"
    [ -L "$rd" ] && continue
    attr="$(sed -n 's/^branch=//p' "$m" | head -n1)"
    case "$attr" in
      "$branch") reap_pane_file "$rd/review.pane"; reap_pane_file "$rd/watch.pane" ;;
      "") warn_unattributed "$rd" ;;
    esac
  done
  return 0
}

if ac_meta_is_verify "$meta"; then
  preserve_incomplete_qa_verifier "$meta" "$id"
  archive_and_reap_verifier "$meta"
  reap_watcher_stamps "$id"
  printf 'teardown %s complete (verifier)\n' "$id"
  exit 0
fi

if [ "$force" = 0 ]; then
  landed_proof || ac_die "refusing teardown of $id (unlanded work); land it or pass --force to discard"
fi

# Evidence preflight - after the gate, before the execution meta is archived
# (header: VERIFIER SWEEP). It is DURABLE and records that the verifier "was
# explicitly torn down", so ahead of the gate it wrote exactly that about a
# verifier still running, on the one path teardown must leave untouched. If an
# incomplete QA artifact cannot be made durable, nothing verifier-owned is
# reaped or returned.
prepare_task_verifiers

# Archive task state - the FIRST durable act, before the pane-kill (header:
# ORDER GUARANTEE). The status append and both moves are one unit.
archive="$state_dir/archive/$id"
mkdir -p "$archive"
ac_status_append "$id" "resolved: teardown$([ "$force" = 1 ] && printf ' (forced)')"
mv "$meta" "$archive/meta"
[ -f "$(ac_task_status "$id")" ] && mv "$(ac_task_status "$id")" "$archive/status"
reap_watcher_stamps "$id"

# Kill the session window (ignore if already gone).
backend_kill_window "$id"
sweep_task_verifiers

# Return the leased worktree to the pool (reset discards; proof already ran).
# Crewdeputies have no worktree lease or crew branch - their home stays put.
if [ "$kind" = roomchief ]; then
  demote_fam="${id%-chief}"
  demote_suffix=""
  [ "$force" = 1 ] && demote_suffix=" (forced)"
  demote_msg="DEMOTED: roomchief closed$demote_suffix"
  if ! room_err="$("$bin_dir/ac-room.sh" post "$demote_fam" crewchief "$demote_msg" 2>&1 >/dev/null)"; then
    ac_warn "could not post DEMOTED to room $demote_fam: $room_err - post it by hand: $bin_dir/ac-room.sh post $demote_fam crewchief \"$demote_msg\""
  fi
fi

if [ "$kind" != crewdeputy ] && [ "$kind" != roomchief ]; then
  # Every lease the task took, swept then returned - the sweep FIRST, since the
  # return resets the tree out from under the records it reads (header:
  # PANE-AGENT SWEEP). A chief or deputy holds no pool lease and runs no pane
  # agent of its own, so neither loop is theirs.
  rest_ids="$lease_ids"
  while IFS= read -r lease; do
    # Popped in LOCKSTEP with the path list, so each return names the
    # acquisition it belongs to and a slot re-leased since then is refused
    # rather than reset out from under its new holder.
    case "$rest_ids" in *:*) lease_id=${rest_ids%%:*}; rest_ids=${rest_ids#*:} ;; *) lease_id=$rest_ids; rest_ids="" ;; esac
    [ -n "$lease" ] || continue   # no lease recorded for this slot - normal, stay silent
    if [ ! -d "$lease" ]; then
      # The lease record and the disk have DIVERGED - something removed a
      # leased worktree out from under the pool. Report it; repairing or
      # re-creating the directory is not this loop's job, and the run must
      # still reach every step after it (same distinction as the branch -d
      # refusal above: continuing is correct, the silence was the defect).
      ac_warn "skipping vanished lease $lease: directory no longer exists"
      continue
    fi
    sweep_pane_agents "$lease"
    # --force: the landed-work proof (or the captain's explicit --force)
    # already authorized discarding whatever is left in the tree.
    if [ -n "$lease_id" ]; then
      "$bin_dir/ac-tree.sh" return "$lease" --force --if-lease-id "$lease_id" >/dev/null 2>&1 \
        || ac_warn "could not return worktree $lease (it may have been re-leased); check the pool with ac-tree.sh list"
    else
      "$bin_dir/ac-tree.sh" return "$lease" --force >/dev/null 2>&1 \
        || ac_warn "could not return worktree $lease; check the pool with ac-tree.sh list"
    fi
  done <<EOF
$(printf '%s\n' "$leases" | tr ':' '\n')
EOF

  # Drop a fully-landed crew branch from the project repo (keep if unmerged).
  # -d's merge check is NOT the landed proof above (that one also accepts
  # origin, a containing remote branch or a merged PR), so a legitimately
  # landed task can meet a legitimate refusal. Report it in git's own words -
  # swallowing it is what left an orphaned branch behind a `complete` line.
  # -d stays -d, and like every step here this can never fail the teardown.
  if git -C "$project_dir" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    # An epic-landed branch is merged into the RECORDED integration branch,
    # not the default - -d's merged check cannot see that, so prove the
    # containment ourselves and use -D deliberately (else the stale branch
    # blocks this story's own -r2 spawn on the name-collision refusal).
    del_flag="-d"
    if eb_del="$(ac_epic_base_for "$id" "$(basename "$project_dir")" 2>/dev/null)"; then
      eb_del_branch="${eb_del%% *}"
      if git -C "$project_dir" merge-base --is-ancestor "refs/heads/$branch" "refs/heads/$eb_del_branch" 2>/dev/null \
        || git -C "$project_dir" merge-base --is-ancestor "refs/heads/$branch" "refs/remotes/origin/$eb_del_branch" 2>/dev/null; then
        del_flag="-D"
      fi
    fi
    if ! branch_err="$(git -C "$project_dir" branch "$del_flag" "$branch" 2>&1)"; then
      # `git branch -D` refuses IDENTICALLY when a worktree holds the branch
      # checked out (verified on git 2.55.0: same "used by worktree" message,
      # exit 1), so suggesting -D there sends the reader into a second
      # refusal. Classify from git STATE, not git's error PROSE: that prose is
      # LOCALIZED (verified: LC_ALL=de_DE.UTF-8 renders a wholly different
      # string for the identical refusal), so matching it would just move
      # this task's own defect - trusting git's words instead of its exit
      # status - onto a different string under any non-English locale.
      # `worktree list --porcelain` is a stability-contracted, locale-free
      # format (same idiom as ac-merge-local.sh's merge-STATE checks, not
      # merge-prose parsing) - a `branch refs/heads/<name>` line names the
      # worktree that's holding it, structurally immune to $LANG.
      if git -C "$project_dir" worktree list --porcelain \
        | grep -Fxq "branch refs/heads/$branch"; then
        reclaim="free it from that worktree, then git branch -D $branch"
      else
        reclaim="git branch -D $branch"
      fi
      ac_warn "kept $branch in $project_dir: $branch_err - reclaim: $reclaim"
    fi
  fi
fi

# Tear down any qa infra the task left behind (task-scoped compose stack;
# traps do not fire when a pane is killed, so teardown owns this cleanup).
# Bounded and instrumented - contract: QA-INFRA SWEEP in the header.
if [ -n "${project_dir:-}" ] && [ -d "$project_dir" ] && command -v docker >/dev/null 2>&1; then
  for sig in HUP INT TERM URG; do
    # shellcheck disable=SC2064  # $sig expands NOW: the signal name IS the evidence.
    trap "ac_warn \"teardown $id: caught SIG$sig during the qa-infra sweep\"; trap - $sig; kill -$sig \$\$" "$sig"
  done
  qa_secs="$(qa_infra_timeout)"
  qa_infra_down_bounded "$qa_secs" \
    || ac_warn "qa-infra sweep for $id did not complete (status $?, bound ${qa_secs}s) - docker is unusable or hung; any task stack survives: (cd $project_dir && $bin_dir/ac-qa.sh infra down --task $id)"
  trap - HUP INT TERM URG
fi

printf 'teardown %s complete%s\n' "$id" "$([ "$force" = 1 ] && printf ' (forced)')"

# Landing checkpoint: demoting a chief is the ONE moment a room-parallel slot
# frees (ac-room.sh close cannot be - it refuses until the chief is already
# demoted), so surface the next queued family here, ac-ready ride-along style.
# ADVISORY ONLY: promotion is the crewchief's triage call, and a destructive
# verb must not also open sessions. Guarded twice over - set -euo pipefail is
# in force, and an advisory may never flip the exit code of work that landed.
if [ "$kind" = roomchief ]; then
  next="$("$bin_dir/ac-ready.sh" queued 2>/dev/null | head -n1 || true)"
  [ -z "$next" ] || printf 'a chief slot is free - next queued family: %s (promote with bin/ac-spawn.sh --roomchief %s)\n' "$next" "$next"
fi
