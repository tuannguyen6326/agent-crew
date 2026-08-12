#!/usr/bin/env bash
# ac-scene.sh - the L2 SCENE store: one consolidated, heat-tracked topic file
# between L1 (repo-knowledge facts, learnings bullets) and L3 (the always-loaded
# CREWMATE-learned layer).
#
# Usage:
#   ac-scene.sh new    <slug> --summary <line> [--file <path>]   (body on stdin)
#   ac-scene.sh update <slug> [--summary <line>] [--file <path>] (body on stdin)
#   ac-scene.sh merge  <src>... --into <slug> --summary <line> [--file <path>]
#   ac-scene.sh show   <slug> [--cite]
#   ac-scene.sh list
#   ac-scene.sh -h | --help
#
# WHY IT EXISTS: the fleet had L0 (data/<family>/room.md), L1 (repo-knowledge +
# the learnings ledger) and L3 (CREWMATE-learned.md), and NOTHING between L1 and
# L3. Measured on drydock 2026-08-09: knowledge too cross-cutting for one
# repo-knowledge line and too big for the 4096-byte always-loaded budget had
# nowhere to consolidate, so it stayed flat - 1677 Pending bullets/800KB before
# rotation, 487 facts with no topic view - and re-entering a topic meant
# re-deriving it from dozens of L1 lines every time. A scene is that missing
# read: ONE file that restores a topic's working context.
#
# PULL, NEVER PUSH - the load-bearing difference from CREWMATE-learned: a scene
# is read on purpose (intake, recall, a chief orienting), never seeded into a
# crew worktree and never auto-loaded into any prompt. That is why a scene takes
# the repo-knowledge TRUST TIER (a chief may write one by hand, like
# `ac-know.sh add`) instead of the always-loaded layer's gate tier: nothing it
# says enters a context that did not ask for it. A consumer treats scene content
# as EVIDENCE to cite, never as instructions to obey.
#
# THE STORE: $AC_HOME/records/scenes/<slug>.md, slug [a-z0-9][a-z0-9-]*.
# Four fixed head lines, then free markdown:
#
#   # Scene: <slug>
#   META: created=<iso> updated=<iso> heat=<n>
#   summary: <one line - what this scene restores context for>
#   <blank>
#   <body>
#
# `summary:` is the cheap index `list` and any recall verb rank against without
# opening bodies, so it is single-line and refuses newline/CR/`|` exactly as
# ac-know.sh's fields do (the same record-injection posture). The body is capped
# at 16384 bytes: a scene over that is two scenes, or one that needs a harder
# consolidation - and the cap is what keeps a recall budget meaningful.
#
# HEAT is TOUCHES, not edits: `show --cite` (+1), `update` (+1), and `merge`
# (sum of every merged scene, +1). It answers ONE question - which scene to
# merge away first - and a read-count answers it better than an edit-count,
# which is why this differs from the design it is ported from. A never-touched
# scene is the coldest by construction, the same floor an absent `heat:` gives
# an ac-know.sh entry.
#
# THE TIERED CAP is the whole reason this store cannot rot into a second flat
# pile. `config/scene-max` (default 30) caps the FILE COUNT, and the tier
# changes which verbs are legal:
#
#   count <  max-1   GREEN   every verb
#   count == max-1   AMBER   `new` refuses - one slot left is not a slot
#   count >= max     RED     `new` refuses AND names the 3 coldest scenes
#                            (lowest heat, then oldest updated) plus the exact
#                            merge command shape
#
# `update` and `merge` are legal at EVERY tier - the pressure must always have
# an exit. Nothing auto-merges and nothing is ever deleted: `merge` moves each
# source scene VERBATIM to records/scenes/scenes-archive/<slug>.md (the
# skills-archive convention), so consolidation is recoverable and the machine
# never destroys a judgment it did not make.
#
# WRITER SYMMETRY: the DISTILL transaction lands `kind: scene` candidates by
# CALLING THESE VERBS, never by writing the files itself, so the tier and the
# lock bind the machine writer exactly as they bind a hand. Every write is
# atomic (tmp+mv) under records/scenes/.lock; a refused lock writes nothing.
#
# Exit: 0 ok; non-zero on any refusal (each names what is wrong).

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

