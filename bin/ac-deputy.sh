#!/usr/bin/env bash
# ac-deputy.sh - the crewdeputy routing layer: render the routing table, check
# it strictly, answer a routed order back to the parent, and hand queued
# backlog items over to a deputy.
#
# Usage: ac-deputy.sh list
#        ac-deputy.sh validate
#        ac-deputy.sh report '<text>' [--doc <abs-path>]
#        ac-deputy.sh handoff <deputy-id> <backlog-id>...
#
# The registry GRAMMAR (line shape, the VALID/LEGACY/INVALID classes, legacy
# read-compatibility) is owned by ac-lib.sh's `crewdeputy routing table` block;
# this script owns how that table is RENDERED and how liveness is resolved.
#
# --- list: the session-start digest block --------------------------------------
#
# AUTHORITATIVE for the `-- crewdeputies (routing table) --` block. Three
# distinguishable states, because "no registry" and "an empty registry" are
# different facts about the fleet:
#   ABSENT: records/crewdeputies.md - no crewdeputies registered
#   EMPTY:  records/crewdeputies.md present, 0 entries - no crewdeputies registered
#   the FULL table, never truncated - the chief routes against it, so a head -n
#   cut would silently hide a deputy.
#
# One entry renders as a TAB-separated head line plus TAB-indented
# continuations (the ac-fleet-view.sh house style):
#   <STATE>\t<id>\thome: <path>\tprojects: <list|none>
#   \tcharter: <one-liner, or (none) for a legacy line>
#   \tscope: <text, or the unset notice for a non-routable entry>
#   \trecover: bin/ac-spawn.sh <id> --crewdeputy --recover   (DOWN/NOT-RUNNING only)
# An INVALID line prints its VERBATIM source plus one reason, so a typo is
# fixable without opening the ledger. A trailing tally closes the block.
#
# Liveness per entry, first match wins:
#   HOME-MISSING  home dir absent, or present without .ac-crewdeputy-home.
#                 Registry and disk disagree: never routable, never auto-fixed,
#                 and NO recover hint - removing or repairing a registry line is
#                 a captain-facing act, like removing a project.
#   NOT-RUNNING   no state/<id>.meta in the PARENT home: seeded (or torn down)
#                 and never spawned since.
#   DOWN          meta present, backend window not alive. The pane died; the
#                 deputy's OWN crew may still be running in its home.
#   LIVE          meta present, backend window alive.
# It is a PRESENCE read only (meta + backend_window_alive), deliberately not the
# deeper ac-crew-state.sh probe: the digest already pays that cost for in-flight
# crew, and a second deep read per deputy changes no decision.
#
# `list` ALWAYS exits 0 and renders even on a corrupt ledger - a digest block
# may never take session start down. It is READ-ONLY (parses a file, probes
# windows) and therefore safe under the read-only session lock.
#
# --- validate: the strict twin --------------------------------------------------
#
# Exits non-zero when any `- ` line is INVALID, naming each one (the
# ac-ready.sh validate pattern). Fail-OPEN where a session depends on it,
# fail-CLOSED where a deliberate check asks.
#
# --- report: the deputy -> parent RETURN CHANNEL ---------------------------------
#
# AUTHORITATIVE for how a crewdeputy answers a routed order. It runs INSIDE the
# deputy home (AC_HOME = the deputy home) and writes ACROSS homes, which is why
# it exists at all: no other script does. Two durable effects, in order:
#   1. `<iso> report: <text>[ doc: <path>]` appended to the PARENT's
#      state/<id>.status - the parent's index of what came back;
#   2. ONE wake record published into the PARENT's fleet spool
#      (ac_wake_publish, kind `deputy`), so the crewchief's ordinary
#      ac-wake-drain.sh emits `deputy <id> <text>` with no new consumer code.
# Both are on disk, so the outcome survives a restart of BOTH sessions. A pane
# line stays a legitimate real-time TRIGGER, but it is never the PAYLOAD; if the
# two disagree, this return is authoritative.
#
# The payload is SANITIZED: tabs and newlines collapse to single spaces, because
# the wake record is TSV and a raw tab would tear the field and silently swallow
# the answer. An answer longer than one line travels as a DOCUMENT inside the
# deputy's own home, with --doc carrying its absolute path as the pointer.
#
# ac_wake_publish is called from this script's MAIN shell, never a subshell -
# its $$-keyed collision identity requires it (ac-lib.sh owns that contract).
#
# Refusals: this home is not a crewdeputy home, the resolved parent has no
# state/ directory, the text is empty, or --doc is not absolute. A missing
# parent REGISTRY entry only WARNS and still delivers - the send side is
# fail-closed because a misaddressed ORDER is worse than none, but a stranded
# ANSWER is pure loss. That asymmetry is deliberate.
#
# Routine churn inside the deputy home (its own spawns, gates, landings) does
# NOT return here. Only phase changes the parent must act on do: done, blocked,
# needs-decision, failed, a declared paused, and captain-facing escalations.
#
# --- handoff: moving queued work into a deputy's own ledger ----------------------
#
# AUTHORITATIVE for the backlog handoff. It runs in the PARENT home and moves
# named `## Queued` items into the deputy's own records/backlog.md, so a deputy
# owns its domain's queue from day one instead of inheriting an invisible one.
# The chief judges SCOPE (the same natural-language judgment as routing) and
# names the ids; this moves exactly those, or nothing.
#
# Every precondition is checked BEFORE any write, and any failure aborts the
# WHOLE handoff - a partial move splits a queue across two ledgers with no
# record of the split:
#   1. the deputy resolves to a parsed registry entry whose home exists and
#      holds a records/backlog.md with a `## Queued` section;
#   2. each id matches EXACTLY one `- [ ] <id> - ` line, under `## Queued`. An
#      `## In flight` item is refused (its crewmate, worktree lease and meta
#      live in the parent home and cannot follow the line); a `## Done` item is
#      refused (history stays where it was made);
#   3. the line carries no `epic:<id>` token and the id is named in no other
#      line's `blocked-by:` - moving it would strand a dependent in a ledger
#      that can never see it satisfied;
#   4. the AS1 guard below.
# Then: ac_records_backup (the reversibility floor every mutating records path
# respects), remove the lines from the parent ledger, append them BYTE-
# IDENTICALLY at the END of the deputy's `## Queued` section - no re-writing, no
# annotation, and behind whatever the deputy already had queued, since queue
# order is meaningful - print each moved line, and record `handoff: <ids>` on
# the parent's state/<deputy-id>.status.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-backend.sh"
. "$(dirname "$0")/ac-wake-lib.sh"
. "$(dirname "$0")/ac-maintenance-lib.sh"

