#!/usr/bin/env bash
# ac-ready.sh - the queued-work scheduler primitive and DAG validator.
# Idempotent and read-only over records/backlog.md: run it at every landing
# checkpoint, wake drain, session start, and /debrief - an interrupted
# checkpoint heals at the next run.
#
#   ac-ready.sh                 # default report: READY / STUCK / HELD lines.
#                               #   EVERY startable OR held Queued item, plain
#                               #   and epic alike, in backlog order (=
#                               #   priority order), uncapped and untruncated -
#                               #   the captain auto-fly rule (records/captain.md
#                               #   2026-07-21) is defined over this report,
#                               #   so an item it never names can never be
#                               #   started. Prints NOTHING when there is
#                               #   nothing - safe to wire into digests.
#   ac-ready.sh queued          # the SAME startable set as bare ids: no STUCK
#                               #   lines, no HELD lines, no `(epic:<e>)`
#                               #   decoration. That is what makes it pipeable -
#                               #   ac-teardown.sh takes `head -n1` of it, where
#                               #   a STUCK or HELD line would name a
#                               #   never-startable family as the next promote
#                               #   candidate. A selector for advisories, never
#                               #   the scheduler's word.
#   ac-ready.sh watch-set <fam> # the roomchief's read-only AC_WATCH_ONLY set:
#                               #   <fam> plus its IN-FLIGHT story family ids
#                               #   (an epic), comma-joined, family first and
#                               #   stories in backlog order. A non-epic family
#                               #   has no stories, so the set is EXACTLY <fam>
#                               #   - byte-identical to the pre-epic
#                               #   single-family arming. Recomputed at each
#                               #   re-arm so a scoped watcher tracks its
#                               #   stories as they start and land; a story's
#                               #   pane then routes to the epic roomchief's
#                               #   spool, not the fleet's.
#   ac-ready.sh validate <epic> # mechanical story-map checks: every listed
#                               #   story has a backlog line, ids are valid
#                               #   single tokens (no reserved -spec/-arch/
#                               #   -plan/-review/-ship/-design/-chief/-rN
#                               #   suffixes), and the blocked-by graph among
#                               #   the epic's stories is ACYCLIC
#   ac-ready.sh overlap --semantic '<order text>'  # the System One fold-or-mint proposer
#   ac-ready.sh overlap <path>... # the intake file-interlock check (read-
#                               #   only, prints NOTHING when clean). Per
#                               #   path, one line per hit:
#                               #   LANDED - a state/.landings record <7d old
#                               #     touching the path: family, age, and its
#                               #     data/<family>/room.md as required
#                               #     reading (ledger contract: ac-lib.sh's
#                               #     landing-ledger block)
#                               #   INFLIGHT - a crew/* branch in a projects/
#                               #     repo whose diff vs the default branch
#                               #     touches the path
#                               #   BRIEF - an in-flight brief (data/<id>/
#                               #     brief.md with a live state/<id>.meta)
#                               #     that names the path
#
# READY  <id> (epic:<e>)  - a Queued item that can START NOW: blockers ALL
#                           Done clean, and - for a story - its epic under
#                           config/epic-parallel (default 2) in-flight
#                           stories. A plain item satisfies both trivially,
#                           so it is READY on the same terms.
# STUCK  <id> blocker <b> <missing|failed|abandoned> - a dependent that can
#                           never start; raise ONE ASK in the epic room
# STUCK  <id> blocked-by malformed - ... - the row carries a `blocked-by`
#                           token the pinned grammar did not read, so a
#                           dependency is unreadable; fix the LINE. Never
#                           READY and never offered by `queued`: an unreadable
#                           dependency read as "none" is how a one-character
#                           slip authorized starting a story whose blocker was
#                           still flying (the parser fills blockers_malformed;
#                           src/backlog.ts owns that detection).
# HELD   <id> - captain hold - ... - the row carries the `[@held]` token
#                           (docs/backlog.md) as one of its `[...]`
#                           groups, OR a mis-typed attempt at it - sentinel
#                           present but wrong ("@hold" as well as "@held"),
#                           OR the sentinel forgotten outright (a ONE-WORD
#                           group, no space or TAB, spelling "held"/"hold" -
#                           `[held]`, `[hold]`, `[on-hold]`). NEVER READY and
#                           never offered by `queued`, same fail-closed
#                           direction as a malformed `blocked-by` - a hold is
#                           heavier than a dependency, so a slip may not read
#                           as "no hold" either. NOT pinned to rp[2] the way
#                           `[EPIC]`/`[failed]`/`[abandoned]` are: on a live
#                           ledger rp[2] is usually ALREADY another bracket
#                           tag (`[CAPTAIN-ORDERED ...]`, `[MONITOR ...]`),
#                           so `[@held]` has to be found wherever it actually
#                           sits, but AUTHORITY still needs POSITION: only a
#                           group in the leading run of `[...]` groups right
#                           after the id counts as the real token, so a row,
#                           receipt, or doc line that quotes `[@held]` (wrapped
#                           in backticks) or writes it in the wrong place never
#                           silently holds itself (full rule: the header of
#                           src/backlog.ts, the one owner).
#                           THE `@` SENTINEL is what the WELL-FORMED token and
#                           one malformed rule match on, not the bare word: a
#                           live ledger row was measured to false-positive on
#                           a bracket-syntax-only design, because this
#                           grammar's OTHER bracket tags (`[SLICE ...]`,
#                           `[CAPTAIN ORDER LANDED ...]`) carry free-text
#                           prose that uses "held"/"hold" as an ordinary
#                           English verb ("the guardrail held"). `@`
#                           immediately before the word is the part that
#                           prose never writes, so matching on it keeps the
#                           hold token distinguishable from a sentence inside
#                           a free-text tag. The SECOND malformed rule needs
#                           no sentinel: a group whose entire content is ONE
#                           WORD can never be a free-text tag's prose (a
#                           sentence is always multi-word), so "held"/"hold"
#                           alone in a one-word group is still a hold
#                           attempt, measured zero false positives against
#                           the live ledger's actual one-word bracket groups
#                           (`[x]`, `[abandoned]`, `[failed]`, `[project]`,
#                           `[needs-decision]`, `[0]`). Neither rule is a
#                           whole-line substring scan like `blocked-by`'s
#                           malformed check - every match stays scoped to one
#                           `[...]` group. Release is a CAPTAIN act: no
#                           script here or elsewhere clears `[@held]`; a
#                           chief removes it from the line by hand on the
#                           captain's word - EXCEPT the dated arm
#                           `[@held until <YYYY-MM-DD>]`, which releases
#                           ITSELF: HELD before that date, READY on and after
#                           it, so a time-bound hold needs no hand-edit. The
#                           parser extracts the date (src/backlog.ts's
#                           hold_until), this scheduler is the one that
#                           compares it to today. A hold whose date shape is
#                           anything else is not a dated hold: it reads
#                           `hold malformed`, the same fail-closed direction
#                           as every other slip, never an accidental release.
# Backlog grammar (docs/backlog.md): story lines carry `epic:<id>`;
# `blocked-by: id1,id2 - reason` (comma-joined, no spaces, one space after the
# colon, lowercase). Done lines marked `[failed]`/`[abandoned]` are terminal
# but never satisfy a blocker. `[@held]` anywhere among a row's `[...]` groups
# is a captain hold - visible, never scheduled, cleared only by the captain.
#
# OVERLAP --semantic (the System One fold-or-mint proposer, config/jev). The
# path interlock above answers "same FILE surface"; docs/backlog.md's rule is wider
# - "the same file surface, the same mechanism, or the same defect class, not
# the same wording" - and reading every open row for it was the chief's eyes
# alone. `overlap --semantic '<order text>'` asks bin/ac-jev.sh one choice
# question per OPEN row (In flight + Queued, never Done), all in ONE request
# over one state (the order, then every open row's line and body), and under
# `on` prints the rows the model calls related - `overlap-flying  <id>  p=<p>`
# for In flight (never folded into: its brief is fixed), `fold-candidate  <id>
# p=<p>` for Queued - in ledger order, closed by `state_sha=<sha>`, the key
# `ac-jev.sh label --site overlap` takes for the fold/mint the chief really
# made. Off or absent prints nothing and makes no request; shadow logs only.
# It proposes: folding stays the chief's read of the row, and an In flight
# row stays off limits whatever the model says. A ledger whose open rows
# exceed the adapter's request cap is one reason line and no proposal, the
# adapter's own fail direction; chunking is not built until a fleet's ledger
# needs it.
set -euo pipefail
# The report, queued, watch-set and validate run in src/ready.ts; overlap, glue
# around git, grep and ac-jev, runs here. ac-lib.sh is sourced only past this
# dispatch, so the ledger verbs never pay for it.
case "${1:-}" in
  "" | queued | watch-set | validate)
    . "$(dirname "${BASH_SOURCE[0]}")/ac-bun.sh"
    ac_bun_exec src/ready.ts "$@"
    ;;
