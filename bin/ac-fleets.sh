#!/usr/bin/env bash
# ac-fleets.sh - READ-ONLY cross-fleet overview. For EVERY fleet home under the
# homes container, print a compact status block so the captain can survey all
# fleets without visiting each one.
#
# Usage: ac-fleets.sh [--json | --paths] [<container>]
#        ac-fleets.sh -h | --help
#
# --json re-emits the SAME survey as ONE JSON document (the dashboard's data
# layer, D2): a re-emission of what the walk already computes, never a second
# accounting. Text mode stays byte-identical - --json is purely additive. The
# JSON adds only what the cross-fleet cards render on top of the text fields
# (the per-home config pins and the learn/curate cadence line) and a top-level
# `totals` aggregate; the schema is pinned by tests/ac-fleets.test.sh.
#
# --paths is the paths-only sibling of --json: `{homes:[{path,crewdeputies:
# [...]}]}`, home-discovery only (is_home + crewdeputy nesting), none of
# --json's per-home crew/inbox/watcher/wakes/lock/cadence/config computation -
# no totals either. bin/dashboard.ts's allowedHomePaths() is the one consumer:
# it reads only h.path/h.crewdeputies from a full --json walk and threw the
# rest away, paying the whole per-home accounting (including one ac-room.sh
# list shell-out per home) for nothing every time its cache expired.
#
# Container resolution (first hit wins):
#   1. the <container> argument
#   2. $AC_HOMES_CONTAINER
#   3. the parent directory of $AC_HOME, when AC_HOME is set
#   4. ~/Work/ac-homes
# A missing/unreadable container prints a notice and exits 0 (a survey never
# fails). The resolved container is printed in the header.
#
# A home is any immediate child dir of the container that holds data/, state/,
# or config/. Non-home dirs are skipped silently. Crewdeputy homes nested at
# <home>/crewdeputies/<name> are surveyed too, recursively, one indent deeper.
#
# Per home it reports:
#   crew    - task ids in flight with kind/project and the LAST recorded
#             state/<id>.status line; --json also carries each task's
#             recorded delivery mode (meta mode=, null when unset/"-") so
#             the dashboard shows the mode a task RUNS with. This is NOT a live backend probe: the
#             command never touches the herdr backend, so it stays fast and
#             safe across many homes (unlike ac-fleet-view.sh, which drives the
#             backend for a single owned home).
#   verify  - the VERIFICATION agents in flight, reported APART from crew -
#             never in the crew rows and never in crew.count. A verification
#             pane agent has no backlog row, but its short-lived exact-ref lease
#             and caller/family linkage remain visible for supervision. The
#             class is `ac_meta_is_verify` (bin/ac-lib.sh), read from the meta's
#             own kind. Text mode prints the block only when one exists, so a
#             home with none renders exactly as before; --json always carries
#             the top-level `verify[]` array, empty when there are none.
#   inbox   - the captain inbox: rooms with unanswered GATE/ASK entries and
#             rooms in HANDBACK. The accounting is ac-room.sh's own (this
#             re-enters `ac-room.sh list` with AC_HOME set per home rather than
#             re-implementing the pending logic). A room that is BOTH
#             gate-pending AND in HANDBACK emits one combined
#             `PENDING-CAPTAIN(n)+HANDBACK` line and is tallied under BOTH
#             pending and handback here - ac-room.sh no longer masks the
#             hand-back behind the gate, so it cannot rot until the gate clears.
#   watcher - armed or down, from the state/.last-watcher-beat liveness beacon
#             (stale beyond AC_GUARD_GRACE seconds, default 300 = the watcher
#             coverage floor shared with the Stop hook (ac-turnend-guard.sh),
#             ac-wake-drain.sh, and ac-statusline.sh - NOT ac-guard.sh's
#             tighter 90s warn-only advisory); state/.watcher-owner names the
#             holder pid.
#   wakes   - queued wakes across the WHOLE home: spool records in
#             state/.wake-spool[.<fam>]/ (drain claim dirs are not wake stores
#             and are never counted).
#   lock    - the per-home session lock (state/.session-lock): free, held
#             (owner pid alive) or stale (owner pid dead), with pid + since.
#   config  - (--json only) the flow/promote/remote-mirror pins the cards show.
#   cadence - (--json only) the learn (debriefs/learn-every) and curate
#             (runs_since/curate-every) counters plus their DUE flags, and the
#             learn counter's last_run stamp (epoch seconds, null when the home
#             never landed a distill run). `totals` tallies the DUE flags as
#             learning_due/curate_due - the count of homes at/over their own
#             threshold, the digest's signal made fleet-wide.
#
# STRICTLY READ-ONLY over every home: it never acquires a lock, stamps a guard,
# drives a backend, or writes any file under any home. Home paths are computed
# directly and only PURE ac-lib readers (ac_meta_get, ac_wake_family_spools)
# plus the local cfg_read (direct first-line read) are
# used - never the mkdir-ing path helpers (ac_state_dir/ac_data_dir/
# ac_config_dir/ac_config_read) - so a home with no state/ yet renders an
# empty-but-valid block and NOTHING is created. In particular the wakes tally
# only globs and counts: it never drains a queue it surveys.
# The one re-entry (`ac-room.sh list`) is gated on an existing data/ dir, so it
# too creates nothing.
#
# Knobs: AC_GUARD_GRACE=300 (watcher-staleness threshold; the default IS the
#   coverage floor the Stop hook / ac-wake-drain.sh / ac-statusline.sh enforce,
#   so the survey agrees with them; 90 is ac-guard.sh's tighter warn-only
#   advisory, still selectable by exporting the env var).
# Exit: 0 always.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-wake-lib.sh"