REGISTRY_LABEL='records/crewdeputies.md'
# ac_deputy_parse emits TSV, but a TAB is IFS-WHITESPACE: `read` collapses runs
# of it, so an INVALID record (five empty fields) or an entry with an empty
# scope would silently SHIFT every later field. Re-separate with US (\037), a
# non-whitespace delimiter `read` keeps positional, before any loop.
FS_US=$'\037'

deputy_state() {
  # deputy_state <id> <home> - the entry's one liveness state (see header).
  local id="$1" home="$2"
  if [ ! -d "$home" ] || [ ! -f "$home/.ac-crewdeputy-home" ]; then
    printf 'HOME-MISSING\n'; return 0
  fi
  if [ ! -f "$(ac_task_meta "$id")" ]; then
    printf 'NOT-RUNNING\n'; return 0
  fi
  # SUBSHELL, not a silenced call: an unsupported backend in a stale meta dies
  # inside it, so one bad entry degrades to DOWN instead of killing the digest -
  # while the reason still reaches stderr.
  if ( AC_BACKEND="$(ac_task_backend "$id")"; export AC_BACKEND; backend_window_alive "$id" ); then
    printf 'LIVE\n'
  else
    printf 'DOWN\n'
  fi
}

cmd_list() {
  local reg records cls id home charter scope projects reason state
  local n=0 live=0 down=0 notrun=0 missing=0 invalid=0
  reg="$(ac_deputy_registry)"
  if [ ! -f "$reg" ]; then
    printf 'ABSENT: %s - no crewdeputies registered\n' "$REGISTRY_LABEL"
    return 0
  fi
  records="$(ac_deputy_parse "$reg" | tr '\t' "$FS_US")"
  if [ -z "$records" ]; then
    printf 'EMPTY: %s present, 0 entries - no crewdeputies registered\n' "$REGISTRY_LABEL"
    return 0
  fi
  while IFS="$FS_US" read -r cls id home charter scope projects reason; do
    [ -n "$cls" ] || continue
    n=$((n + 1))
    if [ "$cls" = INVALID ]; then
      invalid=$((invalid + 1))
      printf 'INVALID\t%s\treason: %s\n' "$id" "$reason"
      continue
    fi
    state="$(deputy_state "$id" "$home")"
    case "$state" in
      LIVE) live=$((live + 1)) ;;
      DOWN) down=$((down + 1)) ;;
      NOT-RUNNING) notrun=$((notrun + 1)) ;;
      HOME-MISSING) missing=$((missing + 1)) ;;
    esac
    printf '%s\t%s\thome: %s\tprojects: %s\n' "$state" "$id" "$home" "$projects"
    printf '\tcharter: %s\n' "$charter"
    if [ -n "$scope" ]; then
      printf '\tscope: %s\n' "$scope"
    else
      printf '\tscope: (unset - not routable until a scope: is added)\n'
    fi
    case "$state" in
      DOWN|NOT-RUNNING) printf '\trecover: bin/ac-spawn.sh %s --crewdeputy --recover\n' "$id" ;;
    esac
  done <<EOF
