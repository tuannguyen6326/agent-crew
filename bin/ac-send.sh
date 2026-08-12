#!/usr/bin/env bash
# ac-send.sh - send one literal line (or a named key) to a crewmate pane.
#
# Usage: ac-send.sh <id> [--force] '<text>'
#        ac-send.sh <id> --key <Enter|Escape|C-c>
#
# Fail-closed, three ways:
# - refuses when the crewmate meta or window is missing, so a message can
#   never land in the wrong pane.
# - refuses TEXT into a BLOCKED pane (backend_agent_blocked: the agent sits
#   on an interactive prompt): typed text feeds the dialog, its trailing
#   Enter ACCEPTS whatever option is highlighted, and digit-selectable
#   options can reach a PERMANENT always-allow grant. Peek first, answer the
#   dialog deliberately with --key, or pass --force to send anyway. Keys
#   never need --force - --key IS the deliberate dialog answer.
# - TEXT delivery is verified (contract: ac-backend.sh delivery verification):
#   a send whose submit is never acknowledged exits non-zero with the reason
#   on stderr instead of reporting "sent to <target>" - and it names WHICH of
#   the two reasons it was, because the next move differs: text STRANDED in
#   the composer is resubmitted, while a pane that could not be READ leaves
#   the submit neither confirmed nor refuted and is peeked at first.
#
# --key is FOCUSED but UNVERIFIED, and says so. herdr's send-keys needs focus
# on the key path too, so the key is pressed on a focused tab - never blind.
# But a keypress has no reliable observable to probe: Escape on a pane with no
# dialog, C-c on an idle pane, or any key a TUI absorbs redraws nothing, so a
# render-change verdict there would be a coin flip, not evidence (the text
# path escapes this only because an accepted submit ALWAYS clears the
# composer). So no verdict is faked: --key reports
# `delivered (unverified) to <target>` and confirming the EFFECT is the
# caller's job (bin/ac-peek.sh). Its exit status is unchanged - non-zero only
# when the herdr CLI itself fails.
#
# --- the write-side marker guard (TEXT only) ----------------------------------
#
# Steer text lands VERBATIM in a pane the watcher greps, so a chief instructing
# a crewmate ABOUT the marker protocol wakes ITSELF with its own words - lived,
# in this fleet. Before delivering, the text is scanned for a bare marker verb
# (ac_bare_marker_verbs, ac-lib.sh - which owns the detection contract and is
# deliberately broader than AC_CAPTAIN_RE, since a mid-sentence marker phrase
# soft-wraps to visual column 0 and matches there). A hit prints ONE warning on
# stderr naming the offending token(s) and the two safe forms - backtick-wrap it
# (`done:`) or drop the trailing colon.
#
# It WARNS and DELIVERS, never refuses: steer text may legitimately quote a
# marker, and this is a footgun, not a policy. Exit status, stdout and the
# delivered bytes are all unchanged by it. The --key path is untouched - it
# carries no text to scan.
#
# A delivered steer - text or key - also clears the pane's CAPTAIN-WAIT STAMP (contract:
# ac-backend.sh) - the steer IS the answer the stamped pane was parked on;
# a fleet-stamped pane is NOT refused as blocked (the refusal above targets
# real interactive prompts only).
#
# --- the chief-order marker (routed orders to a crewdeputy) ----------------------
#
# AUTHORITATIVE for the marked chief-to-deputy channel. A crewdeputy is itself a
# chief with its own chat, which the crewchief never reads: unmarked, a routed
# order is indistinguishable from the captain typing into that pane, and the
# deputy cannot know whether its answer is owed to a human in the room or to a
# parent chief that will never look there. So when - and ONLY when - the target
# meta records kind=crewdeputy, the delivered line becomes:
#
#   [chief-order home=<parent-home-abs> deputy=<id>] <text>
#
# applied once, immediately before backend_send_line, so every refusal above
# runs first. Nothing else in the distro applies it: a captain typing into the
# pane, and a --key keystroke, stay UNMARKED and are therefore an explicit
# conversational intervention, not a routed order. The prefix cannot false-wake
# a watcher: AC_CAPTAIN_RE requires a marker VERB right after the tolerated
# prefix class, and `[chief-order ...]` is not one.
#
# Two refusals are added for a crewdeputy target, both BEFORE delivery, because
# an unmarked or misaddressed order is worse than a failed one:
# - the routing table has no parseable entry for the id, or its home: is gone -
#   the answer would have nowhere durable to land;
# - the parent home cannot be resolved - the marker cannot be constructed. In
#   practice the earlier `no crewmate meta` refusal already covers an
#   unresolvable home (the meta path resolves through it), so this is the
#   fail-closed floor rather than a distinct reachable case.
#
# A confirmed marked send appends `<iso> routed: <order>` to state/<id>.status,
# the parent's durable index of what it asked - so a restart is not amnesia.
# Every non-crewdeputy target is byte-unchanged: no marker, no status line.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-backend.sh"
[ ! -x "$(dirname "$0")/ac-guard.sh" ] || "$(dirname "$0")/ac-guard.sh" || true  # warn-only advisory