esac
. "$(dirname "$0")/ac-lib.sh"
# overlap reads the home only inside command substitutions, which swallow its
# refusal - without this a homeless check would print nothing, the clean answer.
( ac_home >/dev/null )

cmd_overlap_semantic() {
  # overlap --semantic '<order text>' - the System One fold-or-mint proposer
  # (header: OVERLAP --semantic). One choice question per OPEN row (In flight
  # + Queued, never Done), all in ONE request over one state: the order plus
  # every open row's line and body. Prints only under config/jev=on:
  # `overlap-flying  <id>  p=<p>` for an In flight row the model calls
  # related (never folded into - its brief is fixed), `fold-candidate  <id>
  # p=<p>` for a Queued one, ledger order, then `state_sha=<sha>` - the key
  # `ac-jev.sh label --site overlap` takes for the chief's real fold/mint.
  local order="$1" f rows id sec rest out
  [ -n "$order" ] || ac_die "usage: ac-ready.sh overlap --semantic '<order text>'"
  f="$(ac_records_dir)/backlog.md"
  [ -f "$f" ] || return 0
  rows="$(LC_ALL=C awk "$AC_DONELINE_AWK"'
    /^## In flight/ { sec = "in flight"; next }
    /^## Queued/    { sec = "queued"; next }
    /^## /          { sec = ""; next }
    sec == "" { next }
    /^- \[/ { ac_doneline($0, o); id = o["id"]; if (id != "") printf "%s\t%s\t%s\n", id, sec, $0; next }
    /^[ \t]+[^ \t]/ && id != "" { sub(/^[ \t]+/, ""); printf "%s\t%s\tbody\t%s\n", id, sec, $0 }
  ' "$f")"
  [ -n "$rows" ] || return 0
  local state; state="$(mktemp "${TMPDIR:-/tmp}/ac-ready-semantic.XXXXXX")"
  {
    printf 'ORDER:\n%s\n\nOPEN ROWS:\n' "$order"
    while IFS=$'\t' read -r id sec rest; do
      case "$rest" in body*) printf '  %s\n' "${rest#body	}" ;; *) printf '[%s] (%s) %s\n' "$id" "$sec" "$rest" ;; esac
    done <<<"$rows"
  } >"$state"
  local -a q=()
  while IFS=$'\t' read -r id sec rest; do
    case "$rest" in body*) continue ;; esac
    q+=(--choice "$id" \
        --instructions "Is the backlog row [$id] related to the ORDER? Related means the same file surface, the same mechanism, or the same defect class, not the same wording." \
        --criteria related='Related: the same file surface, the same mechanism, or the same defect class, not the same wording.' \
          unrelated='Unrelated: a different surface, mechanism and defect class.' \
          unclear='Not enough reliable evidence.')
  done <<<"$rows"
  out="$("$(dirname "$0")/ac-jev.sh" ask --site overlap --state-file "$state" "${q[@]}")" || out=''
  if [ -n "$out" ]; then
    while IFS=$'\t' read -r id sec rest; do
      case "$rest" in body*) continue ;; esac
      jq -r --arg id "$id" --arg tag "$([ "$sec" = queued ] && printf fold-candidate || printf overlap-flying)" \
        '.[$id] | select(.choice == "related") | "\($tag)  \($id)  p=\(.p.related)"' <<<"$out"
    done <<<"$rows"
    printf 'state_sha=%s\n' "$("$(dirname "$0")/ac-jev.sh" sha --state-file "$state")"
  fi
  rm -f "$state"
}

