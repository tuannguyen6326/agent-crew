#!/usr/bin/env bash
# ac-merge-local.sh - land a local-only crewmate task from crew/<id> into the
# project's local default branch. Writes into a project clone - one of the
# few sanctioned writes.
#
# Usage: ac-merge-local.sh <id> [--no-ff]
#
# Default path (no flag): FAST-FORWARD ONLY. LANDING is byte-for-byte the
# original behavior: requires the primary checkout to be on the default
# branch, clean, and $default to be an ancestor of crew/<id> (a pure
# fast-forward); on success it prints `fast-forwarded <default> to <branch>`,
# which asserts $default's tree now IS crew/<id>'s tree. The REFUSAL is
# deliberately NOT unchanged: when $default is not an ancestor of the
# branch, the merge is never attempted (git's own bare --ff-only error would
# say nothing useful here) - the helper refuses up front, in its own voice.
# The refusal is ACTOR-AWARE: an unscoped actor (crewchief/captain) is named
# `--no-ff` as the conflict-free escape hatch; a scoped actor (AC_CREW_ID or
# AC_SCOPE set - a crewmate/roomchief) is never offered it, because the
# primary-checkout commit guard (bin/ac-tree.sh D2) refuses that actor's
# --no-ff merge commit - it is instead told to rebase the branch and re-run
# the plain land, or hand the landing back to the crewchief. This path never
# falls back to `--no-ff` on its own; that would change the default and is a
# captain decision, not this script's (see captain ruling "k conflict thi
# khoi rebase", family merge-local-cannot-honor-the-captain-no-rebase-rule).
#
# --no-ff path (opt-in): lands a non-fast-forwardable-but-CONFLICT-FREE
# crew/<id> as an ordinary merge commit. It is tried with `git merge --no-ff
# --no-commit` first; on any conflict, `git merge --abort` restores the
# checkout to clean / on $default / not MERGING before refusing and naming
# the conflicting paths - this is real git state, not a project clone, so a
# conflicted land here must never be left mid-merge. On success it prints
# `merged <branch> into <default> (--no-ff)`, which asserts $default now
# CONTAINS crew/<id>'s history, NOT that $default's tree IS the branch's
# tree - that distinction is the entire point of the flag; do not let it
# drift into folklore when reading a landing receipt. When $branch is
# ALREADY an ancestor of $default (the same no-op re-land the bare path's
# --ff-only already treats as success), git creates no MERGE_HEAD and there
# is nothing to commit - this path recognizes that and says so plainly
# instead of claiming a merge commit that was never made.
#
# Requires either way: the primary checkout is on the default branch and is
# clean of TRACKED dirt on entry - the refusal names the dirty paths. An
# untracked file is not refused on its own: it can only matter if the
# incoming commits add a file at the same path, and git itself refuses that
# collision (mid-merge, in its own voice, on both the --ff-only and --no-ff
# paths) rather than this up-front check.
#
# There is no .gitignore special case: ac-tree.sh ignores the worktree pool
# (`/.crew/`) per-clone via `.git/info/exclude` (never tracked, invisible to
# `git status`), so a local-only land never self-inflicts .gitignore dirt.
#
# Landing interlock (contract: ac-lib.sh's landing-ledger block): BEFORE the
# merge it prints one LANDING-OVERLAP warning per touched file another family
# landed <24h ago (warn-only), and after it it records every landed file to
# the state/.landings ledger - unchanged by which path landed, since the
# landed set is derived from the branch's own commits, not from the merge
# result. It also prints the KNOWLEDGE-GAP flag when this family recorded no
# repo-knowledge entry for the project (ac_knowledge_warn, warn-only, NOT
# behind the landed[] guard).

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
# ...and its documented sibling, AFTER it: the qa merge gate reads the
# project yaml through ac_yaml_has, which lives there. Without this line
# the gate is an unbound command on the one path that must never be
# ambiguous. No cycle - ac-lib.sh loads nothing from it, and the call is
# resolved at RUN time, after both files are loaded.
. "$(dirname "$0")/ac-pipeline-lib.sh"
. "$(dirname "$0")/ac-qa-lib.sh"   # ac_qa_gate_ok: the merge-time qa.require_for_ship gate
[ ! -x "$(dirname "$0")/ac-guard.sh" ] || "$(dirname "$0")/ac-guard.sh" || true  # warn-only advisory
ac_require git

