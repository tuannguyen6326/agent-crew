#!/usr/bin/env bash
# ac-learn.sh - automatic fleet-local Learning entrypoint.
#
# Usage:
#   ac-learn.sh tick [<landing-id>]
#   ac-learn.sh autoroom
#   ac-learn.sh suite [<task-id>]
#   ac-learn.sh run
#   ac-learn.sh note <line>...          # place landing lessons under `## Pending`
#   ac-learn.sh land <candidate-file>   # compatibility-only manual landing
#   ac-learn.sh promote <skill-name>    # fail-closed compatibility command
#   ac-learn.sh maintenance status|resume <txid>|abandon <txid>
#
# `tick` advances the lock-protected Learning generation/cadence and reports the
# resulting count. A keyed landing tick is idempotent through state/.learn-ticks.
# The first threshold crossing publishes one learning-due wake; `autoroom`
# evaluates the durable level and uses ac-spawn.sh's atomic `.meta-claims`
# protocol, so concurrent drains can create at most one learning chief.
#
# A DUE `autoroom` promotes nothing until records/learnings.md clears the
# LEDGER SHAPE GATE (learn_ledger_shape_gate, checked FIRST, before the suite
# gate below - two greps versus a whole pane run): an un-canonicalized legacy
# rung-qualified pointer row, or a canonical `[distilled -> ...]` row whose
# `[evidence]` link names a records/learnings-archive/<name>.md that does not
# exist, each force every per-candidate plan to bundle a ledger-wide repair
# that the maintenance gate then correctly refuses as over-broad - spending the
# whole DISTILL cycle on candidates it was always going to lose (measured
# twice: 2026-07-28 7/7 revise, 2026-08-03 5/5 revise). Neither shape is
# auto-repaired; the gate HOLDS and prints the one line naming the defect and
# its remedy, same contract as the suite gate.
#
# A DUE `autoroom` ALSO promotes nothing until the FULL SUITE is green for the
# current cycle and tree: it starts `suite` as its own paned task and HOLDS,
# printing what it is waiting on. `suite` runs the bare tests/run-suite.sh and
# records one verdict. The gate's contract is above learn_suite_record.
#
# `run` snapshots the retro window, active fleet-local learned skills, and the
# fleet ledgers into data/learning-<epoch>/. A fresh `panes.learning` scout
# writes retro.md, report.md, and candidate files only inside that run. A run is
# complete only when both retro.md and report.md are non-empty and the report
# declares status ok; an incomplete scout cannot advance either cadence.
#
# Each skill/patch/crewmate candidate is converted to one immutable closed action plan
# plus input manifest. The independent explicit maintenance gate
# (`ac-gate.sh maintenance --mode learning`) binds its receipt to both hashes.
# A matching `continue` receipt authorizes the shared backup-first, journaled,
# idempotent maintenance transaction. `revise` preserves Pending without asking
# the captain. `ask-captain`, an unavailable/invalid gate, contradictory input,
# or `kind: rule` emits a durable room question with the exact plan hash; captain
# silence never approves. Learning never invokes QA, unit tests, or service
# validation.
#
# Successful skill/patch transactions write only <fleet>/skills/<name>/SKILL.md
# (a crewmate transaction its CREWMATE-learned.md rewrite instead),
# append source evidence verbatim to records/learnings-archive/<name>.md, remove
# consumed records from `## Pending`, and maintain one canonical fleet-local
# pointer under `## Distilled`:
#   - [distilled -> <name>] sources=<n> updated=<date> (...)
# The rewrite is EXACT over every frame this writer can itself emit: outside the
# consumed records and that pointer row it reproduces the ledger byte for byte -
# blank separators, and the surplus seam blanks an older ledger accreted,
# included - so the maintenance gate never sees an edit broader than the plan
# declared, in either direction. It is NOT a fixed point on a frame the writer
# cannot emit - surplus blanks between the title and `## Pending`, or an empty
# `## Pending` exactly two blank lines from `## Distilled` - because one blank
# per seam cannot round-trip them; such a ledger was hand-edited, and the
# transaction canonicalizes it. The `[evidence]` link is emitted only for a pointer
# whose records/learnings-archive/<name>.md already exists or is staged by this
# same transaction, so the index never links a file that does not exist.
# A pointer can never contradict the evidence it links either: once a skill HAS
# an archive, the transaction refuses unless the `sources=` it is about to
# publish equals the total that archive's `source-count:` lines declare. That is
# what closes `counts[name] += count` - learn_ledger_split aggregates every
# pointer row sharing a name, so a duplicated row inflates a claim nothing else
# reconciles. It is a code invariant, not a data repair: a skill with no archive
# has no evidence to reconcile against, keeps its pre-existing count, and is
# already written without an `[evidence]` link.
# The transaction resets only the generation it captured. It then ticks Curate
# and runs automatic Curate when its own cadence is due.
#
# `note` is the ONE placing append onto the ledger, and the reason every
# instruction site names it instead of describing a hand-edit: it inserts its
# arguments verbatim at the end of the `## Pending` body, where the retro window
# and the transaction read them. An append at end-of-file lands after
# `## Distilled` - the pointer index - which learn_ledger_split drops, so a
# landing lesson written by hand is deleted by the next transaction. It is pure
# insertion (every existing line is reproduced exactly once, so no pending
# source can be lost), carries no opinion about a lesson's own shape, mints the
# canonical frame when the ledger is absent, and refuses a line that is itself a
# section marker.
#
# The apply is RESUMABLE, not all-or-nothing: it mutates N independent files
# and no shell commits N renames atomically, so each action is idempotent by
# hash instead and a replay of the same plan finishes exactly what did not
# land. `maintenance` is the operator surface for that. An UNSETTLED
# transaction refuses every other Learning/Curate transaction, and neither
# `run` (fresh run_id) nor `land` (fresh txid) can ever finish the one holding
# the claim - so a crash between the claim and the final `complete`, or a plan
# whose second action failed, wedged the loop until someone read state/ by
# hand. `status` names every unsettled transaction (as does the session-start
# digest), `resume <txid>` replays its recorded plan through the same
# hash-bound apply, and `abandon <txid>` settles one that cannot be replayed -
# keeping the journal as the record, rolling nothing back, and saying what is
# still committed and where the pre-mutation backup is.
#
# `land` remains a compatibility interface for an already `approved:` candidate,
# but stages and commits through the same maintenance transaction; it is not the
# normal automatic authority. `promote` always refuses because learned skills
# are permanently fleet-owned.
#
# The one-time `migrate` subcommand (the sole legacy container reader) was
# RETIRED by audit-f7 after running on every fleet home: no learnings.md holds
# a live @container pointer anymore, and the legacy container store is never
# read. Its history (gated plan, verbatim archive, recoverable source moves)
# lives in git at the retirement commit.
#
# Candidate files keep the existing `kind`, `name`, `description`, `===sources===`,
# `===skill===`, and `===patch===` grammar. The scout proposes rule candidates
# for captain review but no automatic plan may mutate captain.md.
#
# `kind: crewmate` (learning-output-reroute) is the fourth candidate kind: an
# always-loaded METHOD lesson for the machine-owned $AC_HOME/CREWMATE-learned.md,
# which ac_seed_crewmate_md merges into every crew worktree as its own layer
# (container -> learned -> fleet -> crewdomain: the captain's hand-written
# CREWMATE.md deliberately reads later and wins on conflict; captains never
# edit the learned file, transactions never touch CREWMATE.md). The routing
# rule lives in the scout brief: a lesson no task-matched invocation would ever
# reach is a crewmate lesson, and `kind: skill` is reserved for demonstrated
# procedures - each skill land also stages one discovery-pointer line into the
# layer's `## when to reach for a learned skill` section, so no learned skill
# exists without its always-loaded trigger again. The transaction composes the
# `## <name>` heading and `(learned <date>)` provenance itself and REFUSES: a
# body over 12 lines, a body carrying a `## ` heading (entry spoofing), a
# duplicate name, a staged file over the 4096-byte always-loaded budget (the
# refusal names the retire remedy), and any rewrite dropping an existing entry
# without retired accounting (ac_crewmate_learned_no_loss, defense in depth for
# future curate rewrites). Evidence compaction is identical to a skill land -
# archive + `[distilled -> <name>]` pointer - with the pointer's first link
# `[lesson](../CREWMATE-learned.md)` since no skill store exists. The file
# rides ac_records_backup's reversibility floor and each planning run keeps a
# backup/CREWMATE-learned.md.prev copy.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-backend.sh"   # the suite gate opens the run its own pane
                                    # (backend_window_new/send_line/kill_window)
. "$(dirname "$0")/ac-wake-lib.sh"
. "$(dirname "$0")/ac-maintenance-lib.sh"

# --- candidate parsing --------------------------------------------------------

candidate_header() {
  # candidate_header <file> <key> - value of the first `key:` HEADER line
  # (header = everything before the first ===section=== marker). Empty if absent.
  local file="$1" key="$2"
  sed -n '/^===[a-zA-Z]*===$/q;p' "$file" | grep -m1 "^$key:" | sed "s/^$key:[[:space:]]*//" || true
}

candidate_section() {
  # candidate_section <file> <name> - the body of the ===<name>=== block,
  # exclusive of its marker, up to the next ===...=== marker or EOF.
  local file="$1" name="$2"
  awk -v want="===$name===" '
    $0 == want { insec = 1; next }
    /^===[a-zA-Z]*===$/ { insec = 0 }
    insec { print }
  ' "$file"
}

# valid_slug <name> - agentskills-strict skill name for candidate staging.
# Rejects: empty, any char outside [a-z0-9-], a leading
# / trailing / consecutive hyphen, and >64 chars. name == parent folder is a
# spec MUST, so a malformed slug would land a spec-invalid skill.
valid_slug() {
  case "$1" in '' | *[!a-z0-9-]* | -* | *- | *--*) return 1 ;; esac
  [ "${#1}" -le 64 ]
}

# valid_description <desc> - agentskills-strict description: non-empty and
# <=1024 chars. Candidate staging owns the one validation decision.
valid_description() {
  [ -n "$1" ] || return 1
  [ "${#1}" -le 1024 ]
}

# --- run: the DISTILL run (backup + spawn scout + collect) --------------------

reap_scout_panes() {
  # Best-effort close EVERY pane agent this distill run opened (+ each pane's
  # tab, or the SHARED pane-agent workspace only when that tab was its last one
  # - never a co-tenant reviewer/qa run). Armed as cmd_run's EXIT trap.
  #
  # Keyed on the run's pane LEDGER, not on one id baked in at arm time: a run
  # that also opens a REVISION / candidate re-author pane records it there too,
  # and a trap holding a single id could never retire it. Every step is wrapped
  # so a herdr failure never changes cmd_run's exit code, and the helper's own
  # stdout is captured rather than printed so it never leaks into cmd_run's
  # result - but a close that did NOT take is WARNED to stderr (contract:
  # ac-pane-agent.sh REAP OUTCOME), because reap-pane always exits 0 and this
  # caller is the only place that silence can be broken.
  local ledger="${1:-}" helper pane out
  [ -f "$ledger" ] || return 0
  helper="${AC_PANE_AGENT:-$(dirname "$0")/ac-pane-agent.sh}"
  [ -x "$helper" ] || return 0
  while IFS= read -r pane; do
    [ -n "$pane" ] || continue
    out="$("$helper" reap-pane --pane "$pane" 2>/dev/null)" || true
    case "$out" in
      *'"closed":false'*)
        ac_warn "learning scout pane $pane did not close - it is orphaned in the pane-agent workspace; retire it by hand: ac-pane-agent.sh reap-pane --pane $pane" ;;
    esac
  done <"$ledger"
}

learn_epoch_to_date() {
  # learn_epoch_to_date <epoch> - print the UTC YYYY-MM-DD date for an epoch.
  # GNU (Linux CI) first, then BSD (macOS dev boxes) fallback (R4.6). GNU
  # first, not BSD: BSD's `-r` is unambiguously the epoch form, but GNU's `-r`
  # means `--reference=FILE` - a file in $PWD named exactly the epoch would
  # make a BSD-first probe silently return that file's mtime as the window
  # anchor instead of erroring. GNU's `-d @epoch` fails cleanly on BSD
  # (`illegal option -- d`), so the fallback still fires correctly there.
  # Local to this file - no second caller needs it, so it stays out of
  # ac-lib.sh.
  local epoch="$1"
  date -u -d "@$epoch" +%Y-%m-%d 2>/dev/null || date -u -r "$epoch" +%Y-%m-%d
}

learn_lessons_lift() {
  # learn_lessons_lift <family> <out> - concatenate the `## Lessons` section of
  # every stage report.md under this family into <out>, each block headed by the
  # report it came from. Prints ` lessons=<n>` (a window.md marker fragment) when
  # anything was lifted, and nothing at all otherwise - so an absent section is
  # silent rather than a stray empty file the scout must open to discover is empty.
  #
  # The section runs from `## Lessons` to the next `## ` heading or EOF, which is
  # the shape the crewmate contract writes. Live dir first, then the archived
  # copy: every window member has landed, so it is exactly the class
  # bin/ac-archive.sh moves.
  local fam="$1" out="$2" base rep n=0 tmp
  base="$(ac_data_dir)/$fam"
  [ -d "$base" ] || base="$(ls -d "$(ac_data_dir)"/archive/*/"$fam" 2>/dev/null | head -1)"
  [ -n "$base" ] && [ -d "$base" ] || return 0
  tmp="$(mktemp)"
  # -maxdepth 2: a family's own report.md and one stage level under it. Deeper
  # is not a stage (ac-brief.sh owns the layout), and an unbounded walk would
  # follow whatever a task happened to leave in its dir.
  for rep in $(find "$base" -maxdepth 2 -name report.md -type f 2>/dev/null | sort); do
    if awk '/^## Lessons/ { f = 1; next } f && /^## / { exit } f' "$rep" | grep -q '[^[:space:]]'; then
      printf '### %s\n\n' "${rep#$(ac_data_dir)/}" >>"$tmp"
      awk '/^## Lessons/ { f = 1; next } f && /^## / { exit } f' "$rep" >>"$tmp"
      printf '\n' >>"$tmp"
      n=$((n + 1))
    fi
  done
  if [ "$n" -gt 0 ]; then
    { printf '# Stage-report lessons: %s\n\n' "$fam"; cat "$tmp"; } >"$out"
    printf ' lessons=%s' "$n"
  fi
  rm -f "$tmp"
}