id="${1:-}"; shift || true
[ -n "$id" ] || ac_die "usage: ac-send.sh <id> [--force] '<text>' | --key <key>"
force=0
if [ "${1:-}" = "--force" ]; then force=1; shift; fi
[ -f "$(ac_task_meta "$id")" ] || ac_die "no crewmate meta for $id"
AC_BACKEND="$(ac_task_backend "$id")"; export AC_BACKEND
# Three-state liveness (contract: ac-backend.sh WINDOW LIVENESS): still fail-closed
# and still exit 1, but a backend that cannot be READ is not reported as a dead
# pane - the chief's next move is the backend, not a teardown.
alive_rc=0
backend_window_alive "$id" || alive_rc=$?
case "$alive_rc" in
  0) ;;
  2) ac_die "the BACKEND could not be read for $id - nothing was delivered, and the pane's liveness is UNKNOWN (it may well be alive); check the backend itself (herdr status server), then send again" ;;
  *) ac_die "window gone for $id" ;;
esac

if [ "${1:-}" = "--key" ]; then
  key="${2:-}"
  [ -n "$key" ] || ac_die "missing key name"
  backend_send_key "$id" "$key"
  verb='delivered (unverified) to'
else
  text="${1:-}"
  [ -n "$text" ] || ac_die "refusing to send an empty message"
  if [ "$force" = 0 ] && backend_agent_blocked "$id"; then
    ac_die "$id is BLOCKED on an interactive prompt - text would feed the dialog and its Enter would ACCEPT it (digit options can grant a permanent always-allow). Peek it (bin/ac-peek.sh $id), answer deliberately with ac-send.sh $id --key <key>, or override with ac-send.sh $id --force '<text>'"
  fi
  # WRITE-SIDE MARKER GUARD (contract: the header). Warn, deliver anyway.
  if bare_markers="$(ac_bare_marker_verbs "$text")"; then
    printf 'warning: this steer carries a bare marker verb (%s) - the watcher greps the pane TAIL, so your own words can wake you and stamp the pane (a mid-sentence marker soft-wraps to visual column 0 and matches). Backtick-wrap it (`done:`) or drop the trailing colon. Delivering anyway.\n' \
      "$(tr '\n' ' ' <<<"$bare_markers" | sed 's/ *$//')" >&2
  fi
  order="$text"
  marked=0
  if [ "$(ac_meta_get "$(ac_task_meta "$id")" kind)" = crewdeputy ]; then
    dep_home="$(ac_deputy_parse | awk -F'\t' -v i="$id" '$1 != "INVALID" && $2 == i { print $3; exit }')"
    [ -n "$dep_home" ] \
      || ac_die "$id is a crewdeputy with no parseable entry in $(ac_deputy_registry) - a routed order needs a home for its answer to land in; fix the registry line first"
    [ -d "$dep_home" ] \
      || ac_die "crewdeputy home is gone: $dep_home - fix or remove the registry line for $id before routing work to it"
    parent_home="$(ac_home)"
    [ -d "$parent_home" ] \
      || ac_die "cannot resolve the parent home for the chief-order marker - refusing to deliver an UNMARKED routed order"
    text="[chief-order home=$parent_home deputy=$id] $text"
    marked=1
  fi
  # Both failures refuse, but they are DIFFERENT facts and the captain's next
  # move differs (contract: ac-backend.sh delivery verification) - a strand is
  # resubmitted, an unreadable pane is peeked at first.
  send_rc=0
  backend_send_line "$id" "$text" || send_rc=$?
  case "$send_rc" in
    0) ;;
    2) ac_die "delivery UNVERIFIED for $id - the pane could not be read, so the submit was neither confirmed nor refuted (see stderr above)" ;;
    *) ac_die "delivery NOT confirmed for $id - the text likely sits stranded in the composer (see stderr above)" ;;
  esac
  if [ "$marked" = 1 ]; then ac_status_append "$id" "routed: $order"; fi
  verb='sent to'
fi
# A delivered steer answers a captain-wait: release the UI stamp HERE, which is
# where the timing is right. herdr re-adopts a released pane only on a state
# TRANSITION, and this steer supplies one (idle->working) - it is not the agent
# merely "reacting" that restores the view, so a release with no transition
# behind it leaves the pane out of the agents panel (contract: ac-backend.sh
# CAPTAIN-WAIT STAMP). No-op when the pane carries no stamp.
backend_clear_wait "$id" 2>/dev/null || true
printf '%s %s\n' "$verb" "$(backend_target "$id")"