id="${1:-}"
noff="${2:-}"
[ -n "$id" ] || ac_die "usage: ac-merge-local.sh <id> [--no-ff]"
[ -z "$noff" ] || [ "$noff" = "--no-ff" ] || ac_die "usage: ac-merge-local.sh <id> [--no-ff]"
meta="$(ac_task_meta "$id")"
[ -f "$meta" ] || ac_die "no crewmate meta for $id"
project_dir="$(ac_meta_get "$meta" project_dir)"
worktree="$(ac_meta_get "$meta" worktree)"
branch="$(ac_crew_branch "$id")"

default="$(ac_default_branch "$project_dir")"
# Epic-target landing (epic-branch-mech): when the id's epic records an
# integration branch for this repo, THAT branch is the landing target, by
# REF-ONLY ff update - no checkout flip, so the primary-checkout-on-default
# invariant and the commit guard stay untouched and a SCOPED chief can land
# (the live epic practice). --no-ff onto an epic target is refused here: a
# genuine merge commit belongs in a leased worktree, not the primary.
target="$default"; epic_mode=0; epic_push=0
if eb_entry="$(ac_epic_base_for "$id" "$(basename "$project_dir")")"; then
  target="${eb_entry%% *}"
  epic_mode=1
  case " ${eb_entry#"$target"} " in *" push=yes "*) epic_push=1 ;; esac
  if ! git -C "$project_dir" rev-parse --verify --quiet "refs/heads/$target" >/dev/null; then
    git -C "$project_dir" rev-parse --verify --quiet "refs/remotes/origin/$target" >/dev/null \
      || ac_die "epic target $target exists neither locally nor on origin - cut it first: ac-epic-branch.sh create <epic> $(basename "$project_dir")"
    git -C "$project_dir" branch "$target" "refs/remotes/origin/$target"
  fi
fi
# The primary checkout must sit on the DEFAULT branch - except an epic-mode
# landing, where sitting on the TARGET itself is the live practice (the epic
# IS those clones' working line) and is handled by an in-place ff merge below.
current="$(git -C "$project_dir" symbolic-ref --short HEAD 2>/dev/null || printf 'DETACHED')"
if [ "$epic_mode" = 1 ]; then
  [ "$current" = "$default" ] || [ "$current" = "$target" ] \
    || ac_die "primary checkout is on '$current' - an epic landing needs it on '$default' or on the target '$target'"
else
  [ "$current" = "$default" ] || ac_die "primary checkout is on '$current', not '$default'"
fi

status="$(git -C "$project_dir" status --porcelain -uno)"
if [ -n "$status" ]; then
  paths="$(printf '%s\n' "$status" | sed 's/^...//' | tr '\n' ' ')"
  ac_die "primary checkout is dirty: ${paths% } (commit, stash, or discard, then retry)"
fi

# The crew branch usually lives only in the worktree's ref store, which the
# main repo shares; verify it resolves from the project clone.
git -C "$project_dir" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null \
  || ac_die "branch $branch not found in $project_dir (did the crewmate commit? worktree: $worktree)"

# qa.require_for_ship gate: refuse the local land unless a passing crew-qa run
# is on record for the crew branch head (no-op when not required). Passing the
# task id lets the gate adjudicate a required-profile MANIFEST when the task
# declared one - EVERY required profile must have a passing attestation at this
# head, not merely any one pair (ac_qa_gate_ok / ac_qa_gate_matrix).
if [ "$epic_mode" = 1 ]; then
  # qa.require_for_ship guards the PRODUCTION merge; an epic-branch landing
  # is integration, not production - the epic gate's own QA round owns it
  # (epic-branch-mech proposal, captain ruling 2026-08-19).
  printf 'qa.require_for_ship: deferred to the epic gate (epic-branch landing)\n'
else
  ac_qa_gate_ok "$project_dir" "$(git -C "$project_dir" rev-parse "refs/heads/$branch")" "$id" \
    || ac_die "local merge blocked by qa.require_for_ship (see message above)"
fi

# Landing interlock: warn on <24h foreign-family overlaps before the merge,
# record the landed files after it (header + ac-lib.sh landing-ledger block).
# The landed set is the branch's OWN commits - the three-dot merge-base range
# ($default...$branch = what this branch added since it diverged from the
# default), NOT the two-dot tree diff. A two-dot `git diff $default $branch`
# reverse-reports files that OTHER families added to $default when it has
# advanced past the branch (a no-op re-land, or an un-rebased land's pre-merge
# warn), stamping a sibling's files under THIS family and pointing the overlap
# warn at the wrong room. Three-dot attributes exactly the files crew/<id>
# adds; for a genuine fast-forward it equals the two-dot set.
family="$(ac_family_of_id "$id")"
landed=()
while IFS= read -r p; do landed+=("$p"); done \
  < <(git -C "$project_dir" diff --name-only "$target...refs/heads/$branch")
