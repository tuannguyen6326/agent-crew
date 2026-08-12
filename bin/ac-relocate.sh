#!/usr/bin/env bash
# ac-relocate.sh <id> [--family <fam> | --root] - move a live task window to
# another herdr workspace WITHOUT losing its claude session: close the old
# tab, recreate it in the target workspace, resume the recorded session_id
# there, and tell the agent to pick up where it left off (a roomchief is also
# told to re-arm its family watcher, which died with the old tab).
#
# Target (FAMILY WORKSPACE GROUPING, ac-backend.sh header): default is the
# task's OWN family workspace (ac_window_family from the id - the healing
# move for a tab stranded in the wrong space); --family <fam> names another
# family's workspace; --root targets the fleet ROOT workspace. The workspace
# is resolved adopt-by-label (created when absent), never from a knob - the
# per-role group knobs are retired.
# Refuses, fail-closed: unknown task, non-herdr backend (a stale meta
# has no window groups), missing session_id (nothing to resume - respawn
# instead), agent not idle (never kill a pane mid-write). Already in the
# target workspace = no-op success.
#
# Both steers are DIAGNOSED, never a bare errexit abort, and they split on what
# their failure costs: an undelivered RESUME line means nothing was resumed, so
# it dies; an undelivered NOTICE fails after the tab was recreated, the meta
# updated and the session already resumed, so it WARNS - a fatal there would
# skip the status append and leave the fleet's durable record blind to a
# relocation that really happened.
#
# Knobs: AC_SPAWN_SETTLE (seconds before the follow-up notice; default 8).

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-backend.sh"

id="${1:-}"
[ -n "$id" ] || ac_die "usage: ac-relocate.sh <id> [--family <fam> | --root]"
shift
fam_flag=""; root=0
while [ $# -gt 0 ]; do
  case "$1" in
    --family) fam_flag="${2:-}"; [ -n "$fam_flag" ] || ac_die "--family needs a value"; shift 2 ;;
    --root) root=1; shift ;;
    *) ac_die "unknown flag: $1 (usage: ac-relocate.sh <id> [--family <fam> | --root])" ;;
  esac
done
[ "$root" = 1 ] && [ -n "$fam_flag" ] && ac_die "--family and --root are mutually exclusive"

meta="$(ac_task_meta "$id")"
[ -f "$meta" ] || ac_die "no such task in flight: $id"
AC_BACKEND="$(ac_task_backend "$id")"
export AC_BACKEND
[ "$AC_BACKEND" = herdr ] || ac_die "relocate is herdr-only; backend of $id is $AC_BACKEND"
ac_require herdr jq

kind="$(awk -F= '$1=="kind"{print $2}' "$meta")"
sid="$(awk -F= '$1=="session_id"{print $2}' "$meta")"
dir="$(awk -F= '$1=="worktree"{print $2}' "$meta")"
[ -n "$sid" ] || ac_die "no session_id recorded for $id - cannot resume; respawn instead"
[ -n "$dir" ] || ac_die "no worktree recorded for $id"

# Resolve the target workspace by label (never a knob): --root = the fleet
# ROOT workspace, --family = that family's, default = the id's own family
# through the scope ladder (ac_window_family) - except a crewdeputy, whose
# home is fleet-level and defaults to root.
if [ "$root" = 1 ]; then fam=""
elif [ -n "$fam_flag" ]; then fam="$fam_flag"
elif [ "$kind" = crewdeputy ]; then fam=""
else fam="$(ac_window_family "$id")"; fi
label="$(herdr_ws_family_label "$fam")"
ws="$(herdr_resolve_workspace "$label")"
[ -n "$ws" ] || ac_die "could not resolve herdr workspace '$label'"
group="${fam:-root}"

pane="$(herdr_pane "$id")"
tab="$(herdr_tab "$id")"
[ -n "$pane" ] && [ -n "$tab" ] || ac_die "no window handle for $id"
if [ "${tab%%:*}" = "$ws" ]; then
  printf '%s already in group %s (workspace %s)\n' "$id" "$group" "$ws"
  exit 0
fi

status="$(herdr_cli tab get "$tab" | jq -r '.result.tab.agent_status // "unknown"')"
case "$status" in
  idle|done) : ;;
  *) ac_die "agent of $id is '$status' - relocate only an idle window (never kill a pane mid-write)" ;;
esac

herdr_cli tab close "$tab" >/dev/null 2>&1 || ac_warn "old tab $tab already gone"
out="$(herdr_tab_create "$ws" "$dir" "$id")" || ac_die "herdr tab create failed (workspace $ws)"
newtab="$(jq -r '.result.tab.tab_id // empty' <<<"$out")"
newpane="$(jq -r '.result.root_pane.pane_id // empty' <<<"$out")"
[ -n "$newtab" ] && [ -n "$newpane" ] || ac_die "could not parse herdr tab create output"
herdr_close_default_tabs "$ws"
printf '%s %s\n' "$newpane" "$newtab" >"$(ac_pane_file "$id")"
ac_meta_set "$meta" window "herdr:pane-$newpane"

resume="claude --resume $sid"
notice="Notice: your window was relocated to the $group workspace ($ws) - same session, nothing lost. Continue where you left off."
if [ "$kind" = roomchief ]; then
  fam="$(awk -F= '$1=="project"{print $2}' "$meta")"
  resume="AC_SCOPE=$(printf '%q' "$fam") $resume"
  notice="Notice: your window was relocated to the $group workspace ($ws) - same session, nothing lost. Your family watcher died with the old tab: re-arm it as a background task (AC_WATCH_ONLY=\$(bin/ac-ready.sh watch-set $fam) bin/ac-watch.sh - recompute the set each re-arm so an epic keeps covering its in-flight story panes), then continue."
elif [ "$kind" = crewdeputy ]; then
  resume="AC_HOME=$(printf '%q' "$dir") $resume"
fi

settle="${AC_SPAWN_SETTLE:-8}"
case "$settle" in ''|*[!0-9.]*|*.*.*) ac_die "AC_SPAWN_SETTLE must be a number: $settle" ;; esac
backend_send_line "$id" "$resume" \
  || ac_die "resume line NOT delivered to $id (see stderr above) - the session was never resumed; the new tab exists, so re-send it by hand: bin/ac-send.sh $id '$resume'"
sleep "$settle"
backend_send_line "$id" "$notice" \
  || ac_warn "relocation notice NOT delivered to $id (see stderr above) - the session IS resumed, so re-send it only if the agent looks confused: bin/ac-send.sh $id '$notice'"

ac_status_append "$id" "working: relocated to $group ($ws)"
printf 'relocated %s group=%s window=herdr:pane-%s\n' "$id" "$group" "$newpane"
