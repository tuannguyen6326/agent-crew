#!/usr/bin/env bash
# ac-watch-autoarm.sh - Stop-hook watcher continuity: the fleet re-arms its own
# watcher instead of the chief remembering to.
#
# Wired in .claude/settings.json as a Stop hook with "asyncRewake": true and an
# explicit timeout. Claude Code runs it in the BACKGROUND on every turn end and
# wakes the session when it exits 2, showing its stderr as a system reminder.
#
# WHY IT EXISTS - three failures this fleet already recorded, all with the same
# root (records/learnings.md):
#   - a second arm exits `already running`, so when the FIRST watcher
#     heartbeat-exits the chief is left blind with no notification (2026-07-16);
#   - `already running` is not proof of coverage: an externally-killed watcher
#     leaves a stale lock that false-positives every re-arm (2026-07-16);
#   - a watcher can be killed externally, and the recorded remedy is "after ANY
#     watcher task ends, check the exit reason and re-arm" (2026-07-16).
# Every one of them ends in "and then the chief must remember". This hook is
# what remembers.
#
# MEASURED CONTRACT (Claude Code 2.1.220, probed directly 2026-07-26 in an
# isolated sandbox - these are observations, not documentation claims, and the
# published docs DISAGREE with two of them):
#   1. Stop hooks fire in headless (`claude -p`) runs too, payload carries
#      `stop_hook_active`.
#   2. A blocking Stop hook is admitted NINE times per turn chain (one with
#      stop_hook_active=false, then eight with true) before Claude stops
#      anyway. The docs say the SECOND block is ignored; on 2.1.220 it is not.
#   3. `stop_hook_active` is true on EVERY firing after the first block in a
#      chain - which is exactly why ac-turnend-guard.sh's `stop_hook_active ->
#      exit 0` line means the synchronous guard blocks at most ONCE per chain
#      even though the harness would admit nine.
#   4. `asyncRewake: true` works: the hook runs detached, exit 2 wakes the
#      session, and its stderr reaches the model (observed: the model answered
#      the probe's stderr text).
#   5. Each firing gets its OWN process group, so the hook's timeout takes the
#      whole tree - including a watcher started in its foreground - with it.
#
# WHAT IT DOES. While supervision is owed, run bin/ac-watch.sh in the
# FOREGROUND of this hook-owned process tree and translate how it closed:
#   heartbeat        -> re-arm silently and keep going. This is the whole
#                       point: a heartbeat costs the chief nothing instead of
#                       one wake plus one re-arm turn every AC_HEARTBEAT.
#   already running  -> someone else holds the singleton; exit 0, stay out.
#                       A config-swap REFUSAL says the same thing (a LIVE
#                       watcher holds the lock, with another config) and stands
#                       aside too - never "supervision is NOT covered".
#   anything else    -> print that reason to stderr and exit 2, which wakes the
#                       chief with the reason already in front of it.
# The loop is bounded by AC_AUTOARM_BUDGET (default 3000s, under the hook
# timeout) and ends in exit 2 as well, so coverage is handed back to a live
# chief rather than lapsing silently when the budget runs out.
#
# EVERY ARM THIS HOOK MAKES IS MARKED BOUNDED (AC_AUTOARM=1, recorded by
# ac-watch.sh in its lock dir). The watcher dies with this firing, so a CHIEF
# arming by hand must not be told `already running` and stand its own - durable -
# arm aside for it: measured 2026-08-06, the chief's arm reported coverage at T+0
# and that same watcher was retired by the budget handback 2.5s later, leaving the
# turn-end guard to block on a stood-down beacon. ac-watch.sh's Singleton block
# owns the refusal; the flag is only how it can tell the two owners apart, and it
# does not change what THIS hook reads (a firing standing aside from a
# predecessor's watcher still gets the `already running` prefix it globs on).
#
# THE ARM ENV is reconstructed on every pass, exactly as the chief would set it
# by hand (AGENTS.md section 7): a SCOPED roomchief session arms with
# AC_WATCH_ONLY=<its watch set> (ac-ready.sh watch-set), an UNSCOPED crewchief
# session with AC_WATCH_SKIP=<the promoted families>. Arming the fleet watcher
# UNSKIPPED puts BOTH watchers on a promoted family's panes, and they share the
# per-id dedup marker - so that family's wake lands in whichever spool won the
# race rather than the one its roomchief drains.
# SOURCE OF THE PROMOTED SET: the state/<fam>-chief.meta files with
# kind=roomchief - the same metas ac-spawn.sh counts against the room-parallel
# cap and ac-room.sh reads to decide a room is promoted, so no second predicate
# is invented here, and a demote (the meta goes) drops the family at the next
# re-arm. Meta PRESENCE is deliberately the whole test: ac-watch.sh REVALIDATES
# every skip on every poll (roomchief window liveness, beacon freshness, busy
# declaration) and covers the family directly the moment its scoped coverage is
# down - so this hook owes it a cheap list, never a liveness probe that could
# hang inside the Stop hook.
#
# NEVER `&`, `nohup` or `disown` here: the point is that the watcher lives
# INSIDE the hook's process tree, which the harness owns and reaps.
#
# SCOPE (mirrors ac-turnend-guard.sh, which owns the reasoning): a genuine
# primary checkout of a fleet home, never a crewmate's linked worktree, never a
# crewdeputy home, and for an UNSCOPED session only when this session's harness
# ancestor holds the home lock - a read-only session must not arm the fleet
# watcher. A scoped roomchief does not hold that lock and is not read-only, so
# it arms its own family watcher with the watch set recomputed here, exactly as
# its charter tells it to do by hand.
#
# ROLLBACK. Suspecting this hook is enough to back it out - no captain approval
# needed, the standing authorization and the symptom list are in
# records/captain.md ("ROLLBACK ROUTE FOR THE WATCHER AUTO-ARM HOOK",
# 2026-07-26). In short: confirm with `printf '{}' | bin/ac-watch-autoarm.sh;
# echo rc=$?` (rc=0 and silent means the hook declined this turn and is not your
# problem), then LEVEL 1 - delete the Stop block naming this script from
# .claude/settings.json, which takes effect at the next turn end and leaves this
# file and its test in place; LEVEL 2, only if the code is actually wrong,
# `git revert` the commit that added it. EITHER WAY, arm the watcher by hand
# afterwards (AGENTS.md section 7) - this hook is what was remembering.
#
# Fails open (exit 0) on every missing dependency. A broken continuity hook must
# leave the fleet exactly as it found it, never wedge the harness.
# Exit codes: 0 nothing owed / someone else covers / broken dependency,
#             2 wake the chief, reason on stderr.