[ "${#landed[@]}" -eq 0 ] || ac_landing_warn "$family" "${landed[@]}"
# The KNOWLEDGE-GAP flag rides the same checkpoint but NOT the landed[] guard:
# a family that recorded no repo knowledge is flagged whatever its diff looks
# like. Warn-only, always returns 0 (ac-lib.sh owns the contract).
ac_knowledge_warn "$family" "$project_dir"

if [ "$noff" = "--no-ff" ]; then
  [ "$epic_mode" = 0 ] \
    || ac_die "--no-ff is not available for an epic-branch landing: a merge commit onto $target belongs in a leased worktree, never the primary checkout - rebase $branch onto $target and land ff, or route the merge through the epic gate"
  # --no-ff lands a CLEAN merge only: try it with --no-commit so a conflict
  # can be inspected and unwound before anything is refused. Two distinct
  # failure shapes exist and must not be handled alike: (a) git ENTERED the
  # merge and hit real conflicts - MERGE_HEAD exists, and `merge --abort` is
  # the one command that returns clean/on-default/not-MERGING before naming
  # the conflicting paths; (b) git REFUSED to even start the merge (e.g.
  # unrelated histories) - no MERGE_HEAD is ever created, the checkout was
  # never touched, and `merge --abort` itself fails here ("no merge to
  # abort"), so it must not be called - the refusal instead says the merge
  # never started and quotes git's own reason.
  if ! err="$(git -C "$project_dir" merge --no-ff --no-commit "$branch" 2>&1 >/dev/null)"; then
    if git -C "$project_dir" rev-parse -q --verify MERGE_HEAD >/dev/null; then
      conflicts="$(git -C "$project_dir" diff --name-only --diff-filter=U | tr '\n' ' ')"
      git -C "$project_dir" merge --abort
      ac_die "--no-ff merge of $branch conflicts on: ${conflicts% } (checkout left clean on $default)"
    else
      ac_die "--no-ff merge of $branch never started: $err (checkout untouched, still clean on $default)"
    fi
  fi
  if git -C "$project_dir" rev-parse -q --verify MERGE_HEAD >/dev/null; then
    # A real merge is staged and ready to commit - but the commit itself can
    # still be refused (e.g. a pre-commit hook), and that refusal must not
    # leave MERGE_HEAD behind either: abort back to clean before naming it.
    if ! commit_err="$(git -C "$project_dir" commit -q --no-edit 2>&1 >/dev/null)"; then
      git -C "$project_dir" merge --abort
      ac_die "--no-ff commit of $branch was refused: $commit_err (checkout restored, clean on $default)"
    fi
    [ "${#landed[@]}" -eq 0 ] || ac_landing_record "$family" "${landed[@]}"
    ac_status_append "$id" "merged: local $default (--no-ff)"
    printf 'merged %s into %s (--no-ff)\n' "$branch" "$default"
  else
    # No-op: $branch was already an ancestor of $default ("Already up to
    # date"), so git created no MERGE_HEAD and there is nothing to commit -
    # the exact situation the bare path's --ff-only already lands as a
    # success. Run the SAME ledger calls the bare path runs for it, so the
    # two paths never diverge on this situation, and say so truthfully
    # instead of claiming a merge commit that was never made.
    [ "${#landed[@]}" -eq 0 ] || ac_landing_record "$family" "${landed[@]}"
    ac_status_append "$id" "merged: local $default"
    printf '%s already contains %s; no merge commit created (--no-ff)\n' "$default" "$branch"
  fi
