#!/usr/bin/env bash
# ac-feature.sh - the FEATURE integration-branch verbs (feature-branch-mech).
#
# A feature accumulates SEVERAL crew tasks on one branch per repo that stays
# LOCAL until ship: create cuts it at the recorded target's freshest tip and
# never pushes; member rows bind with the `feature:<name>` ledger token
# (AC_DONELINE_AWK's f["feature"]) and land onto the branch through the
# ordinary ac-merge-local path via the shared resolver (ac_epic_base_for);
# `ship` publishes the branch ONCE and opens the single PR to the recorded
# target (captain rulings 2026-08-24, receipted in the feature-branch-mech
# room: standalone mechanism reusable by epic-branch-mech; many tasks per
# feature; one review/QA gate at the tip before push; target captain-recorded).
#
# The RECORD is data/<feature>/branches - `<repo> <branch> [target=<branch>]
# push=deferred`, one line per repo - chief-written on the captain's word and
# receipted DECIDED: to the feature room. ac_epic_branches_file /
# ac_epic_branch_entry (ac-lib.sh) own its archive-aware resolution exactly as
# for an epic record: the FILE shape is shared, and `push=deferred` on the
# entry is what marks it a FEATURE entry - the ac-tree.sh fence and this
# script both key on it, and an entry without it is an epic-shaped record
# these verbs refuse toward ac-epic-branch.sh. `target` defaults to the
# repo's default branch when the key is absent.
#
#   create <feature> <repo>          cut the recorded branch LOCALLY at the
#                                    freshest tip of its target
#                                    (ac_freshest_ref <repo> <target>; origin
#                                    repos fetch first). NEVER pushes -
#                                    deferred publication is the mode's
#                                    defining property. Idempotent, and it
#                                    never moves an existing branch.
#   verify <feature> <repo>          exit 0 iff the recorded, unretired branch
#                                    exists LOCALLY - a deferred-push branch
#                                    judged on origin would fail every
#                                    pre-ship verify. Quiet, built to be
#                                    gated on.
#   show   <feature>                 delegate to ac-epic-branch.sh show - the
#                                    record verbs are kind-agnostic.
#   retire <feature>                 delegate to ac-epic-branch.sh retire
#                                    (chief-only fence rides the delegate).
#   ship   <feature> <repo> [--dry-run]
#                                    the gated exit: members terminal, partial
#                                    receipts, ONE review round at the LOCAL
#                                    tip, QA when the container row pins it,
#                                    target-drift refusal, then push + the
#                                    single PR. See the SHIP block below.
#
# CHIEF-ONLY on the mutating verbs (create/ship), the domain_chief_only
# pattern: a PreToolUse hook cannot see a bash verb, so the guard lives here.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/ac-lib.sh"

chief_only() {
  [ -z "${AC_SCOPE:-}" ] \
    || ac_die "$1 is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=$AC_SCOPE) - the feature branch is cut and shipped on the captain's word by the fleet chief; a scoped chief reads the record (show/verify) and never mutates it"
}

repo_dir() {
  local d
  d="$AC_HOME/projects/$1"
  [ -d "$d/.git" ] || [ -f "$d/.git" ] || ac_die "no project clone at projects/$1"
  printf '%s\n' "$d"
}

has_origin() { git -C "$1" remote get-url origin >/dev/null 2>&1; }

entry_or_die() {
  # entry_or_die <verb> <feature> <repo> - prints the entry; dies with the
  # verb's own remedy on a missing record/entry, names the retirement on rc 2,
  # and refuses an entry that does not carry push=deferred - that entry is an
  # EPIC-shaped record and belongs to ac-epic-branch.sh's verbs.
  local verb="$1" feature="$2" repo="$3" entry rc=0
  entry="$(ac_epic_branch_entry "$feature" "$repo")" || rc=$?
  case "$rc" in
    0) : ;;
    2) ac_die "$verb: the $feature record is retired ($(head -1 "$(ac_epic_branches_file "$feature")")) - a retired feature has no integration branch; re-record on the captain's word if the feature truly reopens" ;;
    *) ac_die "$verb: no record entry for $repo under feature $feature - write data/$feature/branches first (the captain's word, receipted DECIDED: to the room): '<repo> <branch> [target=<branch>] push=deferred'" ;;
  esac
  case " ${entry#"${entry%% *}"} " in
    *" push=deferred "*) : ;;
    *) ac_die "$verb: the $feature entry for $repo carries no push=deferred key - that is an epic-shaped record, not a feature entry; a FEATURE branch stays local until ship (add push=deferred on the captain's word, or use ac-epic-branch.sh for an epic record)" ;;
  esac
  printf '%s\n' "$entry"
}

entry_target() {
  # entry_target <entry> <repo-dir> - the recorded target branch, defaulting
  # to the repo's default branch when the key is absent.
  local entry="$1" dir="$2" rest target=""
  rest=" ${entry#"${entry%% *}"} "
  case "$rest" in *" target="*) target="${rest#* target=}"; target="${target%% *}" ;; esac
  [ -n "$target" ] || target="$(ac_default_branch "$dir")"
  printf '%s\n' "$target"
}

cmd_create() {
  local feature="$1" repo="$2" entry branch dir target
  chief_only create
  entry="$(entry_or_die create "$feature" "$repo")"
  branch="${entry%% *}"
  dir="$(repo_dir "$repo")"
  target="$(entry_target "$entry" "$dir")"
  if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
    printf 'exists: %s in %s (left untouched)\n' "$branch" "$repo"
    return 0
  fi
  if has_origin "$dir"; then
    git -C "$dir" fetch origin --quiet \
      || ac_die "create: fetch origin failed for $repo - the branch must be cut at the target's real tip, not a stale mirror"
  fi
  git -C "$dir" rev-parse --verify --quiet "refs/heads/$target" >/dev/null 2>&1 \
    || git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$target" >/dev/null 2>&1 \
    || ac_die "create: target branch $target resolves nowhere in $repo - the record names a target that does not exist"
  git -C "$dir" branch "$branch" "$(ac_freshest_ref "$dir" "$target")"
  printf 'created: %s in %s at the tip of %s (LOCAL - deferred push)\n' "$branch" "$repo" "$target"
}

cmd_verify() {
  local feature="$1" repo="$2" entry branch dir
  entry="$(entry_or_die verify "$feature" "$repo")"
  branch="${entry%% *}"
  dir="$(repo_dir "$repo")"
  git -C "$dir" show-ref --verify --quiet "refs/heads/$branch" \
    || ac_die "verify: $branch does not exist locally in $repo - a feature branch lives LOCALLY until ship; create it (ac-feature.sh create $feature $repo) before any member spawns against it"
}

cmd="${1:-}"
case "$cmd" in
  create)
    [ $# -eq 3 ] || ac_die "usage: ac-feature.sh create <feature> <repo>"
    cmd_create "$2" "$3" ;;
  verify)
    [ $# -eq 3 ] || ac_die "usage: ac-feature.sh verify <feature> <repo>"
    cmd_verify "$2" "$3" ;;
  show|retire)
    [ $# -eq 2 ] || ac_die "usage: ac-feature.sh $cmd <feature>"
    exec "$(dirname "${BASH_SOURCE[0]}")/ac-epic-branch.sh" "$cmd" "$2" ;;
  *)
    ac_die "usage: ac-feature.sh create|verify <feature> <repo> | show|retire <feature> | ship <feature> <repo> [--dry-run]" ;;
esac
