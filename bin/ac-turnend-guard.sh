#!/usr/bin/env bash
# ac-turnend-guard.sh - "no turn ends blind" Stop-hook predicate (Claude Code).
#
# Wired as a Stop hook in .claude/settings.json. Blocks a turn end (exit 2 +
# reason on stderr) when the session would go blind: wakes IT must drain are
# pending, or the watcher serving it has a stale liveness beacon.
#
# Scoped (ac-lib.sh owns the keying): a roomchief (AC_SCOPE=<fam>) is judged
# on its OWN wake store (spool records + legacy queue file, ac_wake_pending)
# and its OWN family watcher's beacon; the fleet chief on its own store plus
# any ORPHAN family store it would drain (a live family's store belongs to
# its chief and never pins the fleet's turn).
#
# The queued-wake predicate is judged BEFORE the inflight gate on purpose:
# demoting the last chief leaves its orphaned wake pending exactly as the
# inflight count hits 0, so gating on the count first would end the turn
# blind on that wake.
#
# STANDING COVERAGE (remote-wired idle fleet): with ZERO crew in flight the
# guard still blocks when config/remote-poll is executable, THIS session
# holds the live session lock, and no live watcher beacon exists (absent or
# older than AC_GUARD_GRACE) - remote orders are wired but nothing is
# polling, so the lock holder must arm bin/ac-watch.sh (its idle mode keeps
# the poll slot running) before parking. Without the remote hook an idle
# fleet may park unwatched, exactly as before.
#
# RELATION TO ac-watch-autoarm.sh (the sibling Stop hook, asyncRewake): that
# one ARMS, this one OBJECTS. They are deliberately not merged and not
# coordinated: the harness runs Stop hooks in parallel, so on a genuinely
# uncovered turn end this guard may block once before the auto-arm has armed -
# which is correct, because at that instant the fleet IS blind. The next firing
# carries stop_hook_active and this guard stands down while the auto-arm keeps
# working. The `stop_hook_active -> exit 0` line below is therefore KEPT on
# purpose: measured on Claude Code 2.1.220 the harness admits nine blocking
# firings per chain, but blocking nine times would only repeat a message nobody
# can act on faster - the auto-arm is what actually restores coverage.
#
# Inert (exit 0) when: stop_hook_active is set in the hook payload (loop
# guard), this checkout is a linked worktree (crewmates do not guard), the
# .ac-crewdeputy-home marker exists, an UNSCOPED session does not hold the
# home lock (read-only - see the block below; a scoped roomchief is NOT
# exempted, it owns its store), or nothing is in flight and nothing is
# queued (except the standing-coverage rule above). Fails open on any
# missing dependency: a broken guard must never wedge the harness.
#
# Standing coverage is FLEET business: it can only fire for the unscoped
# lock-holding session, because a roomchief never holds the home lock and
# its watcher never polls remote (ac-watch.sh's slot needs an unscoped
# watcher). So a scoped session reaches its own scoped predicate below.
#
# LANDING-RECEIPT reminder (fleet only, additive): at an OTHERWISE-CLEAN turn
# end - past every wake and coverage predicate, so it masks none - the guard
# blocks (exit 2) when config/remote-mirror is chief/on and a NEW backlog Done
# line (since the last check) has a family with no landing-receipt stamp: a
# task landed but its Slack done-report may be unposted. It fires at most once
# per Done line (a seen-set of the current Done ids) and fails open on any
# missing dependency. The chief clears it by posting the report and running
# `ac-remote.sh done-stamp <family>`. See landing_receipt_check below.
#
# HANDBACK block (fleet only, additive, PERSISTENT): while any room sits in
# HANDBACK - a roomchief reported back and nobody demoted it or closed the
# room - the guard reports it on EVERY blocking turn end, not only an
# otherwise-clean one. HANDBACK is a PERSISTENT state while queued wakes, the
# standing-coverage remote-poll gap, and a stale watcher beacon are all
# TRANSIENT conditions, so a persistent state must be reported ALONGSIDE
# whatever else is firing instead of queueing behind it: the three earlier
# exit-2 sites (queued wakes, standing-coverage, stale-watcher-with-inflight)
# each append the same HANDBACK line before their own exit 2, and the
# otherwise-clean tail still blocks on it alone via handback_check. Absent
# this, a busy fleet - a wake queued at most turn ends, or a watcher beacon
# continuously stale - never reaches the otherwise-clean tail and a room can
# sit in HANDBACK indefinitely with nothing objecting (the incident this
# guards against: a real family that posted HANDBACK with its work merged and
# sat unclaimed for a day, caught by the captain,
# not the guard). This is a STATE check, so it catches the failure whatever
# the CAUSE (wake lost, wake ignored, chief forgot, a drain consumed into a
# backgrounded task nobody read) - a signal-side fix can only ever catch its
# own half. Unlike the landing-receipt reminder it is NOT fire-once: the
# property is "a room cannot sit in HANDBACK across turn ends with nothing
# objecting", and one dismissal would retire it. The chief clears it by one of
# THREE acts: `ac-teardown.sh <family>-chief` (demote) then `ac-room.sh
# close`, or - refusing the hand-back instead of accepting it - posting
# `HANDBACK-REFUSED:` to the room, which settles the obligation while the
# family stays open and the roomchief stays alive to work the remedy.
# stop_hook_active above already bounds repeated blocks. See handback_owed,
# handback_note and handback_check below.
#
# PARKED reminder (fleet only, additive, and the one check here that does NOT
# block): at the same otherwise-clean turn end, with NO family in flight, a
# captain inbox of 0 and NO READY item (bin/ac-ready.sh), the guard prints one
# JSON `systemMessage` on stdout and exits 0 - Claude Code parses hook JSON on
# exit 0 and shows systemMessage to the user, while only exit 2 / decision:block
# stops a turn (Claude Code hooks reference, code.claude.com/docs/en/hooks). It
# reminds the chief to /debrief and end the session; records/captain.md
# ("Standing: PARKED-RESTART") is the authority and says explicitly that this is
# chief discipline, NOT code-enforced - so a refusal here would be a bug. The
# READY condition is the narrowing the same day's standing order forces ("keep
# working the backlog while items remain"): a reminder that fires while work is
# startable says stop at exactly the wrong moment, so anything on the schedule -
# a STUCK line included - keeps it silent. See parked_reminder below.