else
  # Pre-check ancestry so a non-fast-forwardable branch is refused in this
  # helper's own voice instead of surfacing git's bare --ff-only error under
  # set -e - and so --ff-only is never even attempted when it cannot succeed.
  # --ff-only also succeeds as a no-op when $branch is already an ancestor of
  # $default (already-landed/no-op re-land, case 8 in the test file), so both
  # directions count as fast-forwardable - only a genuine divergence refuses.
  if ! git -C "$project_dir" merge-base --is-ancestor "refs/heads/$target" "refs/heads/$branch" \
      && ! git -C "$project_dir" merge-base --is-ancestor "refs/heads/$branch" "refs/heads/$target"; then
    # --no-ff is only real advice for an actor the primary-checkout commit
    # guard (bin/ac-tree.sh D2) does not fence: AC_CREW_ID/AC_SCOPE set means
    # a crewmate/roomchief, whose --no-ff merge commit that guard refuses
    # late, at the --no-ff path's own commit refusal below - so a scoped
    # actor gets the remedies it can actually use instead of advice that
    # only burns a cycle.
    if [ "$epic_mode" = 1 ]; then
      ac_die "$branch is not fast-forwardable: $target has diverged from it (a sibling story landed first). Rebase $branch onto $target and re-run the plain land"
    fi
    if [ -n "${AC_CREW_ID:-}" ] || [ -n "${AC_SCOPE:-}" ]; then
      ac_die "$branch is not fast-forwardable: $default has diverged from it. --no-ff is not available here (the primary-checkout commit guard refuses it for a crewmate/roomchief) - rebase $branch onto $default and re-run the plain land, or hand the landing back to the crewchief"
    fi
    ac_die "$branch is not fast-forwardable: $default has diverged from it. Land a conflict-free branch with 'ac-merge-local.sh $id --no-ff', or rebase $branch onto $default first"
  fi
  # The ancestor pre-check above only rules out divergence; an ancestor-
  # compatible branch can still fail HERE when an untracked file in the
  # primary checkout collides with a path the incoming commits add - git
  # refuses the fast-forward outright (no ref move, no MERGE_HEAD) and this
  # wraps that refusal in the helper's own voice instead of leaving git's
  # bare stderr as the only signal.
  if [ "$epic_mode" = 1 ]; then
    # REF-ONLY ff update: `git fetch . src:dst` refuses a non-ff move by
    # default, the checkout is never touched, and the commit guard has
    # nothing to see. Already-ancestor (no-op re-land) is landed truthfully.
    if git -C "$project_dir" merge-base --is-ancestor "refs/heads/$branch" "refs/heads/$target"; then
      printf '%s already contains %s; nothing to move\n' "$target" "$branch"
    elif [ "$current" = "$target" ]; then
      # The target is CHECKED OUT in the primary (the live epic practice) -
      # `git fetch . src:dst` refuses to move the current branch's ref, so
      # this ff is an in-place --ff-only merge: no commit is minted, the
      # commit guard has nothing to see, and the tree follows the ref.
      if ! err="$(git -C "$project_dir" merge --ff-only "$branch" 2>&1 >/dev/null)"; then
        ac_die "ff of $target (checked out) from $branch failed: $err ($target untouched)"
      fi
      printf 'fast-forwarded %s to %s (in place)\n' "$target" "$branch"
    elif ! err="$(git -C "$project_dir" fetch --quiet . "refs/heads/$branch:refs/heads/$target" 2>&1 >/dev/null)"; then
      ac_die "ff update of $target from $branch failed: $err ($target untouched)"
    else
      printf 'fast-forwarded %s to %s (ref-only)\n' "$target" "$branch"
    fi
    if [ "$epic_push" = 1 ] && git -C "$project_dir" remote get-url origin >/dev/null 2>&1; then
      # The record's push=yes flag is the captain's own landing rule - the
      # push rides the landing so the integration branch is never stale for
      # the next story's fence. A failed push is LOUD but does not un-land.
      if git -C "$project_dir" push --quiet origin "refs/heads/$target:refs/heads/$target" 2>/dev/null; then
        printf 'pushed %s to origin (record push=yes)\n' "$target"
      else
        ac_warn "push of $target to origin FAILED - the landing stands; retry: git -C $project_dir push origin $target"
      fi
    fi
    [ "${#landed[@]}" -eq 0 ] || ac_landing_record "$family" "${landed[@]}"
    ac_status_append "$id" "merged: local $target (epic)"
  else
    if ! err="$(git -C "$project_dir" merge --ff-only "$branch" 2>&1 >/dev/null)"; then
      ac_die "fast-forward of $branch failed: $err ($default untouched)"
    fi
    [ "${#landed[@]}" -eq 0 ] || ac_landing_record "$family" "${landed[@]}"
    ac_status_append "$id" "merged: local $default"
    printf 'fast-forwarded %s to %s\n' "$default" "$branch"
  fi
fi
