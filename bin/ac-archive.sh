#!/usr/bin/env bash
# ac-archive.sh - move CLOSED task families out of the flat data/ namespace.
#
# AUTHORITATIVE for the archive layout and for which families are eligible.
# Where NEW artifacts are created is unchanged and stays owned by
# bin/ac-brief.sh's header: every brief/report/room is still born at
# data/<id>/ or data/<family>/<stage>/. This script only relocates families
# whose story is already over.
#
# Usage:
#   ac-archive.sh archive [--dry-run]        # move every CLOSED family
#   ac-archive.sh restore <family> [--dry-run]   # move one back, live again
#
# LAYOUT: an archived family becomes data/archive/<year>/<family>/, carrying
# its whole task dir verbatim (brief, report, room, nested stage dirs, gate
# artifacts). <year> is the year of the family's OWN last `CLOSED:` room entry -
# never the year the migration runs - so history groups by when it happened and
# re-running next year re-shards nothing.
#
# ELIGIBILITY - exactly one class moves:
#   - data/<family>/room.md contains a `CLOSED:` entry  -> ARCHIVE.
#   - room exists with no `CLOSED:`                     -> skipped, still open.
#   - no room.md at all (bare scouts, self-tasks)       -> skipped. Nothing on
#     disk says they are finished and guessing here loses data; whether they
#     should be archived is a captain question, not this script's.
#   - `CLOSED:` present but no resolvable year          -> REFUSED and named,
#     and the run exits 1. A refusal is never bucketed by a guess and never
#     passes silently.
# Learning run dirs (data/learning-<ts>/) and other roomless dirs are skipped by
# the same rule, with no special case. data/archive/ itself carries no room.md,
# so it can never select itself.
#
# MANUAL ONLY. Nothing in bin/, .agents/ or docs/ may invoke this script - not
# ac-curate.sh's CURATE-DUE auto-run, not ac-session-start.sh, not
# ac-wake-drain.sh. Moving hundreds of live directories is a deliberate act the
# crewchief performs when the fleet is quiet: ac-room.sh list, the turn-end
# guard and session-start all sweep data/ continuously, so a migration that can
# fire by itself defeats the split it exists for. tests/ac-archive.test.sh
# asserts the absence of any caller.
#
# IDEMPOTENT: a second run finds no eligible live family and says so. REVERSIBLE:
# `restore` moves a family back to its live path (refusing to clobber an
# existing live dir, and refusing a family that is not archived); an
# archive -> restore round trip is byte-identical.
#
# Reads stay correct across the move: ac_room_file (bin/ac-lib.sh) resolves a
# family's room live-first then archived, which is what keeps
# `ac-room.sh show <family>` and the Learning retro snapshot working on an
# archived family. The live-only data/*/room.md globs (the captain inbox, the
# turn-end guard, the statusline, the remote push) deliberately do NOT follow:
# every archived family is CLOSED, so it contributes no pending item and no
# hand-back to any of them.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

closed_year() {
  # closed_year <room-file> - the 4-digit year of the LAST `CLOSED:` entry,
  # empty when the room has no CLOSED: entry or no resolvable year on it.
  # Position-pinned to the room's own entry grammar (ac-room.sh's header):
  # `- [<iso>] <actor>> CLOSED: ...`, so a prose mention of CLOSED: inside a
  # message never sets the year.
  awk '
    /^- \[[0-9]{4}-/ && /^- \[[^]]*\] [^>]*> CLOSED:/ {
      y = substr($0, 4, 4)
    }
    END { if (y != "") print y }
  ' "$1"
}

cmd_archive() {
  local dry=0
  case "${1:-}" in
    --dry-run) dry=1 ;;
    '') ;;
    *) ac_die "usage: ac-archive.sh archive [--dry-run]" ;;
  esac

  local data dir fam room year dest moved=0 refused=0
  data="$(ac_data_dir)"
  for dir in "$data"/*/; do
    fam="$(basename "$dir")"
    [ "$fam" = archive ] && continue
    room="$data/$fam/room.md"
    [ -f "$room" ] || continue                       # no room: never guess
    grep -q '^- \[[^]]*\] [^>]*> CLOSED:' "$room" || continue   # still open
    year="$(closed_year "$room")"
    if [ -z "$year" ]; then
      printf 'refused  %s - CLOSED: entry carries no resolvable year\n' "$fam"
      refused=$((refused + 1))
      continue
    fi
    dest="$data/archive/$year/$fam"
    if [ -e "$dest" ]; then
      printf 'refused  %s - %s already exists\n' "$fam" "$dest"
      refused=$((refused + 1))
      continue
    fi
    if [ "$dry" = 1 ]; then
      printf 'would archive  %s -> archive/%s/%s\n' "$fam" "$year" "$fam"
    else
      mkdir -p "$data/archive/$year"
      mv "$data/$fam" "$dest"
      printf 'archived  %s -> archive/%s/%s\n' "$fam" "$year" "$fam"
    fi
    moved=$((moved + 1))
  done

  if [ "$dry" = 1 ]; then
    printf 'would archive %s family(ies); refused %s\n' "$moved" "$refused"
  else
    printf 'archived %s family(ies); refused %s\n' "$moved" "$refused"
  fi
  [ "$refused" = 0 ] || return 1
  return 0
}

cmd_restore() {
  local fam="${1:-}" dry=0
  [ -n "$fam" ] || ac_die "usage: ac-archive.sh restore <family> [--dry-run]"
  case "${2:-}" in
    --dry-run) dry=1 ;;
    '') ;;
    *) ac_die "usage: ac-archive.sh restore <family> [--dry-run]" ;;
  esac
  case "$fam" in *[!a-zA-Z0-9_-]*) ac_die "family must be [a-zA-Z0-9_-]: $fam" ;; esac

  local data src found=""
  data="$(ac_data_dir)"
  for src in "$data"/archive/*/"$fam"; do
    [ -d "$src" ] || continue
    found="$src"
    break
  done
  [ -n "$found" ] || ac_die "restore: $fam is not archived"
  [ -e "$data/$fam" ] && ac_die "restore: $data/$fam already exists - move it aside first"

  if [ "$dry" = 1 ]; then
    printf 'would restore  %s <- %s\n' "$fam" "${found#"$data"/}"
    return 0
  fi
  mv "$found" "$data/$fam"
  # Leave no empty <year> shell behind; rmdir only ever succeeds when the year
  # bucket really is empty, so a concurrent archive is never clobbered.
  rmdir "$(dirname "$found")" 2>/dev/null || true
  printf 'restored  %s\n' "$fam"
}

case "${1:-}" in
  archive) shift; cmd_archive "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  *) awk 'NR>1{if(!/^#/)exit; print}' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