set -uo pipefail
. "$(dirname "$0")/ac-lib.sh" 2>/dev/null || exit 0
. "$(dirname "$0")/ac-backend.sh" 2>/dev/null || exit 0
. "$(dirname "$0")/ac-wake-lib.sh" 2>/dev/null || exit 0

payload="$(cat 2>/dev/null || true)"
case "$payload" in *'"stop_hook_active":true'*) exit 0 ;; esac

home="$(ac_home 2>/dev/null)" || exit 0
[ -e "$home/.ac-crewdeputy-home" ] && exit 0

gd="$(git -C "$home" rev-parse --git-dir 2>/dev/null || true)"
gcd="$(git -C "$home" rev-parse --git-common-dir 2>/dev/null || true)"
[ -n "$gd" ] && [ "$gd" != "$gcd" ] && exit 0

state_dir="$home/state"

scope="${AC_SCOPE:-}"

# Session-lock exemption: when ANOTHER live session holds this home's lock,
# this session is READ-ONLY (it must not drain wakes or arm the fleet
# watcher - see ac-lock.sh), so blocking its turn end on fleet signals
# would demand exactly what the lock forbids. The holder is recognized by
# pid ancestry: the guard runs under the harness process the lock records.
#
# UNSCOPED sessions only. A roomchief never holds the home lock either
# (ac-lock.sh skips scoped sessions by design), but it is NOT read-only: it
# owns and drains its family's wake store. Exempting it would make its guard inert
# and let it end its turn blind on its own family's wakes - the very bug
# this scoping fixes, one level down. So a scoped session skips the
# exemption and goes on to its scoped predicate below.
lock="$state_dir/.session-lock"
holds_lock=0
if [ -z "$scope" ] && [ -f "$lock" ]; then
  holder="$(sed -n 's/^pid=//p' "$lock" | head -1)"
  if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
    p=$$; mine=0
    while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
      [ "$p" = "$holder" ] && { mine=1; break; }
      p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    done
    [ "$mine" = 1 ] || exit 0
    holds_lock=1
  fi