$records
EOF
  printf 'registered: %s (live %s, down %s, not-running %s, home-missing %s, invalid %s)\n' \
    "$n" "$live" "$down" "$notrun" "$missing" "$invalid"
  return 0
}

cmd_validate() {
  local reg rc=0 cls id reason
  reg="$(ac_deputy_registry)"
  [ -f "$reg" ] || return 0
  while IFS="$FS_US" read -r cls id _ _ _ _ reason; do
    [ "$cls" = INVALID ] || continue
    printf 'INVALID %s: %s\n' "$id" "$reason"
    rc=1
  done <<EOF
$(ac_deputy_parse "$reg" | tr '\t' "$FS_US")
EOF
  return "$rc"
}

cmd_report() {
  # cmd_report '<text>' [--doc <abs-path>] - see the RETURN CHANNEL header.
  local text="${1:-}" doc="" home id parent body payload
  shift 1 2>/dev/null || true
  while [ $# -gt 0 ]; do
    case "$1" in
      --doc) doc="${2:-}"; shift 2 ;;
      *) ac_die "unknown argument: $1" ;;
    esac
  done
  [ -n "$text" ] || ac_die "usage: ac-deputy.sh report '<text>' [--doc <abs-path>]"
  ac_is_crewdeputy_home || ac_die "report runs INSIDE a crewdeputy home (no .ac-crewdeputy-home marker here)"
  home="$(ac_home)"
  id="$(basename "$home")"
  parent="$(cd "$home/../.." 2>/dev/null && pwd -P)" || parent=""
  [ -n "$parent" ] && [ -d "$parent/state" ] \
    || ac_die "cannot resolve a parent fleet above $home - refusing to write a return with nowhere to land"
  case "$doc" in
    '') ;;
    /*) ;;
    *) ac_die "--doc must be an absolute path (the parent resolves it from its own home): $doc" ;;
  esac

  body="$text"
  if [ -n "$doc" ]; then body="$body doc: $doc"; fi
  # The registry is only the ROUTING table: an unregistered deputy still gets
  # its answer through, loudly (see the header's asymmetry note).
  ac_deputy_parse "$parent/records/crewdeputies.md" \
    | awk -F'\t' -v i="$id" '$1 != "INVALID" && $2 == i { found = 1 } END { exit !found }' \
    || ac_warn "no registry entry for $id in the parent's routing table - delivering the return anyway"
  printf '%s report: %s\n' "$(ac_iso)" "$body" >>"$parent/state/$id.status"
  # TSV payload: a raw tab or newline would tear the record and swallow the answer.
  payload="$(printf '%s' "$body" | tr '\t\n' '  ')"
  ac_wake_publish "$parent/state" '' deputy "$id" "$payload"
  printf 'reported %s to %s\n' "$id" "$parent"
}

cmd_handoff() {
  # cmd_handoff <deputy-id> <backlog-id>... - see the HANDOFF header.
  local dep="${1:-}" home backlog dep_backlog item found line section repo mode arc
  shift 1 2>/dev/null || true
  [ -n "$dep" ] && [ $# -gt 0 ] || ac_die "usage: ac-deputy.sh handoff <deputy-id> <backlog-id>..."
  ! ac_is_crewdeputy_home || ac_die "handoff runs in the PARENT fleet home, not inside a crewdeputy home"

  home="$(ac_deputy_parse | awk -F'\t' -v i="$dep" '$1 != "INVALID" && $2 == i { print $3; exit }')"
  [ -n "$home" ] || ac_die "no crewdeputy '$dep' in $(ac_deputy_registry)"
  [ -d "$home" ] || ac_die "crewdeputy home is gone: $home"
  dep_backlog="$home/records/backlog.md"
  [ -f "$dep_backlog" ] || ac_die "crewdeputy $dep has no records/backlog.md to hand work into"
  grep -q '^## Queued' "$dep_backlog" || ac_die "crewdeputy $dep has no '## Queued' section in its backlog"
  backlog="$(ac_records_dir)/backlog.md"
  [ -f "$backlog" ] || ac_die "no parent backlog at $backlog"

  # VALIDATE EVERY ITEM FIRST - nothing is written until all of them pass.
  local moving="" ids=""
  for item in "$@"; do
    found="$(awk -v id="$item" '
      /^## / { sec = substr($0, 4); next }
      $0 ~ "^- \\[[ x]\\] " id "( \\[[^]]*\\])* - " { n++; s = sec; l = $0 }
      END { if (n == 1) printf "%s\t%s\n", s, l }
    ' "$backlog")"
    [ -n "$found" ] || ac_die "no line (or more than one) for '$item' in $backlog"
    section="${found%%	*}"
    line="${found#*	}"
    [ "$section" = "Queued" ] \
      || ac_die "'$item' sits under '## $section', not '## Queued' - only queued work can follow a domain"
    case "$line" in
      *epic:*) ac_die "'$item' belongs to an epic - moving it would strand its dependents in a ledger that cannot see it satisfied" ;;
    esac
    awk -v id="$item" '
      $0 ~ "^- \\[[ x]\\] " id "( \\[[^]]*\\])* - " { next }
      /blocked-by:/ {
        bb = $0; sub(/.*blocked-by:[ ]*/, "", bb); sub(/ - .*/, "", bb)
        n = split(bb, a, ",")
        for (i = 1; i <= n; i++) if (a[i] == id) exit 1
      }
    ' "$backlog" || ac_die "'$item' is named in another line's blocked-by: - moving it would strand that dependent"
    # AS1 GUARD (the one mechanical call site; grep AS1 to find it). A deputy
    # home holds its OWN clone, so a `local-only` landing merges into that
    # clone's local default branch and the parent's clone - the fleet's working
    # copy - never sees it. Delete this block, the AGENTS.md sentence, and the
    # matching test case to veto the rule; nothing else branches on mode.
    repo="$(printf '%s' "$line" | sed -n 's/.*(repo: \([^,)]*\).*/\1/p')"
    # FAIL CLOSED on an unresolvable repo: this guard is the single mechanical
    # enforcement of AS1, so an unknown input must refuse like every other
    # precondition in this loop, never wave the item through.
    [ -n "$repo" ] \
      || ac_die "'$item' carries no (repo: <name>) token, so its delivery mode cannot be resolved for the AS1 check - fix the backlog line: $line"
    # Mode is PER-TASK: the registry no longer
    # answers, so the ONLY thing this guard can read is the row's own
    # contract pin. An unpinned row is unresolvable - refuse and ask for the
    # pin, exactly like the missing repo token above: after the handoff the
    # deputy's chief picks the mode autonomously, and local-only is on its
    # cheap path, so the boundary here is the last point AS1 is enforceable.
    pin_mode="$(printf '%s\n' "$line" | awk "$AC_DONELINE_AWK"'
      /^- \[[ x]\] / { ac_doneline($0, o); print o["contract"]; exit }
    ' | tr " " "\n" | sed -n "s/^mode://p")"
    [ -n "$pin_mode" ] \
      || ac_die "'$item' pins no mode on its row, so the AS1 check cannot resolve its delivery mode (the registry no longer answers - mode is per-task). Pin it in the row's contract group (e.g. [mode:direct-pr]) before the handoff: $line"
    case "$pin_mode" in
      local-only) ac_die "'$item' is local-only work (repo: $repo) - it stays with the parent fleet, whose clone is the one a local landing reaches" ;;
    esac
    moving="$moving$line
