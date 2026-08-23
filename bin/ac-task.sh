#!/usr/bin/env bash
# ac-task.sh <verb> - every ROUTINE mutation of records/backlog.md as a verb
# instead of a model rewriting markdown. Authoritative spec for the verbs, the
# lock, the body block and the archives; the LINE grammar itself stays owned by
# AGENTS.md section 9 + AC_DONELINE_AWK, and the contract vocabulary by
# ac_contract_lint. This script EMITS what they parse and never invents a
# second dialect.
#
#   ac-task.sh add <id> <one-line> [--contract '<tokens>'] [--repo <name>]
#   ac-task.sh start <id>                 # Queued -> In flight, stamps `since`
#   ac-task.sh done <id> <outcome> [--verb merged|reported|...]
#   ac-task.sh hold <id> [--until <YYYY-MM-DD>] [--why <text>]
#   ac-task.sh unhold <id>
#   ac-task.sh update-note <id> <text>    # the row's BODY, off the line
#   ac-task.sh prune [--keep <n>]         # Done tail -> dated archive
#
# THREE PROPERTIES ARE THE POINT:
#
# 1. LOCKED ATOMIC WRITES. Every verb takes the advisory lock
#    `records/.backlog.md.lock` (ac_lock_acquire, AC_TASK_LOCK_TIMEOUT secs,
#    default 10), RE-READS the file inside it, and publishes by tmp+rename.
#    Several live sessions measurably write one ledger in a day and the
#    harness Edit path has no guard; a refused write changes nothing.
#
# 2. BODY OFF THE LINE. A row's narrative rides as INDENTED lines (two spaces)
#    directly under its bullet - the LINE stays the index, so AC_DONELINE_AWK
#    and every scheduler reading it are untouched, and a body is opaque to all
#    of them. The body moves with its row through start/done/prune, and a
#    replaced body is appended to `records/backlog-body-archive.md` rather
#    than dropped.
#
# 3. HOLD-UNTIL. `[@held until <YYYY-MM-DD>]` is the dated arm of the captain
#    hold: HELD before the date, READY on and after it, with no hand-edit to
#    release. The bare `[@held]` is unchanged and still needs a captain act.
#    A malformed date fails CLOSED (HELD) exactly like every other hold slip.
#
# RESIDUAL: `hold --why <text>` appends the reason as ordinary prose at the end
# of the line, where AGENTS.md section 9 puts it, and `unhold` removes the
# TOKEN only - the prose stays, because nothing on disk records which trailing
# words were the hold's. A chief that wants the stale reason gone edits it.
#
# HAND-EDITING STAYS LEGAL. This script owns no state of its own: it re-reads
# the file on every verb and tolerates rows nobody here wrote. Every verb is
# IDEMPOTENT - a re-run prints `already:` and writes nothing - and prints one
# receipt line per call.
#
# The chief-only fence is unchanged: a scoped session is refused by
# bin/ac-ledger-guard.sh whichever path it writes through.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

ledger="$(ac_records_dir)/backlog.md"
lockdir="$(ac_records_dir)/.backlog.md.lock"
today="$(date +%Y-%m-%d)"

