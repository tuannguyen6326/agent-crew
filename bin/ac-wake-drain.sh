#!/usr/bin/env bash
# ac-wake-drain.sh - atomically drain queued wakes, report unacknowledged
# crewmate completions, and assert watcher liveness.
#
# Usage: ac-wake-drain.sh
#        ac-wake-drain.sh ack <id> [<id>...]
#
# Prints each queued wake as `<kind> <id> <payload>`, then the unacknowledged
# completions of the tasks in this session's scope, then a `WATCHER-DOWN`
# warning when crew is in flight but the liveness beacon is stale. Run at
# session start and whenever the harness is woken.
#
# Each wake line may be followed by ONE indented `  status <id>: <text>`
# context line (annotate_wakes owns the rules): a `report` carries its marker
# in the payload, but `stale`/`ended`/`gone`/`ask` carry little or nothing, so
# the chief had to read the task before it knew what it was looking at - and
# that round-trip is time the crewmate spends parked. The wake line itself is
# byte-identical and printed first, the context is bounded, skipped when the
# payload already says it, and skipped entirely when the status is missing or
# unreadable, so nothing that parses `<kind> <id> <payload>` is affected.
#
# Scope (ac-lib.sh owns the keying and the store contract): a session drains
# the wakes of its OWN scope - a roomchief (AC_SCOPE=<fam>) takes
# state/.wake-spool.<fam>/ and nothing else; the fleet chief takes
# state/.wake-spool/. That isolation is the point: neither can consume the
# other's wakes.
#
# The spool is drained by claiming each RECORD with an atomic per-record
# rename - NEVER the container, which is permanent (that is what makes a
# producer's `ln` unable to fail ENOENT; ac-lib.sh owns that contract).
# Records emit in lexical filename order = producer-stamp order (the DECIDED
# ordering contract, ac-lib.sh).
#
# Fleet orphan fallback: a family whose roomchief is NOT LIVE (backend window
# dead, or its chief meta archived by teardown) cannot drain its own wakes,
# so the fleet chief drains that family's spool IN PLACE with the same
# primitive - a demoted family's wakes are never stranded. A LIVE family is
# skipped. The atomic per-record rename is the no-double-drain backstop:
# whoever renames first emits, the other finds nothing - concurrent drainers
# can SPLIT a spool's records, but each record is emitted exactly once IN THE
# NORMAL PATH. Across a drainer that dies mid-claim, the guarantee weakens to
# AT-LEAST-once: sweep_dead_claims (below) returns a dead claimer's records to
# the spool so a lost wake is never silently swallowed, but it cannot tell "died
# before emitting" from "died right after emitting, before its claim dir was
# removed" - so the same record can be re-emitted and the chief sees it twice.
# Deliberate: a duplicate wake costs a re-read, a lost one costs the completion
# itself, so the sweep fails toward DUPLICATION, never toward loss.
#
# Each session judges the watcher that serves IT: the WATCHER-DOWN beat is
# read from state/.last-watcher-beat[.<fam>] per scope, through
# ac_watcher_beat_read (ac-wake-lib.sh), which owns what each no-beat state means -
# an ABSENT beacon (nothing ever armed here) reads differently from the 0 a
# watcher writes on every exit (routine: drain and re-arm), because the two
# demand opposite responses.
#
# Ride-alongs after the drain, FLEET ONLY (a scoped roomchief drain runs none of
# them - they are all fleet-wide side effects): the queued-work scheduler
# (`ac-ready.sh`); - when the remote transport is configured (executable
# config/remote-poll hook) - `ac-remote.sh push-pending`, best-effort, so NEW
# captain-pending gates/asks reach the remote channel at every drain
# (push-pending itself dedups by stamp and batches one message per family
# thread); and `ac-learn.sh autoroom`, the DISTILL auto-trigger, which opens the
# cap-exempt `learning` room when a distill run is OWED. That third one is
# fleet-only for the sharpest version of the same reason: promoting a roomchief
# is the crewchief's act, and a scoped session's AC_SCOPE would leak into the
# spawn. Every drain is a landing checkpoint, so this is also what makes the
# trigger LEVEL-triggered rather than dependent on the crossing wake - and it
# gives session-start the same trigger for free, since the digest runs a drain.
#
# UNACKNOWLEDGED COMPLETIONS (the staged-flow blindness hotfix, 2026-07-20).
# A wake is a one-shot: a marker deduped away, a wake published into the wrong
# scope's spool during a scoped-watcher gap, or a stage that printed no marker
# at all leaves a FINISHED crewmate nobody learns about. So the drain ALSO
# reports completions from durable evidence, every pass, until acked. It rides
# HERE because the turn-end guard already forces a chief to run the drain
# before ending a turn - no new habit, and no change to the watcher's
# wake/dedup logic. PURELY ADDITIVE: it never consumes, suppresses or reorders
# a wake, and the drain's exit status is untouched.
#
# Per live `state/<id>.meta` in scope, two channels, artifact first:
#   ARTIFACT  - `report.md` in the id's data dir (ac_task_dir resolves the
#               ac-brief.sh layout; the suffix grammar is never re-implemented
#               here) exists and is NEWER than the ack stamp.
#   IDLENESS  - only for a task with NO report artifact (an implement mid-run):
#               the pane signals the watcher already computes - `.change-<id>`
#               quiet past ${AC_STALE:-240}s, a captured tail matching neither
#               AC_BUSY_RE nor AC_CAPTAIN_RE, and `.change-<id>` newer than the
#               ack stamp. Every backend call is guarded: a pane that cannot be
#               captured is simply not reported, never a failed drain.
#               It re-reads the watcher's OWN stamp, so it also applies the
#               watcher's OWN role suppressions - the two CHIEF-QUIET predicates
#               of ac-wake-lib.sh (ac_chief_gate_parked / ac_chief_child_live, which
#               own the reasoning): a `<fam>-chief` parked at the captain or
#               supervising a live family task is EXPECTED quiet, and reporting
#               it here would resurrect a wake the watcher deliberately DECLINED
#               to emit - once per drain, forever, since acking it settles
#               nothing (the chief's own ack output is the pane change that
#               makes `.change-<id>` newer than the stamp again).
# The reported lines deliberately match NO AC_CAPTAIN_RE marker - they are
# printed into a chief's own pane, which a watcher polls.
#
# ACK: `ac-wake-drain.sh ack <id>...` touches `state/.ack-<id>` - the ONLY new
# writer, and the only write outside the wake store. Nothing acks implicitly:
# a plain drain NEVER stamps, because auto-acking would recreate the very bug
# (an item seen once and lost forever). Scope mirrors the wake scoping above:
# a roomchief reports only its own family's ids, the fleet chief the rest -
# ids whose family has no LIVE roomchief, plus the `<family>-chief` panes,
# which are fleet-scoped by charter.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"
. "$(dirname "$0")/ac-backend.sh"   # orphan liveness probe: backend_window_alive
. "$(dirname "$0")/ac-wake-lib.sh"

