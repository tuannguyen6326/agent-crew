#!/usr/bin/env bash
# ac-epic-ship.sh - the EPIC GATE + 2-PR exit for a branch-recorded epic
# (epic-branch-mech proposal v2 sections 3.5/3.6; captain rulings 2026-08-19:
# review/QA run per EPIC, and the ask-captain rules are unchanged inside one).
#
# Usage: ac-epic-ship.sh <epic> <repo> [--dry-run]
#
# PRECONDITIONS, all fail-closed, checked in order - the verb REFUSES with the
# exact remedy instead of doing a lesser thing:
#   1. RECORD: an unretired data/<epic>/branches entry for <repo>
#      (ac_epic_branch_entry), and the branch verifies
#      (ac-epic-branch.sh verify).
#   2. STORIES TERMINAL: every ledger row of the epic (`epic:<epic>` token,
#      plus the epic row itself) is checked off (`- [x]`). In-flight/queued
#      stories are listed in the refusal.
#   3. PARTIAL EPIC IS A CAPTAIN CALL (red-team M8): every [failed]/[abandoned]
#      story must carry a captain receipt in the epic room -
#      `DECIDED: epic-ship partial - <story> revert|keep ...` - because an
#      abandoned story that LANDED before dying leaves its commits in the
#      integration branch, and nothing else decides revert-vs-keep. Missing
#      receipts are listed; the chief posts the GATE:/ASK: and records the
#      captain's answer, then re-runs.
#   4. REVIEW ROUND AT THE TIP (captain ruling R1): data/<epic>/gate/review.json
#      must be an ac-verify codereview output whose reviewed_ref IS the current
#      epic tip and whose findings carry no action="fix". Anything else refuses
#      and prints the exact ac-verify command for the round.
#   5. QA WHEN PINNED: an epic row contract pinning `qa:yes` requires the
#      crew-qa pass attestation for the exact tip
#      (<repo>/.crew/qa/passed/<tip>*). The refusal names the crew-qa
#      invocation and the epic-tip TEST-RECEIPT caveat (a ut coverage row can
#      only qualify against a ship test receipt minted AT the tip - no story
#      run's SHA can stand in).
#
# THE 2-PR EXIT (merged-proof corrected per red-team B1: this fleet's own
# default merge is SQUASH, under which no epic commit is ever an ancestor of
# staging - so "PR-1 merged" is proven by ancestry OR by the forge reporting
# the RECORDED PR-1 url as MERGED, never by ancestry alone):
#   - staging recorded: PR-1 `branch -> staging` first; PR-2 `branch ->
#     default` only after PR-1 is proven merged.
#   - no staging: the single `branch -> default` PR.
#   Opened PR urls are recorded in data/<epic>/gate/ships.env (pr1_url=/
#   pr2_url=) and receipted to the room as `SHIPS: ...`; re-runs are
#   idempotent - an already-open PR is reported, not re-opened. The branch is
#   pushed first when the record says push=yes. --dry-run prints every
#   mutating command instead of running it. This verb NEVER merges - the
#   captain / merge authority does.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/ac-lib.sh"
ac_require git jq

chief_only() {
  [ -z "${AC_SCOPE:-}" ] \
    || ac_die "epic-ship is the CREWCHIEF's verb and this session is scoped (AC_SCOPE=$AC_SCOPE) - the exit of an epic is the fleet chief's act on the captain's word"
}

epic="${1:-}"; repo="${2:-}"; dry=0
[ "${3:-}" = "--dry-run" ] && dry=1
[ -n "$epic" ] && [ -n "$repo" ] || ac_die "usage: ac-epic-ship.sh <epic> <repo> [--dry-run]"
chief_only

run_or_print() {
  if [ "$dry" = 1 ]; then printf 'DRY-RUN: %s\n' "$*"; else "$@"; fi
}

# --- 1. record + branch ---------------------------------------------------------
entry="$(ac_epic_branch_entry "$epic" "$repo")" && rc=0 || rc=$?
case "$rc" in
  0) : ;;
  2) ac_die "the $epic record is retired - a retired epic has no exit to run" ;;
  *) ac_die "no branches record entry for $repo under epic $epic - this epic is not branch-recorded" ;;