learn_retro_snapshot() {
  # learn_retro_snapshot <rundir> - the RETRO first-pass source snapshot
  # (R1-R2): resolve the distill window - [anchor_date, now] at DATE
  # granularity, anchor = state/.learn.meta last_run (absent/non-numeric ->
  # the full ## Done section, R1.3) - against records/backlog.md's ## Done
  # lines, then write sources/retro/window.md (the manifest - not the
  # scout's job), copy each window member's data/<family>/room.md into
  # sources/retro/rooms/<family>.md, AND lift each member's stage-report
  # `## Lessons` sections into sources/retro/lessons/<family>.md.
  #
  # The lessons half closes a STRUCTURAL blindness this loop carried from the
  # start, already recorded as repo-knowledge by family evidence-class-rule:
  # only room.md was snapshotted, so a lesson or failure mode a crewmate named
  # inside spec/arch/plan/implement/report.md was invisible to the learning
  # loop no matter how well it was written - and `## Lessons` is the section
  # EVERY crewmate is contracted to write (docs/examples/CREWMATE.md). Only
  # that section is lifted, never whole reports: the rest is context the room
  # already carries, and copying it would cost the scout its window for no
  # added evidence. Bounded by the window itself, so noise cannot grow without
  # bound. REPORT-ONLY: reads records/backlog.md, state/.learn.meta,
  # data/<family>/room.md and its stage report.md files; writes ONLY inside $rundir.
  # Prints the member count on stdout so cmd_run can decide the R4.4 warn.
  local rundir="$1" retrodir backlog anchor_epoch anchor_date
  local members_tsv skipped_tsv count id date marker doneline roomsrc lessons
  retrodir="$rundir/sources/retro"
  mkdir -p "$retrodir/rooms" "$retrodir/lessons"

  anchor_epoch="$(ac_meta_get "$(ac_learn_meta)" last_run)"
  case "$anchor_epoch" in '' | *[!0-9]*) anchor_epoch="" ;; esac
  anchor_date=""
  [ -n "$anchor_epoch" ] && anchor_date="$(learn_epoch_to_date "$anchor_epoch")"

  backlog="$(ac_records_dir)/backlog.md"
  members_tsv="$(mktemp "$retrodir/members-XXXXXX")"
  skipped_tsv="$(mktemp "$retrodir/skipped-XXXXXX")"

  if [ -f "$backlog" ]; then
    # Window membership (R1.4-R1.5): id/date/verb come from the ONE shared
    # Done-line parser (AC_DONELINE_AWK in ac-lib.sh, which owns the F1/F1b
    # date-group + fallback + verb-shape logic and never invents a verb). The
    # `marker` this snapshot records is the terminal state when tagged
    # (failed/abandoned), else the Done verb, else `unknown`. A line with no
    # date anywhere is SKIPPED (R1.4), never a member.
    awk -v anchor="$anchor_date" -v mfile="$members_tsv" -v sfile="$skipped_tsv" "$AC_DONELINE_AWK"'
      /^## Done/ { sec = "done"; next }
      /^## /     { sec = ""; next }
      sec == "done" && /^- \[[ x]\] / {
        ac_doneline($0, o)
        id = o["id"]; date = o["date"]
        marker = (o["terminal"] == "failed" || o["terminal"] == "abandoned") ? o["terminal"] : o["verb"]
        if (date == "") { printf "%s\t%s\n", id, $0 >> sfile; next }
        if (anchor == "" || date >= anchor) printf "%s\t%s\t%s\t%s\n", id, date, marker, $0 >> mfile
      }
    ' "$backlog"
  fi

  count="$(wc -l <"$members_tsv" | tr -d ' ')"

  {
    if [ -n "$anchor_date" ]; then
      printf 'anchor: %s (%s)\n' "$anchor_epoch" "$anchor_date"
    else
      printf 'anchor: none - full Done section\n'
    fi
    printf 'resolved: %s\n' "$(ac_iso)"
    printf 'members: %s\n\n' "$count"

    if [ "$count" -eq 0 ]; then
      printf 'no families landed in this window\n\n'
    else
      printf '## Members\n\n'
      while IFS=$'\t' read -r id date marker doneline; do
        [ -n "$id" ] || continue
        # E7: a family id outside [a-zA-Z0-9_-] (ac-room.sh's own family
        # validation, ac-room.sh:106) never gets a room lookup - no-room.
        case "$id" in
          *[!a-zA-Z0-9_-]*)
            printf '%s %s %s no-room\n' "$id" "$date" "$marker" ;;
          *)
            # HISTORY read: every window member has landed, so it is exactly
            # the class bin/ac-archive.sh moves - resolve live-first then
            # archived, or archiving a family silently empties its retro window.
            roomsrc="$(ac_room_file "$id")"
            lessons="$(learn_lessons_lift "$id" "$retrodir/lessons/$id.md")"
            if [ -f "$roomsrc" ]; then
              cp "$roomsrc" "$retrodir/rooms/$id.md"
              printf '%s %s %s room%s\n' "$id" "$date" "$marker" "$lessons"
            else
              printf '%s %s %s no-room%s\n' "$id" "$date" "$marker" "$lessons"
            fi
            ;;
        esac
        printf '  %s\n\n' "$doneline"
      done <"$members_tsv"
    fi

    if [ -s "$skipped_tsv" ]; then
      printf '## Skipped (no parsable date)\n\n'
      while IFS=$'\t' read -r id doneline; do
        [ -n "$id" ] || continue
        printf '%s skipped-no-date\n  %s\n\n' "$id" "$doneline"
      done <"$skipped_tsv"
    fi
  } >"$retrodir/window.md"

  rm -f "$members_tsv" "$skipped_tsv"
  printf '%s\n' "$count"
}

cmd_run() {
  ac_require jq
  local ts rundir records captain helper out done_line status transcript ledger
  local backup retro_members examined scout_ok learn_generation
  local kickoff verify_id verify_meta verify_status verify_handle pane_early
  local pane raw_tab out_tmp pane_pid start_deadline
  learn_generation="$(ac_learn_generation)"
  backup="$(ac_learn_backup)"

  ts="$(ac_now)"
  rundir="$(ac_data_dir)/learning-$ts"
  mkdir -p "$rundir/sources"

  # Rotation FIRST, so the sources/ snapshot below copies the BOUNDED ledger -
  # that bound is what makes the land contract exact-line citation feasible
  # (the learn_rotate_pending header owns the contract).
  learn_rotate_pending

  # Snapshot the distill SOURCES into the run dir so the scout reads them
  # in-tree (cwd = run dir). Copies, not symlinks or absolute reads: a pane
  # agent's file access is scoped to its cwd tree, and a copy keeps the scout
  # from ever touching the live ledgers.
  records="$(ac_records_dir)"
  captain="$records/captain.md"
  [ -f "$records/learnings.md" ] && cp "$records/learnings.md" "$rundir/sources/learnings.md"
  [ -f "$captain" ] && cp "$captain" "$rundir/sources/captain.md"

  # RETRO first-pass (Q3/Q4-A, R1-R2): resolve the distill window and
  # snapshot its manifest + member rooms into sources/retro/, BEFORE the
  # scout spawns, so Pass 1 reads it in-tree like every other source.
  retro_members="$(learn_retro_snapshot "$rundir")"

  # Also snapshot the existing LEARNED skill store into sources/skills/, one
  # SKILL.md per skill at sources/skills/<name>/SKILL.md, so the scout can match
  # a lesson cluster against skills that ALREADY cover its territory (patch-
  # before-new). The fleet-local store is the only active learned-skill source;
  # legacy container skills are never read (the migration command is retired).
  # Copies, not symlinks: the cwd-scoped
  # scout can only read in-tree. Empty stores => sources/skills/ has no entries;
  # the missing-dir globs stay literal and the -f guard skips them (no error).
  local sksrc skname skdst
  for sksrc in "$(ac_skills_dir)"/*; do
    [ -f "$sksrc/SKILL.md" ] || continue
    skname="$(basename "$sksrc")"
    skdst="$rundir/sources/skills/$skname"
    [ -e "$skdst" ] && continue
    mkdir -p "$skdst"
    cp "$sksrc/SKILL.md" "$skdst/SKILL.md"
  done

  # The SCENE store (L2) as a one-line-per-scene index, so Pass 2 can match a
  # lesson cluster against a scene's territory the way it already matches
  # against skills, and can see the store's count/tier before proposing one.
  # `list` only, never the bodies: the scout proposes, the chief writes.
  "$(dirname "$0")/ac-scene.sh" list >"$rundir/sources/scenes.md" 2>/dev/null || : >"$rundir/sources/scenes.md"

  # The ALWAYS-LOADED layer plus its staleness grading, so Pass 2 can propose
  # reinforce-or-retire per STALE entry instead of leaving the one always-paid
  # store ungraded (<=4096 bytes by construction - the cheapest source here).
  [ -f "$(ac_home)/CREWMATE-learned.md" ] && cp "$(ac_home)/CREWMATE-learned.md" "$rundir/sources/crewmate-learned.md"
  cmd_stale >"$rundir/sources/always-loaded-staleness.md" 2>/dev/null || : >"$rundir/sources/always-loaded-staleness.md"

  # The distill contract. This heredoc is the ONE source of truth for the scout's
  # instructions; `run` writes it into every run dir's brief.md verbatim.
  cat >"$rundir/brief.md" <<'SCOUT_BRIEF'
# learning scout - distill contract

You are the independent `learning` scout for the agent-crew fleet: a fresh-eyes
pane agent, NOT the crewchief. You PROPOSE, you never land. Nothing you write
reaches a skill store or a ledger. After your turn, the caller validates the
complete run, stages immutable maintenance plans, and sends skill/patch plans
through an independent maintenance gate. Write ONLY inside this run directory.

## Execution constraint (read this first)

Do NOT launch any async/background sub-agents (the `Agent`/`Explore`/`Task`
tools). Read the room snapshots in `./sources/retro/rooms/*.md` INLINE
yourself, in ONE continuous flow. Write `./retro.md`, then `./report.md` and
each `./candidate-*.md`, BEFORE your turn ends.

Why: this run harvests you as done the moment your pane goes idle (turn-end).
An async sub-agent ends your turn while it keeps running in the background, so
the run will reap you before you synthesize anything.

If the window is too wide to hold every room snapshot in context at once, work
NEWEST-first and read/summarize snapshots in batches inline, noting in
`retro.md` any member you did not reach (see Pass 1 below).

This run has TWO passes, in order: Pass 1 - RETRO reconstructs what actually
happened in the families that landed since the last run; Pass 2 - DISTILL
proposes candidates from the ledgers AND the retro together. Do Pass 1 FIRST -
Pass 2 reads its output.

## Pass 1 - RETRO (do this FIRST)

- Read `sources/retro/window.md` - the manifest of every family landed in this
  distill window (or the full `## Done` history when this is the first run) -
  and, for each member it marks `room`, its `sources/retro/rooms/<family>.md`,
  plus `sources/retro/lessons/<family>.md` for each member marked `lessons=<n>`.
- For EVERY member family, reconstruct: what the family set out to do versus
  what actually landed; friction (gate loops, review rounds, re-routes,
  `blocked:`/`needs-decision:` items, failures); what worked and should become
  standard practice.
- Add a CROSS-FAMILY section: friction or a working practice that recurs in TWO
  OR MORE families is called out as a pattern - that is what earns a durable
  artifact later, in Pass 2.
- A member's Done line may carry an `epic:<id>` token (an epic and each of its
  stories land as separate Done lines that share the token) - GROUP those
  members under their shared epic instead of reconstructing each in isolation,
  so the epic's own friction/pattern is not lost as noise between its stories.
- Every observation cites the family and the room entry (or backlog line) it
  derives from. A family that yields nothing is listed as such - never invent
  material.
- `window.md` states the member count up front; a wide window is never
  truncated for you. If it is too wide to cover every member in full, work
  NEWEST-first and say in `retro.md` which member(s) you did not reach.
- Write this pass's output to `./retro.md` BEFORE you propose any candidate in
  Pass 2.

## Pass 2 - DISTILL

### Sources (read these, in ./sources/)

- `sources/retro/lessons/<family>.md` - the `## Lessons` sections lifted from
  that family's stage reports (spec/arch/plan/implement), where a crewmate
  wrote its FIRST-HAND method lessons. Present only for members that wrote any
  (window.md marks them `lessons=<n>`). Prefer these words over a chief's
  second-hand summary of the same run, exactly as you already prefer a
  `(by: <task-id>, first-hand)` ledger bullet.
- `./retro.md` - THIS run's Pass 1 output (write it first). A retro
  observation may support a candidate even when `sources/learnings.md` never
  captured it - that is the point of the pass.
- `sources/learnings.md` - the fleet's raw work-lessons (procedural material).
  This is the NEWEST window: older bullets were rotated verbatim into
  records/learnings-archive/pending-*.md before staging, so every line you
  read here is one your `===sources===` citation can actually reach.
  Cluster recurring lessons; a cluster general enough to guide future crews is a
  SKILL candidate. Name the EXACT source bullet line(s) each candidate distils;
  a successful transaction archives them verbatim before replacing them with
  one canonical skill pointer, so it must find them exactly.
- `sources/captain.md` - the captain's existing standing rules (semantic memory:
  who the captain is, what they want, how the crew must operate). Read it for
  de-dup / supersede awareness. A recurring captain CORRECTION that is not yet a
  standing rule is a RULE candidate. There is no source bullet to compact for a
  rule (the correction lived in chat), and captain.md wording is NEVER
  paraphrased - propose the rule in the captain's own words.
- `sources/crewmate-learned.md` + `sources/always-loaded-staleness.md` - the
  ALWAYS-LOADED lesson layer and its age grading. A STALE entry must re-prove
  itself: search THIS window (retro, lessons, rooms) for independent evidence
  that the lesson was exercised, confirmed, or re-derived - plausibility,
  importance, prior knowledge, and the entry's own text are NOT evidence.
  Propose per stale entry, in `report.md` under `## Always-loaded staleness`
  (report-only, the chief applies - exactly like scene proposals):
  `reinforce <slug> - evidence: <the window pointer>` when evidence exists,
  `retire <slug> - <why>` when none does (the retire itself rides the
  existing 4096-budget pairing rule at the next land, never a new path).
- `sources/scenes.md` - the fleet's L2 SCENE store index (one line per scene:
  slug, heat, updated, summary), plus its count against `config/scene-max`. A
  scene is a consolidated TOPIC file a reader opens on purpose - the layer
  between a repo-knowledge fact and the always-loaded crewmate layer. Read this
  before proposing one, both to match a cluster against a scene that already
  covers its territory and to see whether the store has room.

- `sources/skills/*/SKILL.md` - the fleet's EXISTING learned skill store (one dir
  per skill). BEFORE proposing a new skill for a lesson cluster, match the
  cluster against these by DESCRIPTION / TERRITORY, never by name: read each
  skill's frontmatter `description:` first, then its body, and decide whether the
  cluster's territory is ALREADY covered. This is patch-before-new: a name-only
  clobber-guard would let a same-topic lesson under a different name slip past.

### What to propose

Only candidates the sources genuinely support. Zero candidates is a valid
outcome - say so in the report rather than inventing one. Do NOT capture one-off
incidents or anything a standing rule or existing skill already covers - those
are noise, not durable lessons. A learned skill may never share a NAME with a
built-in crew skill (crew-ship, crew-qa, document). Bullets suffixed
`(by: <task-id>, first-hand)` are the crewmate's own words from inside the
work - prefer them as evidence over a chief's second-hand summary of the same
run.

For every lesson cluster, decide between three tiers BEFORE writing a candidate:

- Territory ALREADY covered by an existing skill (matched by description /
  territory above) -> propose a PATCH candidate (`kind: patch`) that names that
  existing skill; the body is ONLY the addition, written as a labeled
  `## <subsection>` that extends the skill. Do NOT spawn a second same-topic
  skill under a new name. A `skill-defect: <name> - <what is wrong>` line in a
  crewmate report is a ready-made patch candidate - prefer it as first-hand
  evidence.
- A METHOD, REASONING, or DISCIPLINE lesson -> propose a CREWMATE-LESSON
  candidate (`kind: crewmate`, form below). The routing test: would a crewmate
  matching its CURRENT TASK against this description ever invoke it? If not,
  it is `kind: crewmate`, not a skill - it belongs in the always-loaded layer,
  not behind an invocation that will never come.
- GENUINELY NEW procedural territory -> propose a NEW skill candidate
  (`kind: skill`), exactly as below. `kind: skill` is RESERVED for a
  repeatable multi-step procedure that DEMONSTRABLY WORKED in a real task - a
  recovered error, a corrected approach, or a non-obvious workflow - whose
  sources cite that task's lesson, and whose `description:` names the concrete
  trigger (project, operation, or failure mode) a crewmate would search for.
  The routing test above rejects; this names what passes.

A candidate supported ONLY by `./retro.md` (no `sources/learnings.md` bullet
backs it) still gets an EMPTY `===sources===` section - do not invent a
bullet - and you must flag it `source: retro-only` when you write it up in
`report.md` (below), so the captain knows the evidence is this run's retro.

SCENE PROPOSALS are a FIFTH output and they are NOT candidates - they go in
`report.md`, never in a `candidate-*.md`, because a candidate is by definition
something the maintenance transaction lands and a scene is not landed that way
(it takes the repo-knowledge trust tier: the chief runs `bin/ac-scene.sh`
itself, exactly as it runs `ac-know.sh add` on a proposed fact). Propose one
when a cluster is a TOPIC rather than a lesson - several facts and lessons that
only make sense together, the thing a reader would want restored in one read.
Write them under a `## Scene proposals` section, one block each:

    op: new|update|merge
    name: <slug of the scene to write>
    merge-from: <slug-a,slug-b>        (op=merge only)
    summary: <one line - what this scene restores context for>
    body: |
      <the consolidated topic text>

Match against `sources/scenes.md` FIRST: a cluster whose territory an existing
scene already covers is an `update` or a `merge`, never a second scene under a
new name - the same patch-before-new rule the skill tiers use. If the store is
at or near its cap, propose the `merge` that makes room as its own block; do
not propose a `new` the store cannot take.

Write each candidate to its own file `candidate-<slug>.md`. Do NOT write an
`approved:` line. Automatic authority comes only from the later hash-bound
maintenance-gate receipt; candidate headers never authorize mutation.

Skill candidate:

    kind: skill
    name: <slug, lowercase [a-z0-9-]>
    description: <one line - when a crew should reach for this skill>
    ===sources===
    <date><TAB><short hook><TAB><exact learnings.md bullet line, verbatim>
    ===skill===
    # <name>

    <the SKILL.md body: the distilled behaviour, in the fleet's own voice>

- `<date>` is the source lesson's date (its `## YYYY-MM-DD` section header).
- `<short hook>` is a few words naming the lesson - it rides in the pointer that
  replaces the bullet, so keep it terse and specific.
- The third field is the source bullet copied VERBATIM (the whole `- ...` line).
- Separate the three fields with a literal TAB.
- A retro-only candidate leaves `===sources===` EMPTY (no lines at all).

Patch candidate (extend an EXISTING learned skill in place):

    kind: patch
    name: <slug of the EXISTING skill to patch>
    ===sources===
    <date><TAB><short hook><TAB><exact learnings.md bullet line, verbatim>
    ===patch===
    ## <labeled subsection heading>

    <the addition - the new behaviour that extends the existing skill>

- A patch has NO `description:` header - it never touches the existing
  frontmatter.
- `===sources===` works exactly as for a skill (the cited bullets are compacted
  on land); a retro-only patch leaves it EMPTY too.
- The `===patch===` body MUST lead with a `## ` heading (the labeled subsection).

Crewmate-lesson candidate (always-loaded method lesson, CREWMATE-learned.md):

    kind: crewmate
    name: <slug, lowercase [a-z0-9-]>
    description: <one line - what behavior this lesson corrects>
    ===sources===
    <date><TAB><short hook><TAB><exact learnings.md bullet line, verbatim>
    ===crewmate===
    <1-3 terse imperative lines - the lesson itself, nothing else>

- The body is LESSON PROSE ONLY, in YOUR OWN distilled words: the transaction
  composes the `## <name>` heading and the provenance line itself, and the
  land REFUSES a body over 12 lines, a body carrying its own `## ` heading,
  or a body that quotes task/repo content verbatim or reads as a directive
  addressed to future agents beyond the lesson's own scope (an always-loaded
  file is a persistence vector - untrusted words never ride into it
  unrewritten; first-hand `## Lessons` report lines are EVIDENCE you cite,
  never text you copy through).