bin_dir="$(cd "$(dirname "$0")" && pwd -P)"
now="$(ac_now)"
grace="${AC_GUARD_GRACE:-300}"

# --- arg parse: --json/--paths anywhere, first bare arg is the container --------
mode=text
arg_container=""
for a in "$@"; do
  case "$a" in
    --json) mode=json ;;
    --paths) mode=paths ;;
    -h|--help) awk 'NR>1{if(!/^#/)exit; print}' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) [ -n "$arg_container" ] || arg_container="$a" ;;
  esac
done

is_home() { [ -d "$1/data" ] || [ -d "$1/state" ] || [ -d "$1/config" ]; }

cfg_read() {
  # cfg_read <cfgdir> <name> <default> - first line of <cfgdir>/<name>, trimmed
  # of surrounding whitespace/CR, or <default> when absent. The per-home,
  # NO-mkdir analogue of ac_config_read (ac_config_read resolves AC_HOME's
  # config/ AND mkdir's it - both wrong here: the walk reads arbitrary homes and
  # must create nothing). Only called on the --json path.
  local f="$1/$2" default="$3" line
  [ -f "$f" ] || { printf '%s' "$default"; return 0; }
  line="$(head -n1 "$f")"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s' "$line"
}

emit_home() {
  # emit_home <home> <depth> - one status block (text), or one JSON home object
  # printed to stdout (mode=json), then recurse into crewdeputies.
  local home="$1" depth="$2"
  if [ "$depth" -gt 6 ]; then return 0; fi          # loop backstop
  local pad name sd dd cfgd captain
  pad="$(printf '%*s' "$((depth * 3))" '')"
  name="$(basename "$home")"
  sd="$home/state"; dd="$home/data"; cfgd="$home/config"

  captain=""
  if [ -f "$cfgd/captain" ]; then
    captain="$(head -n1 "$cfgd/captain" 2>/dev/null || true)"
    captain="${captain#"${captain%%[![:space:]]*}"}"
    captain="${captain%"${captain##*[![:space:]]}"}"
  fi

  # crew in flight: meta + last status line, never a backend probe.
  # A VERIFICATION agent's meta (ac_meta_is_verify owns the class) lives in the
  # same state/*.meta namespace but is NOT crew - it holds no backlog row, while
  # its short-lived exact-ref lease is verifier-owned. It is surveyed into its
  # OWN verify list and can never inflate the crew tally the digest/dashboard
  # read.
  local crew_count=0 crew_lines="" crew_tasks_json="[]" meta id kind project dmode stf status row
  local verify_count=0 verify_lines="" verify_json="[]" row_json
  local caller family ref worktree verify_row
  if [ -d "$sd" ]; then
    for meta in "$sd"/*.meta; do
      [ -e "$meta" ] || continue
      id="$(basename "$meta" .meta)"
      kind="$(ac_meta_get "$meta" kind)"
      project="$(ac_meta_get "$meta" project)"
      # The task's DELIVERY mode ($mode is this function's output format).
      dmode="$(ac_meta_get "$meta" mode)"
      stf="$sd/$id.status"
      if [ -s "$stf" ]; then status="$(tail -n1 "$stf" | cut -d' ' -f2-)"; else status='-'; fi
      if [ "${#status}" -gt 100 ]; then status="${status:0:97}..."; fi
      row="$(printf '%s     %-16s %-6s %-14s %s' "$pad" "$id" "${kind:--}" "${project:--}" "$status")"
      if [ "$mode" = json ]; then
        row_json="$(jq -c -n \
          --arg id "$id" --arg kind "$kind" --arg project "$project" --arg status "$status" \
          --arg dmode "$dmode" \
          '{id:$id,
            kind:(if $kind=="" then null else $kind end),
            project:(if $project=="" then null else $project end),
            mode:(if $dmode=="" or $dmode=="-" then null else $dmode end),
            status:$status}')"
      fi
      if ac_meta_is_verify "$meta"; then
        caller="$(ac_meta_get "$meta" caller)"
        family="$(ac_meta_get "$meta" family)"
        ref="$(ac_meta_get "$meta" ref)"
        worktree="$(ac_meta_get "$meta" worktree)"
        verify_row="${row} caller=${caller:--} family=${family:--} ref=${ref:0:12}"
        verify_count=$((verify_count + 1))
        verify_lines="${verify_lines}${verify_row}
"
        if [ "$mode" = json ]; then
          row_json="$(jq -c -n \
            --arg id "$id" --arg kind "$kind" --arg project "$project" --arg status "$status" \
            --arg caller "$caller" --arg family "$family" --arg ref "$ref" --arg worktree "$worktree" \
            '{id:$id,
              kind:(if $kind=="" then null else $kind end),
              project:(if $project=="" then null else $project end),
              status:$status,
              caller:(if $caller=="" then null else $caller end),
              family:(if $family=="" then null else $family end),
              ref:(if $ref=="" then null else $ref end),
              worktree:(if $worktree=="" then null else $worktree end)}')"
          verify_json="$(jq -c --argjson r "$row_json" '. + [$r]' <<<"$verify_json")"
        fi
      else
        crew_count=$((crew_count + 1))
        crew_lines="${crew_lines}${row}
"
        [ "$mode" = json ] && crew_tasks_json="$(jq -c --argjson r "$row_json" '. + [$r]' <<<"$crew_tasks_json")"
      fi
    done
  fi

  # captain inbox: ac-room.sh's own pending/handback accounting, per home.
  local inbox_pending=0 inbox_handback=0 inbox_lines="" inbox_entries_json="[]" inbox_ndjson="" line n
  if [ -d "$dd" ]; then
    # JSON mode collects each entry as one NDJSON line and slurps them with a
    # single `jq -s` after the loop, instead of re-parsing the whole
    # accumulator (`jq -c '. + [...]' <<<"$acc"`) on every line - O(n^2)
    # forks + parse on the path every dashboard request walks.
    if [ "$mode" = json ]; then
      inbox_ndjson="$(mktemp "${TMPDIR:-/tmp}/ac-fleets-inbox.XXXXXX")"
      # Double-quoted: bakes in the actual path NOW. inbox_ndjson is `local`
      # to this function, so a deferred (single-quoted) trap would read it
      # AFTER the function returns and the local has already popped, which
      # errors under `set -u` at the subshell's exit instead of cleaning up.
      trap "rm -f '$inbox_ndjson'" EXIT
    fi
    while IFS= read -r line; do
      case "$line" in
        PENDING-CAPTAIN*)
          n="${line#PENDING-CAPTAIN(}"; n="${n%%)*}"
          case "$n" in ''|*[!0-9]*) n=0 ;; esac
          inbox_pending=$((inbox_pending + n))
          # A combined `PENDING-CAPTAIN(n)+HANDBACK` line (ac-room.sh no longer
          # masks a hand-back behind a pending gate) is tallied under BOTH
          # pending and handback - else the hand-back is dropped from this
          # cross-fleet inbox, the exact rot the fix forbids, one level up. Key
          # on the status TOKEN (the first field), not the whole line: the
          # trailing entry text can mention HANDBACK without it being pending.
          case "${line%%[[:space:]]*}" in *+HANDBACK) inbox_handback=$((inbox_handback + 1)) ;; esac
          inbox_lines="${inbox_lines}${pad}     ${line}
"
          [ "$mode" = json ] && inbox_entry_json "$inbox_ndjson" "$line" ;;
        HANDBACK*)
          inbox_handback=$((inbox_handback + 1))
          inbox_lines="${inbox_lines}${pad}     ${line}
"
          [ "$mode" = json ] && inbox_entry_json "$inbox_ndjson" "$line" ;;
      esac
    done < <(AC_HOME="$home" "$bin_dir/ac-room.sh" list 2>/dev/null || true)
    [ -n "$inbox_ndjson" ] && inbox_entries_json="$(jq -s -c '.' "$inbox_ndjson")"
  fi

  # watcher liveness from the beacon.
  local watcher w_state owner="" beat="" age=""
  if [ -f "$sd/.watcher-owner" ]; then
    owner="$(tr -d '[:space:]' <"$sd/.watcher-owner")"
  fi
  if [ -f "$sd/.last-watcher-beat" ]; then
    beat="$(tr -d '[:space:]' <"$sd/.last-watcher-beat")"
    case "$beat" in ''|*[!0-9]*) beat=0 ;; esac
    if [ "$beat" -eq 0 ]; then
      # The file exists but carries no usable beat - unreadable, or the 0
      # ac-watch.sh's stand_down_beacon writes on every exit. Down all the
      # same, but `now - 0` is a 56-year age, so report no age at all (the
      # convention ac-wake-drain.sh renders); $age stays empty = null in --json.
      watcher="down (no beat on record${owner:+, owner pid $owner})"
    else
      age=$((now - beat))
      if [ "$age" -le "$grace" ]; then
        watcher="armed (beat ${age}s ago${owner:+, owner pid $owner})"
      else
        watcher="down (beat ${age}s > grace ${grace}s${owner:+, owner pid $owner})"
      fi
    fi
  else
    watcher="down (no beacon)"
  fi
  if [ "$crew_count" -eq 0 ]; then
    case "$watcher" in down*) watcher="$watcher - no crew in flight" ;; esac
  fi
  case "$watcher" in armed*) w_state=armed ;; *) w_state=down ;; esac

  # queued wakes: the WHOLE home, summed across every scope's spool - the
  # fleet's plus each promoted family's. Pure glob + count: never a mkdir,
  # never a drain (ac_wake_family_spools excludes the drain claim dirs, so a
  # mid-drain home cannot inflate the tally). A spool record is one file = one
  # wake, so the tally is a name count, never a read.
  local wakes=0 r
  for r in "$sd"/.wake-spool/*; do
    [ -e "$r" ] && wakes=$(( wakes + 1 ))
  done
  while IFS= read -r q; do
    for r in "$q"/*; do
      [ -e "$r" ] && wakes=$(( wakes + 1 ))
    done
  done < <(ac_wake_family_spools "$sd" 2>/dev/null)

  # session lock.
  local lock l_state lpid="" lsince=""
  if [ -f "$sd/.session-lock" ]; then
    lpid="$(ac_meta_get "$sd/.session-lock" pid)"
    lsince="$(ac_meta_get "$sd/.session-lock" since)"
    if [ -n "$lpid" ] && ps -p "$lpid" >/dev/null 2>&1; then
      lock="held pid=$lpid since=${lsince:-?}"; l_state=held
    else
      lock="stale pid=${lpid:-?} since=${lsince:-?}"; l_state=stale
    fi
  else
    lock="free"; l_state=free
  fi

  # --- JSON render: one home object, recursing to nest crewdeputies -------------
  if [ "$mode" = json ]; then
    local flow promote mirror
    flow="$(cfg_read "$cfgd" flow auto)"
    promote="$(cfg_read "$cfgd" promote always)"
    mirror="$(cfg_read "$cfgd" remote-mirror off)"
    # cadence: flat counters (state/.learn.meta debriefs, legacy stows fallback;
    # state/.curate.meta runs_since) vs the config thresholds - the same read
    # ac_learn_due/ac_curate_due do, but for an ARBITRARY home (their AC_HOME
    # binding and mkdir make them unusable across the walk). DUE = count>=every.
    # last_run is the DISTILL stamp ac_learn_reset writes (epoch SECONDS, the
    # unit watcher.beat already uses); null when the home never landed one. Only
    # the learn counter carries it - nothing renders a curate stamp today.
    local lcur lev ccur cev ldue cdue lrun
    lcur="$(ac_meta_get "$sd/.learn.meta" debriefs)"
    [ -n "$lcur" ] || lcur="$(ac_meta_get "$sd/.learn.meta" stows)"
    case "$lcur" in ''|*[!0-9]*) lcur=0 ;; esac
    lrun="$(ac_meta_get "$sd/.learn.meta" last_run)"
    case "$lrun" in ''|*[!0-9]*) lrun=null ;; esac
    lev="$(cfg_read "$cfgd" learn-every 8)"; case "$lev" in ''|*[!0-9]*) lev=8 ;; esac
    ccur="$(ac_meta_get "$sd/.curate.meta" runs_since)"
    case "$ccur" in ''|*[!0-9]*) ccur=0 ;; esac
    cev="$(cfg_read "$cfgd" curate-every 5)"; case "$cev" in ''|*[!0-9]*) cev=5 ;; esac
    if [ "$lcur" -ge "$lev" ]; then ldue=true; else ldue=false; fi
    if [ "$ccur" -ge "$cev" ]; then cdue=true; else cdue=false; fi

    # recurse into crewdeputies, collecting each nested home object.
    local children="[]" cdroot cd cj
    cdroot="$home/crewdeputies"
    if [ -d "$cdroot" ]; then
      for cd in "$cdroot"/*/; do
        [ -d "$cd" ] || continue
        is_home "${cd%/}" || continue
        cj="$(emit_home "${cd%/}" "$((depth + 1))")"
        children="$(jq -c --argjson c "$cj" '. + [$c]' <<<"$children")"
      done
    fi

    jq -n \
      --arg name "$name" --arg path "$home" --arg captain "$captain" \
      --arg flow "$flow" --arg promote "$promote" --arg mirror "$mirror" \
      --argjson crew_count "$crew_count" --argjson tasks "$crew_tasks_json" \
      --argjson verify "$verify_json" \
      --argjson pending "$inbox_pending" --argjson handback "$inbox_handback" \
      --argjson entries "$inbox_entries_json" \
      --arg w_state "$w_state" --arg w_detail "$watcher" \
      --argjson w_age "${age:-null}" --argjson w_beat "${beat:-null}" --arg w_owner "$owner" \
      --argjson wakes "$wakes" \
      --arg l_state "$l_state" --arg l_detail "$lock" --arg l_pid "$lpid" --arg l_since "$lsince" \
      --argjson l_cur "$lcur" --argjson l_ev "$lev" --argjson l_due "$ldue" --argjson l_run "$lrun" \
      --argjson c_cur "$ccur" --argjson c_ev "$cev" --argjson c_due "$cdue" \
      --argjson children "$children" \
      '{
        name: $name,
        path: $path,
        captain: (if $captain == "" then null else $captain end),
        config: { flow: $flow, promote: $promote, mirror: $mirror },
        crew: { count: $crew_count, tasks: $tasks },
        verify: $verify,
        inbox: { pending: $pending, handback: $handback, entries: $entries },
        watcher: {
          state: $w_state, age: $w_age, beat: $w_beat,
          owner: (if $w_owner == "" then null else $w_owner end),
          detail: $w_detail
        },
        wakes: $wakes,
        lock: {
          state: $l_state,
          pid: (if $l_pid == "" then null else $l_pid end),
          since: (if $l_since == "" then null else $l_since end),
          detail: $l_detail
        },
        cadence: {
          learn: { count: $l_cur, every: $l_ev, due: $l_due, last_run: $l_run },
          curate: { count: $c_cur, every: $c_ev, due: $c_due }
        },
        crewdeputies: $children
      }'
    return 0
  fi

  # --- text render (byte-identical with the pre-json script) --------------------
  printf '%s⚓ %s%s\n' "$pad" "$name" "${captain:+   captain: $captain}"
  if [ "$crew_count" -gt 0 ]; then
    printf '%s   crew    : %s in flight\n' "$pad" "$crew_count"
    printf '%s' "$crew_lines"
  else
    printf '%s   crew    : none in flight\n' "$pad"
  fi
  # Verification agents get their OWN labelled block, and only when some exist -
  # a home with none renders byte-identically to the pre-class script.
  if [ "$verify_count" -gt 0 ]; then
    printf '%s   verify  : %s in flight (verification agents, not crew)\n' "$pad" "$verify_count"
    printf '%s' "$verify_lines"
  fi
  if [ "$inbox_pending" -gt 0 ] || [ "$inbox_handback" -gt 0 ]; then
    printf '%s   inbox   : %s pending, %s handback\n' "$pad" "$inbox_pending" "$inbox_handback"
    printf '%s' "$inbox_lines"
  else
    printf '%s   inbox   : clear\n' "$pad"
  fi
  printf '%s   watcher : %s\n' "$pad" "$watcher"
  printf '%s   wakes   : %s queued\n' "$pad" "$wakes"
  printf '%s   lock    : %s\n' "$pad" "$lock"

  # recurse into nested crewdeputy homes.
  local cdroot2 cd2 first=1
  cdroot2="$home/crewdeputies"
  if [ -d "$cdroot2" ]; then
    for cd2 in "$cdroot2"/*/; do
      [ -d "$cd2" ] || continue
      is_home "${cd2%/}" || continue
      if [ "$first" = 1 ]; then printf '%s   crewdeputies:\n' "$pad"; first=0; fi
      emit_home "${cd2%/}" "$((depth + 1))"
    done
  fi
  return 0
}

emit_home_paths() {
  # emit_home_paths <home> - the paths-only sibling of emit_home: `{path,
  # crewdeputies:[...]}`, home-discovery only. No crew scan, no ac-room.sh
  # list shell-out, no watcher/wakes/lock reads, no config/cadence reads -
  # every one of those is per-home work emit_home pays for that
  # allowedHomePaths (bin/dashboard.ts) never reads.
  local home="$1" cdroot cd children="[]" cj
  cdroot="$home/crewdeputies"
  if [ -d "$cdroot" ]; then
    for cd in "$cdroot"/*/; do
      [ -d "$cd" ] || continue
      is_home "${cd%/}" || continue
      cj="$(emit_home_paths "${cd%/}")"
      children="$(jq -c --argjson c "$cj" '. + [$c]' <<<"$children")"
    done
  fi
  jq -n --arg path "$home" --argjson children "$children" \
    '{path: $path, crewdeputies: $children}'
}