state_dir="$(ac_state_dir)"
scope="${AC_SCOPE:-}"

ack_stamp() { printf '%s/.ack-%s\n' "$state_dir" "$1"; }

# The no-arg drain is the primary form; `ack` is the only argument form, and
# it ONLY stamps - it never drains, so silencing an item can never consume a
# wake as a side effect.
case "${1:-}" in
  '') ;;
  ack)
    shift
    [ "$#" -gt 0 ] || ac_die "usage: ac-wake-drain.sh ack <id> [<id>...]"
    for id in "$@"; do touch "$(ack_stamp "$id")"; done
    exit 0 ;;
  *) ac_die "usage: ac-wake-drain.sh | ac-wake-drain.sh ack <id> [<id>...]" ;;
esac

annotate_wakes() {
  # Pass every wake line through UNCHANGED, and add at most ONE indented
  # context line after it. A wake carries `<kind> <id> <payload>`, and for a
  # `report` the payload is the marker itself - but `stale`, `ended`, `gone`
  # and `ask` carry little or nothing, so the chief had to go read the task
  # before it knew what it was looking at. That round-trip is time the crewmate
  # spends parked at blocked:/needs-decision:.
  #
  # BOUNDED, and additive by construction: the wake line is byte-identical and
  # printed FIRST, the context is one trailing line that starts with spaces (no
  # marker can match it, no consumer parsing `<kind> <id> ...` sees a new
  # record), it is capped in length, it is skipped when the payload already
  # says the same thing, and any unreadable status is simply not annotated.
  # A SYMLINKED status file is skipped outright rather than followed - the
  # drain reads whatever the state dir holds, and this stays a read of our own
  # regular file.
  local kind id rest sf line text
  while IFS=' ' read -r kind id rest; do
    printf '%s %s %s\n' "$kind" "$id" "$rest"
    [ -n "$id" ] || continue
    sf="$(ac_task_status "$id")"
    [ -f "$sf" ] && [ ! -L "$sf" ] || continue
    line="$(tail -n 1 "$sf" 2>/dev/null)" || continue
    text="${line#* }"                                   # drop the ISO stamp
    [ -n "$text" ] && [ "$text" != "$line" ] || continue
    case "$rest" in *"$text"*) continue ;; esac         # the payload said it
    [ "${#text}" -le 160 ] || text="${text:0:157}..."
    printf '  status %s: %s\n' "$id" "$text"
  done
}