usage() {
  # Printed from the header's own Usage block, by PATTERN: a hardcoded line
  # range silently drifts the moment a verb is added above it.
  sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
}

reject() { ac_die "scene rejected: $*"; }

SCENE_BODY_MAX=16384

assert_slug() {
  case "${1:-}" in
    '') reject "no slug given" ;;
    [a-z0-9]*[!a-z0-9-]*|*[!a-z0-9-]*) reject "slug must match [a-z0-9][a-z0-9-]* (got: '$1')" ;;
    [!a-z0-9]*) reject "slug must start with [a-z0-9] (got: '$1')" ;;
  esac
}

assert_summary() {
  # The summary is an INDEX line: it must stay one physical line, and it must
  # not carry the `|` other records use as a field separator, so a future
  # tabular reader of `list` can never be spoofed by a summary's own text.
  local v="${1:-}"
  [ -n "$v" ] || reject "--summary is required and must be non-empty"
  case "$v" in
    *$'\n'*|*$'\r'*) reject "--summary must be a single line (no newline or carriage return)" ;;
    *"|"*) reject "'|' cannot appear in --summary (it is the field separator of the records it sits beside)" ;;
  esac
}

scene_dir() { local r; r="$(ac_records_dir)" || return 1; printf '%s\n' "$r/scenes"; }
scene_file() { printf '%s\n' "$(scene_dir)/$1.md"; }
scene_archive_dir() { printf '%s\n' "$(scene_dir)/scenes-archive"; }

scene_meta() {
  # scene_meta <file> <key> - one META field, or empty. The META line is the
  # second physical line by construction, but this reads it by NAME so a later
  # field addition cannot shift what an existing caller sees.
  local f="$1" k="$2"
  [ -f "$f" ] || return 0
  sed -n '2p' "$f" | tr ' ' '\n' | sed -n "s/^$k=//p" | head -1
}

scene_summary() {
  [ -f "$1" ] || return 0
  sed -n '3s/^summary: //p' "$1"
}