inbox_entry_json() {
  # inbox_entry_json <ndjson-file> <ac-room.sh-list-line> - parse one
  # PENDING/HANDBACK line into {status,family,last} and APPEND it as one
  # NDJSON line to <ndjson-file> (json path only); the caller slurps the
  # whole file with one `jq -s` once the loop is done.
  # Line shape (ac-room.sh cmd_list): `<status><spaces><family>\t<last>`.
  local ndjson="$1" line="$2" stok left last fam
  stok="${line%%[[:space:]]*}"
  left="${line%%$'\t'*}"
  last="${line#*$'\t'}"; [ "$last" != "$line" ] || last=""
  fam="${left##* }"
  jq -nc --arg s "$stok" --arg f "$fam" --arg l "$last" \
    '{status:$s, family:$f, last:$l}' >>"$ndjson"
}

# --- container resolution -------------------------------------------------------
container="$arg_container"
[ -n "$container" ] || container="${AC_HOMES_CONTAINER:-}"
if [ -z "$container" ] && [ -n "${AC_HOME:-}" ]; then
  container="$(cd "$AC_HOME/.." 2>/dev/null && pwd -P || true)"
fi
[ -n "$container" ] || container="$HOME/Work/ac-homes"

resolved="$(cd "$container" 2>/dev/null && pwd -P || true)"
if [ -z "$resolved" ]; then
  if [ "$mode" = json ]; then
    jq -n --arg container "$container" --arg at "$(ac_iso)" --argjson grace "$grace" \
      '{container:$container, generated_at:$at, grace:$grace, note:"container not found",
        totals:{homes:0, crew:0, pending:0, handback:0, watchers_down:0,
                learning_due:0, curate_due:0}, homes:[]}'
    exit 0
  fi
  if [ "$mode" = paths ]; then
    jq -n --arg container "$container" '{container:$container, homes:[]}'
    exit 0
  fi
  printf '(fleet homes container not found: %s)\n' "$container"
  exit 0