"
    ids="${ids:+$ids,}$item"
  done

  arc="$(ac_records_backup deputy-handoff)"
  printf 'backup: %s\n' "$arc"
  # Remove from the parent, then insert under the deputy's `## Queued` heading.
  printf '%s' "$moving" >"$backlog.moving.$$"
  awk 'NR == FNR { drop[$0] = 1; next } !($0 in drop)' "$backlog.moving.$$" "$backlog" >"$backlog.tmp.$$"
  mv "$backlog.tmp.$$" "$backlog"
  # APPEND at the END of the deputy's Queued section (flush at the next heading,
  # or at EOF when Queued is last). Queue order is meaningful: inserting right
  # after the heading would silently reprioritize the parent's items above the
  # deputy's own queued work.
  awk -v f="$backlog.moving.$$" '
    inq && /^## / { while ((getline l < f) > 0) print l; inq = 0 }
    { print }
    /^## Queued/ { inq = 1 }
    END { if (inq) while ((getline l < f) > 0) print l }
  ' "$dep_backlog" >"$dep_backlog.tmp.$$"
  mv "$dep_backlog.tmp.$$" "$dep_backlog"
  rm -f "$backlog.moving.$$"
  printf '%s' "$moving"
  ac_status_append "$dep" "handoff: $ids"
  printf 'handed %s to %s\n' "$ids" "$dep"
}

case "${1:-}" in
  list) cmd_list ;;
  validate) cmd_validate ;;
  report) shift; cmd_report "$@" ;;
  handoff) shift; cmd_handoff "$@" ;;
  *) ac_die "usage: ac-deputy.sh <list|validate|report|handoff>" ;;
esac