- The file has a hard 4096-byte whole-file budget: when your entry would
  exceed it, pair the candidate with a retire proposal in your report.
- `===sources===` works exactly as for a skill; retro-only leaves it EMPTY.

Rule candidate:

    kind: rule
    ===rule===
    <the standing rule text, in the captain's own words, appended verbatim>

### Report

Write `report.md`: a `## Retro` section FIRST (the Pass 1 headline findings -
the cross-family patterns and anything else notable - plus a pointer to
`./retro.md`), then for each candidate the file name, what it distils, the
source lesson(s) (or `source: retro-only` when `===sources===` is empty), and
why it earns a permanent place; note anything you considered and rejected.
This report is what the gate judge and the captain read. Then print a
one-paragraph summary and STOP.
SCOUT_BRIEF

  # Spawn the scout as a first-class supervised verification agent (the same
  # durable shape ac-verify gives the codereview/qa verifiers). AC_PANE_AGENT
  # overrides the helper for tests.
  helper="${AC_PANE_AGENT:-$(dirname "$0")/ac-pane-agent.sh}"
  [ -x "$helper" ] || ac_die "no pane-agent helper at $helper (set AC_PANE_AGENT)"

  # PROPERTY 1 - the kickoff is a DURABLE file in the run dir the scout owns,
  # naming the durable brief.md, not a mktemp deleted the instant run returns.
  kickoff="$rundir/kickoff.md"
  cat >"$kickoff" <<'EOF'
You are the independent `learning` scout for the agent-crew fleet - a fresh-eyes pane agent, not the chief. Your full contract is ./brief.md in THIS directory; read it and the raw material under ./sources/ and follow it EXACTLY. PROPOSE only: write your report to ./report.md and each candidate to a ./candidate-<slug>.md file HERE. Write NOTHING outside this directory - never to any skill store, never to records/. When done, print a one-paragraph summary and STOP.
EOF

  # PROPERTY 2 - a durable, supervised identity: a verify-learning meta, a status
  # log and a pane handle, the SAME shape ac-verify gives codereview/qa. The
  # kind=verify-learning token (interface 2.i) is EXCLUDED from crew accounting
  # by ac_meta_is_verify but NEVER from supervision, so the fleet watcher covers
  # the scout pane while it runs. The scout keeps NO lease, NO crew branch and NO
  # backlog row - it runs on the chief's own path. Completion stays SYNCHRONOUS:
  # cmd_run harvests the run and removes the identity below (props 4 ac-done-
  # PRIMARY / 5 until-teardown are superseded by task-flow-v2's fresh-pane model,
  # AGENTS.md). Publishing the handle while the pane is LIVE needs the pane id
  # before the turn ends, so - like ac-verify - launch in the background and read
  # the early pane file the helper writes.
  verify_id="verify-learning-$ts"
  verify_meta="$(ac_task_meta "$verify_id")"
  verify_status="$(ac_task_status "$verify_id")"
  verify_handle="$(ac_state_dir)/.pane-$verify_id"
  pane_early="$rundir/pane.handle"
  out_tmp="$rundir/scout.ndjson"

  # --deliverable is what stops an idle pane from being harvested as a finished
  # pass (ac-pane-agent.sh, IDLE FALLBACK): report.md is the ONE artifact the
  # kickoff above demands unconditionally, so a scout that stopped mid-pass -
  # out of budget, self-blocked - now ends non-ok instead of status ok.
  # The scout pane lands in the LEARNING family workspace, beside the
  # crew:learning-chief tab its DUE checkpoints promote (FAMILY WORKSPACE
  # GROUPING; captain order 2026-08-11 - the chief and its pane agent share
  # one group). `learning` is the STABLE family (the room, the roomchief);
  # the per-run data dir learning-<ts> is not a family. Before this the
  # scout was the documented absent-family case and sat in the fleet ROOT
  # workspace - orphaned once the roomchief existed.
  AC_WINDOW_FAMILY=learning \
  "$helper" run --cwd "$rundir" --prompt-file "$kickoff" \
    --kind learning --label "$verify_id" --timeout "${AC_LEARN_TIMEOUT:-7200}" \
    --deliverable "$rundir/report.md" \
    --pane-file "$pane_early" >"$out_tmp" 2>"$rundir/scout.err" &
  pane_pid=$!

  start_deadline=$(( $(date +%s) + ${AC_LEARN_START_TIMEOUT:-30} ))
  while [ ! -s "$pane_early" ] && kill -0 "$pane_pid" 2>/dev/null \
    && [ "$(date +%s)" -lt "$start_deadline" ]; do
    sleep 0.05
  done
  pane=""; raw_tab=""
  [ ! -s "$pane_early" ] || read -r pane raw_tab <"$pane_early" || true
  if [ -n "$pane" ]; then
    printf '%s %s\n' "$pane" "$raw_tab" >"$verify_handle.tmp.$$" \
      && mv "$verify_handle.tmp.$$" "$verify_handle"
    {
      printf 'kind=verify-learning\n'
      printf 'project=%s\nbackend=herdr\nwindow=%s\ncwd=%s\n' \
        "$(basename "$(ac_home)")" "$pane" "$rundir"
    } >"$verify_meta.tmp.$$"
    # Status is appended BEFORE the meta mv - the same order bin/ac-verify.sh's
    # publish_meta uses (:767-772: "a reader that sees the meta always sees the
    # status too"). ac-learn.sh used to append status LAST, so under load an
    # observer could see the meta but miss the status; this closes that window.
    ac_status_append "$verify_id" "started learning scout pane=$pane"
    mv "$verify_meta.tmp.$$" "$verify_meta"
  fi

  wait "$pane_pid" || true
  out="$(cat "$out_tmp")"
  [ -z "$pane" ] || ac_status_append "$verify_id" "learning scout pane returned"
  rm -f "$verify_handle" "$verify_meta" "$verify_status"
  printf '%s\n' "$out" >"$rundir/scout.log"

  # Best-effort reap EVERY pane agent this run opened, once its id is known.
  # Every terminal event (done/pane_closed/timeout) carries "pane" = the pane's
  # id, so APPEND each one the helper reported to the run's pane LEDGER and arm
  # the EXIT trap NOW - before the ac_die below - so a run that aborts on a
  # missing done event still closes what it opened.
  #
  # The trap is armed on the LEDGER PATH, not on an id baked in at arm time: a
  # single baked id retires only the ORIGINAL scout, so a revision / candidate
  # re-author pane opened for this same run stayed alive in the shared
  # pane-agent workspace with nothing left to close it. Anything that opens a
  # further pane agent for THIS run appends its id here (one per line) and the
  # trap retires it too. The reap is pure cleanup layered on top:
  # reap_scout_panes can never change cmd_run's exit code or corrupt its
  # result/printed output. No pane ledger (scout emitted nothing and nothing
  # else recorded a pane) => a clean no-op.
  ledger="$rundir/scout.panes"
  printf '%s\n' "$out" | jq -r 'select(.pane != null) | .pane' 2>/dev/null \
    | grep -v '^$' >>"$ledger" || true
  # Expand-now is deliberate: the trap then needn't reference a local that may
  # be out of scope when EXIT fires. $rundir is fleet-home-derived (safe chars).
  # shellcheck disable=SC2064
  trap "reap_scout_panes '$ledger'" EXIT

  done_line="$(printf '%s\n' "$out" | jq -c 'select(.event == "done")' 2>/dev/null | tail -n 1)"
  [ -n "$done_line" ] || ac_die "learning scout emitted no done event (raw: $rundir/scout.log)"
  status="$(jq -r '.status' <<<"$done_line")"
  if [ "$status" = ok ]; then
    scout_ok=1
  else
    scout_ok=0
    ac_warn "learning scout ended '$status' - preserving the run and due cadence; no candidate will be gated or applied"
  fi
  transcript="$(jq -r '.transcript // ""' <<<"$done_line")"

  printf 'learning run %s\n' "$rundir"
  printf '  backup: %s\n' "$backup"
  [ -n "$transcript" ] && printf '  transcript: %s\n' "$transcript"
  # ONE predicate, read once: report.md is the artifact this run DECLARED as the
  # pane's --deliverable, so `examined` is both what the summary reports and what
  # the cadence below is gated on - the two can never disagree. Empty counts as
  # absent, the rule ac-pane-agent.sh holds a declared deliverable to.
  if [ -s "$rundir/report.md" ]; then printf '  report: %s\n' "$rundir/report.md"
  else examined=0; printf '  report: (none written)\n'; fi
  # The retro summary is also part of the complete-run predicate. Missing output
  # preserves the run for inspection and leaves both cadences due.
  if [ -f "$rundir/retro.md" ]; then
    printf '  retro: %s\n' "$rundir/retro.md"
  else
    printf '  retro: (none written)\n'
    [ "${retro_members:-0}" -gt 0 ] 2>/dev/null \
      && ac_warn "retro window had $retro_members member(s) but no retro.md was written - inspect $rundir"
  fi
  local n
  n=$(find "$rundir" -maxdepth 1 -name 'candidate-*.md' | wc -l | tr -d ' ')
  printf '  candidates: %s\n' "$n"
  find "$rundir" -maxdepth 1 -name 'candidate-*.md' -print | sed 's/^/    /'
  if [ "$scout_ok" = 1 ] && [ -s "$rundir/report.md" ] && [ -s "$rundir/retro.md" ]; then
    examined=1
    if ! learn_auto_apply_candidates "$rundir"; then
      examined=0
      ac_warn "one or more Learning subjects could not reach a settled receipt/apply state; cadence remains due"
    fi
  else
    examined=0
    printf 'AUTO-MAINTENANCE WITHHELD: a complete ok report + retro is required before gating or apply.\n'
  fi

  # The DISTILL run IS the CURATE "tick" (report §2.4): advance the per-
  # learning-run counter ONCE here, at the single learning-run point, so the
  # session-start `-- curate --` block flags `CURATE DUE` after config/curate-
  # every runs. Placed at the END of cmd_run so a run that aborted earlier
  # (no jq, no scout done event -> ac_die) never counts; a scout that merely
  # ended non-ok (ac_warn above, run still completed) does count - the run
  # happened. Deliberately NOT gated the way the reset below is: this counter
  # paces a records-wide CURATE pass, it owns no retro window, so an attempt
  # that produced nothing costs at most one propose-only curate round early.
  ac_curate_tick
  local curate_n curate_every curate_out curate_cmd
  read -r curate_n curate_every < <(ac_curate_due)
  if [ "$curate_n" -ge "$curate_every" ]; then
    curate_cmd="${AC_CURATE:-$(dirname "$0")/ac-curate.sh}"
    if curate_out="$("$curate_cmd" run 2>&1)"; then
      printf '  automatic Curate:\n%s\n' "$curate_out"
    else
      ac_warn "Curate is due ($curate_n/$curate_every) but its automatic run failed; Curate cadence remains due"
    fi
  fi

  # The RUN also CONSUMES the DISTILL cycle it was owed, for the same reason and
  # at the same point: the counter counts debriefs-since-the-last-EXAMINATION,
  # and `run` is the examination - `land` is only a consequence of it, so a
  # distill that legitimately proposed nothing used to leave the counter over
  # threshold forever. TWO intended effects, not one: ac_learn_reset also stamps
  # last_run, which is the RETRO WINDOW ANCHOR - so the window now advances at
  # run-time instead of land-time, and a run that lands nothing stops
  # re-examining the same window. The snapshot read that anchor far above
  # (learn_retro_snapshot, before the scout); this reset must stay AFTER it.
  #
  # "The pass ran" is what the cycle is owed to, and PRODUCING report.md is what
  # tells that apart from a pass that never happened: it is the one artifact the
  # kickoff demands unconditionally, so a scout that stopped mid-pass - out of
  # budget, self-blocked - writes none. Consuming the cycle on THAT run advanced
  # the anchor past members nothing had read, and they were never re-examined:
  # a real run lost a 43-member window that a chief had to restore by hand
  # (data/learning/room.md 13:36:13Z). So the cycle is withheld and the crossing
  # stays DUE, which re-fires the run rather than dropping the window on the
  # floor. The other direction is untouched, and it is the one this reset was
  # written for: a scout that examined the window and proposed nothing DID run
  # the pass, writes its report.md saying so, and still consumes its cycle.
  if [ "$examined" = 1 ]; then
    if ! ac_learn_reset "$learn_generation"; then
      ac_warn "Learning completed, but a newer cadence generation exists; late debriefs remain due instead of being erased"
    fi
  else
    ac_warn "the scout did not produce a complete ok report + retro - the DISTILL cycle is NOT consumed and the retro window is PRESERVED (still due; re-run after inspecting $rundir)"
  fi
}

# --- compatibility land: approved candidate through the shared transaction ---

cmd_land() {
  local cand="${1:-}"
  [ -n "$cand" ] || ac_die "usage: ac-learn.sh land <candidate-file>"
  [ -f "$cand" ] || ac_die "no candidate file at $cand"

  local kind approved run plan candidate_copy captured
  kind="$(candidate_header "$cand" kind)"
  approved="$(candidate_header "$cand" approved)"
  [ -n "$approved" ] || ac_die "refusing to land an UNAPPROVED candidate ($cand): no 'approved:' header - the captain gate (Q6) must approve first"

  captured="$(ac_learn_generation)"
  IFS=$'\t' read -r run plan candidate_copy < <(
    learn_prepare_candidate_plan "$cand" legacy-captain
  )
  ac_maintenance_apply "$plan" "$run" \
    || ac_die "maintenance transaction refused candidate plan at $plan"
  if ! ac_learn_reset "$captured"; then
    ac_warn "landed $kind, but a newer Learning generation exists; its cadence was preserved instead of reset"
  fi
  printf 'landed %s through maintenance transaction %s\n' "$kind" "$run"
}

# --- always-loaded staleness: the aging signal --------------------------------
#
# (always-loaded-layer-has-no-staleness-signal) The fleet grades every OTHER
# knowledge store - repo-knowledge by mechanical diff (`ac-know.sh verify`),
# the Pending ledger by volume (`rotate-pending`), usage by `heat:` - and the
# one store that rides into EVERY crewmate context had no signal at all: a
# CREWMATE-learned.md entry, once landed, was kept by inertia alone on a
# 4096-byte always-loaded budget. This block ports the AGING semantics from
# the research triage (research/firstmate-native-parity.md, Triage 2026-08-10
# owns the comparison; re-implemented natively, never vendored):
#
#   - an entry's CLOCK is the last date in its `(learned <d>[, reinforced <d>])`
#     line; older than config/learn-stale-days (default 30) grades STALE;
#   - STALE means "must re-prove itself": the DISTILL scout proposes
#     reinforce-or-retire per stale entry (report-only, like scene proposals),
#     and the CHIEF applies - grading never mutates anything;
#   - REINFORCEMENT requires independent evidence from the current window,
#     and the bar is deliberately verbatim from the studied design:
#     plausibility, importance, prior knowledge, and the entry's own text are
#     NOT evidence. `reinforce` therefore REQUIRES --evidence and prints it in
#     the receipt rather than storing it - file bytes are counted content on
#     an always-loaded budget, so the record of WHY lives in the room/report,
#     never in the layer itself;
#   - decay advances only when a pass RUNS (a DISTILL, a digest render, this
#     verb) - no cron, no daemon, matching the distro posture;
#   - RETIRE deliberately gets NO new verb: the landing transaction's
#     4096-budget refusal already forces "pair the new entry with a retire",
#     and ac_crewmate_learned_no_loss already accepts declared retires - this
#     block adds the SIGNAL for which entry, not a second removal path.
#
# Scenes need no twin: `ac-scene.sh` refreshes `updated=` on every write
# INCLUDING a cited read, so a scene's clock already advances on touch; the
# `stale` verb below still GRADES them (read-only) so one command answers
# "what is going stale" for both stores.