cmd_overlap() {
  # The intake file-interlock check; the header above owns the verb, the
  # ledger's shape and windows are ac-lib.sh's landing-ledger block.
  [ "${1:-}" != --semantic ] || { cmd_overlap_semantic "${2:-}"; return 0; }
  [ "$#" -gt 0 ] || ac_die "usage: ac-ready.sh overlap <path>..."
  local hits fam age p repo def b changed bf id
  hits="$(ac_landing_overlaps 604800 '' "$@")"
  if [ -n "$hits" ]; then
    while IFS=$'\t' read -r fam age p; do
      # ac_room_file, not a composed data/<fam>/room.md: an overlapping family
      # has LANDED, so it is the class bin/ac-archive.sh moves, and this pointer
      # is required reading - it must name where the room actually is.
      printf 'LANDED  %s by %s %dh ago - read %s\n' "$p" "$fam" "$((age / 3600))" "$(ac_room_file "$fam")"
    done <<<"$hits"
  fi
  for repo in "$(ac_projects_dir)"/*; do
    [ -d "$repo" ] || continue
    git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
    def="$(ac_default_branch "$repo")"
    while IFS= read -r b; do
      [ -n "$b" ] || continue
      changed="$(git -C "$repo" diff --name-only "$def...$b" 2>/dev/null || true)"
      [ -n "$changed" ] || continue
      for p in "$@"; do
        grep -qxF -- "$p" <<<"$changed" \
          && printf 'INFLIGHT  %s on %s (repo: %s)\n' "$p" "$b" "$(basename "$repo")"
      done
    done < <(git -C "$repo" for-each-ref --format='%(refname:short)' 'refs/heads/crew/*')
  done
  for bf in "$(ac_data_dir)"/*/brief.md; do
    [ -f "$bf" ] || continue
    id="$(basename "$(dirname "$bf")")"
    [ -f "$(ac_state_dir)/$id.meta" ] || continue
    for p in "$@"; do
      grep -qF -- "$p" "$bf" \
        && printf 'BRIEF  %s named in in-flight data/%s/brief.md\n' "$p" "$id"
    done
  done
  return 0
}

case "${1:-}" in
  overlap) shift; cmd_overlap "$@" ;;
  *) awk 'NR>1{if(!/^#/)exit; print}' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