esac
branch="${entry%% *}"
rest=" ${entry#"$branch"} "
staging=""
case "$rest" in *" staging="*) staging="${rest#* staging=}"; staging="${staging%% *}" ;; esac
push_flag=0
case "$rest" in *" push=yes "*) push_flag=1 ;; esac
"$(dirname "${BASH_SOURCE[0]}")/ac-epic-branch.sh" verify "$epic" "$repo"
dir="$AC_HOME/projects/$repo"
[ -d "$dir" ] || ac_die "no project clone at projects/$repo"

# --- 2 + 3. story terminality and the partial-epic captain receipts -----------
ledger="$(ac_records_dir)/backlog.md"
open_rows="" partials=""
while IFS= read -r line; do
  case "$line" in
    "- ["*) : ;;
    *) continue ;;
  esac
  rid="$(printf '%s\n' "$line" | awk "$AC_DONELINE_AWK"'{ ac_doneline($0, f); print f["id"] "\t" f["epic"] "\t" f["terminal"] }')"
  id="${rid%%$'\t'*}"; restf="${rid#*$'\t'}"; repic="${restf%%$'\t'*}"; term="${restf#*$'\t'}"
  # The epic's OWN row closes AFTER the ship (its Done line records the exit),
  # so only STORY rows are held to terminality here.
  [ "$id" = "$epic" ] && continue
  [ "$repic" = "$epic" ] || continue
  case "$line" in
    "- [x]"*) : ;;
    *) open_rows="$open_rows $id"; continue ;;
  esac
  case "$term" in failed | abandoned) partials="$partials $id" ;; esac
done <"$ledger"
[ -z "$open_rows" ] \
  || ac_die "epic $epic has non-terminal stories:${open_rows} - every story lands (or is failed/abandoned by the captain) before the epic exits"
if [ -n "$partials" ]; then
  room="$(ac_room_file "$epic")"
  missing=""
  for p in $partials; do
    grep -q "DECIDED: epic-ship partial - $p " "$room" 2>/dev/null || missing="$missing $p"
  done
  [ -z "$missing" ] \
    || ac_die "partial epic: [failed]/[abandoned] stories need a captain revert-or-keep receipt in the room -${missing} - post the GATE:, record the captain's answer as 'DECIDED: epic-ship partial - <story> revert|keep <words>', then re-run"
fi

# --- 4. review round at the tip -------------------------------------------------
# The exit judges origin's real tip - fetch first (a push does not necessarily
# refresh the clone's remote-tracking ref).
git -C "$dir" fetch origin --quiet 2>/dev/null || true
if git -C "$dir" rev-parse --verify --quiet "refs/remotes/origin/$branch" >/dev/null; then
  tip="$(git -C "$dir" rev-parse "refs/remotes/origin/$branch")"
elif git -C "$dir" rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
  tip="$(git -C "$dir" rev-parse "refs/heads/$branch")"
else
  ac_die "branch $branch resolves nowhere in the clone - fetch origin, or create it first"
fi
default="$(ac_default_branch "$dir")"
base="$(git -C "$dir" merge-base "$default" "$tip")"
gate_dir="$(ac_data_dir)/$epic/gate"
review="$gate_dir/review.json"
review_cmd="bin/ac-verify.sh codereview --repo $dir --ref $tip --family $epic --caller <your AC_CREW_ID> --base $base --intent $(ac_data_dir)/$epic/room.md --output $review"
[ -f "$review" ] \
  || ac_die "no epic review round on record - run ONE independent round over the whole integration diff first: $review_cmd"
r_ref="$(jq -r '.reviewed_ref // ""' "$review" 2>/dev/null || printf '')"
[ "$r_ref" = "$tip" ] \
  || ac_die "the recorded review round is for ref ${r_ref:-<none>}, not the current tip $tip - the tip moved, run a fresh round: $review_cmd"
n_fix="$(jq -r '[.findings[]? | select(.action == "fix")] | length' "$review" 2>/dev/null || printf 'ERR')"
[ "$n_fix" = 0 ] \
  || ac_die "the epic review round left $n_fix open fix finding(s) - fix on the epic branch (the ref change invalidates the round) and run a fresh round: $review_cmd"