usage() { awk 'NR>1{if(!/^#/)exit; print}' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

# --- ledger buffer ------------------------------------------------------------
L=()

load() {
  [ -f "$ledger" ] || ac_die "no ledger at $ledger"
  L=()
  local line
  while IFS= read -r line; do L+=("$line"); done <"$ledger"
}

save() {
  local tmp
  tmp="$(mktemp "$ledger.XXXXXX")"
  # mktemp makes the tmp 0600 and `mv` carries THAT mode onto the ledger, so a
  # bare tmp+rename silently tightens a world-readable record to owner-only
  # (measured: the live drydock ledger went 0644 -> 0600 on the first landing).
  # `cp -p` clones the real file's mode onto the tmp; `>` then rewrites the
  # content in place without touching it.
  cp -p "$ledger" "$tmp"
  printf '%s\n' "${L[@]+"${L[@]}"}" >"$tmp"
  mv "$tmp" "$ledger"
}

# hold_fields <line> - the row's hold state as THE grammar reads it, never a
# substring scan: fills HF_HOLD/HF_UNTIL/HF_MALFORMED from AC_DONELINE_AWK, so
# a prose quotation of the token (`[@held]` in a code span) is an ordinary row
# here exactly as it is to the scheduler.
hold_fields() {
  local out
  out="$(printf '%s\n' "$1" | awk "$AC_DONELINE_AWK"'
    { ac_doneline($0, o); printf "%s\t%s\t%s\n", o["hold"], o["hold_until"], o["hold_malformed"] }')"
  HF_HOLD="${out%%$'\t'*}"
  out="${out#*$'\t'}"
  HF_UNTIL="${out%%$'\t'*}"
  HF_MALFORMED="${out#*$'\t'}"
}

# split_hold <line> - the surgery half of what hold_fields judges: locate the
# AUTHORITATIVE hold token by walking the leading run of [...] groups after
# the id (a quoted or out-of-run shape is never found here, matching the
# parser's position rule), and split the line around it into SH_PRE/SH_GRP/
# SH_POST for a caller that strips or replaces it.
split_hold() {
  local l="$1" id rest scan grp
  case "$l" in '- [ ] '*) ;; *) return 1 ;; esac
  rest="${l#"- [ ] "}"
  id="${rest%% *}"
  [ "$id" != "$rest" ] || return 1
  scan="- [ ] $id"
  rest="${rest#"$id"}"
  while :; do
    case "$rest" in
      ' '*) scan="$scan "; rest="${rest# }"; continue ;;
      '['*) ;;
      *) return 1 ;;
    esac
    case "$rest" in *']'*) ;; *) return 1 ;; esac
    grp="${rest%%]*}]"
    case "$grp" in
      '[@held]'|'[@held until '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]']')
        SH_PRE="${scan% }"
        SH_GRP="$grp"
        SH_POST="${rest#"$grp"}"
        return 0 ;;
    esac
    scan="$scan$grp"
    rest="${rest#"$grp"}"
  done
}

# find_row <id> -> ROW_I (bullet), ROW_END (last body line), ROW_SEC
find_row() {
  local want="$1" i sec="" id rest n=${#L[@]}
  ROW_I=-1; ROW_END=-1; ROW_SEC=""
  for ((i = 0; i < n; i++)); do
    case "${L[$i]}" in
      '## In flight'*) sec=inflight; continue ;;
      '## Queued'*)    sec=queued;   continue ;;
      '## Done'*)      sec=done;     continue ;;
      '- [ ] '*) rest="${L[$i]#"- [ ] "}" ;;
      '- [x] '*) rest="${L[$i]#"- [x] "}" ;;
      *) continue ;;
    esac
    id="${rest%% *}"
    [ "$id" = "$want" ] || continue
    ROW_I=$i; ROW_SEC="$sec"
    break
  done
  [ "$ROW_I" -ge 0 ] || return 1
  ROW_END=$ROW_I
  while [ $((ROW_END + 1)) -lt "$n" ]; do
    case "${L[$((ROW_END + 1))]}" in '  '*) ROW_END=$((ROW_END + 1)) ;; *) break ;; esac
  done
}

section_head() {
  local want="$1" i n=${#L[@]}
  for ((i = 0; i < n; i++)); do
    case "$want:${L[$i]}" in
      'inflight:## In flight'*|'queued:## Queued'*|'done:## Done'*) printf '%s\n' "$i"; return 0 ;;
    esac
  done
  ac_die "ledger has no '$want' section"
}