set -uo pipefail
cat >/dev/null 2>&1 || true          # drain the payload; nothing here reads it

bin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$bin_dir/ac-lib.sh" 2>/dev/null || exit 0

home="$(ac_home 2>/dev/null)" || exit 0
[ -e "$home/.ac-crewdeputy-home" ] && exit 0

gd="$(git -C "$home" rev-parse --git-dir 2>/dev/null || true)"
gcd="$(git -C "$home" rev-parse --git-common-dir 2>/dev/null || true)"
[ -n "$gd" ] && [ "$gd" != "$gcd" ] && exit 0

state_dir="$home/state"
[ -d "$state_dir" ] || exit 0
scope="${AC_SCOPE:-}"

# Unscoped sessions arm the FLEET watcher, which belongs to the lock holder.
# Ancestry, not pid equality: this hook runs under the harness the lock records.
if [ -z "$scope" ]; then
  lock="$state_dir/.session-lock"
  if [ -f "$lock" ]; then
    holder="$(sed -n 's/^pid=//p' "$lock" | head -1)"
    if [ -n "$holder" ] && kill -0 "$holder" 2>/dev/null; then
      p=$$; mine=0
      while [ -n "$p" ] && [ "$p" -gt 1 ] 2>/dev/null; do
        [ "$p" = "$holder" ] && { mine=1; break; }
        p="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
      done
      [ "$mine" = 1 ] || exit 0
    fi
  fi
else
  # SCOPED: the same ownership question the unscoped branch asks, asked for a
  # roomchief. Without it a scoped hook outlives its own family - MEASURED: an
  # arm logged `target=only:<family>` ten minutes after that family was demoted
  # and its room closed, still alive at 7m42s, its chain rooted in another
  # autoarm rather than a pane. The reason it kept arming is that crew_in_flight
  # below globs the WHOLE home: any other family's crewmate answers "supervision
  # is owed", so a dead family's hook re-arms for its own corpse for as long as
  # the fleet has any crew at all. The chief meta is the family's liveness -
  # ac-teardown.sh archives it at demotion - so its absence is the stand-down.
  [ -f "$state_dir/$scope-chief.meta" ] || exit 0
fi

crew_in_flight() {
  # The crew half of owed() below, named so the budget-handback message can
  # tell it apart from the standing remote-poll half.
  local meta
  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || continue
    case "$(ac_meta_get "$meta" kind)" in roomchief|crewdeputy) continue ;; esac
    ac_meta_is_verify "$meta" && continue
    # A chief SELF TASK holds a `tail -f`, not an agent (ac_meta_is_self owns
    # the class): arming a watcher for it would cover a pane that can never
    # emit a captain marker.
    ac_meta_is_self "$meta" && continue
    return 0
  done
  return 1
}

owed() {
  # Supervision is owed while any crew pane is in flight, or - fleet only -
  # while the remote transport is wired, whose standing coverage is the same
  # rule ac-turnend-guard.sh enforces at a turn end.
  crew_in_flight && return 0
  [ -z "$scope" ] && [ -x "$home/config/remote-poll" ] && return 0
  return 1
}