learn_stale_days() {
  local d
  d="$(ac_config_read learn-stale-days 30)"
  case "$d" in ''|*[!0-9]*) ac_die "config/learn-stale-days must be a day count (got: '$d')" ;; esac
  printf '%s\n' "$d"
}

learn_alw_entry_date() {
  # learn_alw_entry_date <file> <slug> - the entry's LAST clock date:
  # `reinforced <d>` when present, else `learned <d>`, else empty (an entry
  # with no date line has no clock and is never graded - fail toward silence,
  # the same direction an unmarked legacy entry deserves).
  awk -v want="## $2" '
    $0 == want { in_e = 1; next }
    in_e && /^## / { exit }
    in_e && /^\(learned / {
      line = $0
      if (match(line, /reinforced [0-9]{4}-[0-9]{2}-[0-9]{2}/))
        print substr(line, RSTART + 11, 10)
      else if (match(line, /learned [0-9]{4}-[0-9]{2}-[0-9]{2}/))
        print substr(line, RSTART + 8, 10)
      exit
    }
  ' "$1"
}

learn_age_days() {
  # learn_age_days <YYYY-MM-DD> - whole days since that date, or empty on a
  # malformed date. macOS date -j; no GNU dependency.
  local then now
  then="$(date -j -f '%Y-%m-%d' "$1" '+%s' 2>/dev/null)" || return 0
  [ -n "$then" ] || return 0
  now="$(ac_now)"
  printf '%s\n' $(( (now - then) / 86400 ))
}

cmd_stale() {
  # `stale` - grade the ALWAYS-LOADED layer (and, read-only, the scene store)
  # by age. Report-only: prints one line per entry, a summary, and the exact
  # remedies. Consumed by the session-start digest (counts only), by cmd_run
  # (snapshotted into sources/), and by a chief deciding what to retire.
  local days live slug d age verdict n=0 stale=0 sdir sf sslug supd sage
  days="$(learn_stale_days)"
  live="$(ac_home)/CREWMATE-learned.md"
  printf 'always-loaded (CREWMATE-learned.md), stale past %s days:\n' "$days"
  if [ ! -f "$live" ]; then
    printf '  (no file yet)\n'
  else
    while IFS= read -r slug; do
      [ -n "$slug" ] || continue
      n=$((n + 1))
      d="$(learn_alw_entry_date "$live" "$slug")"
      if [ -z "$d" ]; then
        printf '  %-40s NO-CLOCK\n' "$slug"
        continue
      fi
      age="$(learn_age_days "$d")"
      if [ -n "$age" ] && [ "$age" -ge "$days" ]; then
        verdict=STALE; stale=$((stale + 1))
      else
        verdict=FRESH
      fi
      printf '  %-40s %s  age=%sd  %s\n' "$slug" "$d" "${age:-?}" "$verdict"
    done < <(grep '^## ' "$live" | sed 's/^## //')
    printf '  -- %s entries, %s stale --\n' "$n" "$stale"
    if [ "$stale" -gt 0 ]; then
      printf '  a STALE entry must re-prove itself: reinforce it on INDEPENDENT current evidence\n'
      printf '    (ac-learn.sh reinforce <slug> --evidence '\''<what this window proved>'\'') or retire it\n'
      printf '    at the next land (the 4096-budget pairing rule) - never keep it by inertia alone.\n'
    fi
  fi
  # Scenes: grading only - their clock already advances on every write,
  # including a cited read, so a stale scene is one genuinely untouched.
  sdir="$(ac_records_dir)/scenes"
  if [ -d "$sdir" ] && [ -n "$(ls "$sdir"/*.md 2>/dev/null)" ]; then
    printf 'scenes (records/scenes/), stale past %s days:\n' "$days"
    for sf in "$sdir"/*.md; do
      [ -f "$sf" ] || continue
      sslug="$(basename "$sf" .md)"
      supd="$(sed -n '2p' "$sf" | tr ' ' '\n' | sed -n 's/^updated=//p' | cut -c1-10)"
      sage="$(learn_age_days "$supd")"
      if [ -n "$sage" ] && [ "$sage" -ge "$days" ]; then
        printf '  %-40s %s  age=%sd  STALE (merge or update it - ac-scene.sh)\n' "$sslug" "$supd" "$sage"
      else
        printf '  %-40s %s  age=%sd  FRESH\n' "$sslug" "$supd" "${sage:-?}"
      fi
    done
  fi
}

cmd_reinforce() {
  # `reinforce <slug> --evidence '<line>'` - refresh the entry's clock, the
  # ONE sanctioned in-place edit of the machine-owned CREWMATE-learned.md
  # (mirroring `heat:` as ac-know.sh's one sanctioned in-place field: a clock
  # carries no claim text, so refreshing it moves no lesson and re-orders
  # nothing). The date line becomes `(learned <orig>, reinforced <today>)`;
  # a repeat reinforce REPLACES the reinforced date - bytes are budget.
  local slug="" evidence="" live lock today tmp current
  while [ $# -gt 0 ]; do
    case "$1" in
      --evidence) evidence="${2:-}"; shift 2 ;;
      -*) ac_die "unknown flag: $1" ;;
      *) [ -z "$slug" ] || ac_die "reinforce takes ONE slug (got '$slug' and '$1')"; slug="$1"; shift ;;
    esac
  done
  [ -n "$slug" ] || ac_die "usage: ac-learn.sh reinforce <slug> --evidence '<what this window proved>'"
  [ -n "$evidence" ] || ac_die "reinforce REQUIRES --evidence: plausibility, importance, prior knowledge, and the entry's own text are not evidence - name what THIS window actually exercised, confirmed, or re-derived. The evidence rides the receipt (and your room post), never the file: bytes there are always-loaded budget."
  case "$evidence" in
    *$'\n'*|*$'\r'*) ac_die "--evidence must be a single line" ;;
  esac
  live="$(ac_home)/CREWMATE-learned.md"
  [ -f "$live" ] || ac_die "no CREWMATE-learned.md in this home - nothing to reinforce"
  grep -qxF "## $slug" "$live" || ac_die "no entry '## $slug' in CREWMATE-learned.md (ac-learn.sh stale lists them)"
  today="$(ac_iso | cut -c1-10)"
  # Three distinct outcomes, told apart BEFORE the rewrite, because two of them
  # produce a byte-identical file and a cmp alone cannot name which: no clock
  # line at all is a refusal (silently succeeding would fake a fresh grade),
  # while already-at-today is a no-op RECEIPT - the clock is where the caller
  # wants it, and refusing a same-day second confirmation would punish exactly
  # the double-checking this verb exists to reward.
  current="$(learn_alw_entry_date "$live" "$slug")"
  [ -n "$current" ] || ac_die "entry '## $slug' carries no '(learned <date>)' line to refresh - nothing written"
  if [ "$current" = "$today" ]; then
    printf 'already reinforced today (%s) - clock unchanged; evidence noted on the receipt: %s\n' "$today" "$evidence"
    return 0
  fi
  lock="$live.lock"
  ac_lock_acquire "$lock" 30 || ac_die "CREWMATE-learned lock $lock could not be acquired within 30s - nothing written"
  tmp="$live.tmp.$$"
  awk -v want="## $slug" -v today="$today" '
    $0 == want { in_e = 1; print; next }
    in_e && /^## / { in_e = 0 }
    in_e && /^\(learned / && !done {
      line = $0
      sub(/, reinforced [0-9]{4}-[0-9]{2}-[0-9]{2}/, "", line)
      sub(/\)$/, ", reinforced " today ")", line)
      print line; done = 1; next
    }
    { print }
  ' "$live" >"$tmp"
  # The clock must actually have moved: an entry with no date line has nothing
  # to reinforce, and silently succeeding would fake a fresh grade.
  # Both no-change shapes were told apart above, so an unchanged file here is
  # a composition bug, never a caller mistake - refuse loudly.
  if cmp -s "$live" "$tmp"; then
    rm -f "$tmp"; ac_lock_release "$lock"
    ac_die "reinforce composed no change for '## $slug' despite a clock at $current - report this (nothing written)"
  fi
  mv "$tmp" "$live"
  ac_lock_release "$lock"
  printf 'reinforced %s (clock -> %s) on evidence: %s\n' "$slug" "$today" "$evidence"
  printf 'post the evidence to the owning room/report - the file deliberately does not store it\n'
}

# --- note: the one placing append onto the ledger ----------------------------

cmd_note() {
  # cmd_note <line>...
  # Append each argument VERBATIM as one line at the end of the `## Pending`
  # body. Placement is the whole job: `## Distilled` opens the pointer index,
  # and learn_ledger_split drops every non-pointer line after it, so an append
  # at end-of-file is deleted by the next transaction. This carries no opinion
  # about the lesson's own shape - the caller writes the ledger's existing
  # convention, and every input line is reproduced exactly once.
  local ledger tmp lines line lock
  [ "$#" -gt 0 ] \
    || ac_die "usage: ac-learn.sh note <line>... (each argument is appended verbatim as one line under '## Pending')"
  for line in "$@"; do
    case "$line" in
      '## Pending'|'## Distilled')
        ac_die "refusing to append the section marker '$line': a second marker makes learn_ledger_split read everything after it as the pointer index and drop it (nothing written)" ;;
    esac
  done
  ledger="$(ac_records_dir)/learnings.md"
  # The whole read-modify-write below is ONE critical section. Unserialized, two
  # landings racing here both read the original and the later `mv` silently
  # discards the earlier writer's lesson. The lock lives HERE rather than around
  # the call sites so every writer is serialized by construction and no future
  # caller can forget to wrap it.
  lock="$(ac_state_dir)/.learn-note.lock"
  ac_lock_acquire "$lock" 30 \
    || ac_die "learnings ledger lock $lock could not be acquired within 30s - NOTHING was written. Re-run the note: a refused note you can see beats a lesson silently lost to a concurrent writer."
  [ -s "$ledger" ] || printf '# Learning Ledger\n\n## Pending\n\n' >"$ledger"
  lines="$(mktemp)"
  printf '%s\n' "$@" >"$lines"
  tmp="$ledger.tmp.$$"
  # Blank lines are HELD rather than printed, so the new lines land at the end
  # of the body proper and the seam blank the writer regenerates stays directly
  # in front of `## Distilled`.
  awk -v add="$lines" '
    function flush_new(  l) { while ((getline l < add) > 0) print l; close(add) }
    function flush_gap(  i) { for (i = 0; i < gap; i++) print ""; gap = 0 }
    $0 == "## Distilled" && !placed { flush_new(); placed = 1; flush_gap(); print; next }
    $0 == "" { gap++; next }
    { flush_gap(); print }
    END { if (!placed) flush_new(); flush_gap() }
  ' "$ledger" >"$tmp"
  mv "$tmp" "$ledger"
  rm -f "$lines"
  ac_lock_release "$lock"
  printf 'appended %s line(s) under ## Pending in %s\n' "$#" "$ledger"
}

# --- rotate-pending: bound the Pending body so DISTILL stays citable ---------
#
# (learn-pending-ledger-is-write-only) Measured before this verb existed: every
# skill the fleet ever landed was retro-only - all learnings-archive blocks
# carry `source-count: 0` - while `## Pending` had grown to 1677 bullets/800KB.
# The land contract demands EXACT verbatim source-line citation
# (learn_validate_sources), which no scout can honour over an unbounded body,
# so the legal retro-only path always won and the ledger was write-only in
# practice. This verb archives the OLDEST `- ` bullets VERBATIM to
# records/learnings-archive/pending-<ts>.md and keeps the newest within
# config/learn-pending-budget bytes (default 131072), leaving a
# `[pending-overflow -> ...]` marker line at the top of the body. cmd_run calls
# it before staging sources/, so the scout copy is always the bounded window a
# citation can actually reach. Old bullets lose nothing they had - they were
# equally unread in Pending - and the archive keeps them greppable evidence.
# Non-bullet body lines (markers included) are never archived, so a rotation
# marker survives every later rotation. The whole rewrite runs under the
# .learn-note.lock: rotation is a ledger read-modify-write like any note, and
# a refused lock rewrites NOTHING. An under-budget ledger is a strict no-op -
# the file is not even rewritten, so its bytes and mtime stay untouched.
learn_rotate_pending() {
  local ledger budget lock archdir ts arch marker tmp archtmp k
  ledger="$(ac_records_dir)/learnings.md"
  [ -f "$ledger" ] || return 0
  budget="$(ac_config_read learn-pending-budget 131072)"
  case "$budget" in
    ''|*[!0-9]*) ac_die "config/learn-pending-budget must be a byte count (got: '$budget')" ;;
  esac
  lock="$(ac_state_dir)/.learn-note.lock"
  ac_lock_acquire "$lock" 30 \
    || ac_die "learnings ledger lock $lock could not be acquired within 30s - rotation refused, nothing rewritten"
  archdir="$(ac_records_dir)/learnings-archive"
  ts="$(ac_now)"; arch="$archdir/pending-$ts.md"; k=2
  while [ -e "$arch" ]; do arch="$archdir/pending-$ts-$k.md"; k=$((k+1)); done
  marker="[pending-overflow -> learnings-archive/$(basename "$arch")]"
  tmp="$(mktemp)"; archtmp="$(mktemp)"
  if ! awk -v budget="$budget" -v archf="$archtmp" -v marker="$marker" '
    { lines[NR] = $0
      if ($0 == "## Pending" && !pstart) pstart = NR
      else if ($0 == "## Distilled" && pstart && !pend) pend = NR }
    END {
      lo = pstart + 1; hi = (pend ? pend - 1 : NR)
      total = 0
      if (pstart) for (i = lo; i <= hi; i++) total += length(lines[i]) + 1
      if (!pstart || total <= budget) exit 0   # no-op: the caller leaves the ledger untouched
      # PREFIX rotation, not a bullet cherry-pick: the real body carries
      # indented continuation lines under their bullet, `### <date>` section
      # headings, and legacy prose (drydock, measured: 1295 continuations, 194
      # headings beside 1677 bullets) - archiving bullets alone strands all of
      # that as orphans. So the archive takes the oldest CONTIGUOUS prefix
      # verbatim, and the cut lands only on a SAFE boundary: a bullet start, a
      # heading, or a blank - never between a bullet and its continuations.
      # Prior [pending-overflow -> ...] markers are the one exception: they
      # stay in the ledger (retained below), never archived.
      # The marker line the rewrite adds is body too - budget the KEPT body
      # including it, or every rotation lands marker-sized bytes over budget.
      overhead = length(marker) + 1
      for (i = lo; i <= hi; i++)
        if (lines[i] ~ /^\[pending-overflow -> /) overhead += length(lines[i]) + 1
      # suffix[i] = bytes of non-marker lines i..hi; cut = smallest boundary i
      # with suffix[i] + overhead <= budget. No such boundary (a pathological
      # tail) -> cut past hi: everything archivable rotates, and the receipt
      # prints the REAL kept size rather than claiming the budget held.
      run = 0
      for (i = hi; i >= lo; i--) {
        if (lines[i] !~ /^\[pending-overflow -> /) run += length(lines[i]) + 1
        suffix[i] = run
      }
      cut = hi + 1
      for (i = lo; i <= hi; i++)
        if ((lines[i] ~ /^- / || lines[i] ~ /^### / || lines[i] == "") && suffix[i] + overhead <= budget) { cut = i; break }
      moved_any = 0
      for (i = lo; i < cut; i++)
        if (lines[i] !~ /^\[pending-overflow -> /) { moved[i] = 1; moved_any = 1 }
      if (!moved_any) exit 0
      for (i = lo; i < cut; i++) if (moved[i]) print lines[i] > archf
      for (i = 1; i < lo; i++) print lines[i]
      for (i = lo; i < cut; i++) if (!moved[i]) print lines[i]   # retained markers, oldest first
      print marker
      for (i = cut; i <= hi; i++) print lines[i]
      if (pend) for (i = pend; i <= NR; i++) print lines[i]
    }
  ' "$ledger" >"$tmp"; then
    rm -f "$tmp" "$archtmp"; ac_lock_release "$lock"
    ac_die "rotate-pending: the ledger rewrite failed mid-pass - nothing installed, $ledger untouched"
  fi
  if [ -s "$archtmp" ]; then
    mkdir -p "$archdir"
    { printf '# Pending overflow - rotated at %s by ac-learn.sh rotate-pending\n' "$ts"
      printf '# Bullets below are VERBATIM, oldest-first, moved out of ## Pending to keep\n'
      printf '# the staged DISTILL copy within config/learn-pending-budget.\n\n'
      cat "$archtmp"
    } >"$arch"
    mv "$tmp" "$ledger"
    printf 'rotated %s bullet(s) into %s (Pending kept within %s bytes)\n' \
      "$(grep -c '^- ' "$arch")" "$arch" "$budget"
  else
    rm -f "$tmp"
  fi
  rm -f "$archtmp"
  ac_lock_release "$lock"
}

# learn_validate_sources <cand> <learnings> - fail-closed PRE-CHECK that every
# ===sources=== bullet exists verbatim in learnings.md BEFORE any write, so a
# source that has drifted since the run is a clean refusal (nothing
# half-written), not a partial state. -Fx: fixed-string, whole-line.
learn_validate_sources() {
  local cand="$1" learnings="$2" bullet
  while IFS=$'\t' read -r _ _ bullet; do
    [ -n "$bullet" ] || continue
    [ -f "$learnings" ] || ac_die "cannot compact: no learnings.md at $learnings"
    grep -qFx -- "$bullet" "$learnings" \
      || ac_die "source bullet not found verbatim in learnings.md (compaction is coupled to landing; nothing written): $bullet"
  done < <(candidate_section "$cand" sources)
}

# --- candidate staging: archive + canonical pointer + closed transaction -------

learn_file_sha_or_absent() {
  if [ -f "$1" ] && [ ! -L "$1" ]; then
    ac_sha256_file "$1"
  elif [ ! -e "$1" ] && [ ! -L "$1" ]; then
    printf '%s\n' -
  else
    return 1
  fi
}

learn_ledger_split() {
  # learn_ledger_split <ledger> <pending-out> <pointer-tsv-out>
  # Accept both legacy rung-qualified pointers and the canonical pointer. The
  # active representation is rebuilt by learn_ledger_stage, so duplicate legacy
  # pointers aggregate here rather than surviving as one record per source.
  local ledger="$1" pending="$2" pointers="$3"
  : >"$pending"
  : >"$pointers"
  [ -f "$ledger" ] || return 0
  awk -v pending="$pending" -v pointers="$pointers" '
    function remember(name, count, date) {
      if (name == "") return
      if (count !~ /^[0-9]+$/) count = 1
      counts[name] += count
      if (date > updated[name]) updated[name] = date
    }
    function consume_pointer(line, name, rest, closing, token, bits, count, date) {
      # Recognize a pointer by POSITION - the marker must open the bullet, not
      # merely appear anywhere on the line - in the two shapes the ledger
      # actually writes. Anything else (including prose quoting the marker as
      # an example) is not a pointer, whatever it mentions.
      if (line ~ /^- \[distilled -> /) {
        rest = substr(line, length("- [distilled -> ") + 1)
        closing = index(rest, "]")
        if (closing == 0) return 0
        name = substr(rest, 1, closing - 1)
        if (name !~ /^[a-z0-9][a-z0-9-]*$/) return 0
        if (substr(rest, closing) !~ /^\] sources=/) return 0
      } else if (line ~ /^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] \[distilled -> /) {
        rest = substr(line, index(line, "[distilled -> ") + length("[distilled -> "))
        closing = index(rest, "]")
        if (closing == 0) return 0
        token = substr(rest, 1, closing - 1)
        split(token, bits, /[[:space:]]+/)
        name = bits[1]
        if (name !~ /^[a-z0-9][a-z0-9-]*$/) return 0
        if (bits[2] != "@fleet" && bits[2] != "@container") return 0
      } else {
        return 0
      }
      count = 1
      if (line ~ /sources=[0-9]+/) {
        count = line
        sub(/^.*sources=/, "", count)
        sub(/[^0-9].*$/, "", count)
      }
      date = ""
      if (line ~ /updated=[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) {
        date = line
        sub(/^.*updated=/, "", date)
        date = substr(date, 1, 10)
      } else if (line ~ /^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] /) {
        date = substr(line, 3, 10)
      }
      remember(name, count, date)
      return 1
    }
    function emit(n,   i) { for (i = 0; i < n; i++) print "" >> pending }
    # learn_ledger_stage re-emits the frame around this body - the title, both
    # section markers, and one blank line at each of those three seams. Consume
    # exactly those blanks here, or every transaction hands the writer the
    # previous frame back and accretes a copy of it. `skip` marks the seam whose
    # blank the writer regenerates; `gap` holds the rest so a blank preceding
    # `## Distilled` can have one subtracted without buffering the whole body.
    # SURPLUS blanks are left alone: a ledger already carrying them is in a
    # shape this plan did not declare, and tidying it would be the same
    # too-broad edit in the other direction.
    $0 == "## Pending" { emit(gap); gap = 0; skip = 1; section = "pending"; canonical = 1; next }
    $0 == "## Distilled" { if (gap > 0) gap--; emit(gap); gap = 0; section = "distilled"; canonical = 1; next }
    consume_pointer($0) { next }
    section == "distilled" { next }
    $0 == "" { if (skip) { skip = 0; next } gap++; next }
    {
      line = $0
      if (!canonical && line ~ /^## /) sub(/^## /, "### ", line)
      if (line ~ /^# (Learning|Learnings)( Ledger)?[[:space:]]*$/) { skip = 1; next }
      skip = 0
      emit(gap); gap = 0
      print line >> pending
    }
    END {
      emit(gap)
      for (name in counts)
        printf "%s\t%d\t%s\n", name, counts[name], updated[name] >> pointers
    }
  ' "$ledger"
}

learn_ledger_stage() {
  # learn_ledger_stage <candidate> <skill> <ledger> <out> <work-dir> [self-link]
  # [self-link] overrides the first link on the CURRENT name's pointer row -
  # a crewmate-lesson land passes its CREWMATE-learned.md link, because at
  # stage time the entry is not on disk yet for the per-row kind read below.
  local cand="$1" name="$2" ledger="$3" out="$4" work="$5" self_link="${6:-}"
  local pending pointers sources filtered next count date hook bullet archdir
  local pname pcount pdate found=0 updated plink
  # Both emitted links resolve relative to the ledger, so the ledger's own
  # directory is what decides whether an `[evidence]` target exists.
  archdir="$(dirname "$ledger")/learnings-archive"
  pending="$work/pending"
  pointers="$work/pointers.tsv"
  sources="$work/source-bullets"
  filtered="$work/pending.filtered"
  next="$work/pointers.next.tsv"
  mkdir -p "$work"
  learn_ledger_split "$ledger" "$pending" "$pointers"
  : >"$sources"
  count=0
  updated=""
  while IFS=$'\t' read -r date hook bullet; do
    [ -n "$bullet" ] || continue
    printf '%s\n' "$bullet" >>"$sources"
    count=$((count + 1))
    if [ -n "$date" ] && { [ -z "$updated" ] || [ "$date" \> "$updated" ]; }; then
      updated="$date"
    fi
  done < <(candidate_section "$cand" sources)
  [ -n "$updated" ] || updated="$(date -u +%Y-%m-%d)"

  if [ -s "$sources" ]; then
    # Count, do not set-test: a candidate declares N occurrences of a bullet, so
    # each declared source consumes at most ONE matching pending line. Set
    # membership removed every identical line, which silently deleted a pending
    # record the plan never declared. Nothing distinguishes the occurrences, so
    # the first in file order is the one consumed.
    awk 'NR == FNR { want[$0]++; next }
         want[$0] > 0 { want[$0]--; next }
         { print }' "$sources" "$pending" >"$filtered"
  else
    cp "$pending" "$filtered"
  fi
  : >"$next"
  while IFS=$'\t' read -r pname pcount pdate; do
    [ -n "$pname" ] || continue
    case "$pcount" in ''|*[!0-9]*) pcount=0 ;; esac
    if [ "$pname" = "$name" ]; then
      pcount=$((pcount + count))
      [ -z "$pdate" ] || [ "$pdate" \< "$updated" ] || updated="$pdate"
      found=1
    fi
    printf '%s\t%s\t%s\n' "$pname" "$pcount" "$pdate" >>"$next"
  done <"$pointers"
  if [ "$found" = 0 ]; then
    printf '%s\t%s\t%s\n' "$name" "$count" "$updated" >>"$next"
  else
    # Update the date on the one row being rewritten without disturbing peers.
    awk -F'\t' -v OFS='\t' -v name="$name" -v updated="$updated" \
      '$1 == name { $3 = updated } { print }' "$next" >"$next.tmp"
    mv "$next.tmp" "$next"
  fi

  {
    printf '# Learning Ledger\n\n## Pending\n\n'
    cat "$filtered"
    [ ! -s "$filtered" ] || printf '\n'
    printf '## Distilled\n\n'
    sort -t $'\t' -k1,1 "$next" | while IFS=$'\t' read -r pname pcount pdate; do
      # A pointer's first link names where the distilled BODY lives: the skill
      # store for a skill/patch row, CREWMATE-learned.md for a crewmate-lesson
      # row (learning-output-reroute). Kind is read from disk per row - a
      # '## <pname>' entry in the crewmate layer with no skill store is a
      # lesson; everything else keeps the historical skill link.
      if [ "$pname" = "$name" ] && [ -n "$self_link" ]; then
        plink="$self_link"
      elif [ ! -f "$(dirname "$ledger")/../skills/$pname/SKILL.md" ] \
        && grep -qxF "## $pname" "$(dirname "$ledger")/../CREWMATE-learned.md" 2>/dev/null; then
        plink="[lesson](../CREWMATE-learned.md)"
      else
        plink="[skill](../skills/$pname/SKILL.md)"
      fi
      # Only the rewritten skill's archive is staged by this transaction; a
      # pointer aggregated from a legacy rung-qualified row may name a skill
      # that never had one. Promising a file no transaction creates is what the
      # gate refuses on evidence grounds, so the link is emitted only when the
      # target will exist.
      if [ "$pname" = "$name" ] || [ -f "$archdir/$pname.md" ]; then
        printf -- '- [distilled -> %s] sources=%s updated=%s (%s; [evidence](learnings-archive/%s.md))\n' \
          "$pname" "$pcount" "$pdate" "$plink" "$pname"
      else
        printf -- '- [distilled -> %s] sources=%s updated=%s (%s)\n' \
          "$pname" "$pcount" "$pdate" "$plink"
      fi
    done
  } >"$out"
}

learn_ledger_shape_gate() {
  # learn_ledger_shape_gate <n> <every> - 0 when records/learnings.md carries
  # neither shape that has each burned a whole DISTILL window: an
  # un-canonicalized legacy rung-qualified pointer row (2026-07-28, 7/7
  # revise), or a canonical `[distilled -> ...]` row whose [evidence] link
  # names a records/learnings-archive/<name>.md that does not exist
  # (2026-08-03, 5/5 revise). Both shapes force EVERY per-candidate plan to
  # bundle a ledger-wide repair alongside its own edit, which the maintenance
  # gate then correctly refuses as over-broad - so the DISTILL cycle gets
  # spent proposing candidates it was always going to lose. Otherwise print
  # the ONE line naming the defect and its remedy, and return non-zero - same
  # HOLD contract as learn_suite_gate, called from the same site in
  # cmd_autoroom, BEFORE it: no repair, no captain ask, no teardown.
  #
  # Deliberately NOT a round-trip diff of learn_ledger_split/learn_ledger_stage
  # against the live ledger: the blank-line accretion learn_ledger_split's own
  # comment documents (surplus blanks after the title, or an empty ## Pending
  # exactly two blanks from ## Distilled) cannot round-trip either, and is not
  # a defect - a generic diff would flag it and get switched off. These two
  # greps target only the two shapes actually measured on disk.
  local n="$1" every="$2" ledger legacy archdir line name
  ledger="$(ac_records_dir)/learnings.md"
  [ -f "$ledger" ] || return 0
  legacy="$(grep -c '^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] \[distilled -> ' "$ledger" || true)"
  if [ "${legacy:-0}" -gt 0 ]; then
    printf 'learning DUE (%s/%s) HELD: records/learnings.md carries %s legacy rung-qualified pointer row(s) (e.g. "- <date> [distilled -> <name> @fleet|@container] ...") that predate the ## Pending/## Distilled frame - every per-candidate plan would bundle their canonicalization and the maintenance gate would refuse it as over-broad (2026-07-28, 7/7 revise); hand-canonicalize the ledger once before the next DISTILL\n' \
      "$n" "$every" "$legacy"
    return 1
  fi
  archdir="$(dirname "$ledger")/learnings-archive"
  while IFS= read -r line; do
    name="$(printf '%s\n' "$line" | sed -n 's/.*\[evidence\](learnings-archive\/\([a-z0-9][a-z0-9-]*\)\.md).*/\1/p')"
    [ -n "$name" ] || continue
    [ -f "$archdir/$name.md" ] && continue
    printf 'learning DUE (%s/%s) HELD: records/learnings.md links [evidence](learnings-archive/%s.md) but that file does not exist - learn_ledger_stage emits the link only when its target exists, so every per-candidate plan would strip it and the maintenance gate would refuse it as over-broad (2026-08-03, 5/5 revise); hand-repair the dangling link before the next DISTILL\n' \
      "$n" "$every" "$name"
    return 1
  done < <(grep '^- \[distilled -> ' "$ledger")
  return 0
}

