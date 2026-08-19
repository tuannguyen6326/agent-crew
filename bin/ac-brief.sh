#!/usr/bin/env bash
# ac-brief.sh - scaffold a crewmate brief.
#
# Usage: ac-brief.sh <id> <project-name> [--scout | --stage <spec|architecture|plan|implement|design|qa>]
#                    [--mode <crew-ship|direct-pr|local-only>] [--review <yes|no>]
#                    [--captain-requested <ref>] [--reason <one line>]
#                    [--qa-required-profile <project/scope/app>]...
#
# --reason <one line> is REQUIRED whenever --captain-requested authorizes a
# time-expensive mode: the chief's justification as given to the captain in
# the ask, recorded on the brief's Escalation: line (a row pin needs none -
# the pin is the captain's own act).
# --captain-requested <ref> DECLARES the authority for the one review raise that
# is optional: direct flow + direct-pr/local-only, where AGENTS.md's
# review-obligation block allows review=yes only "when the captain requests
# independent review". --review yes there is refused without it (fail-CLOSED - a
# chief self-raising review the task does not owe is the accident this stops),
# and the non-empty ref names the captain words it carries out and is RECORDED on
# the brief's Review line. Same shape and same reason as ac-spawn.sh's
# --captain-initiated: an explicit caller declaration, not text-shape matching.
# It is refused anywhere it would authorize nothing (no --review yes); staged and
# crew-ship derive review=yes on their own and need no declaration.
#
# --qa-required-profile (repeatable) records the task's explicit required
# profile set into a FAMILY-level manifest (data/<family>/qa/manifest.json). The
# merge gate then requires a passing attestation for EVERY listed profile at the
# exact merge head. Omit it for a flat/single-profile task (no manifest, no
# matrix - the simple one-profile gate stays). Doc: Required Profile Matrix.
#
# Brief location - the one authoritative statement of the task-data layout:
# - direct tasks and plain scouts (no --stage): data/<id>/brief.md (flat).
#   EXCEPT a SCOPED chief's free-slug fan-out sub-task (AC_SCOPE=<family>,
#   id=<family>-<slug>, no stage/-rN suffix): data/<family>/tasks/<slug>/brief.md,
#   nested so a family's fan-outs, QA rounds and revisions live inside the
#   family dir the way its stages already do (and ride ac-archive.sh's
#   whole-family move for free). The scope is the family signal ON PURPOSE -
#   a prefix guess would nest an unrelated top-level id that merely extends
#   another row's name; unscoped scaffolds stay flat, and pre-existing flat
#   fan-out dirs stay readable forever (ac_task_dir's tasks/ probe).
# - staged-flow tasks (--stage <s>): data/<family>/<stage>[-rN]/brief.md,
#   nested under the family dir with the SHORT stage names
#   (spec, arch, plan, implement, design, qa). Historical review/ship dirs remain
#   readable, but this scaffold no longer creates them. The family comes from the
#   id's canonical suffix (<task>-spec, <task>-arch, <task>-plan,
#   <task>-review, <task>-ship, <task>-design, <task>-qa; revisions keep theirs: <task>-spec-r2 ->
#   data/<task>/spec-r2, and a bare <task>-rN is an implement revision ->
#   data/<task>/implement-rN). The unsuffixed implement id nests at
#   data/<id>/implement; every OTHER stage requires its canonical suffix
#   (an unsuffixed id dies - the resolver could never find that brief).
#   A suffix contradicting --stage dies. Scaffolding a second brief for one
#   id in the other layout dies (the resolver would hit the ambiguity later).
#   Family-level files (room.md, gate artifacts) stay at data/<family>/.
#   <task>-chief maps the same way, to data/<family>/chief, but a roomchief
#   never has a brief there (the room IS its brief) and the stage whitelist
#   below still refuses --stage chief - it never becomes a briefable stage.
# Reports land next to their brief: <dir>/report.md.
# Every brief is CREATED at one of those live paths, always - archiving changes
# nothing here. A family that is already CLOSED may since have been relocated
# whole to data/archive/<year>/<family>/ by bin/ac-archive.sh, whose header owns
# that layout; reads resolve across it through ac_room_file (bin/ac-lib.sh).
#
# Execution briefs (default, = --stage implement) tell one crewmate to own
# IMPLEMENT plus DELIVERY on a `crew/<id>` branch. Scout briefs (--scout) tell
# the crewmate to investigate and deliver ONLY a report.
#
# Normal production topology is direct execution, or staged design -> execution.
# The design crewmate may produce spec, architecture, and plan reports in one
# gated session. Separate code-review and ship production stages are retired.
#
# Refuses to overwrite an existing brief. The orchestrator edits the
# scaffold to fill in the actual task (and stage inputs) before spawning.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

id="${1:-}"; project="${2:-}"
shift 2 2>/dev/null || ac_die "usage: ac-brief.sh <id> <project-name> [--scout | --stage <s>]"
stage="implement"; staged=0; mode_flag=""; review_flag=""; qa_profiles=()
captain_requested=""; captain_requested_set=0; esc_reason=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scout) stage="scout"; staged=0; shift ;;
    --stage) stage="${2:-}"; staged=1; shift 2 ;;
    --mode) mode_flag="${2:-}"; shift 2 ;;
    --review) review_flag="${2:-}"; shift 2 ;;
    --captain-requested) captain_requested="${2:-}"; captain_requested_set=1; shift 2 ;;
    --reason) esc_reason="${2:-}"; shift 2 ;;
    --qa-required-profile) qa_profiles+=("${2:-}"); shift 2 ;;
    *) ac_die "unknown flag: $1" ;;
  esac
done
[ -n "$id" ] && [ -n "$project" ] || ac_die "usage: ac-brief.sh <id> <project-name> [--scout | --stage <s>]"
# A locale whose collation interleaves case (en_US.UTF-8: a,A,b,B,...,z,Z)
# makes a plain a-z range admit most uppercase letters through this glob -
# force C collation for the comparison (LC_ALL=C sort is the same idiom
# already used for `find`/`sort` elsewhere in this codebase).
(LC_ALL=C; case "$id" in *[!a-z0-9-]*) exit 1 ;; esac) || ac_die "id must be [a-z0-9-]: $id"
case "$stage" in scout|spec|architecture|plan|implement|design|qa) ;; *) ac_die "unknown stage: $stage (want spec|architecture|plan|implement|design|qa)" ;; esac
case "$review_flag" in ''|yes|no) ;; *) ac_die "invalid --review: $review_flag (want yes|no)" ;; esac
# The declaration authorizes ONE thing (the optional review raise below); with no
# --review yes there is nothing to authorize, and silently ignoring it would hide
# a caller mistake - the same reason ac-spawn.sh refuses its cap-gate flags on a
# non-roomchief spawn instead of no-op'ing them.
# --captain-requested declares the captain's word for THIS call's time-expensive
# choices. With none present there is nothing to authorize - checked after the
# escalation set is computed below (it used to couple to --review yes alone;
# the escalation gate generalized it to all four take-time modes).

