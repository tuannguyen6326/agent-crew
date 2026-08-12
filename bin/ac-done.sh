#!/usr/bin/env bash
# ac-done.sh - the agent-side PUSH of a completion. AUTHORITATIVE for the push
# contract; ac-watch.sh's PUSH CHANNEL block owns the watcher half.
#
# Usage: ac-done.sh <id> <marker>
#
# An agent runs this the moment it announces `done:` / `blocked:` /
# `needs-decision:` / `failed:` (or a roomchief its hand-back), so its chief's
# harness wakes in tens of milliseconds instead of waiting for the watcher's
# next poll tick (0-15s, ~7.5s on average). The PRINTED marker line stays
# exactly as it is: the pane is the BACKUP channel, and ac-watch.sh stays the
# BACKUP WATCHER that catches an agent which crashed or forgot to announce.
#
# Two acts, in this order, and the first is the one that matters:
#
#  1. PUBLISH one durable wake record through ac_wake_publish - the agent-side
#     mirror of ac-watch.sh's queue_wake: the same record format, the same
#     kind (`report`), and the same spool keying (ac_wake_spool_path /
#     ac_wake_scope_ok own it, and nothing here re-derives it), so every
#     drain, gate and tally handles a pushed wake with no new case. Published
#     from THIS shell, never a subshell - $$ is ac_wake_publish's collision
#     identity (its header states why), and this is the fourth producer to
#     obey that. A publish that did not happen DIES loudly (exit 1): the dedup
#     stamp below has already advanced by then, so swallowing the failure
#     would lose the completion with no trace and no retry - queue_wake's own
#     comment block is the same rule from the watcher's side.
#
#  2. NUDGE the watcher covering that spool through ac_watcher_nudge - the
#     shared mechanism, which ac-wake-lib.sh's WATCHER NUDGE block owns
#     authoritatively (ac-room.sh's hand-back is the other caller): it ends the
#     watcher's poll wait early, under a wrong-kill guard, and stays silent
#     when there is no watcher armed, when the recorded pid is dead or REUSED,
#     or when the watcher is mid-poll with no sleep to end - the record simply
#     waits in the spool for the next drain (or the 15s backup tick). That is
#     the correct QUIET outcome, never an error: the push is an accelerator,
#     the record is the guarantee.
#
# DEDUP - one completion, ONE wake. The pane carries the same completion, so
# the push stamps the watcher's OWN marker dedup before publishing:
#   - state/.seen-<id> = the marker, so the poll that later reads that line
#     off the pane recognises it as already announced and publishes no second
#     record (ac-watch.sh's marker_seen also accepts the pane's TUI-glyph
#     rendering of this same line).
#   - state/.seen-hash-<id> is REMOVED, never faked: it is the pane-tail hash
#     recorded AT A WAKE, and an agent cannot know it. A stale one from an
#     earlier wake would make the watcher's re-wake branch fire on this
#     marker's first poll - the very duplicate this exists to prevent - while
#     its ABSENCE is what tells the watcher to adopt the pane silently (the
#     PUSH ADOPT branch there).
#
# CHANNEL - a crewmate has no AC_HOME, deliberately (ac-spawn.sh:184-191), so
# it cannot resolve state/ the ordinary way. Two NARROW SCALARS on the
# crewmate launch line carry exactly the knowledge this script needs and
# nothing more, mirroring AC_FLEET_MODEL/AC_FLEET_EFFORT, which were added for
# this same "crewmate has no AC_HOME" class of problem:
#   AC_FLEET_STATE - absolute path of the fleet's state/ dir (the spool to
#                    write AND the watcher lock to read both live there).
#   AC_FLEET_SCOPE - the family whose scoped watcher supervises this task,
#                    empty/absent for fleet-scoped work.
# An agent that DOES have a home (a chief running this by hand) resolves
# state/ the ordinary way; the scope stays the scalar's alone, never AC_SCOPE
# - a roomchief's own session scope is not the scope of the wakes ABOUT it
# (its <fam>-chief pane is fleet-scoped by charter), and the fleet spool is
# the catch-all in every unclear case.
# The PATH to this script travels in the brief, not the environment
# (ac-brief.sh bakes it into every brief's signal block, the ac-qa.sh idiom) -
# a third scalar would carry knowledge the brief already carries.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-wake-lib.sh"

id="${1:-}"
marker="${2:-}"
[ -n "$id" ] && [ -n "$marker" ] || ac_die "usage: ac-done.sh <id> <marker>"

state_dir="${AC_FLEET_STATE:-$(ac_state_dir)}"
[ -d "$state_dir" ] || ac_die "fleet state dir not found: $state_dir (AC_FLEET_STATE)"
scope="${AC_FLEET_SCOPE:-}"

# Dedup FIRST: the stamp must be on disk before the record can wake anyone, or
# the poll that answers this very push could still read the pane as new news.
printf '%s\n' "$marker" >"$state_dir/.seen-$id"
rm -f "$state_dir/.seen-hash-$id"

# Main shell, never a subshell (ac_wake_publish's collision identity).
ac_wake_publish "$state_dir" "$scope" report "$id" "$marker" \
  || ac_die "wake NOT published for $id - the completion is not durable; say so in the pane"

printf 'pushed %s scope=%s - %s\n' "$id" "${scope:-fleet}" "$(ac_watcher_nudge "$state_dir" "$scope")"
