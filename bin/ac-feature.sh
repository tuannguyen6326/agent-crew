#!/usr/bin/env bash
# ac-feature.sh - the FEATURE integration-branch verbs (feature-branch-mech).
#
# A feature accumulates SEVERAL crew tasks on one branch per repo that stays
# LOCAL until ship: create cuts it at the recorded target's freshest tip and
# never pushes; member rows bind with the `feature:<name>` ledger token
# (AC_DONELINE_AWK's f["feature"]) and land onto the branch through the
# ordinary ac-merge-local path via the shared resolver (ac_epic_base_for);
# `ship` publishes the branch ONCE and opens one PR per repo to the recorded
# target. The design pins: a standalone mechanism reusable by
# epic-branch-mech; many tasks per feature; one review/QA gate at the tip
# before push; the target is captain-recorded.
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

cmd_ship() {
  # SHIP - the gated exit: ONE review/QA gate at the tip, before push.
  # Preconditions, all fail-closed, checked in order - the verb
  # REFUSES with the exact remedy instead of doing a lesser thing:
  #   1. RECORD: an unretired push=deferred entry, and the LOCAL branch
  #      verifies.
  #   2. MEMBERS TERMINAL: every `feature:<name>` row is checked off (the
  #      container row, id = the feature name, closes AFTER the ship and is
  #      skipped). A member ALSO carrying epic: names two integration targets
  #      and refuses outright. [failed]/[abandoned] members each need a
  #      captain receipt in the room - `DECIDED: feature-ship partial - <id>
  #      revert|keep ...` - because a dead member's landed commits sit in the
  #      branch and nothing else decides revert-vs-keep.
  #   3. NO TARGET DRIFT: the target's freshest tip must be an ancestor of
  #      the feature tip - the branch cut at the target's tip is what makes
  #      the single PR conflict-free by construction, so a drifted feature
  #      refuses toward a rebase in a LEASED worktree on the captain's word,
  #      never an auto-rebase.
  #   4. REVIEW AT THE LOCAL TIP: data/<feature>/gate/review.json must be an
  #      ac-verify codereview output whose reviewed_ref IS the current local
  #      tip and whose findings carry no action="fix". A fix lands as its own
  #      member onto the branch, then ship re-runs at the new tip.
  #   5. QA WHEN PINNED: a container row contract pinning qa:yes requires the
  #      crew-qa pass attestation for the exact tip
  #      (<repo>/.crew/qa/passed/<tip>*).
  # Then, in order: push origin <branch> (the ONE deferred publication - an
  # AGENTS.md section-1 sanctioned write), ONE `gh pr create --base <target>`
  # PER REPO ("single PR" means no 2-PR staging chain, never one PR for a
  # multi-repo feature - two repos cannot share a PR), the url recorded in
  # data/<feature>/gate/ships.env under the PER-REPO key pr_url_<repo> and
  # receipted SHIPS: to the room. Re-runs are idempotent - a recorded PR is
  # reported, not re-opened. This verb NEVER merges - the captain does.
  # KNOWN RESIDUAL on a multi-repo feature: gate/review.json is one slot for
  # the whole feature, so each repo's ship needs the review round re-run at
  # ITS tip before its exit - loud (the ref-mismatch refusal names it), never
  # silent, but a per-repo receipt is its own slice if the friction earns it.
  local feature="$1" repo="$2" dry="${3:-}"
  local entry branch dir target tip target_tip base ledger room
  local gate_dir ships review review_cmd r_ref n_fix pr_url url
  local line rid id rfeat repic term open_rows="" partials="" missing="" p container_contract
  chief_only ship
  ac_require jq
  entry="$(entry_or_die ship "$feature" "$repo")"
  branch="${entry%% *}"
  dir="$(repo_dir "$repo")"
  target="$(entry_target "$entry" "$dir")"
  cmd_verify "$feature" "$repo"

  run_or_print() {
    if [ "$dry" = "--dry-run" ]; then printf 'DRY-RUN: %s\n' "$*"; else "$@"; fi
  }

  # --- 2. member terminality, epic-poisoned rows, partial receipts ------------
  ledger="$(ac_records_dir)/backlog.md"
  while IFS= read -r line; do
    case "$line" in "- ["*) : ;; *) continue ;; esac
    rid="$(printf '%s\n' "$line" | awk "$AC_DONELINE_AWK"'
      { ac_doneline($0, f); print f["id"] "\t" f["feature"] "\t" f["epic"] "\t" f["terminal"] }')"
    id="${rid%%$'\t'*}"; rid="${rid#*$'\t'}"
    rfeat="${rid%%$'\t'*}"; rid="${rid#*$'\t'}"
    repic="${rid%%$'\t'*}"; term="${rid#*$'\t'}"
    [ "$id" = "$feature" ] && continue
    [ "$rfeat" = "$feature" ] || continue
    [ -z "$repic" ] \
      || ac_die "member $id carries epic:$repic BESIDE feature:$feature - two integration targets on one row is a ledger defect; fix the row before the exit"
    case "$line" in
      "- [x]"*) : ;;
      *) open_rows="$open_rows $id"; continue ;;
    esac
    case "$term" in failed | abandoned) partials="$partials $id" ;; esac
  done <"$ledger"
  [ -z "$open_rows" ] \
    || ac_die "feature $feature has non-terminal members:${open_rows} - every member lands (or is failed/abandoned by the captain) before the feature ships"
  if [ -n "$partials" ]; then
    room="$(ac_room_file "$feature")"
    for p in $partials; do
      grep -q "DECIDED: feature-ship partial - $p " "$room" 2>/dev/null || missing="$missing $p"
    done
    [ -z "$missing" ] \
      || ac_die "partial feature: [failed]/[abandoned] members need a captain revert-or-keep receipt in the room -${missing} - post the GATE:/ASK:, record the captain's answer as 'DECIDED: feature-ship partial - <id> revert|keep <words>', then re-run"
  fi

  # --- 3. target drift ---------------------------------------------------------
  # The LOCAL branch is the truth (deferred push), but the TARGET's truth may
  # live on origin - fetch first so the drift check judges the real target.
  git -C "$dir" fetch origin --quiet 2>/dev/null || true
  tip="$(git -C "$dir" rev-parse "refs/heads/$branch")"
  target_tip="$(git -C "$dir" rev-parse "$(ac_freshest_ref "$dir" "$target")")"
  git -C "$dir" merge-base --is-ancestor "$target_tip" "$tip" \
    || ac_die "feature $branch is behind its target $target - rebase the branch onto $target in a LEASED worktree on the captain's word (never the primary checkout, never automatic), re-run the review round at the new tip, then re-run the ship"

  # --- 4. review round at the local tip ----------------------------------------
  base="$(git -C "$dir" merge-base "$target_tip" "$tip")"
  gate_dir="$(ac_data_dir)/$feature/gate"
  review="$gate_dir/review.json"
  review_cmd="bin/ac-verify.sh codereview --repo $dir --ref $tip --family $feature --caller <your AC_CREW_ID> --base $base --intent $(ac_data_dir)/$feature/room.md --output $review"
  [ -f "$review" ] \
    || ac_die "no feature review round on record - run ONE independent round over the whole integration diff first: $review_cmd"
  r_ref="$(jq -r '.reviewed_ref // ""' "$review" 2>/dev/null || printf '')"
  [ "$r_ref" = "$tip" ] \
    || ac_die "the recorded review round is for ref ${r_ref:-<none>}, not the current tip $tip - the tip moved, run a fresh round: $review_cmd"
  n_fix="$(jq -r '[.findings[]? | select(.action == "fix")] | length' "$review" 2>/dev/null || printf 'ERR')"
  [ "$n_fix" = 0 ] \
    || ac_die "the feature review round left $n_fix open fix finding(s) - fix on the feature branch (the ref change invalidates the round) and run a fresh round: $review_cmd"

  # --- 5. qa when the container row pins it -------------------------------------
  container_contract="$(awk -v want="$feature" "$AC_DONELINE_AWK"'
    /^- \[/ { ac_doneline($0, f); if (f["id"] == want) { print f["contract"]; exit } }' "$ledger")"
  case " $container_contract " in
    *" qa:yes "*)
      if ! ls "$dir/.crew/qa/passed/$tip"* >/dev/null 2>&1; then
        ac_die "the container row pins qa:yes and no crew-qa pass attestation exists for the tip $tip - run one behavioral round against the BUILT feature branch (crew-qa skill / bin/ac-qa.sh agent --target $tip ...)"
      fi
      ;;
  esac

  # --- the exit: deferred push, then this repo's ONE PR -------------------------
  # The record slot is PER REPO (feature-ship-single-pr-slot, lab-measured):
  # ships.env keys pr_url_<repo> (non-alnum -> _), because a multi-repo
  # feature ships one PR per repo and a single shared key let repo one's url
  # short-circuit every later repo into a silent rc-0 no-op. A pre-fix bare
  # pr_url= is dead legacy the reader ignores - it cannot be attributed to a
  # repo from the file alone, and gh itself refuses a duplicate head PR
  # loudly, so ignoring it can never silently double-open.
  git -C "$dir" remote get-url origin >/dev/null 2>&1 \
    || ac_die "feature-ship needs an origin remote on $repo - a local-only repo has no PR to open (land it by captain merge instead)"
  mkdir -p "$gate_dir"
  ships="$gate_dir/ships.env"
  repo_key="pr_url_${repo//[^a-zA-Z0-9]/_}"
  pr_url="$(ac_meta_get "$ships" "$repo_key" 2>/dev/null || printf '')"
  if [ -n "$pr_url" ]; then
    printf 'PR already recorded: %s\n' "$pr_url"
    return 0
  fi
  run_or_print git -C "$dir" push origin "refs/heads/$branch:refs/heads/$branch"
  if [ "$dry" = "--dry-run" ]; then
    printf 'DRY-RUN: gh pr create --base %s --head %s --title "feature(%s): %s -> %s" (in %s)\n' \
      "$target" "$branch" "$feature" "$branch" "$target" "$dir"
    return 0
  fi
  url="$(cd "$dir" && gh pr create --base "$target" --head "$branch" \
    --title "feature($feature): $branch -> $target" \
    --body "Feature branch \`$branch\` of \`$feature\` -> \`$target\`. Opened by ac-feature.sh ship after the feature gate (members terminal, review round clean at $tip). The captain merges.")" \
    || ac_die "gh pr create failed for $branch -> $target"
  printf '%s=%s\n' "$repo_key" "$url" >>"$ships"
  "$(dirname "${BASH_SOURCE[0]}")/ac-room.sh" post "$feature" crewchief "SHIPS: pr $url ($repo, feature-ship)" >/dev/null 2>&1 || true
  printf 'opened pr: %s\n' "$url"
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
  ship)
    [ $# -eq 3 ] || { [ $# -eq 4 ] && [ "$4" = "--dry-run" ]; } \
      || ac_die "usage: ac-feature.sh ship <feature> <repo> [--dry-run]"
    cmd_ship "$2" "$3" "${4:-}" ;;
  *)
    ac_die "usage: ac-feature.sh create|verify <feature> <repo> | show|retire <feature> | ship <feature> <repo> [--dry-run]" ;;
esac