data_dir="$(ac_data_dir)"

# Resolve the brief dir per the layout contract in the header. The id's
# suffix is the family marker; a suffix that contradicts --stage dies.
if [ "$staged" = 1 ]; then
  case "$stage" in
    spec) short=spec ;; architecture) short=arch ;; plan) short=plan ;;
    implement) short=implement ;;
    design) short=design ;;
    qa) short=qa ;;
  esac
  sub="$(ac_stage_dir_for_id "$id")"
  if [ -n "$sub" ]; then
    case "${sub#*/}" in
      "$short"|"$short"-r[0-9]*) task_dir="$data_dir/$sub" ;;
      *) ac_die "id suffix of '$id' maps to stage dir '${sub#*/}' but --stage $stage wants '$short'" ;;
    esac
  elif [ "$short" = implement ]; then
    task_dir="$data_dir/$id/implement"
  else
    # A suffix-bearing stage with an unsuffixed id would scaffold a brief the
    # resolver (ac_task_dir) can never find - refuse with the canonical form.
    ac_die "--stage $stage needs the canonical id form <task>-${short}[-rN] (got '$id')"
  fi
else
  task_dir="$data_dir/$id"
  # Fan-out nesting (tasks/; resolver + block comment: ac-lib.sh): a SCOPED
  # chief's free-slug sub-task (AC_SCOPE=<family>, id=<family>-<slug>, no
  # stage/-rN suffix) scaffolds at data/<family>/tasks/<slug>/. The scope is
  # the family signal ON PURPOSE: a prefix guess would nest an unrelated
  # top-level id that merely extends another row's name (dash-review vs
  # dash); an unscoped (crewchief) scaffold stays flat.
  if [ -n "${AC_SCOPE:-}" ] && [ -z "$(ac_stage_dir_for_id "$id")" ]; then
    case "$id" in
      "$AC_SCOPE"-?*) task_dir="$data_dir/$AC_SCOPE/tasks/${id#"$AC_SCOPE"-}" ;;
    esac
  fi
fi

brief="$task_dir/brief.md"
[ -e "$brief" ] && ac_die "brief already exists: $brief"

# Refuse a second brief for the same id in the OTHER layout: the resolver
# would die on that ambiguity at spawn - fail here, at scaffold time.
if [ "$staged" = 1 ]; then
  other="$data_dir/$id/brief.md"
else
  other=""
  osub="$(ac_stage_dir_for_id "$id")"
  if [ -n "$osub" ]; then
    other="$data_dir/$osub/brief.md"
  elif [ -f "$data_dir/$id/implement/brief.md" ]; then
    other="$data_dir/$id/implement/brief.md"
  fi
  # the tasks/-nested twin is the same ambiguity, in BOTH directions: a
  # nested scaffold refuses on an existing flat brief, and a flat scaffold
  # refuses on an existing nested one (longest-prefix probe, resolver-mirrored).
  if [ -z "$other" ]; then
    if [ "$task_dir" != "$data_dir/$id" ]; then
      other="$data_dir/$id/brief.md"
    else
      twin_base="$id"
      while [ "${twin_base%-*}" != "$twin_base" ]; do
        twin_base="${twin_base%-*}"
        if [ -f "$data_dir/$twin_base/tasks/${id#"$twin_base"-}/brief.md" ]; then
          other="$data_dir/$twin_base/tasks/${id#"$twin_base"-}/brief.md"
          break
        fi
      done
    fi
  fi
fi
if [ -n "$other" ] && [ -f "$other" ]; then
  ac_die "a brief for '$id' already exists in the other layout: $other"
fi

# MODE IS PER-TASK ONLY (mode is never fixed on the project registry) - the registry rung and its silent crew-ship fallback are
# GONE. Resolution: the row's pinned token wins (the captain's recorded word);
# else the chief's explicit --mode (its own triage - cheap modes are free, the
# escalation gate below prices crew-ship); else REFUSE - an unspecified mode
# was exactly how the old default spent the heaviest pipeline without anyone
# choosing it. Scouts deliver only report.md, so they resolve no mode at all.
mode=""
if [ "$stage" != scout ]; then
  _early_pin_mode=""
  if [ -f "$(ac_records_dir)/backlog.md" ]; then
    _early_pin_mode="$(ac_row_contract_for_id "$id" "$(ac_records_dir)/backlog.md" \
      | tr " " "\n" | sed -n "s/^mode://p")"
  fi
  if [ -n "$mode_flag" ]; then
    case "$mode_flag" in
      crew-ship|direct-pr|local-only) ;; 
      *) ac_die "invalid --mode: $mode_flag (want crew-ship|direct-pr|local-only)" ;;
    esac
    if [ -n "$_early_pin_mode" ] && [ "$_early_pin_mode" != "$mode_flag" ]; then
      ac_die "--mode $mode_flag contradicts the row's pinned mode:$_early_pin_mode - the pin is the captain's recorded word; change the row (a captain act) or drop the flag (nothing scaffolded)"
    fi
    mode="$mode_flag"
  elif [ -n "$_early_pin_mode" ]; then
    mode="$_early_pin_mode"
  else
    ac_die "mode unspecified for '$id': pass --mode <crew-ship|direct-pr|local-only> (your triage - the time-expensive crew-ship will still ask the captain), or pin it on the backlog row's contract group. There is no registry default any more (captain order: mode is per-task)"
  fi
fi

