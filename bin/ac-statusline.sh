#!/usr/bin/env bash
# ac-statusline.sh - one-line fleet status for terminal status bars.
# wezterm's right-status calls this every few seconds, so it must stay
# fast: file reads only, no git, no network, no backend calls.
#
# Output: `⚓<fleet> <n>▶ <m>⚑[ WATCH!]`
#   <fleet> = basename of the home   <n> = crewmates in flight
#   <m>     = rooms pending on the captain (open GATE:/ASK: entries, counted
#             with the shared ac_room_pending - same accounting as
#             `ac-room.sh pending`, never a second copy of the grammar)
#   WATCH!  = crew in flight but the beacon of the watcher serving THIS
#             session is stale or missing - state/.last-watcher-beat, or
#             .last-watcher-beat.<fam> in a roomchief session (AC_SCOPE), so
#             a family watcher's death is never masked by the fleet's beat.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-wake-lib.sh"

fleet="$(basename "$(ac_home)")"
state="$(ac_state_dir)"

# ACCOUNTING count (n▶): verify panes are excluded, a chief self task is
# LISTED - the SELF-TASK contract in ac-lib.sh. One batched pass, no
# per-meta fork (ac_crew_metas, audit-f4).
inflight=0
while IFS= read -r m; do inflight=$((inflight + 1)); done \
  < <(ac_crew_metas "$state" verify)

# Same accounting as `ac-room.sh pending`, in-process: the shared
# ac_room_pending (ac-wake-lib.sh) keeps this on its no-fork budget while the
# grammar stays in ONE place. A local copy of it drifted once already.
# BATCHED: one call over the whole glob, not one per room - ac_room_pending
# already sums N files in a single awk pass (its own docstring), and rooms
# are never deleted, so a per-room fork would grow without bound on this
# hook that always runs (ac_room_handback_families is the same shape).
data_dir="$(ac_data_dir)"
set -- "$data_dir"/*/room.md
if [ -f "$1" ]; then
  pending="$(ac_room_pending "$@")"
else
  pending=0
fi

# WATCH! is ac_watcher_down's ONE definition (ac-wake-lib.sh), shared with
# ac-guard.sh's WATCHER-DOWN so the status bar and the guard can never
# disagree about the same fleet (audit-f4). Its in-flight set is the
# SUPERVISION set (self tasks owe no watcher), deliberately narrower than
# the accounting count rendered above.
warn=""
ac_watcher_down "$state" "${AC_SCOPE:-}" && warn=" WATCH!"

printf '⚓%s %s▶ %s⚑%s\n' "$fleet" "$inflight" "$pending" "$warn"