# --- 5. qa when the epic row pins it -------------------------------------------
epic_contract="$(awk -v want="$epic" "$AC_DONELINE_AWK"'
  /^- \[/ { ac_doneline($0, f); if (f["id"] == want) { print f["contract"]; exit } }' "$ledger")"
case " $epic_contract " in
  *" qa:yes "*)
    if ! ls "$dir/.crew/qa/passed/$tip"* >/dev/null 2>&1; then
      ac_die "the epic row pins qa:yes and no crew-qa pass attestation exists for the tip $tip - run one behavioral round against the BUILT epic branch (crew-qa skill / bin/ac-qa.sh agent --target $tip ...). Note: a ut coverage row qualifies only against a ship TEST RECEIPT minted at this tip - no story run's SHA can stand in (epic-branch-mech M7)"
    fi
    ;;
esac

# --- ship: push, then the 2-PR (or 1-PR) exit ----------------------------------
mkdir -p "$gate_dir"
ships="$gate_dir/ships.env"
has_origin=0
git -C "$dir" remote get-url origin >/dev/null 2>&1 && has_origin=1
[ "$has_origin" = 1 ] || ac_die "epic-ship needs an origin remote on $repo - a local-only repo has no PR to open (land it by captain merge instead)"
[ "$push_flag" = 0 ] || run_or_print git -C "$dir" push origin "refs/heads/$branch:refs/heads/$branch"

pr1_url="$(ac_meta_get "$ships" pr1_url 2>/dev/null || printf '')"
open_pr() { # open_pr <base> <slot>
  local prbase="$1" slot="$2" url
  if [ "$dry" = 1 ]; then
    printf 'DRY-RUN: gh pr create --base %s --head %s --title "epic(%s): integration -> %s" (in %s)\n' "$prbase" "$branch" "$epic" "$prbase" "$dir"
    return 0
  fi
  url="$(cd "$dir" && gh pr create --base "$prbase" --head "$branch" \
    --title "epic($epic): integration -> $prbase" \
    --body "Integration branch \`$branch\` of epic \`$epic\` -> \`$prbase\`. Opened by ac-epic-ship.sh after the epic gate (stories terminal, review round clean at $tip). The captain merges." )" \
    || ac_die "gh pr create failed for $branch -> $prbase"
  printf '%s_url=%s\n' "$slot" "$url" >>"$ships"
  "$(dirname "${BASH_SOURCE[0]}")/ac-room.sh" post "$epic" crewchief "SHIPS: $slot $url (epic-ship)" >/dev/null 2>&1 || true
  printf 'opened %s: %s\n' "$slot" "$url"
}

if [ -n "$staging" ]; then
  merged1=0
  if git -C "$dir" merge-base --is-ancestor "$tip" "refs/remotes/origin/$staging" 2>/dev/null \
    || git -C "$dir" merge-base --is-ancestor "$tip" "refs/heads/$staging" 2>/dev/null; then
    merged1=1
  elif [ -n "$pr1_url" ] && command -v gh >/dev/null 2>&1; then
    # SQUASH-safe arm (red-team B1): the fleet's default merge rewrites
    # history, so ancestry alone would wedge forever - the forge's verdict on
    # the RECORDED url is the other honest proof.
    [ "$(cd "$dir" && gh pr view "$pr1_url" --json state --jq .state 2>/dev/null)" = MERGED ] && merged1=1
  fi
  if [ "$merged1" = 1 ]; then
    printf 'PR-1 (%s -> %s) proven merged; opening PR-2\n' "$branch" "$staging"
    open_pr "$default" pr2
  elif [ -n "$pr1_url" ]; then
    printf 'PR-1 already open, not merged yet: %s - PR-2 held until it merges\n' "$pr1_url"
  else
    open_pr "$staging" pr1
    printf 'PR-2 (-> %s) held until PR-1 is proven merged (ancestry, or the forge on the recorded url)\n' "$default"
  fi
else
  if [ -n "$(ac_meta_get "$ships" pr2_url 2>/dev/null || printf '')" ]; then
    printf 'production PR already recorded: %s\n' "$(ac_meta_get "$ships" pr2_url)"
  else
    open_pr "$default" pr2
  fi
fi
