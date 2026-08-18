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
#                           token that does NOT match the pinned grammar, so
#                           its dependency is unreadable; fix the LINE. Never
#                           READY and never offered by `queued`: an unreadable
#                           dependency read as "none" is how a one-character
#                           slip authorized starting a story whose blocker was
#                           still flying (the parser fills blockers_malformed;
#                           AC_DONELINE_AWK in ac-lib.sh owns that detection).
# HELD   <id> - captain hold - ... - the row carries the `[@held]` token
#                           (AGENTS.md section 9) as one of its `[...]`
#                           groups, OR a mis-typed attempt at it - sentinel
#                           present but wrong ("@hold" as well as "@held"),
#                           OR the sentinel forgotten outright (a ONE-WORD
#                           group, no whitespace, spelling "held"/"hold" -
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
#                           silently holds itself (full rule: ac-lib.sh's
#                           AC_DONELINE_AWK header, the one owner).
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
#                           captain's word.
# Backlog grammar (AGENTS.md section 9): story lines carry `epic:<id>`;
# `blocked-by: id1,id2 - reason` (comma-joined, no spaces, one space after the
# colon, lowercase). Done lines marked `[failed]`/`[abandoned]` are terminal
# but never satisfy a blocker. `[@held]` anywhere among a row's `[...]` groups
# is a captain hold - visible, never scheduled, cleared only by the captain.
set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

backlog="$(ac_records_dir)/backlog.md"
# No backlog = nothing to schedule - but `overlap` reads the ledger and the
# repos, not the backlog, and must never report "clean" by early exit.
[ -f "$backlog" ] || [ "${1:-}" = overlap ] || exit 0
cap="$(ac_config_read epic-parallel 2)"
case "$cap" in ''|*[!0-9]*) cap=2 ;; esac