# Review is an intake obligation, not a stage or delivery profile. Staged work
# and crew-ship always require it; direct direct-pr/local-only may opt in.
# EPIC EXCEPTION (captain ruling 2026-08-19: review and
# QA run per EPIC, not per story): a story of a BRANCH-RECORDED epic integrates on the epic branch,
# not production, so its per-story independent review defaults to NO - the
# epic gate owns the round over the integrated diff. Staged stories keep
# their design-stage gates; crew-ship stories KEEP their pipeline round for
# now (the --target makes it story-sized; the F4 skip amendment belongs to
# the epic-gate slice). Raising review back on a story stays the captain's
# word (ruling: ask-captain unchanged) - the pin/--captain-requested path
# below is unchanged.
epic_eb_entry=""
epic_eb_branch=""
if epic_eb_entry="$(ac_epic_base_for "$id" "$project" 2>/dev/null)"; then
  epic_eb_branch="${epic_eb_entry%% *}"
fi
pr_base_phrase="the target branch"
[ -z "$epic_eb_branch" ] || pr_base_phrase="the epic integration branch \`$epic_eb_branch\`"
if [ "$staged" = 1 ] && [ -n "$epic_eb_branch" ]; then
  review="${review_flag:-no}"
  if [ "$review" = yes ]; then
    review_line="yes (captain word required - see the raise guard below)"
  else
    review_line="no (epic gate owns the review round - captain ruling 2026-08-19)"
  fi
elif [ "$staged" = 1 ]; then
  [ "$review_flag" != no ] || ac_die "staged flow requires review=yes; --review no is not allowed"
  review=yes
elif [ "$mode" = crew-ship ]; then
  [ "$review_flag" != no ] || ac_die "crew-ship requires review=yes; --review no is not allowed"
  review=yes
else
  # Here review=yes is OPTIONAL, and AGENTS.md's review-obligation block gives it
  # exactly ONE route: "optional yes when the captain requests independent
  # review". The case above validated the VALUE (yes|no); nothing validated the
  # AUTHORITY, so a chief could self-raise it - two roomchiefs did on 2026-07-30
  # and paid 3 and 4 review rounds on families that owed none, both self-reported
  # afterwards, nothing refused them at the time. The one legitimate caller now
  # DECLARES itself and NAMES the captain words it carries out: ac-spawn.sh's
  # --captain-initiated shape, for the same kind of claim and for the same reason
  # ac-room.sh's cmd_post takes a caller declaration instead of matching
  # text-shape - this is an ACCIDENT guard, not a security boundary, so a chief
  # that means to lie still can. FAIL DIRECTION: the raise refuses fail-CLOSED
  # (a warning refuses nothing, and nothing refused either real self-raise), but
  # the captain-requested case stays reachable in ONE flag - a hard refusal with
  # no declared path would block the very review AGENTS.md allows, which would be
  # worse than the gap. The ref is RECORDED on the brief's Review line: the two
  # self-raises were caught only because their chiefs volunteered it.
  if [ "$review_flag" = yes ]; then
    # Row pin first: it is the durable pre-consent. The declared flag stays the
    # per-call authority, its ref recorded exactly as before.
    _pin_rev="$(
      [ -f "$(ac_records_dir)/backlog.md" ] && awk -v want="$id" "$AC_DONELINE_AWK"'
        /^- \[[ x]\] / { ac_doneline($0, o); if (o["id"] == want) { print o["contract"]; exit } }
      ' "$(ac_records_dir)/backlog.md" | tr " " "\n" | sed -n "s/^rev://p" || true
    )"
    if [ "$_pin_rev" = yes ]; then
      review_line="yes (pinned on the backlog row)"
    else
      [ "$captain_requested_set" = 1 ] \
        || ac_die "review=yes on direct + $mode is the CAPTAIN's call, not a chief's (AGENTS.md: 'no by default, optional yes when the captain requests independent review'); if they asked for it, PIN rev:yes on the backlog row's contract group or re-run with --captain-requested '<their words, or the order ref>' - if they did not, drop --review yes"
      [ -n "$captain_requested" ] \
        || ac_die "--captain-requested needs a non-empty ref: name the captain words or order this review carries out"
      review_line="yes (captain-requested: $captain_requested)"
    fi
  fi
  review="${review_flag:-no}"
fi
review_line="${review_line:-$review}"

# --- THE ESCALATION GATE (delivery-contract-on-the-row) -----------------------
# The captain's rule, verbatim from the order: "confirm với captain khi sử dụng
# các mode take time (staged, crew-ship, qa, code-reviewer)" - and the ask must
# carry the REASON ("đưa ra lý do khi chọn các mode take time"). The chief keeps
# auto-triage; SPENDING is what asks. Two authorities satisfy it, either one:
#   - the ledger row PINS the token ([flow:staged], [mode:crew-ship], [rev:yes],
#     [qa:yes] in the row's contract group) - pre-consent, never re-asked;
#   - --captain-requested '<the captain's words, or the order ref>' declares it
#     for this call (the existing review-raise guard, generalized).
# Same accident-guard grade as the review raise it grew from: a chief that
# means to lie still can - this catches the drift, not the liar.
# Scouts are exempt: a scout delivers only report.md - nothing here to spend.
row_contract=""
backlog_file="$(ac_records_dir)/backlog.md"
if [ -f "$backlog_file" ]; then
  row_contract="$(ac_row_contract_for_id "$id" "$backlog_file")"
fi
pin_flow=""; pin_mode=""; pin_rev=""; pin_qa=""
for _tok in $row_contract; do
  case "$_tok" in
    flow:*) pin_flow="${_tok#flow:}" ;;
    mode:*) pin_mode="${_tok#mode:}" ;;
    rev:*)  pin_rev="${_tok#rev:}" ;;
    qa:*)   pin_qa="${_tok#qa:}" ;;
  esac
done
unauthorized=""
wants_any=0
if [ "$stage" != scout ]; then
  if [ "$staged" = 1 ]; then
    wants_any=1
    [ "$pin_flow" = staged ] || [ "$captain_requested_set" = 1 ] \
      || unauthorized="$unauthorized flow:staged"
  fi
  if [ "$mode" = crew-ship ]; then
    wants_any=1
    [ "$pin_mode" = crew-ship ] || [ "$captain_requested_set" = 1 ] \
      || unauthorized="$unauthorized mode:crew-ship"
  fi
  if [ "${#qa_profiles[@]}" -gt 0 ]; then
    wants_any=1
    [ "$pin_qa" = yes ] || [ "$captain_requested_set" = 1 ] \
      || unauthorized="$unauthorized qa:yes"
  fi
  # review=yes counts as spent whenever it is DISCRETIONARY (the optional
  # raise); a review mandated by staged/crew-ship rides THOSE tokens' own
  # authority rather than asking twice for one decision.
  if [ "$review" = yes ] && [ "$staged" != 1 ] && [ "$mode" != crew-ship ]; then
    wants_any=1
    # already authorized above by the raise guard (captain-requested) - a row
    # pin is the second, durable authority the raise guard now also accepts.
  fi