# section_tail <name> - the index to insert a row AT so it lands LAST in the
# section: past its final row's body, before the blank line that separates it.
section_tail() {
  local head last i n=${#L[@]}
  head="$(section_head "$1")"
  last=$((head + 1))
  for ((i = head + 1; i < n; i++)); do
    case "${L[$i]}" in '## '*) break ;; esac
    [ -n "${L[$i]}" ] && last=$((i + 1))
  done
  printf '%s\n' "$last"
}

splice_in() { local at="$1"; shift; L=("${L[@]:0:$at}" "$@" "${L[@]:$at}"); }
splice_out() { local from="$1" count="$2"; L=("${L[@]:0:$from}" "${L[@]:$((from + count))}"); }

# --- line surgery -------------------------------------------------------------

stamp_since() {
  local l="$1" pre grp tail
  case "$l" in
    *", since "*) printf '%s\n' "$l"; return 0 ;;
    *"(repo: "*)
      pre="${l%%"(repo: "*}"
      tail="${l#*"(repo: "}"
      grp="${tail%%)*}"
      printf '%s(repo: %s, since %s)%s\n' "$pre" "$grp" "$today" "${tail#*)}" ;;
    *) printf '%s (since %s)\n' "$l" "$today" ;;
  esac
}

# --- archives -----------------------------------------------------------------

archive_body() {
  # archive_body <id> <line>... - the replaced body, kept rather than dropped.
  local id="$1"; shift
  local arc="$(ac_records_dir)/backlog-body-archive.md"
  { printf '\n## %s body replaced %s\n' "$id" "$today"; printf '%s\n' "$@"; } >>"$arc"
}

# --- verbs --------------------------------------------------------------------

cmd_add() {
  local id="${1:-}" text="${2:-}" contract="" repo="" viol line
  [ -n "$id" ] && [ -n "$text" ] || ac_die "usage: ac-task.sh add <id> <one-line> [--contract <tokens>] [--repo <name>]"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --contract) contract="${2:-}"; shift 2 ;;
      --repo) repo="${2:-}"; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  case "$id" in ''|*[!a-z0-9-]*) ac_die "invalid id '$id' - want [a-z0-9-]" ;; esac
  if [ -n "$contract" ]; then
    viol="$(ac_contract_lint "$contract")"
    [ -z "$viol" ] || ac_die "invalid contract: $viol"
  fi
  load
  if find_row "$id"; then printf 'already: %s exists in %s\n' "$id" "$ROW_SEC"; return 0; fi
  line="- [ ] $id"
  [ -n "$contract" ] && line="$line [$contract]"
  line="$line - $text"
  [ -n "$repo" ] && line="$line (repo: $repo)"
  splice_in "$(section_tail queued)" "$line"
  save
  printf 'ok: added %s to Queued\n' "$id"
}

cmd_start() {
  local id="${1:-}" i block=() spent=""
  [ -n "$id" ] || ac_die "usage: ac-task.sh start <id>"
  load
  find_row "$id" || ac_die "no row for '$id'"
  [ "$ROW_SEC" = queued ] || { printf 'already: %s is in %s\n' "$id" "$ROW_SEC"; return 0; }
  hold_fields "${L[$ROW_I]}"
  [ -z "$HF_MALFORMED" ] || ac_die "$id carries a malformed hold-shaped group - fix the line by hand (AGENTS.md section 9)"
  if [ -n "$HF_HOLD" ]; then
    # An EXPIRED dated hold is exactly what ac-ready offers as READY, so start
    # must take it; the spent token is stripped - the date WAS the release,
    # and a leftover [@held...] on an In-flight line would still read as
    # waiting-on-captain in every display.
    if [ -n "$HF_UNTIL" ] && [ ! "$HF_UNTIL" \> "$today" ]; then
      split_hold "${L[$ROW_I]}" || ac_die "internal: parser saw a hold that the leading-run walk cannot find on: ${L[$ROW_I]}"
      L[$ROW_I]="${SH_PRE}${SH_POST}"
      spent=" (hold until $HF_UNTIL expired - token stripped)"
    else
      ac_die "$id is held - release it before starting (AGENTS.md section 9)"
    fi
  fi
  for ((i = ROW_I; i <= ROW_END; i++)); do block+=("${L[$i]}"); done
  block[0]="$(stamp_since "${block[0]}")"
  splice_out "$ROW_I" $((ROW_END - ROW_I + 1))
  splice_in "$(section_tail inflight)" "${block[@]}"
  save
  printf 'ok: started %s (since %s)%s\n' "$id" "$today" "$spent"
}