# TSV snapshot of the ledger: section, id, marker, epic, blockers, malformed,
# hold, hold_malformed
snapshot() {
  # Field extraction is the ONE shared Done-line parser (AC_DONELINE_AWK in
  # ac-lib.sh); the marker is keyed on the FIXED grammar position (token after
  # the id), never a substring, so a story documenting its own terminal states
  # in prose (the epic maps' two-terminal-state convention) never reads as if it
  # carried one. This walk keeps its own section tracking.
  # Field 10 is the row's EFFECTIVE domain (crewdomain-token): its own token,
  # else its epic row's - the same inheritance ac_domain_tally and the promote
  # derivation apply, computed here in a first pass so every consumer fences
  # or displays domain rows off ONE derivation.
  awk "$AC_DONELINE_AWK"'
    NR == FNR { if (/^- \[/) { ac_doneline($0, o); if (o["domain"] != "") dm[o["id"]] = o["domain"] } next }
    /^## In flight/ { sec = "inflight"; next }
    /^## Queued/    { sec = "queued";   next }
    /^## Done/      { sec = "done";     next }
    /^- \[[ x]\] /  {
      ac_doneline($0, o)
      d = o["domain"]
      if (d == "" && o["epic"] != "") d = dm[o["epic"]]
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", sec, o["id"], o["terminal"], o["epic"], o["blockers"], o["blockers_malformed"], o["hold"], o["hold_malformed"], o["contract"], d
    }
  ' "$backlog" "$backlog"
}

report_lint() {
  # One WARN line per contract violation across the QUEUED rows, printed after
  # the report body. A judge, never a gate: an invalid token must be VISIBLE
  # at the scheduler while the row stays schedulable - enforcement belongs to
  # ac-brief.sh's escalation gate, which reads the same lint.
  snapshot | awk 'BEGIN { FS = "\t" } $1 == "queued" && $9 != "" { printf "%s\t%s\n", $2, $9 }' \
    | while IFS="$(printf '\t')" read -r lid lcon; do
        ac_contract_lint "$lcon" | while IFS= read -r v; do
          [ -n "$v" ] || continue
          printf 'WARN   %s contract: %s\n' "$lid" "$v"
        done
      done
}

cmd_report() {
  report_lint
  snapshot | awk -v cap="$cap" '
    BEGIN { FS = "\t" }
    {
      sec = $1; id = $2; marker = $3; epic = $4; blockers = $5; bad = $6; hold = $7; holdbad = $8; dom = $10; contract = $9
      state[id] = sec
      mark[id] = marker
      if (sec == "inflight" && epic != "" && marker != "epic") flying[epic]++
      if (sec == "queued") { qids[++n] = id; qepic[id] = epic; qblock[id] = blockers; qbad[id] = bad; qhold[id] = hold; qholdbad[id] = holdbad; qcon[id] = contract; qdom[id] = dom }
    }
    END {
      for (i = 1; i <= n; i++) {
        id = qids[i]
        # A line carrying a blocked-by token the pinned grammar did not accept
        # has NO readable dependency, and an unreadable one may never read as
        # none: empty blockers fall through to READY below, which is how a
        # one-character slip authorized starting a story whose blocker still
        # flies. Named here, never scheduled, until the line is fixed.
        if (qbad[id] != "") {
          printf "STUCK  %s blocked-by malformed - fix the line (AGENTS.md section 9: `blocked-by: id1,id2 - reason`)\n", id
          continue
        }
        # A captain hold - well-formed or mis-typed, wherever it sits among
        # the `[...]` groups on the line - refuses to offer the row, same
        # fail-closed direction as blocked-by malformed above; it never falls
        # through to a blocker/READY check.
        if (qholdbad[id] != "") {
          printf "HELD   %s hold malformed - fix the line: needs `[@held]` exactly, positioned in the leading run of `[...]` groups right after the id, or wrapped in backticks if it is only a mention (AGENTS.md section 9)\n", id
          continue
        }
        if (qhold[id] != "") {
          printf "HELD   %s - captain hold; release is a captain act (AGENTS.md section 9)\n", id
          continue
        }
        # An item with no blockers and no epic is trivially READY - it has no
        # blocker to wait on and no cap to sit under - so it falls through to
        # the same print. The auto-fly rule is defined over this report, and
        # it cannot start what the report never names.
        stuck = ""; waiting = 0
        if (qblock[id] != "") {
          m = split(qblock[id], bs, ",")
          for (j = 1; j <= m; j++) {
            b = bs[j]
            if (!(b in state)) { stuck = stuck sprintf("STUCK  %s blocker %s missing\n", id, b); continue }
            if (mark[b] == "failed" || mark[b] == "abandoned") { stuck = stuck sprintf("STUCK  %s blocker %s %s\n", id, b, mark[b]); continue }
            if (state[b] != "done") waiting = 1
          }
        }
        if (stuck != "") { printf "%s", stuck; continue }
        if (waiting) continue
        if (qepic[id] != "" && flying[qepic[id]] + started[qepic[id]] >= cap) continue
        started[qepic[id]]++
        # The contract rides the READY line as INFORMATION - a display, never a
        # scheduling condition: an invalid token must not stop the row, it must
        # be visible (the lint lines below the report are the judge).
        # A DOMAIN row is startable ONLY by promoting its domainchief - the
        # auto-fly rule is defined over this report, so the line must say the
        # start action or the chief flies it as an ordinary task and bypasses
        # the domainchief (crewdomain-token, red-team mitigation).
        dnote = (qdom[id] != "") ? sprintf(" {domain:%s - start = promote its domainchief}", qdom[id]) : ""
        if (qepic[id] != "" && qcon[id] != "") printf "READY  %s (epic:%s) [%s]%s\n", id, qepic[id], qcon[id], dnote
        else if (qepic[id] != "") printf "READY  %s (epic:%s)%s\n", id, qepic[id], dnote
        else if (qcon[id] != "") printf "READY  %s [%s]%s\n", id, qcon[id], dnote
        else printf "READY  %s%s\n", id, dnote
      }
    }
  '
}

cmd_queued() {
  # Reuses snapshot() so the backlog grammar keeps exactly ONE owner (this
  # file). Still a separate walk from cmd_report now that both select the same
  # startable set: this one answers "which family could take a freed slot" in
  # BARE IDS a consumer can pipe, so it must never emit a STUCK line -
  # ac-teardown.sh takes `head -n1` and would name a never-startable family as
  # the next promote candidate.
  snapshot | awk -v cap="$cap" '
    BEGIN { FS = "\t" }
    {
      sec = $1; id = $2; marker = $3; epic = $4; blockers = $5; bad = $6; hold = $7; holdbad = $8; dom = $10
      state[id] = sec
      mark[id] = marker
      if (sec == "inflight" && epic != "" && marker != "epic") flying[epic]++
      if (sec == "queued") { qids[++n] = id; qepic[id] = epic; qblock[id] = blockers; qbad[id] = bad; qhold[id] = hold; qholdbad[id] = holdbad; qdom[id] = dom }
    }
    END {
      for (i = 1; i <= n; i++) {
        id = qids[i]
        # Same refusal as cmd_report, and this selector carries no STUCK/HELD
        # line to say so: a malformed or held row is simply never offered.
        if (qbad[id] != "") continue
        if (qhold[id] != "" || qholdbad[id] != "") continue
        # DOMAIN rows are never offered here (crewdomain-token): this list
        # feeds auto-fly and teardown next-promote, and a domain row starts
        # only by promoting its domainchief - offering it would double-
        # schedule the family past the domain binding.
        if (qdom[id] != "") continue
        startable = 1
        m = split(qblock[id], bs, ",")
        for (j = 1; j <= m; j++) {
          b = bs[j]
          # An unknown blocker leaves state[b] empty - never "done" - so the
          # missing/failed/abandoned cases all fall out here.
          if (state[b] != "done" || mark[b] == "failed" || mark[b] == "abandoned") { startable = 0; break }
        }
        if (!startable) continue
        if (qepic[id] != "" && flying[qepic[id]] + started[qepic[id]] >= cap) continue
        started[qepic[id]]++
        print id
      }
    }
  '
}

cmd_watch_set() {
  # The roomchief's read-only AC_WATCH_ONLY set (header owns the contract):
  # <fam> plus its IN-FLIGHT story family ids, reusing snapshot()'s epic/story
  # grammar so the backlog stays the single owner of it. A non-epic family has
  # no story line naming it, so the set is EXACTLY <fam> - byte-identical to the
  # single-family arming (behavior: epic-roomchief-watch-only-omits-story-ids).
  local fam="${1:-}"
  [ -n "$fam" ] || ac_die "usage: ac-ready.sh watch-set <family>"
  snapshot | awk -F'\t' -v fam="$fam" '
    $1 == "inflight" && $4 == fam { set = set "," $2 }
    END { printf "%s%s\n", fam, set }
  '
}

cmd_validate() {
  local epic="${1:-}"
  [ -n "$epic" ] || ac_die "usage: ac-ready.sh validate <epic-id>"
  local snap stories line rc=0
  snap="$(snapshot)"
  stories="$(awk -v e="$epic" '$0 ~ "^- \\[[ x]\\] " e " \\[EPIC\\]" && match($0, /stories: [a-zA-Z0-9_,-]+/) { print substr($0, RSTART + 9, RLENGTH - 9) }' "$backlog" | head -n 1)"
  [ -n "$stories" ] || ac_die "no [EPIC] line with a stories: list for '$epic'"
  local s
  for s in ${stories//,/ }; do
    case "$s" in
      *-spec|*-arch|*-plan|*-review|*-ship|*-design|*-chief|*-r[0-9]|*-r[0-9][0-9])
        printf 'INVALID id %s: collides with a reserved stage suffix\n' "$s"; rc=1 ;;
      *[!a-zA-Z0-9_-]*)
        printf 'INVALID id %s: bad characters\n' "$s"; rc=1 ;;
    esac
    printf '%s\n' "$snap" | awk -F'\t' -v s="$s" '$2 == s { found = 1 } END { exit !found }' \
      || { printf 'MISSING story line for %s\n' "$s"; rc=1; }
  done
  # Acyclicity (Kahn) over blocked-by edges among this epic's stories.
  printf '%s\n' "$snap" | awk -F'\t' -v list="$stories" '
    BEGIN {
      n = split(list, ss, ",")
      for (i = 1; i <= n; i++) member[ss[i]] = 1
    }
    member[$2] && $5 != "" {
      m = split($5, bs, ",")
      for (j = 1; j <= m; j++) if (member[bs[j]]) { edge[bs[j] "->" $2] = 1; indeg[$2]++ }
    }
    END {
      removed = 1
      while (removed) {
        removed = 0
        for (s in member) {
          if (done[s] || indeg[s] > 0) continue
          done[s] = 1; removed = 1
          for (e in edge) {
            split(e, p, "->")
            if (p[1] == s && !cut[e]) { cut[e] = 1; indeg[p[2]]-- }
          }
        }
      }
      for (s in member) if (!done[s]) { print "CYCLE involving " s; bad = 1 }
      exit bad
    }
  ' || rc=1
  [ "$rc" = 0 ] && printf 'map OK: %s stories, DAG acyclic\n' "$(printf '%s' "$stories" | awk -F, '{print NF}')"
  return "$rc"
}

cmd_overlap() {
  # The intake file-interlock check; the header above owns the verb, the
  # ledger's shape and windows are ac-lib.sh's landing-ledger block.
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
        printf '%s\n' "$changed" | grep -qxF -- "$p" \
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
  "") cmd_report ;;
  queued) shift; cmd_queued "$@" ;;
  watch-set) shift; cmd_watch_set "$@" ;;
  validate) shift; cmd_validate "$@" ;;
  overlap) shift; cmd_overlap "$@" ;;
  *) awk 'NR>1{if(!/^#/)exit; print}' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