drain_spool() {
  # drain_spool <spool-dir> - claims the RECORDS, never the container: the
  # spool dir is permanent (created on demand by producers, never renamed or
  # removed here - ac-lib.sh owns that contract). One batched mv renames
  # every record into a private claim dir (atomic per record: a racing
  # drainer's mv fails on a source the winner took, so each record is
  # claimed by exactly one drainer); awk emits the claims PER FILE in lexical
  # record order - never `cat | awk`, whose byte-wise concatenation would
  # merge a record missing its trailing newline with the next into one torn
  # line (per-file awk ends the last record at each EOF, and costs one fewer
  # fork). rm drops the claim dir. Returns 1 when there was nothing to drain -
  # an EMPTY spool is never touched: litter, not loss.
  local spool="$1" d
  set -- "$spool"/*
  # "Anything here?" must survive a racing drainer claiming entries between
  # the glob and the test: judging the FIRST entry alone made this pass emit
  # nothing while LATER records still sat in the spool. ac_spool_has_record
  # tests EVERY entry of this same snapshot; the mv below already tolerates
  # sources a winner took first.
  ac_spool_has_record "$@" || return 1       # empty or absent: nothing here
  d="$state_dir/.wake-spool-draining.$$"
  mkdir "$d" || return 1
  mv "$@" "$d"/ 2>/dev/null || true          # ONE fork claims every record
  set -- "$d"/*
  [ -e "$1" ] || { rmdir "$d"; return 1; }   # a racing drainer took them all
  awk -F'\t' '{ printf "%s %s %s\n", $2, $3, $4 }' "$@" | annotate_wakes
  rm -rf "$d"
}

sweep_dead_claims() {
  # A drainer killed between claim (the mv in drain_spool) and emit strands
  # its records forever: the enumerators deliberately exclude claim dirs
  # (ac-lib.sh), no later drain revisits one, and the dedup marker has
  # already advanced (the wake never re-fires). Run ONCE, at the start of
  # every drain (scoped or fleet - either can crash mid-claim), before this
  # pass's own claim.
  #
  # NEVER touch a LIVE drainer's claim dir - the medium risk here: only a
  # claim dir whose embedded pid (the dirname suffix) is DEAD is recovered.
  # A non-numeric suffix is not a claim dir this drain recognizes at all
  # (left untouched, same as always).
  #
  # Recovery returns each record to the spool its OWN id maps to (a
  # `*-chief` pane stays fleet-scoped by charter, everything else via
  # ac_family_of_id) - never emitted directly here. That way the ordinary
  # scope-respecting drain that follows decides who claims it: a family
  # that came back live between the crash and this sweep still owns its own
  # wakes, exactly as if the crashed drainer had never touched them.
  local d pid rid fam dest f
  for d in "$state_dir"/.wake-spool-draining.*; do
    [ -d "$d" ] || continue
    pid="${d##*.wake-spool-draining.}"
    case "$pid" in '' | *[!0-9]*) continue ;; esac
    ac_pid_alive "$pid" && continue
    for f in "$d"/*; do
      [ -e "$f" ] || continue
      rid="$(awk -F'\t' '{ print $3; exit }' "$f")"
      case "$rid" in *-chief) fam="" ;; *) fam="$(ac_family_of_id "$rid")" ;; esac
      dest="$(ac_wake_spool_path "$state_dir" "$fam")"
      mkdir -p "$dest"
      mv "$f" "$dest/$(basename "$f")" 2>/dev/null || true
    done
    rmdir "$d" 2>/dev/null || true
  done
}
sweep_dead_claims

# This session drains the spool of ITS OWN scope: a roomchief takes only
# .wake-spool.<fam>/, the fleet chief only .wake-spool/.
emitted=0
if drain_spool "$(ac_wake_spool_path "$state_dir" "$scope")"; then emitted=1; fi

# Fleet fallback: a family whose roomchief is NOT LIVE (window dead or meta
# archived) can no longer drain its own wakes, so the fleet chief drains that
# orphan IN PLACE - the same primitives the roomchief would have run, just
# run by the fleet. A LIVE family is skipped: its chief owns those wakes. No
# hand-off, no staging file, no new wake - an orphan is simply picked up on
# the next pass.
if [ -z "$scope" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if drain_spool "$f"; then emitted=1; fi
  done < <(ac_wake_orphan_files "$state_dir")
fi

[ "$emitted" = 1 ] || printf 'no queued wakes\n'

in_drain_scope() {
  # in_drain_scope <id> - the completion report mirrors the wake scoping
  # (header: UNACKNOWLEDGED COMPLETIONS): a roomchief takes its own family,
  # the fleet chief takes the families no live roomchief covers plus the
  # chief panes themselves.
  local id="$1" fam
  fam="$(ac_family_of_id "$id")"
  if [ -n "$scope" ]; then
    [ "$fam" = "$scope" ]
    return
  fi
  case "$id" in *-chief) return 0 ;; esac
  ! ac_roomchief_live "$state_dir" "$fam"
}

report_completions() {
  # One pass over the in-scope metas: the artifact channel first, the pane
  # idleness fallback only for a task with no report artifact. Read-only -
  # the ack verb is the one writer.
  local meta id ack dir rep changed idle raw tail
  for meta in "$state_dir"/*.meta; do
    [ -e "$meta" ] || continue
    # A VERIFICATION agent (ac_meta_is_verify owns the class) owes the chief no
    # completion report: its caller waits on it directly, and it has no task
    # dir and no ack to stamp.
    ac_meta_is_verify "$meta" && continue
    id="$(basename "$meta" .meta)"
    in_drain_scope "$id" || continue
    ack="$(ack_stamp "$id")"

    # ARTIFACT: -nt is exactly the "absent ack = never acked = report it" rule.
    dir="$(ac_task_dir "$id" 2>/dev/null)" || dir=""
    rep="${dir:+$dir/report.md}"
    if [ -f "$rep" ]; then
      if [ "$rep" -nt "$ack" ]; then
        printf 'UNACKNOWLEDGED COMPLETION: %s has a report at %s (silence it: bin/ac-wake-drain.sh ack %s)\n' \
          "$id" "$rep" "$id"
      fi
      continue
    fi

    # IDLENESS: the watcher's own signals, re-read - never a second poller.
    changed="$state_dir/.change-$id"
    [ -f "$changed" ] || continue
    [ "$changed" -nt "$ack" ] || continue
    idle=$(( $(ac_now) - $(cat "$changed" 2>/dev/null || ac_now) ))
    [ "$idle" -ge "${AC_STALE:-240}" ] || continue
    # A <fam>-chief the WATCHER declined to wake is not idle news here either:
    # this fallback re-reads the watcher's own .change-<id> stamp, so the same
    # two suppressions apply - ONE definition, in ac-lib.sh's CHIEF-QUIET block,
    # which owns why (a chief parked at the captain, or supervising a live family
    # task, would otherwise be nagged every drain and acking it never settles).
    ac_chief_gate_parked "$id" && continue
    ac_chief_child_live "$state_dir" "$id" && continue
    AC_BACKEND="$(ac_task_backend "$id")"
    export AC_BACKEND
    # Guarded: an uncapturable pane (window gone, backend refused) is not
    # reported, and never fails the drain.
    raw="$(backend_capture "$id" 40 2>/dev/null)" || continue
    tail="$(printf '%s\n' "$raw" | sed '/^$/d' | tail -n 25)"
    if grep -qE "$AC_BUSY_RE" <<<"$tail"; then continue; fi
    if grep -qE "$AC_CAPTAIN_RE" <<<"$tail"; then continue; fi
    printf 'IDLE-MAY-BE-WAITING-ON-YOU: %s quiet for %ss with no marker (peek: bin/ac-peek.sh %s; silence it: bin/ac-wake-drain.sh ack %s)\n' \
      "$id" "$idle" "$id" "$id"
  done
}

report_completions

inflight=0
for meta in "$state_dir"/*.meta; do
  [ -e "$meta" ] || continue
  # A VERIFICATION agent demands no watcher coverage of its own: its CALLER
  # waits on it, so a home holding only verifiers must not nag (ac_meta_is_verify).
  ac_meta_is_verify "$meta" && continue
  # A chief SELF TASK holds a `tail -f`, not an agent (ac_meta_is_self owns the
  # class): nothing to cover, so a home holding only self tasks must not nag.
  ac_meta_is_self "$meta" && continue
  inflight=$((inflight + 1))
done
if [ "$inflight" -gt 0 ]; then
  # Judge the watcher that serves THIS session: a roomchief reads its family
  # watcher's beat, not the fleet's (an unscoped fleet beat would mask its
  # own watcher's death). The inflight scan stays fleet-wide on purpose -
  # over-counting only makes the warning fire more eagerly, never less.
  # ac_watcher_beat_read owns the classification and the no-beat wording; $beat
  # is 0 in every no-beat state, so the fire condition is unchanged. The three
  # no-beat states are told APART because they demand opposite responses: an
  # absent beacon means nothing ever armed here, while the 0 ac-watch.sh's
  # stand_down_beacon writes on every exit is the COMMON, routine one - a
  # watcher heartbeat-exited, so drain and re-arm.
  beat="$(ac_watcher_beat_read "$state_dir" "$scope")"
  note="${beat#* }"; beat="${beat%% *}"
  age=$(( $(ac_now) - beat ))
  if [ "$age" -gt "${AC_GUARD_GRACE:-300}" ]; then
    [ -n "$note" ] || note="no fresh beat (age ${age}s)"
    printf 'WATCHER-DOWN: %s crewmate(s) in flight but %s. Arm bin/ac-watch.sh as a background task now.\n' "$inflight" "$note"
  fi
fi

# Ride-alongs: all THREE are FLEET-WIDE side effects, so only the fleet chief's
# drain runs them. A roomchief drain is scoped to its family and does its own
# queue and beacon only - it must not schedule the fleet's backlog, push the
# fleet's captain-pending batch (one pusher fleet-wide, mirroring the watcher's
# single-poller gate), or promote a fleet-level roomchief (a crewchief act,
# whose spawn a scoped session's AC_SCOPE would contaminate).
if [ -z "$scope" ]; then
  # Scheduler ride-along: every drain is a landing checkpoint - surface every
  # READY item and STUCK dependents (prints nothing when there is nothing).
  "$(dirname "$0")/ac-ready.sh" 2>/dev/null || true

  # Remote push ride-along: with the remote transport configured, batch NEW
  # captain-pending items out to the remote channel (best-effort - a drain
  # never fails on transport trouble; push-pending stamp-dedups and stays
  # silent when nothing is pending).
  if [ -x "$(ac_config_dir)/remote-poll" ]; then
    "$(dirname "$0")/ac-remote.sh" push-pending || true
  fi

  # Learning ride-along: every drain is also the checkpoint that re-reads the
  # DISTILL cadence, so a run that is OWED gets its room created here instead of
  # waiting for a chief to notice a digest flag (best-effort - prints nothing
  # when nothing is owed or a learning room already exists).
  "$(dirname "$0")/ac-learn.sh" autoroom || true
fi
