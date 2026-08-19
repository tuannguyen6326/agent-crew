#!/usr/bin/env bash
# ac-epic-branch.sh - the per-epic INTEGRATION-BRANCH verbs (epic-branch-mech).
#
# A branch-recorded epic integrates its stories on one branch per repo before
# the whole ships. The RECORD is data/<epic>/branches (`<repo> <branch>
# [key=value ...]`, e.g. `push=yes staging=<b>`), chief-written on the
# captain's word and receipted DECIDED: to the epic room; ac_epic_branches_file
# / ac_epic_branch_entry (ac-lib.sh) own its archive-aware resolution and the
# `# retired <iso>` end-marker semantics. This script owns the verbs:
#
#   create <epic> <repo>   cut the recorded branch at the repo's freshest
#                          default tip (ac_freshest_ref - THE shared resolver).
#                          Origin-backed repo: fetch, then push the branch ref;
#                          no-origin repo: a local branch. Idempotent, and it
#                          NEVER moves an existing branch - exists = untouched.
#                          Refuses without a record entry: the record is the
#                          captain's word, the branch merely follows it.
#   verify <epic> <repo>   exit 0 iff the recorded, unretired branch exists
#                          (live ls-remote on origin repos; local show-ref on
#                          no-origin repos). Quiet - built to be gated on.
#   show   <epic>          the resolved record, verbatim, with its path.
#   retire <epic>          prepend `# retired <iso>` - the deliberate end of
#                          the fence (run at epic close). Idempotent. Nothing
#                          ever deletes the file: it is provenance.
#
# CHIEF-ONLY on the mutating verbs (create/retire), the domain_chief_only
# pattern: a PreToolUse hook cannot see a bash verb, so the guard lives here.
# A scoped chief (roomchief/domainchief) reads via show/verify and never
# mutates. Known residual, accepted: the record FILE sits in the family dir a
# promoted roomchief can edit - this fences the honest path, and the spawn
# fence enforces whatever the record says regardless of who wrote it.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/ac-lib.sh"

chief_only() {
  [ -z "${AC_SCOPE:-}" ] \
    || ac_die "$1 is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=$AC_SCOPE) - the integration branch is cut and retired on the captain's word by the fleet chief; a scoped chief reads the record (show/verify) and never mutates it"
}

repo_dir() {
  local d
  d="$AC_HOME/projects/$1"
  [ -d "$d/.git" ] || [ -f "$d/.git" ] || ac_die "no project clone at projects/$1"
  printf '%s\n' "$d"
}

has_origin() { git -C "$1" remote get-url origin >/dev/null 2>&1; }

entry_or_die() {
  # entry_or_die <verb> <epic> <repo> - prints the entry; dies with the verb's
  # own remedy on a missing record/entry, and names the retirement on rc 2.
  local verb="$1" epic="$2" repo="$3" entry rc=0
  entry="$(ac_epic_branch_entry "$epic" "$repo")" || rc=$?
  case "$rc" in
    0) printf '%s\n' "$entry" ;;
    2) ac_die "$verb: the $epic record is retired ($(head -1 "$(ac_epic_branches_file "$epic")")) - a retired epic has no integration branch; re-record on the captain's word if the epic truly reopens" ;;
    *) ac_die "$verb: no record entry for $repo under epic $epic - write data/$epic/branches first (the captain's word, receipted DECIDED: to the room)" ;;
  esac
}

cmd_create() {
  local epic="$1" repo="$2" entry branch dir sha
  chief_only create
  entry="$(entry_or_die create "$epic" "$repo")"
  branch="${entry%% *}"
  dir="$(repo_dir "$repo")"
  if has_origin "$dir"; then
    git -C "$dir" fetch origin --quiet \
      || ac_die "create: fetch origin failed for $repo - the branch must be cut at origin's real tip, not a stale mirror"
    if git -C "$dir" ls-remote --exit-code origin "refs/heads/$branch" >/dev/null 2>&1; then
      printf 'exists: %s on origin of %s (left untouched)\n' "$branch" "$repo"
      return 0
    fi
    sha="$(git -C "$dir" rev-parse "$(ac_freshest_ref "$dir")")"
    git -C "$dir" push --quiet origin "$sha:refs/heads/$branch" \
      || ac_die "create: pushing $branch to origin of $repo failed"
    printf 'created: %s on origin of %s at %s\n' "$branch" "$repo" "$sha"
  else
    if git -C "$dir" show-ref --verify --quiet "refs/heads/$branch"; then
      printf 'exists: %s in %s (left untouched)\n' "$branch" "$repo"
      return 0
    fi
    git -C "$dir" branch "$branch" "$(ac_freshest_ref "$dir")"
    printf 'created: %s in %s (local-only repo)\n' "$branch" "$repo"
  fi
}

cmd_verify() {
  local epic="$1" repo="$2" entry branch dir
  entry="$(entry_or_die verify "$epic" "$repo")"
  branch="${entry%% *}"
  dir="$(repo_dir "$repo")"
  if has_origin "$dir"; then
    git -C "$dir" ls-remote --exit-code origin "refs/heads/$branch" >/dev/null 2>&1 \
      || ac_die "verify: $branch is not on origin of $repo - create it (ac-epic-branch.sh create $epic $repo) before any story spawns against it"
  else
    git -C "$dir" show-ref --verify --quiet "refs/heads/$branch" \
      || ac_die "verify: $branch does not exist in $repo - create it (ac-epic-branch.sh create $epic $repo) before any story spawns against it"
  fi
}

cmd_show() {
  local epic="$1" f
  f="$(ac_epic_branches_file "$epic")" \
    || ac_die "show: no branches record for epic $epic (live or archived) - this epic was never branch-recorded"
  printf '# %s\n' "$f"
  cat "$f"
}

cmd_retire() {
  local epic="$1" f tmp
  chief_only retire
  f="$(ac_epic_branches_file "$epic")" \
    || ac_die "retire: no branches record for epic $epic - nothing to retire"
  if head -1 "$f" | grep -q '^# retired'; then
    printf 'already retired: %s\n' "$(head -1 "$f")"
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/eb-retire.XXXXXX")"
  { printf '# retired %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; cat "$f"; } >"$tmp"
  mv "$tmp" "$f"
  printf 'retired: epic %s record at %s\n' "$epic" "$f"
}

usage() { ac_die "usage: ac-epic-branch.sh create|verify <epic> <repo> | show|retire <epic>"; }

verb="${1:-}"
case "$verb" in
  create | verify) [ $# -eq 3 ] || usage; "cmd_$verb" "$2" "$3" ;;
  show | retire) [ $# -eq 2 ] || usage; "cmd_$verb" "$2" ;;
  *) usage ;;
esac