learn_pointer_evidence_check() {
  # learn_pointer_evidence_check <staged-ledger> <staged-archive> <skill>
  # The pointer this transaction is about to publish must not claim more (or
  # fewer) sources than the archive it links declares. learn_ledger_split
  # aggregates `counts[name] += count` over every pointer row sharing a name,
  # so a duplicated row inflates a count that nothing else ever reconciles.
  # Only meaningful once the skill HAS an archive - the caller owns that
  # condition, because without one there is no evidence to reconcile against.
  local ledger="$1" archive="$2" name="$3" claimed declared
  claimed="$(sed -n "s/^- \[distilled -> $name\] sources=\([0-9][0-9]*\) .*/\1/p" "$ledger" | head -1)"
  [ -n "$claimed" ] \
    || ac_die "refusing the transaction: no canonical pointer for '$name' in the staged ledger to reconcile against its archive (nothing written)"
  declared="$(awk '/^source-count: [0-9]+$/ { n += $2 } END { print n + 0 }' "$archive")"
  [ "$claimed" = "$declared" ] && return 0
  ac_die "refusing to publish a pointer that contradicts its own evidence: '[distilled -> $name]' would claim sources=$claimed while records/learnings-archive/$name.md declares $declared (sum of its 'source-count:' lines). Nothing written. Reconcile the two - a duplicated pointer row in records/learnings.md inflates the claim, and a pointer predating its archive claims sources the archive never received."
}

learn_archive_stage() {
  # learn_archive_stage <candidate> <skill> <archive> <out> <txid> <gate-rel>
  #                     <candidate-rel>
  local cand="$1" name="$2" archive="$3" out="$4" txid="$5" gate_rel="$6"
  local candidate_rel="$7"
  local count=0 date hook bullet
  [ ! -f "$archive" ] || cp "$archive" "$out"
  if [ ! -f "$archive" ]; then
    printf '# Learning Evidence: %s\n' "$name" >"$out"
  fi
  while IFS=$'\t' read -r date hook bullet; do
    [ -n "$bullet" ] && count=$((count + 1))
  done < <(candidate_section "$cand" sources)
  {
    printf '\n## %s - %s\n\n' "$(ac_iso)" "$txid"
    printf 'gate: %s\n' "$gate_rel"
    printf 'candidate: %s\n' "$candidate_rel"
    printf 'source-count: %s\n\n' "$count"
    while IFS=$'\t' read -r date hook bullet; do
      [ -n "$bullet" ] || continue
      printf '### %s\n\n%s\n\n' "$date" "$bullet"
    done < <(candidate_section "$cand" sources)
  } >>"$out"
}

learn_crewmate_learned_base() {
  # learn_crewmate_learned_base - print the live CREWMATE-learned.md, or the
  # ownership header when none exists yet (the file is born on its first
  # transaction). The header names the boundary the captain must know: this
  # file is MACHINE-OWNED - the captain's hand-written layer stays CREWMATE.md,
  # which the seed deliberately reads LATER so the captain's word wins.
  local live
  live="$(ac_home)/CREWMATE-learned.md"
  if [ -f "$live" ]; then
    cat "$live"
  else
    printf '# Fleet-learned crewmate lessons\n'
    printf '<!-- written only by ac-learn.sh transactions; captains edit CREWMATE.md instead -->\n'
  fi
}