fi
if [ -n "$unauthorized" ]; then
  ac_die "time-expensive mode(s) not confirmed:$unauthorized - the captain's rule: confirm BEFORE using staged/crew-ship/qa/independent review. Put ONE ask to the captain carrying (1) the REASON each is warranted for THIS task (the signal: financial surface, behavioral surface, multi-file risk, ...), (2) the options, (3) your lean - then either PIN the answer on the backlog row's contract group (e.g. [src:cap flow:staged mode:crew-ship rev:yes qa:no]) so it is never re-asked, or re-run with --captain-requested '<the captain's words, or the order ref>' (nothing scaffolded)"
fi
[ "$captain_requested_set" = 0 ] || [ "$wants_any" = 1 ] || [ "$review_flag" = yes ] \
  || ac_die "--captain-requested with nothing to authorize: this call uses no time-expensive mode (staged/crew-ship/qa/review) - drop the flag"
# The declared path must carry the chief's STATED REASON - the justification
# given to the captain in the ask (captain's rule: 'đưa ra lý do khi chọn các
# mode take time'). Required WITH the declaration, recorded on the brief, so
# the why survives the conversation it was asked in. A row pin needs none:
# no ask happened - the pin is the captain's own act, and the row is its record.
if [ "$captain_requested_set" = 1 ] && [ "$wants_any" = 1 ]; then
  [ -n "$esc_reason" ] \
    || ac_die "--captain-requested authorizes time-expensive mode(s) but carries no --reason '<the justification you gave the captain>': the reason must ride the record, not just the ask (nothing scaffolded)"
  case "$esc_reason" in
    *$'\n'*|*$'\r'*) ac_die "--reason must be a single line" ;;
  esac
fi
[ -n "$esc_reason" ] && [ "$captain_requested_set" = 0 ] \
  && ac_die "--reason without --captain-requested documents an ask that never happened: a pinned row needs no reason (the pin is the captain's own act) and the cheap path spends nothing - drop the flag"
# What the brief records for a declared escalation (empty when pinned/cheap).
escalation_line=""
if [ "$captain_requested_set" = 1 ] && [ "$wants_any" = 1 ]; then
  _spent=""
  [ "$staged" = 1 ] && _spent="$_spent flow:staged"
  [ "$mode" = crew-ship ] && _spent="$_spent mode:crew-ship"
  [ "${#qa_profiles[@]}" -gt 0 ] && _spent="$_spent qa:yes"
  [ "$review" = yes ] && _spent="$_spent rev:yes"
  escalation_line="Escalation:${_spent} - captain-requested: $captain_requested - reason: $esc_reason"
fi

mkdir -p "$task_dir"
# Computed AFTER the mkdir above, not before: ac_family_of_id trusts a plain
# stage suffix only once its nested dir exists on disk
# (family-of-id-suffix-collision), and this is the family/branch derivation's
# OWN first-ever call for a brand-new staged id - calling it any earlier would
# see the not-yet-created dir and print the wrong crew branch.
crew_branch="$(ac_crew_branch "$id")"
captain="$(ac_captain)"