cmd_done() {
  local id="${1:-}" outcome="${2:-}" verb=merged i block=()
  [ -n "$id" ] && [ -n "$outcome" ] || ac_die "usage: ac-task.sh done <id> <outcome> [--verb <verb>]"
  shift 2
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --verb) verb="${2:-}"; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  case "$verb" in ''|*[!a-z]*) ac_die "invalid --verb '$verb' - want a word like merged|reported" ;; esac
  load
  find_row "$id" || ac_die "no row for '$id'"
  [ "$ROW_SEC" != done ] || { printf 'already: %s is Done\n' "$id"; return 0; }
  for ((i = ROW_I; i <= ROW_END; i++)); do block+=("${L[$i]}"); done
  block[0]="- [x] ${block[0]#"- [ ] "} - $outcome ($verb $today)"
  splice_out "$ROW_I" $((ROW_END - ROW_I + 1))
  splice_in "$(($(section_head done) + 1))" "${block[@]}"
  save
  printf 'ok: %s %s (%s %s)\n' "$verb" "$id" "$verb" "$today"
}

cmd_hold() {
  local id="${1:-}" until="" why="" token line
  [ -n "$id" ] || ac_die "usage: ac-task.sh hold <id> [--until <YYYY-MM-DD>] [--why <text>]"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --until) until="${2:-}"; shift 2 ;;
      --why) why="${2:-}"; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  if [ -n "$until" ]; then
    case "$until" in
      [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) ;;
      *) ac_die "invalid --until date '$until' - want YYYY-MM-DD" ;;
    esac
    token="[@held until $until]"
  else
    token="[@held]"
  fi
  load
  find_row "$id" || ac_die "no row for '$id'"
  [ "$ROW_SEC" != done ] || ac_die "$id is Done - a hold schedules nothing"
  hold_fields "${L[$ROW_I]}"
  [ -z "$HF_MALFORMED" ] || ac_die "$id carries a malformed hold-shaped group - fix the line by hand before re-holding (AGENTS.md section 9)"
  line="${L[$ROW_I]}"
  if split_hold "$line"; then line="${SH_PRE}${SH_POST}"; fi
  line="- [ ] $id $token${line#"- [ ] $id"}"
  case "$line" in *" - $why"*) ;; *) [ -n "$why" ] && line="$line - $why" ;; esac
  [ "$line" != "${L[$ROW_I]}" ] || { printf 'already: %s holds %s\n' "$id" "$token"; return 0; }
  L[$ROW_I]="$line"
  save
  printf 'ok: held %s %s\n' "$id" "$token"
}

cmd_unhold() {
  local id="${1:-}"
  [ -n "$id" ] || ac_die "usage: ac-task.sh unhold <id>"
  load
  find_row "$id" || ac_die "no row for '$id'"
  hold_fields "${L[$ROW_I]}"
  [ -z "$HF_MALFORMED" ] || ac_die "$id carries a malformed hold-shaped group - fix the line by hand (AGENTS.md section 9)"
  if [ -z "$HF_HOLD" ]; then printf 'already: %s carries no hold\n' "$id"; return 0; fi
  split_hold "${L[$ROW_I]}" || ac_die "internal: parser saw a hold that the leading-run walk cannot find on: ${L[$ROW_I]}"
  L[$ROW_I]="${SH_PRE}${SH_POST}"
  save
  printf 'ok: released %s from %s\n' "$id" "$SH_GRP"
}