scene_count() { ls "$(scene_dir)"/*.md 2>/dev/null | wc -l | tr -d ' '; }

scene_coldest() {
  # scene_coldest <n> - the n scenes to merge away first: lowest heat, then
  # oldest `updated`. Printed as `<slug> (heat <n>, updated <iso>)` lines.
  local n="$1" f slug heat upd
  for f in "$(scene_dir)"/*.md; do
    [ -f "$f" ] || continue
    slug="$(basename "$f" .md)"
    heat="$(scene_meta "$f" heat)"; upd="$(scene_meta "$f" updated)"
    printf '%s\t%s\t%s\n' "${heat:-0}" "${upd:-}" "$slug"
  done | sort -t"$(printf '\t')" -k1,1n -k2,2 | head -"$n" \
    | while IFS="$(printf '\t')" read -r heat upd slug; do
        printf '  %s (heat %s, updated %s)\n' "$slug" "$heat" "$upd"
      done
}

assert_new_allowed() {
  # The TIER gate, and it guards `new` ONLY - update/merge must stay legal at
  # every tier or the pressure has no exit and the store wedges.
  local max n
  max="$(ac_config_read scene-max 30)"
  case "$max" in ''|*[!0-9]*) ac_die "config/scene-max must be a count (got: '$max')" ;; esac
  n="$(scene_count)"
  if [ "$n" -ge "$max" ]; then
    ac_die "scene store is FULL at the cap ($n/$max, config/scene-max) - merge before adding. Coldest first:
$(scene_coldest 3)
  ac-scene.sh merge <slug-a> <slug-b> --into <slug-a> --summary '<line>' --file <body>"
  fi
  if [ "$n" -eq $((max - 1)) ]; then
    ac_die "scene store is one slot from the cap ($n/$max, config/scene-max) - update an existing scene or merge two, rather than spending the last slot. Coldest first:
$(scene_coldest 3)"
  fi
}

read_body() {
  # read_body <file-flag> - the scene body, from --file or stdin, capped. A
  # body is never composed here: the caller owns the prose, this owns the
  # invariant.
  local ff="${1:-}" body
  if [ -n "$ff" ]; then
    [ -f "$ff" ] || ac_die "--file does not exist: $ff"
    body="$(cat "$ff")"
  else
    body="$(cat)"
  fi
  [ -n "$body" ] || reject "the scene body is empty (a scene with no body is a summary, not a scene)"
  if [ "$(printf '%s' "$body" | wc -c | tr -d ' ')" -gt "$SCENE_BODY_MAX" ]; then
    reject "the scene body exceeds its ${SCENE_BODY_MAX}-byte cap - split it into two scenes, or consolidate harder (a cap keeps a recall budget meaningful)"
  fi
  printf '%s\n' "$body"
}

scene_write() {
  # scene_write <slug> <created> <heat> <summary> <body-file> - atomic compose.
  local slug="$1" created="$2" heat="$3" summary="$4" bodyf="$5" f tmp
  f="$(scene_file "$slug")"
  mkdir -p "$(dirname "$f")"
  tmp="$f.tmp.$$"
  {
    printf '# Scene: %s\n' "$slug"
    printf 'META: created=%s updated=%s heat=%s\n' "$created" "$(ac_iso)" "$heat"
    printf 'summary: %s\n\n' "$summary"
    cat "$bodyf"
  } >"$tmp"
  mv "$tmp" "$f"
}

scene_lock() {
  local d; d="$(scene_dir)"; mkdir -p "$d"
  ac_lock_acquire "$d/.lock" 30 || ac_die "scene store lock $d/.lock could not be acquired within 30s - nothing written"
}
scene_unlock() { ac_lock_release "$(scene_dir)/.lock"; }

cmd_new() {
  local slug="${1:-}"; shift || true
  local summary="" ff=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --summary) summary="${2:-}"; shift 2 ;;
      --file) ff="${2:-}"; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  assert_slug "$slug"; assert_summary "$summary"
  local bodyf; bodyf="$(mktemp)"; read_body "$ff" >"$bodyf"
  scene_lock
  [ -e "$(scene_file "$slug")" ] && { rm -f "$bodyf"; scene_unlock; ac_die "scene '$slug' already exists - use \`update\` (a new scene never silently replaces one)"; }
  # The tier is read INSIDE the lock: two concurrent writers must not both see
  # the same free slot.
  if ! assert_new_allowed; then rm -f "$bodyf"; scene_unlock; return 1; fi
  scene_write "$slug" "$(ac_iso)" 1 "$summary" "$bodyf"
  rm -f "$bodyf"; scene_unlock
  printf 'created %s (heat 1)\n' "$(scene_file "$slug")"
}

cmd_update() {
  local slug="${1:-}"; shift || true
  local summary="" ff="" have_summary=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --summary) summary="${2:-}"; have_summary=1; shift 2 ;;
      --file) ff="${2:-}"; shift 2 ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  assert_slug "$slug"
  [ "$have_summary" -eq 0 ] || assert_summary "$summary"
  local bodyf; bodyf="$(mktemp)"; read_body "$ff" >"$bodyf"
  scene_lock
  local f; f="$(scene_file "$slug")"
  [ -f "$f" ] || { rm -f "$bodyf"; scene_unlock; ac_die "no scene '$slug' to update - \`new\` creates one"; }
  local created heat
  created="$(scene_meta "$f" created)"; heat="$(scene_meta "$f" heat)"
  [ "$have_summary" -eq 1 ] || summary="$(scene_summary "$f")"
  scene_write "$slug" "${created:-$(ac_iso)}" "$(( ${heat:-0} + 1 ))" "$summary" "$bodyf"
  rm -f "$bodyf"; scene_unlock
  printf 'updated %s (heat %s)\n' "$f" "$(( ${heat:-0} + 1 ))"
}

cmd_merge() {
  local into="" summary="" ff="" srcs="" s
  while [ $# -gt 0 ]; do
    case "$1" in
      --into) into="${2:-}"; shift 2 ;;
      --summary) summary="${2:-}"; shift 2 ;;
      --file) ff="${2:-}"; shift 2 ;;
      -*) ac_die "unknown flag: $1" ;;
      *) srcs="$srcs $1"; shift ;;
    esac
  done
  assert_slug "$into"; assert_summary "$summary"
  [ -n "$srcs" ] || reject "merge needs at least one source scene (merge <src>... --into <slug>)"
  for s in $srcs; do assert_slug "$s"; done
  local bodyf; bodyf="$(mktemp)"; read_body "$ff" >"$bodyf"
  scene_lock
  # Validate EVERY source before moving any: a half-done merge would leave the
  # store claiming a consolidation that never happened.
  local heat=0 h created="" f
  for s in $srcs; do
    f="$(scene_file "$s")"
    [ -f "$f" ] || { rm -f "$bodyf"; scene_unlock; ac_die "merge source '$s' does not exist - nothing moved"; }
  done
  for s in $srcs; do
    f="$(scene_file "$s")"
    h="$(scene_meta "$f" heat)"; heat=$(( heat + ${h:-0} ))
    # The merged scene inherits the OLDEST creation date it absorbs: the topic
    # is as old as the earliest thing that knew about it.
    c="$(scene_meta "$f" created)"
    if [ -z "$created" ] || { [ -n "$c" ] && [ "$c" \< "$created" ]; }; then created="$c"; fi
  done
  # `--into` may be one of the sources (the common shape: fold b into a). Its
  # heat is already counted above, so archive it like any other source and let
  # the write below re-create it.
  mkdir -p "$(scene_archive_dir)"
  local moved=""
  for s in $srcs; do
    mv "$(scene_file "$s")" "$(scene_archive_dir)/$s.md"
    moved="$moved $s"
  done
  # An --into that was NOT a source must not already exist unmerged.
  if [ -e "$(scene_file "$into")" ]; then
    scene_unlock; rm -f "$bodyf"
    ac_die "--into '$into' exists and was not among the merged sources - name it as a source, or pick a fresh slug (sources already archived: $moved)"
  fi
  scene_write "$into" "${created:-$(ac_iso)}" "$(( heat + 1 ))" "$summary" "$bodyf"
  rm -f "$bodyf"; scene_unlock
  printf 'merged%s into %s (heat %s); sources archived verbatim in %s\n' \
    "$moved" "$(scene_file "$into")" "$(( heat + 1 ))" "$(scene_archive_dir)"
}

cmd_show() {
  local slug="${1:-}"; shift || true
  local cite=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --cite) cite=1; shift ;;
      *) ac_die "unknown flag: $1" ;;
    esac
  done
  assert_slug "$slug"
  local f; f="$(scene_file "$slug")"
  [ -f "$f" ] || ac_die "no scene '$slug' (ac-scene.sh list shows the store)"
  if [ "$cite" -eq 1 ]; then
    # The bump rides the READ, exactly as ac-know.sh cite does: a counter left
    # to a second deliberate act is a counter nobody keeps.
    scene_lock
    local created heat summary bodyf
    created="$(scene_meta "$f" created)"; heat="$(scene_meta "$f" heat)"
    summary="$(scene_summary "$f")"
    bodyf="$(mktemp)"; tail -n +5 "$f" >"$bodyf"
    scene_write "$slug" "${created:-$(ac_iso)}" "$(( ${heat:-0} + 1 ))" "$summary" "$bodyf"
    rm -f "$bodyf"; scene_unlock
  fi
  cat "$f"
}

cmd_list() {
  local d f slug heat upd n max
  d="$(scene_dir)"
  max="$(ac_config_read scene-max 30)"
  n="$(scene_count)"
  [ "$n" -gt 0 ] || { printf 'no scenes yet in %s (0/%s)\n' "$d" "$max"; return 0; }
  printf 'scenes: %s/%s in %s\n' "$n" "$max" "$d"
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    slug="$(basename "$f" .md)"
    heat="$(scene_meta "$f" heat)"; upd="$(scene_meta "$f" updated)"
    printf '  %s  heat=%s  updated=%s  %s\n' "$slug" "${heat:-0}" "${upd:-}" "$(scene_summary "$f")"
  done
}

case "${1:-}" in
  new) shift; cmd_new "$@" ;;
  update) shift; cmd_update "$@" ;;
  merge) shift; cmd_merge "$@" ;;
  show) shift; cmd_show "$@" ;;
  list) shift; cmd_list "$@" ;;
  -h|--help|"") usage ;;
  *) ac_die "unknown verb: $1" ;;
esac