promoted_families() {
  # The PROMOTED families of this home, comma-joined, as AC_WATCH_SKIP wants
  # them (see THE ARM ENV in the header for why this is the source).
  local m fam out=""
  for m in "$state_dir"/*-chief.meta; do
    [ -e "$m" ] || continue
    [ "$(ac_meta_get "$m" kind)" = roomchief ] || continue
    fam="${m##*/}"; fam="${fam%-chief.meta}"
    out="$out${out:+,}$fam"
  done
  printf '%s\n' "$out"
}

owed || exit 0

budget="${AC_AUTOARM_BUDGET:-3000}"
started="$(date -u +%s)"

# Every arm below is BOUNDED, and ac-watch.sh has to be able to say so. The
# watcher runs in the FOREGROUND of this firing (never `&`/nohup - see the
# header) and dies with it, at the budget handback below or at the harness
# timeout; a chief's hand arm is a harness background task and carries no such
# bound. Without this flag ac-watch.sh answers a chief's re-arm `already
# running` for a watcher this hook is about to retire, and the chief parks on a
# turn nothing covers (behavior: rearm-stands-aside-for-a-watcher-that-then-exits).
# It also keeps THIS hook on its own untouched path: an arm carrying AC_AUTOARM
# still reads `already running` from a predecessor firing's watcher and stands
# aside, so the prefix classification below is unchanged.
export AC_AUTOARM=1

while owed; do
  # A roomchief watches its own family plus its epic's in-flight stories, and
  # the set changes as stories start and land - so it is recomputed on every
  # re-arm, which is the same instruction the roomchief charter gives a human.
  if [ -n "$scope" ]; then
    AC_WATCH_ONLY="$("$bin_dir/ac-ready.sh" watch-set "$scope" 2>/dev/null)" || AC_WATCH_ONLY="$scope"
    export AC_WATCH_ONLY
  else
    # The crewchief half of the same reconstruction, and recomputed for the same
    # reason: a family promoted or demoted since the last pass must change the
    # very next arm.
    AC_WATCH_SKIP="$(promoted_families)"
    export AC_WATCH_SKIP
  fi

  # The reason line is the classifier, NEVER the exit status: every ac-watch.sh
  # close prints it on stdout (ac-watch.sh:565 - stderr is the arm log and
  # "NEVER stdout") and its REFUSALS print one too while exiting 2. Erasing the
  # output on a non-zero status made every refusal arrive empty, i.e. read as a
  # watcher that died mute.
  reason="$("$bin_dir/ac-watch.sh" 2>/dev/null)" || true
  reason="$(printf '%s\n' "$reason" | sed '/^$/d' | tail -n 1)"

  case "$reason" in
    heartbeat)
      # Silent re-arm - the tokenless half of this hook.
      [ "$(( $(date -u +%s) - started ))" -lt "$budget" ] || break
      continue ;;
    'already running'*|'refused: a live watcher'*)
      # The chief armed one by hand, or a previous hook still holds it. The
      # config-swap refusal (ac-watch.sh:879) is the SAME branch and the same
      # fact - the lock is held by a LIVE watcher, a dead or stale one having
      # been reclaimed first - only with a different AC_WATCH_SKIP, which the
      # chief sets inline on its own arm and this hook therefore never sees.
      # Coverage is in place; nagging the chief to release it is not this
      # hook's job. A refusal that armed NOTHING (the owner gate at
      # ac-watch.sh:846-855) is not covered and stays in the `*)` arm.
      exit 0 ;;
    '')
      # No reason line at all: the watcher could not arm or died mute. Hand it
      # back rather than spinning on it.
      printf 'ac-watch-autoarm: the watcher closed with no reason line - supervision is NOT covered; arm it yourself (bin/ac-watch.sh) and check state/.watch.lock.d\n' >&2
      exit 2 ;;
    *)
      printf 'ac-watch-autoarm: %s\n' "$reason" >&2
      printf 'ac-watch-autoarm: drain it (bin/ac-wake-drain.sh); the watcher is re-armed automatically at your next turn end.\n' >&2
      exit 2 ;;
  esac
done

# Budget spent with nothing to report, or nothing left to supervise. When work
# is still in flight the chief must know coverage stopped here - naming the
# branch that actually fired, never unconditionally "crew", since owed() can
# also be true with zero crew in flight on the standing remote-poll branch
# (a chief burned two turns hunting crew that did not exist, 2026-08-01).
if crew_in_flight; then
  printf 'ac-watch-autoarm: auto-arm budget spent with crew still in flight - coverage handed back; it re-arms at your next turn end.\n' >&2
  exit 2
elif owed; then
  printf 'ac-watch-autoarm: auto-arm budget spent with standing remote-poll coverage still owed (no crew in flight) - coverage handed back; it re-arms at your next turn end.\n' >&2
  exit 2
fi
exit 0