fi
container="$resolved"

if [ "$mode" = paths ]; then
  # Same NDJSON-then-`jq -s` batching as --json below, over emit_home_paths
  # instead of emit_home - no totals (nothing downstream needs them).
  paths_ndjson="$(mktemp "${TMPDIR:-/tmp}/ac-fleets-paths.XXXXXX")"
  trap 'rm -f "$paths_ndjson"' EXIT
  for d in "$container"/*/; do
    [ -d "$d" ] || continue
    home="${d%/}"
    is_home "$home" || continue
    hj="$(emit_home_paths "$home")"
    printf '%s\n' "$hj" >>"$paths_ndjson"
  done
  homes_json="$(jq -s -c '.' "$paths_ndjson")"
  jq -n --arg container "$container" --argjson homes "$homes_json" \
    '{container:$container, homes:$homes}'
  exit 0
fi

if [ "$mode" = json ]; then
  # One NDJSON line per home, ONE `jq -s` at the end - not a `jq -c '. + [...]'`
  # re-parse of the whole accumulator per home (O(n^2) forks + parse on the
  # path every dashboard request walks).
  homes_ndjson="$(mktemp "${TMPDIR:-/tmp}/ac-fleets-homes.XXXXXX")"
  trap 'rm -f "$homes_ndjson"' EXIT
  for d in "$container"/*/; do
    [ -d "$d" ] || continue
    home="${d%/}"
    is_home "$home" || continue
    hj="$(emit_home "$home" 0)"
    printf '%s\n' "$hj" >>"$homes_ndjson"
  done
  homes_json="$(jq -s -c '.' "$homes_ndjson")"
  # totals: pure arithmetic over the emitted per-home fields (NOT a second
  # accounting) - every home object, crewdeputies included, has a "crew" key.
  # watchers_down is the COVERAGE-GAP alarm (crew in flight AND watcher down),
  # not every idle beaconless home. learning_due/curate_due COUNT the homes whose
  # own `cadence.*.due` flag is already set - the >= compare stays in bash above,
  # here it is only a tally of booleans (same shape as watchers_down).
  totals_json="$(jq -c '
    [.. | objects | select(has("crew"))] as $all
    | { homes: ($all | length),
        crew: ($all | map(.crew.count) | add // 0),
        pending: ($all | map(.inbox.pending) | add // 0),
        handback: ($all | map(.inbox.handback) | add // 0),
        watchers_down: ($all | map(select(.crew.count > 0 and .watcher.state == "down")) | length),
        learning_due: ($all | map(select(.cadence.learn.due)) | length),
        curate_due: ($all | map(select(.cadence.curate.due)) | length) }
  ' <<<"$homes_json")"
  jq -n --arg container "$container" --arg at "$(ac_iso)" --argjson grace "$grace" \
    --argjson totals "$totals_json" --argjson homes "$homes_json" \
    '{container:$container, generated_at:$at, grace:$grace, totals:$totals, homes:$homes}'
  exit 0
fi

printf '== fleet homes: %s ==\n' "$container"
found=0
for d in "$container"/*/; do
  [ -d "$d" ] || continue
  home="${d%/}"
  is_home "$home" || continue
  found=1
  printf '\n'
  emit_home "$home" 0
done
if [ "$found" = 0 ]; then
  printf '\n(no fleet homes under %s)\n' "$container"
fi
exit 0