cmd_update_note() {
  local id="${1:-}" text="${2:-}" i old=() new=() line
  [ -n "$id" ] && [ -n "$text" ] || ac_die "usage: ac-task.sh update-note <id> <text>"
  load
  find_row "$id" || ac_die "no row for '$id'"
  for ((i = ROW_I + 1; i <= ROW_END; i++)); do old+=("${L[$i]}"); done
  while IFS= read -r line; do
    # A body line is opaque to the awk parsers (they anchor at column 0), but
    # the dashboard's parseBacklog matches `^\s*-\s+\[[ xX]\]` - an indented
    # checkbox AT ANY DEPTH would show up there as a PHANTOM ROW the scheduler
    # cannot see, so the check runs on the line with its own indent stripped.
    case "${line#"${line%%[![:space:]]*}"}" in '- ['*) ac_die "a body line may not start like a row ('$line') - the dashboard would read it as one" ;; esac
    new+=("  $line")
  done <<<"$text"
  if [ "${#old[@]}" = "${#new[@]}" ] && [ "${old[*]+"${old[*]}"}" = "${new[*]}" ]; then
    printf 'already: %s carries this body\n' "$id"; return 0
  fi
  [ "${#old[@]}" = 0 ] || archive_body "$id" "${old[@]}"
  splice_out "$((ROW_I + 1))" "${#old[@]}"
  splice_in "$((ROW_I + 1))" "${new[@]}"
  save
  printf 'ok: body updated on %s (%s line(s), %s archived)\n' "$id" "${#new[@]}" "${#old[@]}"
}

cmd_prune() {
  local keep=20 head i n seen=0 cut=-1 arc moved=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --keep) keep="${2:-}"; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  case "$keep" in ''|*[!0-9]*) ac_die "invalid --keep '$keep' - want a count" ;; esac
  load
  head="$(section_head done)"
  n=${#L[@]}
  # end = one past the Done section: the grammar puts Done last, but
  # hand-editing stays legal, so a section someone added after it must
  # survive a prune untouched rather than being swept into the archive.
  local end=$n
  for ((i = head + 1; i < n; i++)); do
    case "${L[$i]}" in '## '*) end=$i; break ;; esac
  done
  for ((i = head + 1; i < end; i++)); do
    case "${L[$i]}" in '- ['*) ;; *) continue ;; esac
    seen=$((seen + 1))
    if [ "$seen" -gt "$keep" ]; then cut=$i; break; fi
  done
  [ "$cut" -ge 0 ] || { printf 'already: Done holds %s row(s), keep is %s\n' "$seen" "$keep"; return 0; }
  arc="$(ac_records_dir)/backlog-archive-$today.md"
  [ -f "$arc" ] || printf '# backlog Done rows pruned %s\n' "$today" >"$arc"
  for ((i = cut; i < end; i++)); do
    case "${L[$i]}" in '- ['*) moved=$((moved + 1)) ;; esac
    printf '%s\n' "${L[$i]}" >>"$arc"
  done
  splice_out "$cut" $((end - cut))
  save
  printf 'ok: pruned %s Done row(s) into %s\n' "$moved" "$arc"
}

# --- dispatch -----------------------------------------------------------------

verb="${1:-}"
[ -n "$verb" ] || usage
case "$verb" in add|start|done|hold|unhold|update-note|prune) ;; *) usage ;; esac
shift

ac_lock_acquire "$lockdir" "${AC_TASK_LOCK_TIMEOUT:-10}" \
  || ac_die "records/backlog.md is locked by another writer - nothing written"
trap 'ac_lock_release "$lockdir"' EXIT

case "$verb" in
  add) cmd_add "$@" ;;
  start) cmd_start "$@" ;;
  done) cmd_done "$@" ;;
  hold) cmd_hold "$@" ;;
  unhold) cmd_unhold "$@" ;;
  update-note) cmd_update_note "$@" ;;
  prune) cmd_prune "$@" ;;
esac