learn_crewmate_learned_guard() {
  # learn_crewmate_learned_guard <staged-file> <run> - the write-time gates
  # every staged CREWMATE-learned.md rewrite must pass BEFORE it is planned:
  # - the 4096-byte whole-file budget (hermes' tight MEMORY.md cap, adopted):
  #   the file is ALWAYS-LOADED into every crewmate session, so growth is paid
  #   on every spawn - the refusal names the current entries so the remedy
  #   (pair the new entry with a retire) is one look away;
  # - the no-silent-loss check (ac_crewmate_learned_no_loss - openclaw's
  #   preserve-prior-entries gate): this caller stages append-only rewrites,
  #   so the guard is defense in depth against a composition bug;
  # - a .prev copy of the live file under the run, so the exact pre-state of
  #   this one file is readable without untarring the records backup.
  local staged="$1" run="$2" live entries
  live="$(ac_home)/CREWMATE-learned.md"
  if [ "$(wc -c <"$staged" | tr -d ' ')" -gt 4096 ]; then
    entries="$({ [ -f "$live" ] && grep '^## ' "$live" | sed 's/^## //'; } | tr '\n' ' ')"
    ac_die "staged CREWMATE-learned.md exceeds its 4096-byte always-loaded budget - pair the new entry with a retire of one of: ${entries:-none}(nothing written)"
  fi
  ac_crewmate_learned_no_loss "$live" "$staged" "" \
    || ac_die "staged CREWMATE-learned.md drops an existing '## <slug>' entry with no retired accounting (nothing written)"
  if [ -f "$live" ]; then
    mkdir -p "$run/backup"
    cp "$live" "$run/backup/CREWMATE-learned.md.prev"
  fi
}

learn_plan_action() {
  # learn_plan_action <actions-ndjson> <op> <target-rel> <staged-rel> <run>
  local actions="$1" op="$2" target="$3" staged="$4" run="$5"
  local old_sha new_sha
  old_sha="$(learn_file_sha_or_absent "$(ac_home)/$target")" || return 1
  new_sha="$(ac_sha256_file "$run/$staged")" || return 1
  jq -nc --arg op "$op" --arg target "$target" --arg old "$old_sha" \
    --arg new "$new_sha" --arg staged "$staged" \
    '{op:$op,target:$target,old_sha256:$old,new_sha256:$new,staged:$staged}' \
    >>"$actions"
}

learn_prepare_candidate_plan() {
  # learn_prepare_candidate_plan <candidate> <authority> [<owning-run>]
  # Print `<run><TAB><plan><TAB><manifest>`. An automatic run keeps immutable
  # per-subject paths under its existing directory; legacy manual land gets a
  # one-subject compatibility run and a captain-decision receipt.
  local cand="$1" authority="$2" owning="${3:-}"
  local kind name desc subject txid run staged staged_prefix actions plan_out
  local candidate_copy candidate_rel skills target tname tdesc body learnings
  local archive captain gate_rel cml_ptr cml_sec
  command -v jq >/dev/null 2>&1 || ac_die "jq is required for maintenance plans"
  kind="$(candidate_header "$cand" kind)"
  name="$(candidate_header "$cand" name)"
  case "$kind" in
    skill)
      desc="$(candidate_header "$cand" description)"
      valid_slug "$name" || ac_die "skill candidate 'name:' must be an agentskills slug: lowercase [a-z0-9-], <=64 chars, no leading/trailing/consecutive hyphen (got: '$name')"
      valid_description "$desc" || ac_die "skill candidate 'description:' must be non-empty and <=1024 chars (spec-required)"
      [ ! -e "$(ac_skills_dir)/$name" ] || ac_die "refusing to clobber an existing skill store at $(ac_skills_dir)/$name"
      subject="$name" ;;
    patch)
      valid_slug "$name" || ac_die "patch candidate 'name:' must be an agentskills slug: lowercase [a-z0-9-], <=64 chars, no leading/trailing/consecutive hyphen (got: '$name')"
      target="$(ac_skills_dir)/$name/SKILL.md"
      if [ ! -f "$target" ]; then
        if [ -f "$(dirname "$(ac_home)")/.claude/skills/$name/SKILL.md" ]; then
          ac_die "learned skill '$name' exists only in the legacy container store, which is retired and never read; learned skills are permanently fleet-local - copy it into the fleet store deliberately before patching (nothing written)"
        fi
        ac_die "no fleet-local learned skill named '$name' to patch (nothing written)"
      fi
      tname="$(sed -n 's/^name:[[:space:]]*//p' "$target" | head -1)"
      tdesc="$(sed -n 's/^description:[[:space:]]*//p' "$target" | head -1)"
      valid_slug "$tname" || ac_die "refusing to patch '$name': target frontmatter 'name:' is not an agentskills slug (got: '$tname')"
      valid_description "$tdesc" || ac_die "refusing to patch '$name': target frontmatter 'description:' is empty or >1024 chars"
      body="$(candidate_section "$cand" patch)"
      case "$body" in '## '*) ;; *)
        ac_die "patch '===patch===' body must lead with a '## ' labeled subsection heading (nothing written)" ;;
      esac
      subject="$name" ;;
    crewmate)
      # An always-loaded method lesson for CREWMATE-learned.md
      # (learning-output-reroute): same slug/description bar as a skill, and
      # the dedup mirror of the skill clobber refusal - one '## <name>' entry
      # per name, ever; a lesson that moved on is curated, never re-landed.
      desc="$(candidate_header "$cand" description)"
      valid_slug "$name" || ac_die "crewmate candidate 'name:' must be an agentskills slug: lowercase [a-z0-9-], <=64 chars, no leading/trailing/consecutive hyphen (got: '$name')"
      valid_description "$desc" || ac_die "crewmate candidate 'description:' must be non-empty and <=1024 chars (got: '$desc')"
      if [ -f "$(ac_home)/CREWMATE-learned.md" ] \
        && grep -qxF "## $name" "$(ac_home)/CREWMATE-learned.md"; then
        ac_die "CREWMATE-learned.md already carries '## $name' - curate the existing entry instead of re-landing it (nothing written)"
      fi
      subject="$name" ;;
    rule) subject="rule-$(ac_now)" ;;
    *) ac_die "candidate 'kind:' must be skill|patch|crewmate|rule (got: '$kind')" ;;
  esac

  case "$kind" in skill|patch|crewmate)
    learn_validate_sources "$cand" "$(ac_records_dir)/learnings.md" ;;
  esac

  if [ -n "$owning" ]; then
    run="$(cd "$owning" && pwd -P)"
    case "$run/" in "$(ac_data_dir)/"*) ;; *) ac_die "automatic Learning run must resolve under $(ac_data_dir)" ;; esac
    txid="$(basename "$run")"
    staged_prefix="staged/$subject"
    actions="$run/plans/.$subject.actions.$$"
    plan_out="$run/plans/$subject.json"
    candidate_copy="$run/candidates/$subject.md"
    candidate_rel="data/$txid/candidates/$subject.md"
  else
    txid="maintenance-learning-manual-$(ac_now)-$$"
    run="$(ac_data_dir)/$txid"
    staged_prefix=staged
    actions="$run/actions.ndjson"
    plan_out="$run/plan.json"
    candidate_copy="$run/candidate.md"
    candidate_rel="data/$txid/candidate.md"
  fi
  staged="$run/$staged_prefix"
  mkdir -p "$staged/records/learnings-archive" "$staged/skills/$name" \
    "$run/gates/$subject" "$(dirname "$actions")" "$(dirname "$candidate_copy")"
  cp "$cand" "$candidate_copy"
  gate_rel="data/$txid/gates/$subject/decision.md"
  if [ -z "$owning" ]; then
    {
      printf -- '---\nschema: agentcrew.captain-decision/v1\n'
      printf 'mode: learning\nsubject: %s\ndecision: continue\nauthority: %s\n' \
        "$subject" "$authority"
      printf 'candidate_sha256: %s\nreviewed_at: %s\n---\n' \
        "$(ac_sha256_file "$candidate_copy")" "$(ac_iso)"
    } >"$run/gates/$subject/decision.md"
  fi
  : >"$actions"

  case "$kind" in
    skill)
      {
        printf -- '---\nname: %s\ndescription: %s\nmetadata:\n' "$name" "$desc"
        printf '  origin: learned\n  landed: "%s"\n---\n\n' "$(ac_now)"
        candidate_section "$cand" skill
      } >"$staged/skills/$name/SKILL.md" ;;
    patch)
      cp "$(ac_skills_dir)/$name/SKILL.md" "$staged/skills/$name/SKILL.md"
      {
        printf '\n'
        candidate_section "$cand" patch
      } >>"$staged/skills/$name/SKILL.md" ;;
    crewmate)
      body="$(candidate_section "$cand" crewmate)"
      [ -n "$body" ] || ac_die "crewmate candidate '===crewmate===' body is empty (nothing written)"
      # The heading is COMPOSED here, never taken from the body: a body
      # carrying its own '## ' line could smuggle a second entry under a name
      # the dedup and no-loss guards never checked.
      if printf '%s\n' "$body" | grep -q '^## '; then
        ac_die "crewmate '===crewmate===' body must be lesson prose only - the transaction composes the '## $name' heading itself (nothing written)"
      fi
      # The per-entry budget: the file is always-loaded, so an entry is a few
      # terse lines - a lesson that needs more is a skill or a doc.
      [ "$(printf '%s\n' "$body" | grep -c '')" -le 12 ] \
        || ac_die "crewmate '===crewmate===' body is over 12 lines - a lesson that long is a skill or a doc (nothing written)"
      {
        learn_crewmate_learned_base
        printf '\n## %s\n\n%s\n\n(learned %s)\n' "$name" "$body" "$(ac_iso | cut -c1-10)"
      } >"$staged/CREWMATE-learned.md"
      learn_crewmate_learned_guard "$staged/CREWMATE-learned.md" "$run"
      learn_plan_action "$actions" rewrite-crewmate-learned CREWMATE-learned.md \
        "$staged_prefix/CREWMATE-learned.md" "$run" ;;
    rule)
      captain="$(ac_records_dir)/captain.md"
      [ ! -f "$captain" ] || cp "$captain" "$staged/records/captain.md"
      [ -f "$captain" ] || : >"$staged/records/captain.md"
      [ ! -s "$staged/records/captain.md" ] || printf '\n' >>"$staged/records/captain.md"
      candidate_section "$cand" rule >>"$staged/records/captain.md"
      learn_plan_action "$actions" rewrite-registry records/captain.md \
        "$staged_prefix/records/captain.md" "$run" ;;
  esac

  if [ "$kind" = skill ]; then
    # Discovery-pointer coupling (learning-output-reroute): the measured
    # zero-invocation gap was a DISCOVERY gap - crewmates never matched a
    # skill's listing against their task - so a learned skill never again
    # exists without one trigger line in the always-loaded crewmate layer.
    # One grammar, no separate pointer kind; the line is derived from the
    # skill's own trigger-rich description.
    cml_ptr="- when ${desc%.} -> use skill $name"
    cml_sec='## when to reach for a learned skill'
    if ! { [ -f "$(ac_home)/CREWMATE-learned.md" ] \
      && grep -qF -- "use skill $name" "$(ac_home)/CREWMATE-learned.md"; }; then
      if [ -f "$(ac_home)/CREWMATE-learned.md" ] \
        && grep -qxF "$cml_sec" "$(ac_home)/CREWMATE-learned.md"; then
        # Insert directly under the existing section heading, so pointers
        # stay inside their section wherever it sits in the file.
        awk -v sec="$cml_sec" -v ptr="$cml_ptr" \
          '{ print } $0 == sec { print ptr }' \
          "$(ac_home)/CREWMATE-learned.md" >"$staged/CREWMATE-learned.md"
      else
        {
          learn_crewmate_learned_base
          printf '\n%s\n%s\n' "$cml_sec" "$cml_ptr"
        } >"$staged/CREWMATE-learned.md"
      fi
      learn_crewmate_learned_guard "$staged/CREWMATE-learned.md" "$run"
      learn_plan_action "$actions" rewrite-crewmate-learned CREWMATE-learned.md \
        "$staged_prefix/CREWMATE-learned.md" "$run"
    fi
  fi

  if [ "$kind" = skill ] || [ "$kind" = patch ] || [ "$kind" = crewmate ]; then
    learnings="$(ac_records_dir)/learnings.md"
    archive="$(ac_records_dir)/learnings-archive/$name.md"
    learn_archive_stage "$candidate_copy" "$name" "$archive" \
      "$staged/records/learnings-archive/$name.md" "$txid" "$gate_rel" "$candidate_rel"
    learn_ledger_stage "$candidate_copy" "$name" "$learnings" \
      "$staged/records/learnings.md" "$run/work" \
      "$([ "$kind" = crewmate ] && printf '%s' '[lesson](../CREWMATE-learned.md)')"
    # Reconcile the two staged artifacts BEFORE either is planned, so a
    # contradiction refuses with nothing committed. Only when the skill already
    # had an archive: absent one there is no evidence to reconcile against, and
    # learn_ledger_stage already declines to link evidence that does not exist.
    [ ! -f "$archive" ] || learn_pointer_evidence_check \
      "$staged/records/learnings.md" "$staged/records/learnings-archive/$name.md" "$name"
    learn_plan_action "$actions" append-archive \
      "records/learnings-archive/$name.md" \
      "$staged_prefix/records/learnings-archive/$name.md" "$run"
    # A crewmate lesson mints NO skill package - its whole body lives in
    # CREWMATE-learned.md, already planned above.
    [ "$kind" = crewmate ] || learn_plan_action "$actions" \
      "$([ "$kind" = skill ] && printf write-skill || printf patch-skill)" \
      "skills/$name/SKILL.md" "$staged_prefix/skills/$name/SKILL.md" "$run"
    learn_plan_action "$actions" rewrite-ledger records/learnings.md \
      "$staged_prefix/records/learnings.md" "$run"
  fi

  jq -s --arg run_id "$txid" --arg subject "$subject" \
    --arg manifest "$(ac_sha256_file "$candidate_copy")" \
    '{schema:"agentcrew.maintenance-plan/v1",mode:"learning",run_id:$run_id,
      subject:$subject,input_manifest_sha256:$manifest,actions:.}' \
    "$actions" >"$plan_out"
  rm -f "$actions"
  printf '%s\t%s\t%s\n' "$run" "$plan_out" "$candidate_copy"
}

learn_policy_ask_receipt() {
  # learn_policy_ask_receipt <receipt> <plan> <manifest> <subject> <grounds>
  local receipt="$1" plan="$2" manifest="$3" subject="$4" grounds="$5"
  {
    printf -- '---\nschema: "agentcrew.maintenance-gate/v1"\n'
    printf 'mode: "learning"\nsubject: "%s"\ndecision: "ask-captain"\n' "$subject"
    printf 'authority: "repository-policy"\nengine: "policy"\nmodel: ""\n'
    printf 'input_manifest_sha256: "%s"\n' "$(ac_sha256_file "$manifest")"
    printf 'action_plan_sha256: "%s"\nreviewed_at: "%s"\n---\n' \
      "$(ac_sha256_file "$plan")" "$(ac_iso)"
    printf '# Maintenance Gate Decision\n## Decision\nask-captain\n'
    printf '## Grounds\n%s\n' "$grounds"
    printf '## Proposed Process\nRecord one durable captain question and wait; do not mutate fleet state.\n'
  } >"$receipt.tmp.$$"
  mv "$receipt.tmp.$$" "$receipt"
}

learn_captain_escalate() {
  # learn_captain_escalate <run> <subject> <plan> <manifest> <reason>
  local run="$1" subject="$2" plan="$3" manifest="$4" reason="$5"
  local txid plan_sha receipt_rel candidate_rel message
  txid="$(basename "$run")"
  plan_sha="$(ac_sha256_file "$plan")"
  receipt_rel="data/$txid/gates/$subject/decision.md"
  # The manifest IS the immutable candidate copy the plan was built from
  # (learn_prepare_candidate_plan returns it as its third field), so both links
  # name that one file. A path rebuilt from the CALLER's subject misses it: for
  # a `rule` the preparer mints a subject of its own (`rule-<epoch>`).
  candidate_rel="${manifest#"$(ac_home)/"}"
  message="ASK: Learning maintenance cannot decide automatically.
why: $reason
subject: $subject; action-plan-sha256: $plan_sha
options: (1) approve this exact recoverable plan; (2) reject and preserve Pending; (3) request a revised candidate.
tradeoffs: approve compacts supported evidence now; reject preserves all active records; revise spends another learning/gate round.
recommendation: reject or revise unless the linked evidence clearly supports the exact action.
links: candidate=$candidate_rel; gate=$receipt_rel; evidence=$candidate_rel"
  "$(dirname "$0")/ac-room.sh" post learning roomchief "$message" >/dev/null 2>&1 \
    || ac_warn "captain escalation for $subject could not be posted to the learning room"
}