signals() {
  # signals [<done-line suffix>] - the completion block EVERY brief carries, so
  # the two channels can never drift apart in one template. The printed marker
  # is the pane channel the watcher polls as the BACKUP; the push is what wakes
  # the chief now (contract: bin/ac-done.sh). Its path is ABSOLUTE and baked
  # here: the crewmate works in the PROJECT's worktree, which need not carry
  # this checkout's bin/ - the path travels in the brief, the fleet channel it
  # needs (AC_FLEET_STATE) rides its launch line.
  cat <<EOF
When done, print exactly one line starting with \`done: <one-line summary>\`${1:-}.
If blocked, print \`blocked: <reason>\`. If you need a decision, print \`needs-decision: <question>\`.
The MOMENT you print any of those lines, RUN the push as well - a printed line
alone leaves your chief waiting for the watcher's next poll:
\`$(ac_root)/bin/ac-done.sh $id '<the exact line you printed>'\`
EOF
}

primary_accident() {
  # primary_accident - the accident half of the execution seed's primary-
  # checkout guidance (bin/ac-brief.sh implement stage), owed to scout-kind
  # seeds too: "forbidden to change code" says nothing about an ACCIDENTAL
  # write to the primary (a stray tee, an editor save). A scout has no crew
  # branch and no commit step, so it gets only this half, not the whole block.
  cat <<EOF
Edited the primary by mistake? STOP and REPORT it - do NOT clean it up.
\`git checkout --\`, \`git restore\` and \`git reset --hard\` there silently DESTROY
uncommitted captain work at that path, and no lease needs the primary tidy - it
resets from a REF. Leave the edit where it is; the captain owns that tree.
EOF
}

knowledge() {
  # knowledge - the REPO-KNOWLEDGE block every brief carries (contract:
  # bin/ac-know.sh). It bakes RUNNABLE COMMAND LINES, not a bare path: the
  # crewmate's pane has no AC_HOME, so its own ac-know.sh would resolve a
  # DIFFERENT record and every entry it wrote would land in the wrong home.
  # A bare path is ornament; a command line carrying the wrong --home is
  # WORSE than ornament, because it writes. Same discipline the qa store
  # bake already imposes ("pass this VERBATIM"), and the absolute bin/ prefix
  # signals() already bakes - the crewmate's worktree need not carry this
  # checkout's bin/.
  # When the clone does not resolve, NOTHING is named: a brief that names a
  # wrong target is worse than one that names none (the qa-store precedent
  # below).
  # `ask:` leads, and the order is the point (distribution durability): the
  # chief's own intake recall is a DISCIPLINE link, so the worker gets the
  # SAME pull verb baked - a hit the chief forgot to cite into this brief is
  # still one question away from the crewmate, ranked and budgeted, instead
  # of buried in a full-record cat. The cite line closes the heat loop from
  # the worker side for the same reason.
  # Deliberately absent: the scope-map verbs. The closed list governing qa
  # profile resolution is chief-tier, and a brief that named its install verb
  # would re-open through documentation what the code closed.
  local dir rec
  dir="$(ac_project_dir "$project" 2>/dev/null)" || return 0
  rec="$(ac_knowledge_file "$dir" 2>/dev/null)" || return 0
  cat <<EOF

## Repo knowledge

Facts earlier families verified about this codebase - and the fleet's L2 scene
store above them. PULL by your QUESTION before your first change, and again
whenever you are about to re-derive something a prior family may have proved:
a stale fact stated confidently is worse than no fact, and re-deriving a
proved one burns your window. Run these VERBATIM - they carry the fleet home
your pane cannot resolve:

    ask:      $(ac_root)/bin/ac-know.sh recall '<your question - subject/mechanism/terms>' --home $(ac_home) --repo "\$(git rev-parse --show-toplevel)"
    cite:     the ask's output hands you the exact cite/open command per hit -
              run it for the ONE you actually rely on (heat is the fleet's
              re-verify/retire priority; an uncited read is an invisible read)
    full:     cat $rec   (the whole record, unranked and unbudgeted - only when
              the ask's hits do not settle it)
    re-check: $(ac_root)/bin/ac-know.sh verify --home $(ac_home) --repo "\$(git rev-parse --show-toplevel)"
    record:   $(ac_root)/bin/ac-know.sh add --home $(ac_home) --repo "\$(git rev-parse --show-toplevel)" --family $(ac_family_of_id "$id") \\
                --src-file <path>:<line> --fact '<what you learned>'

\`--repo "\$(git rev-parse --show-toplevel)"\` binds YOUR OWN tree's ROOT,
resolved by your shell when you run the command - never the primary clone,
and not your cwd's subdirectory either.
EOF
}

design_contract() {
  # design_contract - the report contract every design-kind brief carries
  # (spec/architecture/plan/design). The AUTHORITATIVE contract is
  # docs/staged-design-flow-spec.md in this distro; the brief bakes its
  # ABSOLUTE path (the crewmate's project worktree does not carry this
  # checkout, the same reason signals() bakes bin/ac-done.sh). The operative
  # per-report rules ride here verbatim so a valid report needs no second
  # read to know its shape; the full per-stage required content and exit
  # criteria stay in the spec doc, never restated here.
  cat <<EOF

## Report contract

Authoritative contract - per-stage required content and exit criteria
(read it before your first report):
$(ac_root)/docs/staged-design-flow-spec.md
Every report carries these sections: Inputs, Summary, Evidence,
Needs Decisions, Risks, Self-Review. A required section with nothing
material to report records one line, \`n/a: <reason>\` - complete, not
missing.
Trace IDs are stage-owned and family-stable: \`R#\` requirements, \`AC#\`
acceptance criteria, \`D#\` architecture decisions, \`T#\` plan tasks.
Append-only across revisions: never renumber or reuse an ID; a removed
item's ID is retired with a one-line note, and no active content references
a retired ID. A revision lists every added, changed, and retired Trace ID.
Reference each accepted prior report by absolute path plus the
\`report_sha256\` your chief's approval carries (the room's \`GATE-ROUTING:\`
receipt); reference its content by Trace ID - never restate it.
Before announcing a report ready, run the inline self-review yourself (no
extra agent, no pane), all nine checks: placeholder scan, consistency
with accepted prior reports, scope, ambiguity, coverage, evidence,
retired-ID check, the architecture Diagram Rule (an accurate diagram when
a trigger applies, else a reasoned \`n/a\`), and the plan TDD check (a
genuine expected RED failure and its verification per behavior-changing
task; each permitted exception carries replacement evidence). The
Self-Review section lists only failures found and fixed, then \`pass\`. A
failure you cannot fix alone never records \`pass\`: an unresolved product
or policy choice becomes \`needs-decision:\`; a contradiction with an
accepted upstream report is announced so the chief returns work to the
earliest affected stage.
EOF
}

standing_rules() {
  # standing_rules - the FLEET STANDING RULES block every brief carries
  # (issue #3 proposal 1): a captain STANDING rule in records/captain.md had
  # NO mechanical path into a crewmate brief - only a chief remembering to
  # hand-copy it, which had already failed once in this fleet (the very brief
  # that ordered this fix hand-copied its own Standing rules section).
  # SELECTS by the rule-BLOCK convention ac-curate.sh's _captain_plan already
  # established (a `- ` line plus its indented continuations) and the
  # existing STANDING marker token ac-domain.sh's `STANDING (domain:<name>): `
  # grammar already uses - not a new shape, and not a wholesale copy of a
  # 500+-line, largely-historical-provenance file.
  # EXCLUDES `STANDING (domain:<name>):` blocks: those already reach the
  # domainchief mechanically, read directly from this SAME file at intake,
  # BEFORE this brief is ever scaffolded (bin/ac-spawn.sh:1102) - and
  # ac-brief.sh cannot know the domain at compose time anyway (AC_DOMAIN is
  # resolved and exported by ac-spawn.sh, which runs AFTER this script; this
  # script's signature takes <id> <project>, no domain argument).
  # FAILS LOUD, never silent, when the source cannot be read - the sibling
  # knowledge() no-ops silently on a STRUCTURAL absence (no clone resolves);
  # an unreadable captain.md is not structural, it is the defect this task
  # fixes with a new cause, so the brief SAYS SO (ac-gate.sh:666-668's
  # "(no standing preferences file on record)" is the precedent this reuses).
  # A line that CARRIES the STANDING token but never becomes part of a
  # parsed `- ` block (roomchief-verify finding on this family, citing
  # records/captain.md:63 - a STANDING rule authored as plain paragraph text
  # under a `## heading`, never a `- ` bullet) must not vanish either: WARN,
  # do not WIDEN the selector to swallow it - bin/ac-domain.sh:150 is the
  # named trap (prose merely MENTIONING the token read as a real entry).
  # bin/ac-deputy.sh:31's shape is the precedent this reuses: an invalid
  # entry prints its VERBATIM source plus one reason, so the next malformed
  # line is visible instead of silently dropped.
  local src blocks warn warnfile
  src="$(ac_records_dir)/captain.md"
  cat <<EOF

## Fleet standing rules

Every STANDING-marked rule block in $src (fleet-wide only - a domain-scoped
\`STANDING (domain:<name>):\` block is delivered to that domain's roomchief
directly at intake, not through this brief). Law here like anything else in
this brief.

EOF
  if [ ! -r "$src" ]; then
    printf '(no standing preferences file on record)\n'
    return 0
  fi
  warnfile="$(mktemp "${TMPDIR:-/tmp}/ac-brief-standing-warn.XXXXXX")"
  blocks="$(awk -v warnfile="$warnfile" '
    function flush() {
      if (bstart == 0) return
      if (blocktext ~ /(^|[^A-Za-z-])STANDING([^A-Za-z-]|$)/ && blocktext !~ /STANDING \(domain:/) print blocktext "\n"
      bstart = 0; blocktext = ""
    }
    /^- / { flush(); bstart = NR; blocktext = $0; next }
    bstart > 0 && /^[ \t]/ { blocktext = blocktext "\n" $0; next }
    {
      flush()
      if ($0 ~ /(^|[^A-Za-z-])STANDING([^A-Za-z-]|$)/) printf "%d: %s\n", NR, $0 > warnfile
    }
    END { flush() }
  ' "$src")"
  warn="$(cat "$warnfile" 2>/dev/null)"
  rm -f "$warnfile"
  if [ -n "$blocks" ]; then
    printf '%s\n' "$blocks"
  else
    printf '(no STANDING-marked entries found in %s)\n' "$src"
  fi
  if [ -n "$warn" ]; then
    printf '\nUNPARSED - mentions STANDING but is not a `- ` bulleted block, so it is NOT selected above (this channel invents no grammar for it; fix the source line, not this channel) - %s:\n%s\n' "$src" "$warn"
  fi
}

case "$stage" in
  scout)
    cat >"$brief" <<EOF
# Scout brief: $id

Project: $project
Kind: scout (report only - NEVER open a PR or push)
Captain: $captain

## Task

<!-- Orchestrator: describe the investigation here. -->

## Deliverable

Write your findings to $task_dir/report.md.
$(primary_accident)
$(knowledge)
$(standing_rules)

$(signals)
EOF
    ;;
  spec)
    cat >"$brief" <<EOF
# Spec brief: $id

Project: $project
Kind: scout stage: spec (report only - NEVER open a PR, push, or change code)${escalation_line:+
$escalation_line}
Captain: $captain

## Task

<!-- Orchestrator: paste the captain's order verbatim here. -->

## Deliverable

Turn the order into a spec at $task_dir/report.md:
problem statement, requirements, ACCEPTANCE CRITERIA the captain can check,
edge cases, and explicit out-of-scope. Read the project code as needed to
ground every requirement in reality. Ambiguities you cannot resolve from
the code are \`needs-decision:\` questions - never invent product behavior.
$(design_contract)
$(primary_accident)
$(knowledge)
$(standing_rules)

$(signals)
EOF
    ;;
  architecture)
    cat >"$brief" <<EOF
# Architecture brief: $id

Project: $project
Kind: scout stage: architecture (report only - NEVER open a PR, push, or change code)${escalation_line:+
$escalation_line}
Captain: $captain

## Inputs

<!-- Orchestrator: link earlier stage reports by ABSOLUTE path, e.g.
     $data_dir/<task>/spec/report.md - otherwise paste the order verbatim.
     The crewmate must read every linked input before starting. -->

## Deliverable

Design the change at system level in $task_dir/report.md:
components/modules touched or introduced, their interfaces and contracts,
data flow, and how it fits the EXISTING architecture (read the real code -
name real modules, not imagined ones). For every affected component, verify
that readers can understand the component without reading its internals and
that its internals can change without breaking consumers that honor that contract.
Present the viable alternatives
with tradeoffs and state which one you recommend and why; a design with no
rejected alternative was not designed. Cover the non-functional angles that
apply (compatibility, migration, performance, security). Include the
smallest useful diagram when the Diagram Rule applies, else a reasoned
\`n/a\`. Decisions that
belong to the captain are \`needs-decision:\` questions.
$(design_contract)
$(primary_accident)
$(knowledge)
$(standing_rules)

$(signals)
EOF
    ;;
  plan)
    cat >"$brief" <<EOF
# Plan brief: $id

Project: $project
Kind: scout stage: plan (report only - NEVER open a PR, push, or change code)${escalation_line:+
$escalation_line}
Captain: $captain

## Inputs

<!-- Orchestrator: link the spec and architecture reports by ABSOLUTE path
     when they exist, e.g. $data_dir/<task>/spec/report.md,
     $data_dir/<task>/arch/report.md - otherwise paste the order verbatim.
     The crewmate must read every linked input before starting. -->

## Deliverable

Write the implementation plan to $task_dir/report.md:
ordered steps, exact files to touch, test strategy, a
RED -> GREEN -> VERIFY -> REFACTOR TDD sequence per behavior-changing
task, risks and their mitigations, and what would make you abort. Ground
it by reading the real code; a plan that names wrong files is a failed
plan.
$(design_contract)
$(primary_accident)
$(knowledge)
$(standing_rules)

$(signals)
EOF
    ;;
  design)
    # Family = first segment of the resolved subpath (design[-rN] ids).
    fam="${sub%%/*}"
    cat >"$brief" <<EOF
# Design brief: $id

Project: $project
Kind: scout stage: design - the admitted spec/architecture/plan stages in ONE session, gated per report (report only - NEVER change code, push, or open a PR)
Mode: $mode
Review: $review_line${escalation_line:+
$escalation_line}
Captain: $captain

## Inputs

<!-- Orchestrator: the captain's order verbatim, plus scouted pointers.
     Record one STAGE-ADMISSION: receipt per stage (admit|skip + grounds)
     in the family room BEFORE this spawn, then cross out the skipped
     sub-stages below; the three-tier pre-implement gate always applies to
     the LAST report produced. -->

## Contract - up to three reports, one session, a GATE between each

Work the needed sub-stages IN ORDER; one report per sub-stage:
1. spec -> $data_dir/$fam/spec/report.md: problem, requirements,
   ACCEPTANCE CRITERIA the captain can check (verbatim, testable),
   edge cases, assumptions, out-of-scope.
2. architecture -> $data_dir/$fam/arch/report.md: components, interfaces,
   the viable alternatives WITH tradeoffs, why the chosen one fits the
   existing system, and the smallest useful diagram when the Diagram Rule
   applies (else a reasoned n/a). For every affected component, verify that
   readers can understand the component without reading its internals and
   that its internals can change without breaking consumers that honor that contract.
3. plan -> $data_dir/$fam/plan/report.md: ordered steps, exact files,
   test strategy per step, and a RED -> GREEN -> VERIFY -> REFACTOR TDD
   sequence per behavior-changing task.

After EACH report print \`done: <sub-stage> report ready (awaiting gate)\`
and STOP - the orchestrator reviews EVERY report before releasing the
next sub-stage; do not start it until they reply with approval or
feedback. Apply feedback as a revision of the SAME report in this
session, then announce it again the same way.
Ground every claim in the real code (cite file:line). Anything you cannot
resolve from the code is a \`needs-decision: <question>\` - never invent
product behavior.
$(design_contract)
$(primary_accident)
$(knowledge)
$(standing_rules)

$(signals)
EOF
    ;;
  implement)
    fam="$(ac_family_of_id "$id")"
    if [ "$mode" = crew-ship ]; then
      review_block="Review is required and is fulfilled exactly once by the \`ac-ship\` review step inside the \`crew-ship\` engine. Do not invoke \`ac-verify codereview\` separately."
      delivery_mode="- Mode crew-ship: run the \`crew-ship\` skill. Its \`ac-ship\` engine owns the guarded 8-step delivery pipeline (intent, rebase, review, test, document, lint, push, pr). Hand over only after checks pass and include the PR URL."
      [ -z "$epic_eb_branch" ] \
        || delivery_mode="$delivery_mode
- EPIC TARGET: start the engine with \`--target $epic_eb_branch\` - this story integrates on the epic branch, and the pipeline's review/base/push/PR all follow that target."
      signals_suffix=" (include the PR URL)"
    elif [ "$review" = yes ]; then
      review_block="Review is required. After delivery preparation and a clean implementation commit, invoke the canonical independent verifier before test/document/lint. Use the exact current ref and target base with this command shape (set \`TARGET_REF\` first):
\`$(ac_root)/bin/ac-verify.sh codereview --repo \"\$PWD\" --ref HEAD --family $fam --caller \"\$AC_CREW_ID\" --base \"\$TARGET_REF\" --intent $brief --output $task_dir/verification/review.json\`"
      if [ "$mode" = direct-pr ]; then
        delivery_mode="- Mode direct-pr: after the ordered review/check/doc loop below, push \`$crew_branch\` and open a PR against $pr_base_phrase. The PR body covers intent, changes, and verification evidence."
        signals_suffix=" (include the PR URL)"
      else
        delivery_mode="- Mode local-only: after the ordered review/check/doc loop below, leave \`$crew_branch\` clean and fully committed. Never push or open a PR."
        signals_suffix=""
      fi
    else
      review_block="Review is not required for this direct task. Skip independent code review unless the captain changes the intake obligation to \`review=yes\`."
      if [ "$mode" = direct-pr ]; then
        delivery_mode="- Mode direct-pr: after the ordered check/doc loop below, push \`$crew_branch\` and open a PR against $pr_base_phrase. The PR body covers intent, changes, and verification evidence."
        signals_suffix=" (include the PR URL)"
      else
        delivery_mode="- Mode local-only: after the ordered check/doc loop below, leave \`$crew_branch\` clean and fully committed. Never push or open a PR."
        signals_suffix=""
      fi
    fi
    cat >"$brief" <<EOF
# Crew brief: $id

Project: $project
Kind: execution (IMPLEMENT + DELIVERY)
Mode: $mode
Review: $review_line${escalation_line:+
$escalation_line}
Captain: $captain

## Inputs

<!-- Orchestrator: link accepted stage reports by ABSOLUTE path, e.g.
     $data_dir/<task>/spec/report.md, $data_dir/<task>/arch/report.md,
     $data_dir/<task>/plan/report.md. The crewmate must READ every linked
     input before its first commit and follow the accepted spec/plan.
     Delete this section for single-stage tasks. -->

## Task

<!-- Orchestrator: describe the change here. -->

## Working rules

You are in a disposable git worktree at detached HEAD on the clean default branch.
Create or continue branch \`$crew_branch\` before your first commit and commit all work there.
Never touch the primary checkout or other worktrees.
Concretely: \`git rev-parse --show-toplevel\` prints YOUR worktree - commit only
there, on \`$crew_branch\`. Its \`git-common-dir\` parent is the PRIMARY checkout,
shared by every worktree; never commit there (a pre-commit guard refuses it).
Edited the primary by mistake? STOP and REPORT it - do NOT clean it up.
\`git checkout --\`, \`git restore\` and \`git reset --hard\` there silently DESTROY
uncommitted captain work at that path, and no lease needs the primary tidy - it
resets from a REF. Leave the edit where it is; the captain owns that tree.
IMPLEMENT with TDD: add a failing regression test, make the smallest code change,
run focused checks, then use exactly one implementer self-review path.
Prefer an applicable code-review plugin, with project-provided plugins first, and
give the selected plugin the full current diff.
Only when no applicable plugin exists, manually self-review the full diff.
Do not run a second manual full-diff review after the plugin.
Repair its findings, rerun affected focused checks, then commit.
The implementer owns repairs from
verification; the verifier only reports findings and may suggest a fix.

## Delivery

$delivery_mode

Follow this order:
1. Prepare delivery inputs and identify the exact target base.
2. Independent review when \`Review: yes\`.
   $review_block
   A \`fix\` finding returns here: repair, test, repeat the same plugin-first
   self-review rule, commit, then run a fresh verifier: round 1 reviews the full
   base-to-ref diff; later rounds verify the immediately previous round's open
   findings and review \`previous reviewed_ref..current ref\`. An \`ask-user\` finding holds
   delivery: print \`needs-decision:\` so chief/roomchief relays it to the captain;
   continue only after the recorded decision. Advisory \`suggested_fix\` text is
   input to the implementer, never permission for the verifier to edit.
3. Run tests required by task/project policy; record an explicit skip otherwise.
   VERIFY GATE = changed-file tests + do-not-break tests ONLY - that is
   your per-change check; NEVER run \`tests/run-suite.sh\` (the full suite)
   here, it is not a landing gate and runs only as its own periodic task
   immediately before each Learning DISTILL run.
4. Run the documentation pass and keep relevant docs synchronized.
5. Run lint required by task/project policy; record an explicit skip otherwise.
6. Push only for \`crew-ship\` or \`direct-pr\`.
7. Open the PR for \`crew-ship\`/\`direct-pr\`. For \`local-only\`, who lands \`$crew_branch\` from here is this fleet's own standing rule, not distro law - see \`## Fleet standing rules\` below; absent one, leave it as a handover for the chief.

Optional QA runs after delivery through \`ac-qa.sh agent\`; a QA defect returns
to IMPLEMENT and invalidates delivery/review evidence affected by the fix.
The FLEET HOME is baked below and passed VERBATIM: your pane carries no
AC_HOME, and every durable source the QA profile freezes descends from that
ONE value, with no per-source flag to supply any of them separately. The qa
charter bakes \`--home\` for its own \`start\` line, but \`agent\` never reads that
charter, so without this line the call can only answer
\`QA_PROFILE_STATUS=needs-profile\`. Fill the placeholders; copy the flag as-is:
\`$(ac_root)/bin/ac-qa.sh agent --home $(ac_home) --target <delivered-sha> --task $fam-qa --brief <qa-charter> --evidence <dir> [--scope <name> --app <name>] [--ship-run <ship run id>] [--qa-rule <number|default>]\`

$(knowledge)
$(standing_rules)
$(signals "$signals_suffix")
EOF
    ;;
  qa)
    # Family = first segment of the resolved subpath (qa[-rN] ids).
    fam="${sub%%/*}"
    # KNOWLEDGE STORE path, baked by the ONE deriver. We run in the crewchief/
    # roomchief context that HAS AC_HOME, so `ac-qa.sh store-dir` in the project
    # clone answers rung 2 - the durable $AC_HOME/data/qa-store/<scope> (contract:
    # bin/ac-qa.sh KNOWLEDGE STORE, which owns the ladder). The qa pane has no
    # AC_HOME and could only refuse, so the path must be NAMED here for the agent
    # to pass back as --store. NEVER re-derive by string interpolation: a
    # $data_dir/qa-store/$project would be a SECOND deriver that skips repo_scope's
    # sanitize_compose lowercasing and diverges the instant a project name carries
    # an uppercase letter - the very class of defect aa55baf closed one layer down.
    # No clone, or store-dir refuses (no qa toolchain, unresolvable scope): name
    # NO path. A brief that names a WRONG store is worse than one that names none;
    # the crew-qa skill treats a store-less run as valid and merely expensive.
    # The FLEET HOME, baked for the same reason the store is: the qa pane has
    # no AC_HOME, and --home is the SINGLE resolution from which both the
    # project config and the scope map descend (contract: bin/ac-qa.sh THE
    # FLEET HOME). Without it a scoped project's pane resolves no home at all
    # (ac_home refuses an unset AC_HOME) and finds neither side - loud, but for
    # the wrong reason.
    home_directive="Fleet home (pass this VERBATIM as \`--home <path>\` on step 1's \`start\` line - your pane has no AC_HOME to resolve it):
$(ac_home)"
    store_directive="No knowledge store is wired for this project yet (no clone to resolve, or store-dir could not resolve one). Run store-less per the \`qa\` skill: derive every case fresh, skip curation, and SAY SO in the testplan and report."
    if store_root="$(ac_project_dir "$project" 2>/dev/null)" \
       && store_path="$(cd "$store_root" && "$(dirname "$0")/ac-qa.sh" store-dir 2>/dev/null)"; then
      store_directive="Knowledge store (pass this VERBATIM as \`--store <path>\` on step 1's \`start\` line - your pane has no AC_HOME to resolve it):
$store_path"
    fi
    cat >"$brief" <<EOF
# QA brief: $id

Project: $project
Kind: qa charter (verify only - NEVER fix, commit, push, or open a PR; executed by the qa PANE AGENT via ac-qa.sh agent --brief <this file>, never by a crewmate)
Captain: $captain

## Inputs

<!-- Orchestrator: name the TARGET (branch $crew_branch / PR / commit), link the
     acceptance criteria by ABSOLUTE path (e.g. $data_dir/$fam/spec/report.md
     or the design report), and when a separate e2e repo applies, the
     PRE-LEASED e2e worktree path. The crewmate must read every input first. -->

## Deliverable

Run the \`qa\` skill (it drives the bin/ac-qa.sh pipeline).
$store_directive
$home_directive

Derive the testplan (testplan.md HERE, next to this brief), boot the
task-scoped infra, exercise the live service per tier (api/db via the e2e
suite, web via the real browser with screenshots), and deliver
$task_dir/report.md - first line \`verdict: passed|failed|unverifiable\`,
the per-case evidence table, findings, and the QA_* envelope.
Evidence lands in $task_dir/evidence/. Proposed e2e specs are a PATCH in
the evidence dir, never a commit.
$(knowledge)
$(standing_rules)

$(signals)
EOF
    ;;
esac

# Required-profile MANIFEST (Story 4): record the task's explicit required
# profile set at intake, the set the merge gate later adjudicates (doc Required
# Profile Matrix l.413, Task Data Layout l.387). It is FAMILY-level -
# data/<family>/qa/manifest.json - so the gate finds it from the task id alone,
# and the qa dir sits beside the stage dir. Written ONLY when the chief names a
# required profile: absent the flag, a flat/single-profile task keeps the simple
# one-profile gate behavior (no manifest, no matrix arm). Built through jq so the
# file is always valid JSON; the pinned profile_sha256/e2e_sha the gate matches
# are not known at intake and are added later, so intake records keys only.
if [ "${#qa_profiles[@]}" -gt 0 ]; then
  for k in "${qa_profiles[@]}"; do
    case "$k" in
      ''|*[!A-Za-z0-9/_-]*) ac_die "invalid --qa-required-profile '$k' (want <project>/<scope>/<app>, chars [A-Za-z0-9/_-])" ;;
    esac
  done
  fam="$(ac_family_of_id "$id")"
  qadir="$data_dir/$fam/qa"
  mkdir -p "$qadir"
  # Best-effort provenance: the base the required set is declared against (the
  # project's default-branch head), empty when the clone does not resolve. The
  # gate binds to the exact merge head it is handed, not to this - it is a
  # human-read record of what source the set was declared for.
  src_ref=""
  if pdir="$(ac_project_dir "$project" 2>/dev/null)"; then
    src_ref="$(git -C "$pdir" rev-parse "$(ac_default_branch "$pdir")" 2>/dev/null || true)"
  fi
  jq -n --arg task "$fam" --arg src "$src_ref" \
    '{task: $task, source_ref: $src, required_profiles: ($ARGS.positional | map({profile_key: .}))}' \
    --args "${qa_profiles[@]}" >"$qadir/manifest.json"
  printf 'required-profile manifest: %s (%s profile(s))\n' "$qadir/manifest.json" "${#qa_profiles[@]}"
fi

printf 'brief scaffolded: %s (stage: %s)\n' "$brief" "$stage"