fi

# The turn-end coverage tally: a roomchief/crewdeputy supervises crew and is
# not itself crew-in-flight; verifier panes are supervised runtime but not
# crewmates; a chief SELF TASK owes no coverage (its pane holds a `tail -f`
# and no agent) and must never pin the chief's turn while it edits. Every
# other kind - ship/scout, and any unknown/absent kind, counted fail-safe -
# still counts (ac_crew_metas owns the classes; audit-f4).
inflight=0
while IFS= read -r meta; do inflight=$((inflight + 1)); done \
  < <(ac_crew_metas "$state_dir" verify self chiefs)
# Liveness of the watcher that serves THIS session (a roomchief reads its own
# family watcher's beat, never the fleet's). Standing coverage below reads the
# same value: it can only fire for an unscoped session, for which this IS the
# fleet beat.
# ac_watcher_beat_read owns the classification and the no-beat wording (and the
# survey of every other beacon reader); $beat is 0 in every no-beat state, so the
# fire condition below is byte-identical to the inline read it replaces.
beat="$(ac_watcher_beat_read "$state_dir" "$scope")"
beat_note="${beat#* }"; beat="${beat%% *}"
age=$(( $(date +%s) - beat ))

landing_receipt_check() {
  # LANDING-RECEIPT reminder: under
  # remote-mirror chief/on, a NEW backlog Done line (a `- [x]` line) whose
  # family has no landing-receipt stamp means a task landed but its Slack
  # done-report may be unposted. Remind (exit 2) and record every current Done
  # id as seen, so the SAME line fires at most once. FAIL-SAFE: any
  # missing/unreadable dependency -> record nothing, stay silent; a first run
  # with no seen-set seeds the baseline silently (nothing is "new" before a
  # baseline). FLEET session only - the backlog is the crewchief's, a roomchief
  # never edits it - which also avoids a seen-set race between scopes. Called
  # ONLY at an otherwise-clean turn end (past every wake and coverage
  # predicate), so it can never mask one. The stamp is set by the chief via
  # `ac-remote.sh done-stamp <family>` right after it posts the done-report.
  [ -z "$scope" ] || return 0
  case "$(ac_config_read remote-mirror off 2>/dev/null)" in
    chief|on) : ;;
    *) return 0 ;;
  esac
  local backlog seen stamp cur id fam owed
  backlog="$(ac_records_dir 2>/dev/null)/backlog.md"
  [ -f "$backlog" ] || return 0
  seen="$state_dir/.landing-seen"
  stamp="$state_dir/.landing-receipt-stamp"
  cur="$(awk '/^- \[x\] /{print $3}' "$backlog" 2>/dev/null)" || return 0
  # First encounter: seed the baseline and stay silent (nothing is "new" yet).
  if [ ! -f "$seen" ]; then
    printf '%s\n' "$cur" >"$seen.tmp.$$" 2>/dev/null \
      && mv "$seen.tmp.$$" "$seen" 2>/dev/null
    return 0
  fi
  owed=""
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    grep -qxF "$id" "$seen" 2>/dev/null && continue           # already seen
    fam="$(ac_family_of_id "$id" 2>/dev/null)" || continue
    [ -n "$fam" ] || continue
    [ -n "$(ac_meta_get "$stamp" "$fam" 2>/dev/null)" ] && continue   # stamped
    case " $owed " in *" $fam "*) ;; *) owed="$owed $fam" ;; esac
  done <<EOF