learn_auto_apply_candidates() {
  # learn_auto_apply_candidates <learning-run> - gate every candidate
  # independently, apply only hash-matched continue receipts, and leave revise /
  # ask-captain sources in Pending. No QA or unit-test command exists here.
  local run="$1" cand kind subject prepared plan manifest receipt gate gate_out
  local decision prep_err rc=0 reason
  local found=0
  gate="${AC_GATE:-$(dirname "$0")/ac-gate.sh}"
  for cand in "$run"/candidate-*.md; do
    [ -f "$cand" ] || continue
    found=1
    kind="$(candidate_header "$cand" kind)"
    subject="$(candidate_header "$cand" name)"
    if [ "$kind" = rule ]; then
      subject="rule-$(basename "$cand" .md | sed 's/^candidate-//')"
    fi
    case "$subject" in
      ''|*[!A-Za-z0-9._-]*) subject="invalid-$(ac_sha256_file "$cand" | cut -c1-12)" ;;
    esac
    mkdir -p "$run/gates/$subject"
    prep_err="$run/gates/$subject/prepare.err"
    if ! prepared="$(learn_prepare_candidate_plan "$cand" maintenance-gate "$run" 2>"$prep_err")"; then
      {
        printf 'schema: agentcrew.maintenance-rejection/v1\n'
        printf 'decision: revise\nsubject: %s\nreviewed_at: %s\n\n' "$subject" "$(ac_iso)"
        printf 'Candidate or staged-plan validation failed. Sources remain Pending.\n\n'
        cat "$prep_err"
      } >"$run/gates/$subject/rejected.md"
      printf '  revise: %s (candidate/plan validation failed; sources preserved)\n' "$subject"
      continue
    fi
    IFS=$'\t' read -r _ plan manifest <<EOF
$prepared
EOF
    receipt="$run/gates/$subject/decision.md"

    if [ "$kind" = rule ]; then
      reason="A new or changed standing captain rule is captain-owned and cannot auto-apply."
      learn_policy_ask_receipt "$receipt" "$plan" "$manifest" "$subject" "$reason"
      learn_captain_escalate "$run" "$subject" "$plan" "$manifest" "$reason"
      printf '  ask-captain: %s (standing-rule authority; no mutation)\n' "$subject"
      continue
    fi

    if gate_out="$("$gate" maintenance --mode learning --run "$run" \
      --subject "$subject" --manifest "$manifest" --plan "$plan" 2>&1)"; then
      [ -z "$gate_out" ] || printf '  %s\n' "$gate_out"
    else
      reason="The selected maintenance gate was disabled, unavailable, invalid, or timed out."
      learn_captain_escalate "$run" "$subject" "$plan" "$manifest" "$reason"
      printf '  ask-captain: %s (gate unavailable; no mutation)\n' "$subject"
      continue
    fi

    if ! decision="$(ac_maintenance_receipt_validate "$receipt" "$plan" "$manifest")"; then
      reason="The gate receipt did not match the immutable manifest and action-plan hashes."
      learn_captain_escalate "$run" "$subject" "$plan" "$manifest" "$reason"
      printf '  ask-captain: %s (invalid gate receipt; no mutation)\n' "$subject"
      continue
    fi
    case "$decision" in
      continue)
        if ! ac_maintenance_apply "$plan" "$run"; then
          ac_warn "continue receipt for $subject became stale or its transaction could not complete; obtain a fresh gate decision"
          rc=1
          continue
        fi
        printf '  auto-applied: %s\n' "$subject" ;;
      revise)
        printf '  revise: %s (sources preserved; no captain question)\n' "$subject" ;;
      ask-captain)
        learn_captain_escalate "$run" "$subject" "$plan" "$manifest" \
          "The maintenance gate returned ask-captain for this exact subject."
        printf '  ask-captain: %s (gate could not decide; no mutation)\n' "$subject" ;;
    esac
  done
  [ "$found" = 1 ] || printf '  AUTO-MAINTENANCE: no candidates; the examined cycle is settled without mutation.\n'
  return "$rc"
}

# --- promote: fleet-local ownership compatibility command ---------------------

cmd_promote() {
  local name="${1:-}"
  [ -n "$name" ] || ac_die "usage: ac-learn.sh promote <skill-name>"
  valid_slug "$name" || ac_die "skill name must be a slug [a-z0-9-] (got: '$name')"
  ac_die "learned skills are permanently fleet-local; promote is a fail-closed compatibility command (the legacy container store is retired and never read)."
}

cmd_maintenance() {
  # `maintenance status|resume <txid>|abandon <txid>` - the operator surface for
  # the shared Learning/Curate transaction (bin/ac-lib.sh owns the mechanism;
  # this file's header owns the contract). It exists because an UNSETTLED
  # transaction refuses every other one, and nothing could end that state: a
  # crash between the claim and the final `complete`, or a plan whose second
  # action failed, wedged the whole knowledge-maintenance loop until someone
  # read state/ by hand - `run` mints a fresh run_id and `land` a fresh txid, so
  # neither can ever finish the transaction that is actually holding the claim.
  #
  # `resume` replays the recorded plan through the SAME hash-bound apply: an
  # action whose target already holds the planned bytes is skipped, so it
  # finishes exactly what did not land, and it re-refuses if the cause is still
  # there. `abandon` settles a transaction that cannot be replayed - the
  # journal keeps the record (status=abandoned) and stops blocking the loop; it
  # rolls nothing back, so it names what was committed and where the
  # pre-mutation backup is.
  local verb="${1:-status}" txid="${2:-}" root journal status plan run committed backup
  root="$(ac_state_dir)/.maintenance-transactions"
  case "$verb" in
    status)
      local rows
      rows="$(ac_maintenance_incomplete "$root")"
      if [ -z "$rows" ]; then
        printf 'no incomplete maintenance transaction - the Learning/Curate loop is clear\n'
        return 0
      fi
      printf 'INCOMPLETE maintenance transaction(s) - every other Learning/Curate transaction refuses until settled:\n'
      while IFS=$'\t' read -r txid status committed plan; do
        [ -n "$txid" ] || continue
        printf '  %s status=%s committed=%s plan=%s\n' "$txid" "$status" "$committed" "$plan"
        printf '    resume: bin/ac-learn.sh maintenance resume %s\n' "$txid"
        printf '    drop:   bin/ac-learn.sh maintenance abandon %s\n' "$txid"
      done <<EOF
$rows
EOF
      ;;
    resume | abandon)
      [ -n "$txid" ] || ac_die "usage: ac-learn.sh maintenance $verb <transaction-id> (list them: ac-learn.sh maintenance status)"
      case "$txid" in *[!A-Za-z0-9._-]*) ac_die "transaction id must be [A-Za-z0-9._-] (got: '$txid')" ;; esac
      journal="$root/$txid/journal"
      [ -f "$journal" ] || ac_die "no maintenance transaction '$txid' on record at $root"
      status="$(ac_meta_get "$journal" status)"
      case "$status" in
        complete) printf '%s already reached complete - nothing to settle\n' "$txid"; return 0 ;;
        abandoned) printf '%s was already abandoned - it blocks nothing\n' "$txid"; return 0 ;;
      esac
      committed="$(ac_meta_get "$journal" held_committed)"
      if [ "$verb" = abandon ]; then
        backup="$(ac_meta_get "$journal" backup)"
        ac_meta_set "$journal" status abandoned
        ac_meta_set "$journal" abandoned_at "$(ac_now)"
        printf 'abandoned %s - it no longer blocks the loop.\n' "$txid"
        printf 'NOTHING was rolled back: %s action(s) of this plan are still committed to disk.\n' "${committed:-an unrecorded number of}"
        [ -z "$backup" ] || printf 'The pre-mutation backup of records/ + skills/ is at %s\n' "$backup"
        return 0
      fi
      plan="$(ac_meta_get "$journal" plan)"
      run="$(ac_meta_get "$journal" run)"
      # A journal written before the plan/run were recorded cannot be replayed:
      # say that, rather than failing in a way that reads like a bad plan.
      { [ -n "$plan" ] && [ -n "$run" ]; } \
        || ac_die "$txid records no plan/run to replay (it predates the resume record) - re-run the owning Learning/Curate run, or settle it: bin/ac-learn.sh maintenance abandon $txid"
      { [ -f "$plan" ] && [ -d "$run" ]; } \
        || ac_die "$txid's plan or run directory is gone (plan=$plan run=$run) - it cannot be replayed; settle it: bin/ac-learn.sh maintenance abandon $txid"
      ac_maintenance_apply "$plan" "$run" \
        || ac_die "$txid could not be resumed - the cause above is still present; fix it and resume again, or abandon it"
      printf 'resumed %s - transaction complete\n' "$txid"
      ;;
    *) ac_die "usage: ac-learn.sh maintenance status|resume <txid>|abandon <txid>" ;;
  esac
}

cmd_tick() {
  # `tick [<landing-id>]`. WITH a landing id the tick is IDEMPOTENT for that
  # landing (ac_learn_tick_claim): the landing debrief's two possible actors -
  # the roomchief before its handback and the crewchief at close-out - cannot see
  # each other, so both ran it and the counter advanced twice per landing. The
  # key is the family/task id, the one identity BOTH already hold, so it works
  # unchanged when a family lands UNPROMOTED and the crewchief is the only actor.
  # A duplicate SAYS so on stdout: the second actor has no other way to learn its
  # tick did nothing. WITHOUT a key the tick is unguarded, as it always was -
  # that is the session /debrief call site, which is not a landing.
  #
  # Advance the per-debrief counter, and on the tick that CROSSES
  # config/learn-every publish a durable FLEET wake so the crewchief hears the
  # DISTILL is due right now - not only at the next session-start digest
  # (ac_learn_due).
  #
  # The wake is a NOTIFICATION and nothing more. The ACT is `autoroom`, which
  # the same drain runs off the LEVEL, so this wake only shortens latency and
  # correctness never rests on it. Its payload therefore names NO command for
  # the reader to execute: a chief that obeyed a `run bin/ac-learn.sh run`
  # instruction would run the distill in ITS OWN context, which is exactly what
  # the dedicated learning room exists to prevent (spec R2).
  #
  # The crossing edge (before < every <= after) fires at most once per cycle -
  # the reset at the END of a successful `run` re-arms it, and ticks already at
  # or over the threshold never re-fire, which is precisely why the ACT reads
  # the level instead of this edge: a counter carried past the edge still gets
  # its room at the next drain.
  local key="${1:-}" before after every
  # An UNQUOTED multi-word key would otherwise key on its first word alone and
  # silently stamp the wrong landing - which double-advances the real one, the
  # unrecoverable direction. Refuse instead.
  [ "$#" -le 1 ] || ac_die "tick takes at most one landing id (got: $*)"
  if [ -n "$key" ]; then
    # The task-id grammar (AGENTS.md section 5, "pick a short id [a-z0-9-]") -
    # not valid_slug, which is the agentskills SKILL-name rule. Whitespace here
    # would corrupt the stamp file's TSV line grammar, so refuse it loudly: an
    # unticked landing with a message beats a silently unreadable ledger.
    case "$key" in *[!a-z0-9-]*) ac_die "tick key must be a task/family id [a-z0-9-] (got: '$key')" ;; esac
    if ! ac_learn_tick_claim "$key"; then
      printf 'tick skipped: landing %s is already counted - one landing advances the counter once, whichever actor runs it\n' "$key"
      return 0
    fi
  fi
  read -r before every < <(ac_learn_due)
  ac_learn_tick
  read -r after _ < <(ac_learn_due)
  # SAY what the tick did. Silence on the ordinary path is indistinguishable
  # from a silent failure (wrong cwd, unreadable state dir), so the natural
  # repair is to run it again - and a second tick DOUBLE-counts the landing,
  # firing the DISTILL against a counter that never reflected real landings.
  # Observed first-hand at a real landing (2026-07-25) and three times in the
  # 2026-07-21 distill window. The guarded siblings already speak: the keyed
  # duplicate says `tick skipped:` above, and the crossing edge publishes its
  # wake below.
  printf 'tick: debriefs=%s/%s\n' "$after" "$every"
  if [ "$before" -lt "$every" ] && [ "$after" -ge "$every" ]; then
    ac_wake_publish "$(ac_state_dir)" "" learning-due learning \
      "$after/$every - the cap-exempt learning room opens itself at the next drain; do NOT run the distill in this session" \
      || ac_warn "learning DUE ($after/$every) but its wake could not be published"
  fi
}

