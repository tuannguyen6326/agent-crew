#!/usr/bin/env bash
# ac-home-seed.sh - provision a persistent crewdeputy home.
#
# Usage: ac-home-seed.sh <name> (--projects <p1,p2,...> | --no-projects)
#
# Creates $AC_HOME/crewdeputies/<name>/{state,data,config,projects}:
# - inherits the parent's config knobs (backend, crew-harness, launch-*,
#   crew-dispatch.json, herdr-session) by copying them; workspaces need no
#   knob at all - they resolve adopt-by-label per fleet (ac-backend.sh
#   FAMILY WORKSPACE GROUPING), so the crewdeputy's crew groups under its
#   own "<name>"-labelled workspaces automatically;
# - copies the fleet-wide CREWMATE.md when the parent keeps one;
# - seed-copies the parent's records/captain.md when present (captain style, so
#   the crewdeputy's captain-facing prose matches the fleet voice - one-time,
#   deputy-owned afterward, unlike the converged config knobs);
# - drops the .ac-crewdeputy-home marker (the turn-end guard skips crewdeputy homes);
# - seeds records/projects.md and records/backlog.md skeletons;
# - clones each requested project FROM the parent's clone (origin re-pointed
#   at the parent's origin URL, so the crewdeputy pushes to the real remote);
# - registers the home in the parent's records/crewdeputies.md, in the routing-
#   table grammar owned by ac-lib.sh, with an EMPTY scope: what work a deputy
#   owns is the chief's judgment, and a scopeless entry is never routed to.
#
# Spawn the crewdeputy afterwards with: ac-spawn.sh <name> --crewdeputy
# Refuses to overwrite an existing home.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
ac_require git

name="${1:-}"
shift || true
projects=""
no_projects=0
while [ $# -gt 0 ]; do
  case "$1" in
    --projects) projects="$2"; shift 2 ;;
    --no-projects) no_projects=1; shift ;;
    *) ac_die "unknown argument: $1" ;;
  esac
done
[ -n "$name" ] || ac_die "usage: ac-home-seed.sh <name> (--projects <p1,p2,...> | --no-projects)"
# A locale whose collation interleaves case (en_US.UTF-8: a,A,b,B,...,z,Z)
# makes a plain a-z range admit most uppercase letters through this glob -
# force C collation for the comparison (LC_ALL=C sort is the same idiom
# already used for `find`/`sort` elsewhere in this codebase).
(LC_ALL=C; case "$name" in *[!a-z0-9-]*) exit 1 ;; esac) || ac_die "name must be [a-z0-9-]: $name"
if [ "$no_projects" = 0 ] && [ -z "$projects" ]; then
  ac_die "pass --projects <p1,p2,...> or --no-projects explicitly"
fi

parent="$(ac_home)"
home_dir="$parent/crewdeputies/$name"
[ -e "$home_dir" ] && ac_die "home already exists: $home_dir"

# Validate requested projects against the parent's clones before touching disk.
requested=""
if [ "$no_projects" = 0 ]; then
  IFS=',' read -ra reqs <<<"$projects"
  for p in "${reqs[@]}"; do
    p="$(printf '%s' "$p" | tr -d ' ')"
    [ -n "$p" ] || continue
    [ -d "$parent/projects/$p/.git" ] || ac_die "parent has no clone at projects/$p"
    requested="$requested $p"
  done
fi

mkdir -p "$home_dir/state" "$home_dir/data" "$home_dir/records" "$home_dir/config" "$home_dir/projects"
: >"$home_dir/.ac-crewdeputy-home"

# Inherit config knobs. Workspace ids are deliberately absent from the list:
# the retired herdr-workspace* knobs are never read (ac-backend.sh FAMILY
# WORKSPACE GROUPING resolves workspaces adopt-by-label per fleet), so there
# is nothing to inherit and nothing to exclude. herdr-session IS inherited:
# the herdr server session is shared across homes.
for knob in backend crew-harness crew-dispatch.json herdr-session wedge-alarm captain flow promote; do
  [ -f "$parent/config/$knob" ] && cp "$parent/config/$knob" "$home_dir/config/$knob"
done
for launch in "$parent"/config/launch-*; do
  [ -f "$launch" ] && cp "$launch" "$home_dir/config/$(basename "$launch")"
done
[ -f "$parent/CREWMATE.md" ] && cp "$parent/CREWMATE.md" "$home_dir/CREWMATE.md"

# Seed data skeletons.
printf '# Projects\n\n' >"$home_dir/records/projects.md"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' >"$home_dir/records/backlog.md"

# Carry the captain's recorded style/preferences (records/captain.md) so the
# crewdeputy's captain-facing prose - room and remote narrative, the CLAUDE.md
# section 8 voice - matches the fleet from its first turn. Config knobs above
# stay CONVERGED (parent wins every session); this is a one-time SEED-COPY, like
# CREWMATE.md: the deputy owns the file afterwards and may add domain-local
# rules, so a later session never clobbers them. Absent parent copy -> the
# deputy starts without one, exactly as an unseeded fleet would.
pcaptain="$(ac_records_dir)/captain.md"
[ -f "$pcaptain" ] && cp "$pcaptain" "$home_dir/records/captain.md"

# Clone projects from the parent's clones; push targets stay the real origin.
cloned=""
for p in $requested; do
  git clone --quiet "$parent/projects/$p" "$home_dir/projects/$p"
  origin_url="$(git -C "$parent/projects/$p" remote get-url origin 2>/dev/null || true)"
  if [ -n "$origin_url" ]; then
    git -C "$home_dir/projects/$p" remote set-url origin "$origin_url"
  fi
  # Carry the parent's registry line (mode included) when it has one.
  reg_line="$(grep -E "^- $p \[" "$(ac_records_dir)/projects.md" 2>/dev/null | head -n1 || true)"
  printf '%s\n' "${reg_line:-- $p [crew-ship] - inherited from parent (added $(ac_iso))}" >>"$home_dir/records/projects.md"
  cloned="${cloned:+$cloned,}$p"
done

# Register with the parent fleet, in the routing-table grammar (ac-lib.sh's
# `crewdeputy routing table` block). Seeding cannot know the SCOPE - what work
# this deputy owns is the chief's judgment - so it writes the field EMPTY, which
# is exactly what makes the entry non-routable, and says so below. The charter
# is a self-describing placeholder for the same reason.
reg="$(ac_records_dir)/crewdeputies.md"
[ -f "$reg" ] || printf '# Crewdeputies\n\n' >"$reg"
printf -- '- %s - (charter unset - one line on what this crewdeputy is for) - home: %s - scope: - projects: %s (added %s)\n' \
  "$name" "$home_dir" "${cloned:-none}" "$(ac_iso)" >>"$reg"

printf '%s\n' "$home_dir"
ac_warn "seeded crewdeputy home $name; spawn with: ac-spawn.sh $name --crewdeputy"
ac_warn "fill in charter and scope: for $name in $reg - an entry with no scope: is never routed work"