$cur
EOF
  # Record the current Done ids as seen BEFORE any block, so the same line
  # fires at most once even if the reminder is dismissed.
  printf '%s\n' "$cur" >"$seen.tmp.$$" 2>/dev/null \
    && mv "$seen.tmp.$$" "$seen" 2>/dev/null
  if [ -n "$owed" ]; then
    printf 'agent-crew: a task landed (backlog Done) but its Slack done-report may be unposted for:%s. Post it then stamp it (bin/ac-remote.sh done-stamp <family>) before ending the turn.\n' "$owed" >&2
    exit 2
  fi
  return 0
}

handback_owed() {
  # handback_owed - print the space-joined families still owed a HANDBACK
  # (empty if none), on stdout. FLEET session only - a roomchief that just
  # posted its own hand-back cannot clear it (it cannot demote itself, and
  # `ac-room.sh close` is fail-closed), so this must stay silent for a scoped
  # session or firing at any of its call sites below would wedge exactly the
  # turn that reports back.
  #
  # SHARED by handback_check (the otherwise-clean tail) and the three earlier
  # exit-2 sites (queued wakes, standing-coverage, stale-watcher-with-inflight)
  # via handback_note below - each turn end takes exactly one of those four
  # paths, so this still runs at most once per invocation, never twice.
  #
  # The HANDBACK grammar is NOT copied here: ac_room_handback_families
  # (ac-wake-lib.sh) owns it and answers for N rooms in ONE awk pass. That
  # batching is the point - this runs on EVERY fleet turn end and rooms are
  # never deleted (AGENTS.md section 8), so any per-room cost grows without
  # bound on the one hook that always runs. `ac-room.sh list` computes the
  # same state, but it is the whole-fleet lister (~5 forks per room, plus the
  # pending count and the last-entry column this needs none of, measured
  # ~2.0s at 180 rooms) and every other consumer of it - ac-fleets.sh,
  # ac-dash.sh, ac-session-start.sh - calls it ON DEMAND, never at each turn
  # end.
  #
  # FAIL-OPEN: no rooms at all (the glob matches nothing) and any failing read
  # alike print nothing.
  [ -z "$scope" ] || return 0
  local data owed
  data="$(ac_data_dir 2>/dev/null)" || return 0
  set -- "$data"/*/room.md
  [ -f "$1" ] || return 0                     # unmatched glob: no rooms yet
  owed="$(ac_room_handback_families "$@" 2>/dev/null | tr '\n' ' ')" || return 0
  printf '%s' "${owed% }"
}

handback_note() {
  # handback_note - print the HANDBACK reminder to stderr when any room is
  # owed one (return 0), else return 1 with nothing printed. Computes
  # handback_owed EXACTLY ONCE per call, and only one caller ever runs per
  # turn end (see handback_owed's comment), so the awk pass behind it still
  # runs at most once. ADDS a line, never replaces the caller's own message
  # and never exits itself, so it is safe to call right before an earlier
  # block's own exit 2 (queued wakes, standing-coverage,
  # stale-watcher-with-inflight) as well as from handback_check below.
  local owed
  owed="$(handback_owed)"
  [ -n "$owed" ] || return 1
  printf 'agent-crew: room(s) in HANDBACK - a roomchief reported back and is still waiting: %s. Demote it (bin/ac-teardown.sh <family>-chief) then close the room (bin/ac-room.sh close <family> <outcome>), or if you REFUSE the hand-back post HANDBACK-REFUSED: <why> (bin/ac-room.sh post <family> <actor> "HANDBACK-REFUSED: <why>") to keep the family open and the roomchief alive, before ending the turn.\n' "$owed" >&2
  return 0
}

handback_check() {
  # HANDBACK block (see header): a room whose last HANDBACK: entry is not yet
  # followed by DEMOTED:/CLOSED: is a roomchief still waiting to be demoted and
  # its room closed. Called at the otherwise-clean turn end, AFTER
  # landing_receipt_check: this block is persistent, so running it first would
  # starve that fire-once reminder of the run that records its seen-set. The
  # three earlier exit-2 sites report the SAME state via handback_note above
  # instead of waiting for this call, which is what makes the state reachable
  # on a busy fleet too - see the HANDBACK header block for why.
  handback_note && exit 2
  return 0
}

parked_reminder() {
  # PARKED reminder (see header): fleet only, judged LAST, and the one check
  # here that never blocks - it PROMPTS, it does not enforce.
  # Silence is the load-bearing direction, so every unreadable input returns
  # quietly: a wrong reminder tells the chief to stop mid-backlog.
  [ -z "$scope" ] || return 0
  local ready data queued
  ready="$("$(dirname "$0")/ac-ready.sh" 2>/dev/null)" || return 0
  [ -z "$ready" ] || return 0            # anything on the schedule: keep going
  # ac-ready.sh reads the FLEET backlog only, so a fleet holding assigned-but-
  # unpromoted crewdomain rows would read as "nothing READY" and this reminder
  # would tell the chief to END the session on top of queued work. Every other
  # domain-unaware consumer merely fails to SHOW something; this one's failure
  # is an ACTION, which is why it is fixed rather than named. Same helper the
  # `ac-domain.sh list` render uses - never a parse of that rendered block.
  queued="$(ac_domain_tally 2>/dev/null | awk '{ print $1 }')" || return 0
  [ "${queued:-0}" = 0 ] || return 0     # queued domain work: keep going
  data="$(ac_data_dir 2>/dev/null)" || return 0
  set -- "$data"/*/room.md
  if [ -f "$1" ]; then
    [ "$(ac_room_pending "$@" 2>/dev/null || printf 1)" = 0 ] || return 0
  fi
  printf '{"systemMessage":"agent-crew: the fleet is PARKED - nothing in flight, captain inbox 0, no READY item. Run /debrief and END this session (records/captain.md, Standing: PARKED-RESTART); the next order opens a fresh one."}\n'
}