learn_charter() {
  # learn_charter <n> <every> - the self-contained English charter posted to room
  # `learning` BEFORE the promote. `ac-spawn.sh --roomchief` takes no brief (the
  # room IS the brief) and its roomchief prompt is generic and code-owned, so an
  # auto-created chief reading only that prompt would have no idea it must call
  # `ac-learn.sh run`.
  cat <<EOF
CHARTER: room \`learning\` was created automatically because the fleet reached its distill threshold ($1/$2 debriefs). This executes the captain's standing policy.
AUTHORITY: records/captain.md delegates the end-to-end Learning loop and its cap-exempt system room to the crewchief. The captain retains post-hoc veto authority.
WHY A ROOM: the work must remain visible while the independent scout and the maintenance gate retain separate judgment.
ROOMCHIEF DUTIES:
(1) Run \`bin/ac-learn.sh run\`. It snapshots the fleet, launches the independent Learning scout, validates a complete run, and gates/applies eligible skill or patch plans automatically.
(2) Read retro.md, report.md, candidate files, gate receipts, and transaction journals in data/learning-<epoch>/. Do not author scout artifacts in this session.
(3) Do not add \`approved:\` or call compatibility \`land\`/\`promote\`. A matching hash-bound maintenance-gate \`continue\` is the only automatic authority. \`revise\` preserves Pending; only a real escalation asks the captain.
(4) When the cycle settles, run \`bin/ac-room.sh handback learning '<one-line result>'\` so the crewchief can demote and close the room.
EOF
}

# --- the full-suite gate in front of the DISTILL ------------------------------
# records/captain.md 2026-07-27 STANDING "THE FULL SUITE MOVES TO A PERIODIC TASK
# RUN BEFORE LEARNING": no landing path runs tests/run-suite.sh any more, so it
# runs as its OWN periodic task immediately before each DISTILL, hung off the
# cadence Learning already fires on. "A RED SUITE IS A GATE, NOT A NOTE" - only a
# green suite releases the run, because a retro reasoning about a fleet whose
# suite is red is reasoning about a fleet that does not work.
#
# The gate's whole state is ONE verdict record, state/.learn-suite.meta -
# DOT-prefixed like every other learn-loop state file, since it is a record and
# not a task (a bare state/*.meta enumerates as a phantom crewmate):
#   generation=<n>  the cadence generation the run answered for
#   head=<sha>      the tree it ran against
#   status=green|red
#   exit=<rc>       run-suite.sh's own status (1 a red test, 2 a runner that
#                   could not proceed - never collapsed into one word)
#   at=<epoch>
# BOTH keys must match the CURRENT cycle or the record releases nothing. The
# generation is the captain's "stale green from a previous cycle does not release
# this one"; the head is that same rule on the other axis - a green taken before
# the fix landed describes a tree the retro will not be reasoning about. Binding
# the head is also what ENDS a red with no knob and no timer: the fix lands, HEAD
# moves, and the next checkpoint starts a fresh run by itself.

learn_suite_record() { printf '%s/.learn-suite.meta\n' "$(ac_state_dir)"; }

learn_suite_root() {
  # The distro checkout this ac-learn.sh belongs to - the tree whose suite the
  # ruling names. Bound to the SCRIPT, never to the caller's cwd: a drain runs
  # from wherever its chief happens to be.
  (cd "$(dirname "$0")/.." && pwd -P)
}

learn_suite_head() {
  git -C "$(learn_suite_root)" rev-parse HEAD 2>/dev/null || printf 'no-head\n'
}

learn_suite_inflight() {
  # Print the id of a suite task still in flight and return 0; return 1 when
  # there is none - having RECLAIMED any whose pane the backend says is gone.
  #
  # Meta PRESENCE alone is not the predicate. cmd_suite retires its own identity
  # when it FINISHES, never when it is KILLED, so a SIGKILLed pane - a host
  # reboot, a herdr restart - leaves a meta that no other actor removes
  # (ac-teardown's verifier sweeps are gated on verifier_owned_by_task, and this
  # task is owned by none). A presence-only gate would then hold the DISTILL at
  # "still in flight" for ever, waiting for a human to notice and rm a file -
  # the one shape the level trigger exists to rule out, and the only failure
  # mode of this gate that would not heal itself. A killed owner is a case this
  # codebase RECOVERS from: ac_lock_stale reclaims a lock left by a dead pid.
  #
  # THREE-STATE, never collapsed (ac-backend.sh WINDOW LIVENESS owns why). Only
  # a DEFINITE gone - the backend was REACHED and answered - reclaims. An
  # UNOBSERVABLE backend is not a death and keeps HOLDING: stamping it dead
  # would start a second suite on top of a live one, and the two runs would race
  # for the same verdict record.
  local m id b rc
  for m in "$(ac_state_dir)"/verify-suite-*.meta; do
    [ -e "$m" ] || continue
    id="$(basename "$m" .meta)"
    b="$(ac_meta_get "$m" backend 2>/dev/null || true)"
    rc=0
    ( AC_BACKEND="${b:-herdr}"; export AC_BACKEND
      backend_window_alive "$id" ) 2>/dev/null || rc=$?
    if [ "$rc" = 1 ]; then
      ac_warn "the full-suite run $id died before recording a verdict (the backend says its pane is gone) - reclaiming it, so the next checkpoint starts a fresh run"
      rm -f "$m" "$(ac_task_status "$id")" "$(ac_state_dir)/.pane-$id"
      continue
    fi
    printf '%s\n' "$id"
    return 0
  done
  return 1
}

learn_suite_launch() {
  # Start the suite as its OWN task and print its id. The captain's shape: "it is
  # a TASK, not a chief-side shell call ... it gets a herdr pane and a meta like
  # any other work" (no-invisible-task, 2026-07-21) - so it is neither a
  # subprocess of the drain nor a run inside a chief's context.
  #
  # kind=verify-suite puts it in the VERIFICATION class (ac_meta_is_verify):
  # supervised by the watcher like any other pane, but OUT of crew accounting,
  # which is what a non-crewmate meta must be or it nags WATCHER-DOWN, blocks a
  # room from closing, blocks a chief's demote and pollutes the crew survey (the
  # six consumers of that class, ac-lib.sh:766). Same shape the learning scout
  # already publishes for itself above.
  #
  # It opens in backend_window_new's ordinary crewmate group, NOT the pane-agent
  # group: that group belongs to ac-pane-agent.sh's own tab path, for AGENT
  # sessions launched by its two arms, and this run is a plain command that needs
  # the crew:<id> tab label every backend verb below addresses it by.
  local id root meta window
  root="$(learn_suite_root)"
  id="verify-suite-$(ac_now)"
  meta="$(ac_task_meta "$id")"
  backend_window_new "$id" "$root"
  window="$(backend_target "$id")"
  {
    printf 'kind=verify-suite\n'
    printf 'project=%s\nbackend=%s\nwindow=%s\ncwd=%s\nspawned_at=%s\n' \
      "$(basename "$root")" "$(ac_backend)" "$window" "$root" "$(ac_iso)"
  } >"$meta.tmp.$$"
  ac_status_append "$id" "started the full-suite gate run"
  mv "$meta.tmp.$$" "$meta"
  # The run happens IN the pane. ANY non-zero send retires the whole identity -
  # tab included, since a task meta with no run behind it holds the gate at "in
  # flight" for ever, and that is the unrecoverable direction. That covers exit 2
  # (the pane could not be READ, so the line may or may not have gone through) on
  # purpose: killing a run that might be going costs one suite, while trusting an
  # unverified send costs the loop.
  if ! backend_send_line "$id" \
    "AC_HOME=$(printf '%q' "$(ac_home)") $(printf '%q' "$root/bin/ac-learn.sh") suite $id"; then
    backend_kill_window "$id" 2>/dev/null || true
    rm -f "$meta" "$(ac_task_status "$id")"
    return 1
  fi
  printf '%s\n' "$id"
}

learn_suite_gate() {
  # learn_suite_gate <n> <every> - 0 when a GREEN full-suite verdict for THIS
  # cycle and THIS tree is on record, so the promote may proceed. Otherwise
  # print the ONE line the drain shows the chief and return non-zero.
  #
  # LEVEL-triggered like its caller: every answer comes from two file reads plus
  # a glob, so a lost wake, a restart between the run and the promote, or a
  # counter already carried past its threshold all reach the same decision.
  local n="$1" every="$2" rec gen head id
  rec="$(learn_suite_record)"
  gen="$(ac_learn_generation)"
  head="$(learn_suite_head)"
  if [ "$(ac_meta_get "$rec" generation)" = "$gen" ] \
    && [ "$(ac_meta_get "$rec" head)" = "$head" ]; then
    case "$(ac_meta_get "$rec" status)" in
      green) return 0 ;;
      red)
        # HOLD, and do NOT re-run: the same tree gives the same answer, and a
        # fresh 6-minute suite on every drain would burn the box instead of
        # fixing anything. The fix lands, HEAD moves, and the run below starts.
        printf 'learning DUE (%s/%s) HELD: the full suite is RED for this cycle (run-suite exit %s, %s) - fix it first; Learning waits, and the fix landing starts a fresh run by itself\n' \
          "$n" "$every" "$(ac_meta_get "$rec" exit)" "$rec"
        return 1 ;;
    esac
  fi
  if id="$(learn_suite_inflight)"; then
    printf 'learning DUE (%s/%s) HELD: the full-suite run %s is still in flight\n' \
      "$n" "$every" "$id"
    return 1
  fi
  if ! id="$(learn_suite_launch)"; then
    printf 'learning DUE (%s/%s) HELD: the full-suite run could not be started - the next checkpoint retries\n' \
      "$n" "$every"
    return 1
  fi
  printf 'learning DUE (%s/%s) HELD: started the full-suite run %s - only a GREEN suite releases the DISTILL (records/captain.md 2026-07-27)\n' \
    "$n" "$every" "$id"
  return 1
}

cmd_suite() {
  # `suite [<task-id>]` - the periodic full-suite run the gate above starts,
  # executing INSIDE its own pane. It records exactly one verdict for the cycle
  # and tree it began on, then retires its own identity.
  local id="${1:-}" root rec gen head runner rc status
  case "$id" in
    '' | verify-suite-*) ;;
    *) ac_die "suite takes its own task id (verify-suite-*), never another task's (got: '$id')" ;;
  esac
  root="$(learn_suite_root)"
  rec="$(learn_suite_record)"
  # Read the cycle and the tree BEFORE the run, never after: the verdict belongs
  # to the tree the suite actually ran against, so a landing mid-run leaves the
  # record stale (the next checkpoint re-runs) instead of claiming a green for a
  # tree nothing tested.
  gen="$(ac_learn_generation)"
  head="$(learn_suite_head)"
  # The bare invocation - the one place it is still correct (captain 2026-07-27,
  # TDD IS THE EVIDENCE retired it from every landing and verify path).
  # AC_LEARN_SUITE_BIN overrides the runner for tests, like AC_PANE_AGENT.
  runner="${AC_LEARN_SUITE_BIN:-$root/tests/run-suite.sh}"
  rc=0
  "$runner" || rc=$?
  if [ "$rc" -eq 0 ]; then status=green; else status=red; fi
  printf 'generation=%s\nhead=%s\nstatus=%s\nexit=%s\nat=%s\n' \
    "$gen" "$head" "$status" "$rc" "$(ac_now)" >"$rec.tmp.$$"
  mv "$rec.tmp.$$" "$rec"
  if [ -n "$id" ]; then
    rm -f "$(ac_task_meta "$id")" "$(ac_task_status "$id")" "$(ac_state_dir)/.pane-$id"
  fi
  printf 'suite %s (run-suite exit %s) recorded for generation %s at %s\n' \
    "$status" "$rc" "$gen" "$head"
  return "$rc"
}

cmd_autoroom() {
  # AUTO-CREATE the learning room when a DISTILL is owed, carrying out the
  # captain's standing order: the chief opens its own room for that work,
  # without asking, and it never consumes a room-parallel slot.
  #
  # LEVEL-triggered, never edge-triggered. The predicate is two pure file reads -
  # DUE, and no learning roomchief meta - recomputable by any process at any
  # checkpoint, which is what makes a lost wake, a restart between the crossing
  # and the spawn, or a counter already carried PAST its threshold all still
  # fire. The crossing wake (cmd_tick) only shortens the latency; correctness
  # never rests on it.
  #
  # No stamp key and no new state ACROSS checkpoints: the roomchief meta IS the
  # already-fired fact while the room lives - the same PRESENCE rule the cap
  # itself uses, so nobody writes that fact explicitly and it cannot disagree
  # with reality - and the counter reset at the end of a `run` ends the cycle.
  #
  # WITHIN one crossing there IS a lock, and the accepted architecture §9 said
  # there would not be (captain 2026-07-21 chose this over keeping "no lock").
  # §9 justified "no lock" on the premise that ac-spawn.sh's duplicate-meta
  # refusal kills the loser of a race; that premise is false. That refusal is a
  # plain [ -e ] test, and the whole backend half of a spawn - including
  # reap_orphan_window over the SHARED per-id pane handle - runs before the meta
  # exists. Two concurrent checkpoints could therefore both pass it, and the
  # second could reap a window the first had not yet made addressable: worse
  # than two rooms. That second hazard is closed at its own layer now, not here
  # - ac-spawn.sh's atomic pre-meta claim is taken before BOTH
  # reap_orphan_window call sites, so a contender blocks on the claim and never
  # reaches the reap (measured: no reap, 5/5). The TOCTOU
  # itself is pre-existing and shared by every spawn, so it is not fixed here;
  # this is the first caller that can fire from two processes with no human in
  # between, so the firing predicate is serialized HERE, narrowly, with the
  # distro's OWN lock primitive - ac_lock_acquire/ac_lock_release, which
  # publishes the owner PID and RECOVERS a lock left by a killed owner
  # (ac_lock_stale, AC_LOCK_STALE_GRACE). That transient, self-healing recovery
  # is the whole reason to reuse it rather than a hand-rolled claim: a SIGKILL
  # anywhere in the held window leaves a pid-published dir that the next
  # checkpoint reclaims, so a dead owner never PERMANENTLY disarms the loop.
  #
  # WHAT THIS LOCK IS AND IS NOT, measured - so nobody re-derives it from the
  # §9 history above and lands back on the wrong mechanism. The double promote
  # is closed by the spawn-owned ATOMIC PRE-META CLAIM in ac-spawn.sh
  # (spawn_meta_claim_acquire, state/.meta-claims/<id>), NOT by this lock: with
  # the claim landed, replacing both lock calls with `:` still yields exactly
  # one promoted, addressable room in every measured cell.
  #
  # What the lock still buys: the authoritative DUE + meta re-read below is
  # serialized, and the ORDINARY (un-killed) race posts ONE charter instead of
  # two - and `--roomchief` takes no brief, so that charter is the only thing
  # telling an auto-created chief what to do.
  #
  # What it demonstrably does NOT buy: survival of a SIGKILL of its own owner.
  # The owner delegates the promote to an ac-spawn.sh CHILD that outlives it,
  # while the dead owner's published pid makes this lock stale with NO grace
  # (ac_lock_stale reclaims a named-but-dead pid at once) - so a concurrent
  # checkpoint DOES reclaim the lock, DOES re-read DUE + still-no-meta, and DOES
  # launch a second spawn. What stops that spawn doing harm is the claim, held
  # by the still-live child, and nothing here. The captain accepted that
  # residual on 2026-07-22 rather than fix it in this function; it was closed
  # afterwards inside ac-spawn.sh, exactly where that decision pointed.
  #
  # BEST-EFFORT by contract: its host (the fleet ride-along in ac-wake-drain.sh)
  # keeps its own exit status and output whatever happens here, and a create that
  # FAILS records nothing - firing is recorded on success, never on intent - so
  # the next checkpoint simply retries.
  local n every meta lock ref outcome spawn_out held

  # Promoting a roomchief is a CREWCHIEF act (AGENTS.md section 8): a scoped
  # session - a roomchief, or a family drain - never promotes a fleet-level
  # chief, and its AC_SCOPE would leak into the spawn.
  [ -z "${AC_SCOPE:-}" ] || return 0

  # A cheap not-DUE gate BEFORE the lock, so the overwhelming majority of drains
  # (not DUE) still cost two file reads and take no lock. It is only a gate: a
  # not-DUE read never creates a room, so bailing here is always safe, and the
  # authoritative read that a CREATE rests on happens under the lock below.
  read -r n every < <(ac_learn_due)
  [ "$n" -ge "$every" ] || return 0

  # Serialize the firing predicate. timeout 0 -> the loser returns at once and
  # SILENTLY (a race between two checkpoints is normal operation, not a fault -
  # spec E2). A leaked lock from an abnormal exit is stale-recoverable, so it
  # never disarms the loop; the explicit release below keeps the common paths
  # from making the next drain wait out the grace.
  lock="$(ac_state_dir)/.learn-autoroom.lock"
  ac_lock_acquire "$lock" 0 || return 0

  # RE-READ the authoritative predicate UNDER the lock - both DUE and the meta.
  # A caller that passed the pre-lock gate on a STALE DUE (another cycle reset
  # the counter and tore its room down while this one waited) must find not-DUE
  # or the meta here and create nothing; the lock is what makes that read
  # decisive. `ref` names the standing rule the promote carries out.
  read -r n every < <(ac_learn_due)
  meta="$(ac_state_dir)/learning-chief.meta"
  ref='records/captain.md "Learning room is chief-created and CAP-EXEMPT (2026-07-21)"'
  outcome=""
  if [ "$n" -ge "$every" ] && [ ! -e "$meta" ]; then
    # THE FULL-SUITE GATE, in FRONT of the charter post: only a GREEN suite for
    # this cycle releases the DISTILL (captain 2026-07-27). Its line is captured
    # rather than printed here so it obeys the same print-after-release rule as
    # `outcome` below, and so an ac_die inside the launch (a backend that cannot
    # be reached) ends the substitution instead of this function - which would
    # otherwise walk out over the still-held lock.
    #
    # THE LEDGER SHAPE GATE runs FIRST, ahead of the (expensive) full-suite
    # gate: a wrongly-shaped records/learnings.md dooms the DISTILL regardless
    # of the suite verdict, and it is two greps versus a whole pane run.
    if ! held="$(learn_ledger_shape_gate "$n" "$every")"; then
      outcome="$held"
    elif ! held="$(learn_suite_gate "$n" "$every")"; then
      outcome="$held"
    elif ! "$(dirname "$0")/ac-room.sh" post learning crewchief "$(learn_charter "$n" "$every")" >/dev/null; then
      ac_warn "learning DUE ($n/$every) but the charter could not be posted - the next checkpoint retries"
    elif spawn_out="$("$(dirname "$0")/ac-spawn.sh" --roomchief learning --system-initiated "$ref" 2>&1)"; then
      [ -z "$spawn_out" ] || printf '%s\n' "$spawn_out"
      outcome="learning DUE ($n/$every): auto-created room \`learning\` and promoted its roomchief (system-initiated, cap-exempt)"
    else
      # A concurrent checkpoint may have won the spawn-owned meta claim and
      # completed while this caller waited. That is the expected idempotent
      # loser, not a failed promote and not a warning for the fleet drain.
      if [ ! -e "$meta" ]; then
        [ -z "$spawn_out" ] || printf '%s\n' "$spawn_out" >&2
        ac_warn "learning DUE ($n/$every) but the roomchief promote failed BEFORE its meta was written, so the next checkpoint retries (contract: ac-spawn.sh's post-meta tail warns, it never fails a promote - otherwise this line would be a lie)"
      fi
    fi
  fi

  ac_lock_release "$lock"
  # Printed AFTER the release so a closed stdout (the F5 failure mode) can never
  # skip it, and never under set -e's reach before the lock is dropped.
  [ -z "$outcome" ] || printf '%s\n' "$outcome"
}

cmd="${1:-}"
case "$cmd" in
  tick) shift; cmd_tick "$@" ;;
  autoroom) cmd_autoroom ;;
  suite) shift; cmd_suite "$@" ;;
  run) shift; cmd_run "$@" ;;
  note) shift; cmd_note "$@" ;;
  land) shift; cmd_land "$@" ;;
  promote) shift; cmd_promote "$@" ;;
  maintenance) shift; cmd_maintenance "$@" ;;
  rotate-pending) learn_rotate_pending ;;
  stale) cmd_stale ;;
  reinforce) shift; cmd_reinforce "$@" ;;
  *) ac_die "usage: ac-learn.sh tick [<landing-id>]|autoroom|suite [<task-id>]|run|note <line>...|land <candidate>|promote <name>|rotate-pending|stale|reinforce <slug> --evidence <line>|maintenance status|resume <txid>|abandon <txid>" ;;
esac