# Queued wakes are judged per SCOPE, and BEFORE the inflight gate: demoting
# the LAST chief leaves its orphaned wake pending exactly as inflight hits 0,
# so exiting on the count first would end the turn blind on that wake. A
# roomchief is gated on its own wake store alone; the fleet on what IT drains -
# its own store, plus any orphan (a live family's store is its chief's).
if [ -n "$scope" ]; then
  queued=0
  ac_wake_pending "$state_dir" "$scope" 2>/dev/null && queued=1
else
  queued=0
  { ac_wake_pending "$state_dir" '' || ac_wake_orphan_pending "$state_dir"; } 2>/dev/null && queued=1
fi
if [ "$queued" = 1 ]; then
  printf 'agent-crew: queued wakes are pending. Run bin/ac-wake-drain.sh and handle them before ending the turn.\n' >&2
  handback_note
  exit 2
fi

if [ "$inflight" -eq 0 ]; then
  # STANDING COVERAGE (see header): remote orders wired + this session is
  # the live lock holder + no live watcher beacon -> an idle park would
  # leave the remote channel unpolled. Any other idle fleet stays exempt.
  # Reached only with nothing queued (the predicate above already exits 2),
  # and holds_lock is 0 for any scoped session, so this stays fleet business.
  if [ "$holds_lock" = 1 ] && [ -x "$home/config/remote-poll" ] \
    && [ "$age" -gt "${AC_GUARD_GRACE:-300}" ]; then
    printf 'agent-crew: remote orders are wired but nothing is polling - arm bin/ac-watch.sh as a background task (it stays up when idle).\n' >&2
    handback_note
    exit 2
  fi
  landing_receipt_check
  handback_check
  parked_reminder
  exit 0
fi

if [ "$age" -gt "${AC_GUARD_GRACE:-300}" ]; then
  printf 'agent-crew: %s crewmate(s) in flight but %s. Arm bin/ac-watch.sh as a background task before ending the turn.\n' \
    "$inflight" "${beat_note:-the watcher beacon is stale (${age}s)}" >&2
  handback_note
  exit 2
fi
landing_receipt_check
handback_check
exit 0
