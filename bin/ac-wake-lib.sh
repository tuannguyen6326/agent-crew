#!/usr/bin/env bash
# ac-wake-lib.sh - the wake/spool/room concern, split out of ac-lib.sh
# (audit-f3, codebase-audit-2026-07-29 finding 3). Not an entrypoint; sourced
# after ac-lib.sh by any script that needs it - ac-lib.sh does NOT source this
# file (the ac-pipeline-lib.sh pattern: the CALLER sources both, and every
# function here fails closed on a missing CORE sibling rather than assuming
# one).
#
# Owns: the wake scope + publication helpers (ac_wake_spool_path /
# ac_watcher_beat_path / ac_watcher_beat_read / ac_chief_busy_path /
# ac_wake_family_spools / ac_roomchief_live / ac_wake_orphan_files /
# ac_spool_has_record / ac_wake_orphan_pending / ac_wake_pending /
# ac_wake_publish - the authoritative spec for how a wake is keyed to its
# consumer, how a record reaches disk, and which families the fleet owns; see
# their block below), the watcher nudge (ac_watcher_pid / ac_watcher_nudge -
# ending a covering watcher's poll wait early, and the wrong-kill guard that
# makes it safe), the room grammar (ac_room_pending - the authoritative
# MATCHER for counting a room's unanswered GATE:/ASK: items; ac_room_review_rulings
# - the stable projection an independent code review reads;
# ac_room_marker_malformed - the write-side twin ac-room.sh cmd_post calls to
# REFUSE a malformed GATE/ASK/DECIDED-opening message; ac_room_handback_families
# - the authoritative matcher for the HANDBACK state, batched over N room files
# in one pass), and the two CHIEF-QUIET predicates (ac_chief_gate_parked /
# ac_chief_child_live - the authoritative answer to "is this <fam>-chief
# EXPECTED to be quiet", shared by ac-watch.sh's stale/ended arm and
# ac-wake-drain.sh's idle notice).
#
# LAYERING: depends only on ac-lib.sh core (ac_state_dir, ac_data_dir,
# ac_now, ac_meta_get, ac_pid_alive, ac_family_of_id, ac_meta_is_verify, ...).
# Never depended on by another sub-lib.

# --- wake scope + publication: the one routing/atomicity/ordering source ------
#
# AUTHORITATIVE for the wake store: its keying, its atomicity and its
# ordering contract. The producers (ac-watch.sh queue_wake, ac-room.sh
# handback, ac-remote.sh ingest_stream), the drains (ac-wake-drain.sh), the
# gates (ac-turnend-guard.sh, ac-guard.sh) and the tally (ac-fleets.sh) all
# bind here, so the scope key, the family filter and the record protocol can
# never drift apart.
#
# STORE: a wake is ONE FILE holding one `ts\tkind\tid\tpayload` record,
# living in the spool directory of its consumer's scope -
# state/.wake-spool/ is the FLEET spool (drained by the crewchief) and every
# promoted roomchief owns state/.wake-spool.<family>/, which only IT drains
# while live. Scope is carried in the spool dirname and the record format is
# identical in every spool. ONE store shape, deliberately: a pre-spool
# drain-once FILE (state/.wake-queue[.<family>]) was carried alongside this
# one for a rollout window that never existed - the first released bin/
# already published through ac_wake_publish and only ever READ that file - so
# every wake-store change reasoned through two shapes, and the phantom-family
# trap it documented (`.wake-queue.spool` enumerating as a family) existed
# only because of its glob.
#
# ATOMICITY: publication is ac_wake_publish - the record is fully written and
# closed on a private .wake-tmp.* inode nobody else can name, then published
# by one atomic link(2); the drain claims each record by one atomic
# rename(2). No shared append exists, so a record can neither be torn nor
# written into a drain-orphaned inode (R1). The spool container is created on
# demand and never RENAMED at all (moving it out from under a live producer's
# `ln` would risk ENOENT on the parent). It IS removed - by a bare rmdir,
# which only ever succeeds truly empty - in exactly one place: ac-room.sh
# cmd_close, once ITS OWN preflight has
# already confirmed the family has no live crewmate/roomchief left (so no
# producer can reach that scope to race the rmdir) and REFUSES (via
# ac_spool_has_record, the ONE spool-pending predicate) to remove a spool that
# still holds an undrained record.
#
# ORDERING (DECIDED: captain, option A, 2026-07-17): the drain emits records
# in producer-stamp order - lexical filename order over
# `<ts_ns>.<pid>.<seq6>`, where ts_ns is ONE fixed-width `date +%s%N` capture
# per record. Two records bearing the SAME stamp sort by pid then seq
# (unspecified across producers). A backward wall-clock step can misorder
# records about DIFFERENT subjects; a same-id sequence cannot invert (a
# watcher publishes at most one wake per process). Where %N is unsupported
# the stamp degrades to second resolution; CORRECTNESS never rests on stamp
# resolution - only ordering granularity does.
#
# The path/enumeration/predicate helpers are PURE: they take state_dir as
# DATA and create nothing (no mkdir, no touch). The read-only ac-fleets.sh
# and the mkdir-avoiding turn-end guard depend on that - do not reach for
# ac_state_dir here. ac_wake_publish is the ONE deliberate exception
# (mkdir/printf/ln): it is a producer's verb, never a reader's, and it stays
# out of the purity contract.

ac_wake_scope_ok() {
  # ac_wake_scope_ok <scope> - 0 when <scope> is a legal family name, i.e. a
  # bare single path segment [A-Za-z0-9_-]+ (ac-spawn.sh:491, ac-room.sh:106).
  # Empty, dot-bearing, slash-bearing or otherwise odd scopes are refused, so
  # a malformed AC_SCOPE can neither leak a stray file nor escape state/.
  case "${1:-}" in
    '' | *[!A-Za-z0-9_-]*) return 1 ;;
    *) return 0 ;;
  esac
}

ac_wake_spool_path() {
  # ac_wake_spool_path <state_dir> [<scope>] - the spool DIRECTORY for a
  # scope: the family spool for a valid scope, else the FLEET spool. Callers
  # pass "${AC_SCOPE:-}", so an unscoped (fleet) session and a malformed scope
  # both land on the fleet spool - the crewchief is the catch-all. Pure: it
  # prints a path and creates nothing (the producer's mkdir -p in
  # ac_wake_publish is the only place a spool comes to exist).
  if ac_wake_scope_ok "${2:-}"; then
    printf '%s/.wake-spool.%s\n' "$1" "$2"
  else
    printf '%s/.wake-spool\n' "$1"
  fi
}

ac_watcher_beat_path() {
  # ac_watcher_beat_path <state_dir> [<scope>] - the liveness beacon for a
  # scope. Each watcher stamps its OWN beat and each session reads the beat
  # of the watcher that serves it, so a roomchief whose family watcher died
  # sees WATCHER-DOWN instead of the fleet watcher's fresh beat.
  if ac_wake_scope_ok "${2:-}"; then
    printf '%s/.last-watcher-beat.%s\n' "$1" "$2"
  else
    printf '%s/.last-watcher-beat\n' "$1"
  fi
}

ac_watcher_beat_read() {
  # ac_watcher_beat_read <state_dir> [<scope>] - read the beacon ac_watcher_beat_path
  # names and CLASSIFY it, printing `<beat> <note>`: the beat every caller's fire
  # condition is computed from (0 whenever there is none, so `now - beat` stays
  # byte-identical to the old inline `cat || printf 0`), and a rendering note that
  # is EMPTY for a usable beat and otherwise says which no-beat state this is.
  # The three are decidable from the file alone and need OPPOSITE responses:
  #   ABSENT      - no beacon: nothing has ever armed here, you have been blind.
  #   UNREADABLE  - present but empty or non-numeric. An empty read is what a
  #                 reader sees when it catches a truncate-then-write mid-flight
  #                 (ac-watch.sh publishes by rename now, so this is a real
  #                 anomaly rather than the routine race it was until 2026-07-27).
  #   STOOD DOWN  - the 0 stand_down_beacon writes on every watcher exit: the
  #                 COMMON state, "a watcher just heartbeat-exited, drain and
  #                 re-arm", not an emergency.
  # No caller may print an age here: `now - 0` is a 56-year figure that a chief
  # reads as a live outage and reports to the captain (c8afc50, 2026-07-25), which
  # is why the wording "no beat on record" is fixed here rather than per renderer.
  #
  # SURVEY of the other beacon readers, checked against each file rather than by
  # name (the trap this convention exists to close: c8afc50 surveyed the readers
  # and ruled out ac-guard.sh correctly, while bin/ac-turnend-guard.sh - a
  # DIFFERENT file with a near-identical name - repeated the bug untouched):
  #   ac-turnend-guard.sh, ac-wake-drain.sh - the two that RENDER a figure; both
  #     read through this helper.
  #   ac-fleets.sh - renders one too, and already branches absent ("no beacon")
  #     from non-numeric/0 ("no beat on record") inline; converting it would
  #     change no output, so it is left alone.
  #   ac-guard.sh, ac-statusline.sh - age as a BOOLEAN ("WATCHER-DOWN", " WATCH!");
  #     they print no number, so no figure can be nonsense.
  #   ac-watch.sh skip_coverage_live - age as a boolean too, deciding whether a
  #     family's scoped coverage is still live; reads through this helper since
  #     2026-08-05. It was left inline on the "prints no number" criterion above,
  #     and that criterion is not the whole test: a boolean caller renders no
  #     nonsense figure, but it still feeds the value to `$(( now - beat ))`, and
  #     bash evaluates a non-numeric VALUE as an arithmetic expression - looking
  #     its first identifier up as a variable and, under set -u, killing the
  #     process. That is how an unreadable beacon stopped fleet supervision
  #     silently on 2026-08-05 (pid 66812, "line 957: signal: unbound variable" -
  #     a variable present in no version of ac-watch.sh). So the test for a new
  #     reader is whether the raw value can reach ARITHMETIC, not whether an age
  #     gets printed.
  local f beat note=""
  f="$(ac_watcher_beat_path "$1" "${2:-}")"
  if [ ! -e "$f" ]; then
    beat=0; note='no beat on record (no beacon - nothing has armed a watcher here)'
  else
    # Command substitution already strips the trailing newline; anything else
    # in the file - a second line, padding, a partial write - stays visible to
    # the digits-only test below, exactly as the inline reads this replaces
    # judged it. Flattening the whitespace out would turn a two-line beacon
    # into a plausible number and print an age from it.
    beat="$(cat "$f" 2>/dev/null || true)"
    case "$beat" in
      0) note='no beat on record (a watcher stood its beacon down on exit - drain and re-arm)' ;;
      ''|*[!0-9]*) beat=0; note='no beat on record (the beacon is unreadable)' ;;
    esac
  fi
  printf '%s %s\n' "$beat" "$note"
}

ac_watcher_down() {
  # ac_watcher_down <state_dir> [<scope>] - TRUE (exit 0) when supervision is
  # owed and the watcher serving this scope shows no usable fresh beat. The
  # ONE definition of both halves (audit-f4: ac-guard.sh judged in-flight as
  # verify+self-skipped against a 90s default grace while ac-statusline.sh
  # judged verify-skipped against 300s - the same AC_GUARD_GRACE env, two
  # defaults, two in-flight sets, so the status bar's WATCH! and the guard's
  # WATCHER-DOWN could disagree about the same fleet):
  #   in flight = the SUPERVISION set - verify panes are watched but a self
  #     task owes no watcher (the SELF-TASK block in ac-lib.sh), and chiefs
  #     COUNT (a roomchief pane is fleet-watched);
  #   down = the scope's beacon (ac_watcher_beat_read: absent, stood-down 0,
  #     or unreadable all read as beat 0) is older than AC_GUARD_GRACE,
  #     default 300 - the value every OTHER consumer already used; ac-guard's
  #     lone 90 made the enforcing hook more trigger-happy than the Stop hook
  #     during the ordinary exit->re-arm gap, the exact false-alarm class the
  #     watcher exists to absorb.
  local sd="$1" scope="${2:-}" inflight=0 beat age m
  while IFS= read -r m; do inflight=$((inflight + 1)); done \
    < <(ac_crew_metas "$sd" verify self)
  [ "$inflight" -gt 0 ] || return 1
  beat="$(ac_watcher_beat_read "$sd" "$scope")"
  beat="${beat%% *}"
  age=$(( $(ac_now) - beat ))
  [ "$age" -gt "${AC_GUARD_GRACE:-300}" ]
}

ac_chief_busy_path() {
  # ac_chief_busy_path <state_dir> <family> - the BUSY DECLARATION for <family>'s
  # roomchief: the epoch (one line) until which that chief is blocked inside ONE
  # bounded synchronous call and therefore CANNOT take a turn. Written by the
  # blocking caller itself (ac-gate.sh), read by ac-watch.sh's AC_WATCH_SKIP
  # revalidation, cleared by the writer on every trappable exit
  # (behavior: skip-grace-too-short-for-a-chief-inside-a-long-synchronous-gate).
  #
  # DELIBERATELY NOT the beacon (ac_watcher_beat_path above): that file asserts "a
  # scoped WATCHER is covering this family" and is read by ac-guard.sh,
  # ac-turnend-guard.sh, ac-wake-drain.sh, ac-statusline.sh and ac-fleets.sh -
  # touching it here would lie to all five, including the turn-end guard that
  # decides whether a chief may end a turn. This file says something different and
  # weaker: the chief is BUSY, not that anything is watching.
  #
  # The value is an ABSOLUTE expiry, not a start stamp, because only the blocking
  # caller knows the budget it actually waits on - so the declaration is bounded by
  # construction and fails closed on its own: a caller killed with no chance to
  # clean up (SIGKILL - the EXIT trap covers TERM/INT) holds the skip until the
  # bound passes and no longer.
  printf '%s/.chief-busy-until.%s\n' "$1" "$2"
}

ac_wake_family_spools() {
  # ac_wake_family_spools <state_dir> - print every valid family spool dir,
  # one per line. The filter is PREFIX-STRIP + bare-token, never last-dot
  # extraction, so a family legitimately named `draining` keeps its spool.
  # The glob structurally excludes the fleet spool (`.wake-spool`, no dot
  # suffix) and the drain's claim dirs (`.wake-spool-draining.<pid>`, dash not
  # dot); [ -d ] excludes any stray non-directory in the namespace. A family
  # legitimately named `spool` lives at `.wake-spool.spool` and stays
  # first-class.
  #
  # EINTR-safe: each entry's printf is wrapped in a retrying `until`. A
  # caller runs under set -e (every real one does), so a bare printf inside
  # the for BODY that gets EINTR (a real ac-wake-drain.sh run hit this twice
  # - "printf: write error: Interrupted system call") aborts the REST of the
  # loop silently; a command used as an if/while/until CONDITION never
  # triggers errexit on failure, so wrapping the printf in `until` both
  # sidesteps that and gives the interrupted write somewhere to retry into.
  # Retried WHOLE, never accumulated into one bigger emit: a single spool
  # path is always far under PIPE_BUF (POSIX guarantees at least 512 bytes),
  # so the write is atomic - it lands entirely or not at all, never a
  # torn/partial line. This bash/kernel pair can still occasionally report
  # EINTR on a write that had ALREADY landed (verified live,
  # 3.2.57(1)-release arm64-apple-darwin24), so a retry can rarely re-emit an
  # already-delivered line whole - never a torn one. That duplicate is
  # harmless to every consumer here (each acts per family; re-draining an
  # already-drained spool is a no-op) and is the accepted trade-off against
  # the alternative this fixes: a silently missing line. Bounded at 5 tries,
  # no sleep between them - EINTR needs re-attempting, not a wait. Exhausting
  # the 5 for ONE entry `break`s that entry's own retry only, never `return`s
  # out of the whole enumeration - a bare `return 1` here would reintroduce
  # the exact defect being fixed, one level up (the rest of the directories
  # silently dropped instead of just the one line that could not get out).
  local sd="$1" d b sfx tries failed=0
  for d in "$sd"/.wake-spool.*; do
    [ -d "$d" ] || continue          # nullglob-safe, and dirs only
    b="${d##*/}"
    sfx="${b#.wake-spool.}"
    ac_wake_scope_ok "$sfx" || continue
    tries=0
    until printf '%s\n' "$d"; do
      tries=$((tries + 1))
      if [ "$tries" -ge 5 ]; then
        failed=1
        break
      fi
    done
  done
  [ "$failed" -eq 0 ]
}

ac_roomchief_live() {
  # ac_roomchief_live <state_dir> <family> - 0 when the family's roomchief is
  # LIVE (its chief meta is present AND its backend window is alive), 1 when
  # NOT LIVE: the meta is archived (teardown ran) or the window died. NOT
  # LIVE is exactly the condition that makes .wake-spool.<family> an orphan
  # the fleet drains in place; a LIVE family is skipped, because its own
  # roomchief drains it (that skip IS the cross-drain fix).
  #
  # Cheap signal first: the meta stat settles the clean-demote path without
  # touching a backend, so a backend hiccup cannot hang the Stop hook. The
  # window probe needs ac-backend.sh sourced by the CALLER; absent it (or on
  # any probe error) the family reads NOT LIVE - fail-safe, because draining
  # an orphan to the crewchief surfaces the wake, while skipping it could
  # strand one.
  local sd="$1" fam="$2" m b
  m="$sd/$fam-chief.meta"
  [ -e "$m" ] || return 1
  command -v backend_window_alive >/dev/null 2>&1 || return 1
  b="$(ac_meta_get "$m" backend 2>/dev/null || true)"
  ( AC_BACKEND="${b:-herdr}"; export AC_BACKEND
    backend_window_alive "$fam-chief" ) 2>/dev/null
}

ac_wake_orphan_files() {
  # ac_wake_orphan_files <state_dir> - print the spool dir of every family
  # whose roomchief is NOT LIVE: the stores that belong to the FLEET chief. A
  # live family's spool is its own chief's and is never listed - that skip IS
  # the cross-drain fix. This is the ONE definition of "the fleet's orphans":
  # the drain acts on this list, the turn-end gate and the advisory ask about
  # it (via ac_wake_orphan_pending), so the three can never disagree about
  # which families the fleet owns.
  #
  # Needs ac-backend.sh sourced by the caller for the window probe; see
  # ac_roomchief_live for the fail-safe when it is absent.
  #
  # EINTR-safe the same way and for the same reason as ac_wake_family_spools
  # above (its own comment owns the full argument, including why retry
  # exhaustion `break`s the one entry rather than `return`ing out of the
  # whole enumeration): each entry's printf is retried whole, on the same
  # atomic-write-under-PIPE_BUF grounds, never accumulated into one bigger
  # emit.
  local sd="$1" d fam tries failed=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    fam="${d##*/.wake-spool.}"
    ac_roomchief_live "$sd" "$fam" && continue
    tries=0
    until printf '%s\n' "$d"; do
      tries=$((tries + 1))
      if [ "$tries" -ge 5 ]; then
        failed=1
        break
      fi
    done
  done < <(ac_wake_family_spools "$sd" 2>/dev/null)
  [ "$failed" -eq 0 ]
}

ac_spool_has_record() {
  # ac_spool_has_record <globbed-spool-entries...> - 0 iff at least one arg
  # names an existing file (a spool record). Callers pass the glob `"$dir"/*`
  # directly: with a match each entry is tested; with NO match the shell hands
  # the literal unexpanded pattern, which [ -e ] correctly reads as absent - so
  # an empty (or absent) spool reads "no record", never the [ -s ]-on-a-dir
  # trap ([ -s ] is true for any directory). This is the ONE spool-pending
  # predicate: ac_wake_pending, ac_wake_orphan_pending and ac-wake-drain.sh's
  # drain_spool all route through it so they can never disagree on what makes a
  # spool non-empty.
  local r
  for r in "$@"; do [ -e "$r" ] && return 0; done
  return 1
}

ac_wake_orphan_pending() {
  # ac_wake_orphan_pending <state_dir> - 0 when some orphan spool still holds
  # wakes, i.e. the fleet chief has something to drain beyond its own. A
  # spool holds wakes when it holds at least one record file - NEVER judged
  # with [ -s ], which is true for any directory. FAIL-OPEN: any error reads
  # as "nothing pending", so a broken predicate can never wedge a turn end.
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    ac_spool_has_record "$f"/* && return 0
  done < <(ac_wake_orphan_files "$1" 2>/dev/null)
  return 1
}

ac_wake_pending() {
  # ac_wake_pending <state_dir> [<scope>] - 0 when the scope's OWN spool holds
  # at least one record. PURE (reads only) - the turn-end gate and the
  # advisory call this, so the predicate must never block or create state. An
  # empty-but-existing spool dir is litter, not pending.
  local s
  s="$(ac_wake_spool_path "$1" "${2:-}")"
  ac_spool_has_record "$s"/* && return 0
  return 1
}

# --- wake publication: private write, one atomic link --------------------------

# _ac_wake_seq: process-global publication counter. DEFINED AT LIBRARY LOAD
# (every producer that can publish has it initialized before any publish),
# strictly increasing within the process, NEVER reset - not even per second:
# it must stay monotonic across ts ticks so two same-stamp records from one
# process can never share a name (see ac_wake_publish).
_ac_wake_seq=0

ac_wake_seam() {
  # ac_wake_seam <label> - TEST-ONLY fault-injection seam (the crash_at
  # pattern): runs the AC_WAKE_SEAM_RUN hook when AC_WAKE_SEAM_AT names this
  # label, so a test can force a full drain between
  # a publish's private write and its link. Unset (production) it is inert.
  [ "${AC_WAKE_SEAM_AT:-}" = "$1" ] || return 0
  [ -x "${AC_WAKE_SEAM_RUN:-}" ] || return 0
  "$AC_WAKE_SEAM_RUN"
}

ac_wake_publish() {
  # ac_wake_publish <state_dir> <scope> <kind> <id> <payload> - publish one
  # wake record; returns 0 IF AND ONLY IF the record is durably published.
  # The record is fully written and closed on a private mktemp inode, then
  # published by one atomic link(2) under `<ts_ns>.<pid>.<seq6>`; ln refuses
  # an existing destination (EEXIST), so no record is ever silently replaced.
  #
  # NEVER call this from a subshell: $$ is the collision-identity. A bash
  # subshell keeps the parent's $$ and a COPY of _ac_wake_seq, so a
  # subshell-published record could collide live with its parent's and break
  # the K-bound below. All three producers call from their main shell.
  #
  # TERMINATION: the one loop steps past names that already exist. Every
  # colliding name embeds OUR pid, and exactly one live process owns a pid at
  # a time, so every collider was published by a DEAD predecessor (pid
  # reuse): the collider set is FIXED at loop entry, each iteration consumes
  # it by one, and the loop runs at most K+1 times for K pre-existing
  # same-prefix names - no sleep, no clock, no lock, at any stamp resolution.
  #
  # FAILURE: on any non-zero return the record was NOT published and nothing
  # was destroyed - from the first successful write onward every failure path
  # RETAINS the bytes on disk as .wake-tmp.* (inert litter outside every
  # enumerated namespace); the caller dies loudly under set -e, parity with a
  # failed append today. A clock that prints nothing (or garbage) fails
  # BEFORE any byte exists: an empty stamp would name the record
  # `.<pid>.<seq>` - a DOTFILE invisible to every glob (drain, pending,
  # tally) = a silently lost wake. The ONLY rm of the temp sits strictly
  # past the commit point, and a cleanup failure there is litter, never
  # failure - reporting it would invite a retry and duplicate the wake.
  local sd="$1" scope="$2" kind="$3" id="$4" payload="$5" spool ts_ns ts tmp dest
  # RECORD CHARSET, pinned HERE because this is the single producer chokepoint:
  # one place fixes the grammar for every producer at once. The payload is the
  # one field no producer controls - ac-done.sh passes crewmate argv straight
  # through - and a tab or newline in an agent-authored marker splits the
  # `ts\tkind\tid\tpayload` record, so the drain's `$2 $3 $4` render TRUNCATES
  # the completion line the chief then acts on (the wake still arrives, which
  # is what makes it silent). Folded to spaces, never DELETED: deleting the
  # separator glues the words either side of it into one and corrupts the same
  # line more quietly than it truncates it.
  payload="$(printf '%s' "$payload" | tr '\t\n' '  ')"
  spool="$(ac_wake_spool_path "$sd" "$scope")"
  ts_ns="$(date +%s%N)"                       # ONE capture: record field AND
  case "$ts_ns" in                            # filename stamp, SAME instant.
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]*) : ;;
    *) return 1 ;;                            # broken clock: 10 leading digits
  esac                                        # (the seconds field) or refuse -
                                              # the tail may be %N digits or
                                              # BSD date's literal `N`, both fine
  ts="${ts_ns:0:10}"
  tmp="$(mktemp "$sd/.wake-tmp.XXXXXXXX")" || return 1
  printf '%s\t%s\t%s\t%s\n' "$ts" "$kind" "$id" "$payload" >"$tmp" || return 1
  ac_wake_seam after-write
  [ -d "$spool" ] || mkdir -p "$spool" || return 1   # the spool is PERMANENT
  while :; do                                 # at most K+1 passes (above)
    dest="$spool/$ts_ns.$$.$(printf '%06d' "$_ac_wake_seq")"
    if ln "$tmp" "$dest" 2>/dev/null; then
      rm -f "$tmp" || true   # the ONLY temp removal: past the commit point
      _ac_wake_seq=$((_ac_wake_seq + 1))
      return 0
    fi
    if [ -e "$dest" ]; then                   # a dead predecessor's record
      _ac_wake_seq=$((_ac_wake_seq + 1))      # step past it; the set is FIXED
      continue
    fi
    return 1                                  # hard fs error - tmp retained
  done
}

# --- the watcher nudge --------------------------------------------------------
#
# AUTHORITATIVE for how a publisher ends the covering watcher's poll wait
# early, and for the WRONG-KILL GUARD that makes it safe. Two callers share it:
# ac-done.sh's agent-side push (whose header owns the PUSH contract) and
# ac-room.sh's hand-back. Both publish first and nudge second - the record is
# the guarantee, the nudge is only an accelerator, so a nudge that finds
# nothing to end is the correct QUIET outcome and never an error.
#
# The nudge KILLS THE POLL `sleep` CHILD ALONE - behavior ac-watch.sh's
# poll_wait already documents and relies on ("A kill aimed at the sleep CHILD
# alone just ends the wait early"). This USES that behavior, it does not build
# it: the wait ends, the loop's top-of-cycle push check runs at once, and the
# watcher exits so the harness wakes.
#
# WRONG-KILL GUARD (the sharp edge of the whole story). Both ends of the target
# are confirmed before any signal is sent: the pid recorded in the watcher's
# lock dir must still be running an `ac-watch` command line (a REUSED pid is
# running something else, and is refused), and the process actually signalled
# must be a `sleep` CHILD of exactly that pid. A watcher inside a poll pass has
# no such child and is left alone.

ac_watcher_pid() {
  # ac_watcher_pid <state-dir> <scope> - the pid of the LIVE watcher covering
  # this scope, or 1 when there is none to nudge. The lock name is
  # ac-watch.sh's: the fleet watcher holds .watch.lock.d, a scoped one the
  # .watch-only-<scope>.lock.d suffix - which ac-watch.sh keys on AC_SCOPE (the
  # ONE family a scoped watcher files for), NOT its full AC_WATCH_ONLY set, so a
  # valid scope maps to exactly one lock name even for an epic roomchief that
  # also watches its story panes.
  local sd="$1" scope="${2:-}" lock pid
  if ac_wake_scope_ok "$scope"; then
    lock="$sd/.watch-only-$scope.lock.d"
  else
    lock="$sd/.watch.lock.d"
  fi
  pid="$(cat "$lock/pid" 2>/dev/null || true)"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  ac_pid_alive "$pid" || return 1
  # PID REUSE (see the guard above): the recorded pid must still BE a watcher.
  ps -o command= -p "$pid" 2>/dev/null | grep -q 'ac-watch' || return 1
  printf '%s\n' "$pid"
}

ac_watcher_nudge() {
  # ac_watcher_nudge <state-dir> <scope> - end the covering watcher's poll wait
  # early. Prints a one-line outcome and never fails its caller: an un-nudged
  # record is drained later. The child walk is one `ps`, not pgrep: the
  # toolchain doctor declares no such dependency, and ac_pid_chain reads
  # processes the same way.
  local sd="$1" scope="${2:-}" wpid child
  if ! wpid="$(ac_watcher_pid "$sd" "$scope")"; then
    printf 'no armed watcher for this scope - the record waits in the spool\n'
    return 0
  fi
  child="$(ps -o pid=,ppid=,comm= -A 2>/dev/null \
    | awk -v p="$wpid" '$2 == p && $3 ~ /(^|\/)sleep$/ { print $1; exit }')"
  if [ -z "$child" ]; then
    printf 'watcher pid=%s is mid-poll, nothing to nudge - the record waits in the spool\n' "$wpid"
    return 0
  fi
  if kill "$child" 2>/dev/null; then
    printf 'nudged watcher pid=%s (poll sleep %s ended early)\n' "$wpid" "$child"
  else
    printf 'watcher pid=%s could not be nudged, nothing to nudge - the record waits in the spool\n' "$wpid"
  fi
}

# --- room grammar: the pending and HANDBACK state of data/<family>/room.md -----
#
# AUTHORITATIVE for how a room entry is COUNTED, and for when a room is in
# HANDBACK. The entry format and the receipt semantics (what
# TRIAGE:/SELF-APPROVED: mean) stay owned by ac-room.sh's header; this owns only
# the matchers, because each has more than one consumer and a copy of one
# already drifted (bcec534 widened the room's matcher; the statusline's copy was
# never opened).
#
# A decision settles one open item (oldest first) whether it is the bare
# `DECIDED:` form, the captain-attribution `DECIDED <family>:` form (the
# section-8 echo that disambiguates one chat stream across many tasks), or the
# paren-attribution `DECIDED (<attr>):` form a captain actually writes (e.g.
# `DECIDED (captain):`, and the two may combine as `DECIDED <family> (<attr>):`).
# The optional ` <family>` uses the same [A-Za-z0-9_-] charset the family
# validation enforces; the colon is still required (a bare `DECIDED` settles
# nothing) and only one item is settled per line (no over-count).
#
# Only a bare `GATE:` (or `ASK:`) is a pending item: the matcher counts the
# EXACT token - the word then a colon - so a receipt verb that merely shares
# the `GATE` prefix is NOT counted. `GATE-PASSED (auto):` (the auto
# pre-implement tier) and `GATE-LOOPED:` (the roomchief looped a gate its
# judge REJECTED back to the crewmate, no captain involved) both read as
# receipts, exactly like `SELF-APPROVED:`/`TRIAGE:`: informational, zero
# pending. A gate the chief adjudicates ITSELF never pends (approve ->
# SELF-APPROVED:/GATE-PASSED:, reject-and-loop -> GATE-LOOPED:); a gate that
# genuinely awaits the CAPTAIN stays a bare `GATE:` and pends until DECIDED.
# This is why a self-looped gate no longer inflates the captain inbox or
# blocks `ac-room.sh close` (before it, a mislabeled looped `GATE:` needed a
# fabricated accounting `DECIDED:` to clear - the drain-race-r1 incident).
#
# Room consumers do not all need the same projection. ac_room_pending below
# counts unresolved captain items. ac_room_review_rulings selects the compact
# accepted/captain context an exact-ref code reviewer reads; it deliberately
# omits GATE-LOOPED because those are rejected-draft receipts, not accepted
# behavior. ac-gate.sh projects NOTHING: since 2026-07-26 its second chief reads
# room.md whole, from disk, for full parity with the owning chief - so no verb
# set here is authoritative for it, and none should be borrowed for it again.
#
# There is deliberately no "delivered, awaiting the crewchief to land" verb:
# `GATE:` covers waiting on the captain, `HANDBACK:` (ac_room_handback_families
# below) already covers waiting on the crewchief, including the land-only
# case. See AGENTS.md section 8, room lifecycle, near the HANDBACK sentences.

ac_room_review_rulings() {
  # ac_room_review_rulings <room-file> - stable, file-order projection for an
  # independent code review: captain questions/decisions, intake TRIAGE,
  # accepted chief/gate receipts, and explicit corrections. Empty/missing room
  # yields nothing. Rejected GATE-LOOPED rounds and ordinary narration stay in
  # room-snapshot.md for targeted surrounding context, never default reading.
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    /^- \[[^]]*\] [^>]*> (GATE|ASK):/ { print; next }
    /^- \[[^]]*\] [^>]*> DECIDED( [A-Za-z0-9_-]+)?( \([^)]*\))?:/ { print; next }
    /^- \[[^]]*\] [^>]*> (TRIAGE|SELF-APPROVED):/ { print; next }
    /^- \[[^]]*\] [^>]*> GATE-PASSED \(auto\):/ { print; next }
    /^- \[[^]]*\] [^>]*> CORRECTION( \([^)]*\))?:/ { print; next }
  ' "$file"
}

ac_room_pending() {
  # ac_room_pending <file>... - gates/asks minus decisions, floored at 0 PER
  # FILE and summed over the files given. One file in, one count out - the
  # single-file answer is unchanged; N files are BATCHED into one awk pass for
  # the same reason ac_room_handback_families is (below): ac-turnend-guard.sh
  # reads the whole room set on a turn end, and rooms are never deleted, so a
  # per-room fork would grow without bound on a hook that always runs. The
  # per-file reset is load-bearing: a DECIDED: in one room settles nothing in
  # another.
  # The verb need not sit flush against the colon: a legitimately-authored
  # `ASK (1 of 2):` (message starts with the verb, colon after an optional word
  # and/or parenthetical) is a real pending item, matched by the same
  # "verb, optional word, optional (parenthetical), then colon" shape the
  # DECIDED rule uses. The word-break requirement (space or colon after the
  # verb) still excludes receipts that merely START with the token -
  # `GATE-LOOPED:`, `GATE-PASSED (auto):` - which continue with `-`.
  #
  # The actor field is POSITION-pinned (`[^]]*` for the stamp, `[^>]*` for the
  # actor), never greedy: a greedy `.*> ` re-anchors on ANY `> ` inside the
  # MESSAGE, and a Slack-quote relay carries exactly that. An embedded
  # `> DECIDED:` then silently settled a real captain gate (an item drops out
  # of the inbox - fail-open) and an embedded `> GATE:` minted a phantom
  # pending that blocks room close. The write-side twin below validates only
  # line-OPENING verbs, so it cannot refuse a quoted one: this is the only
  # place that position can be enforced. This pin is FILE-WIDE, not local to
  # this function: ac_room_review_rulings and ac_room_handback_families read
  # the same room grammar and share the identical `[^]]*` / `[^>]*` shape, so
  # the whole file stays internally consistent. No actor name may contain `>` - ids
  # are [a-z0-9-] (AGENTS.md section 5) and a family is [a-zA-Z0-9_-]
  # (ac-room.sh cmd_post) - so pinning it excludes no legitimate entry.
  [ "$#" -gt 0 ] || { printf '0\n'; return 0; }   # no files: never awk's stdin
  awk '
    FILENAME != cur { total += (open > 0 ? open : 0); cur = FILENAME; open = 0 }
    /^- \[[^]]*\] [^>]*> (GATE|ASK)( [A-Za-z0-9_-]+)?( \([^)]*\))?:/ { open++ }
    /^- \[[^]]*\] [^>]*> DECIDED( [A-Za-z0-9_-]+)?( \([^)]*\))?:/ { if (open > 0) open-- }
    END { print total + (open > 0 ? open : 0) }
  ' "$@"
}

ac_room_marker_malformed() {
  # ac_room_marker_malformed <text> - the WRITE-SIDE twin of ac_room_pending's
  # counting grammar, kept in this same function block so the two can never
  # drift silently (change one, check the other): true (exit 0) when <text>'s
  # FIRST line opens with a BARE counting verb (GATE/ASK/DECIDED, word-broken
  # by a space/colon/end-of-line - never a compound receipt verb like
  # GATE-LOOPED/GATE-PASSED/GATE-VERIFY, which continues past the verb with
  # `-` and is never validated here) but does not close it with the "optional
  # word, optional (parenthetical), then colon" shape ac_room_pending requires
  # before a line counts as an answered/pending item. Anchored on the raw
  # MESSAGE (no `- [<iso>] <actor>> ` room-line prefix - the caller has not
  # written the line yet) and only its first line: a multi-line message's
  # later lines never carry that prefix in the room file either, so
  # ac_room_pending never reads them as a marker regardless of their content.
  # ac-room.sh cmd_post is the ONE caller: it REFUSES a malformed marker at
  # authoring time, before the mis-shaped line can hang a room PENDING
  # forever - a DASH where the grammar needs a colon (`DECIDED (captain:
  # "merge") - landing approved...`) settles nothing and never counts, so a
  # captain answer recorded that way looks DECIDED to a human and stays open
  # to every machine reader (close, the inbox, the turn-end guard) forever.
  local first
  first="$(printf '%s\n' "$1" | head -n1)"
  grep -qE '^(GATE|ASK|DECIDED)([[:space:]]|:|$)' <<<"$first" || return 1
  grep -qE '^(GATE|ASK|DECIDED)([[:space:]][A-Za-z0-9_-]+)?([[:space:]]\([^)]*\))?:' <<<"$first" && return 1
  return 0
}

ac_room_handback_families() {
  # ac_room_handback_families <room-file>... - print the FAMILY of every room
  # whose last HANDBACK: entry is not yet followed by a DEMOTED:, CLOSED: or
  # HANDBACK-REFUSED: entry, one per line, in argument order. The ONE copy of
  # that grammar. HANDBACK-REFUSED: is the crewchief REFUSING a hand-back
  # (mis-recorded authority, remedies required, whatever) while the family
  # stays OPEN and the roomchief stays ALIVE - it clears the obligation the
  # same way DEMOTED:/CLOSED: do, without either of those acts; a later
  # HANDBACK: re-opens it, so a refusal never permanently retires the state.
  #
  # BATCHED BY DESIGN - it takes N files and makes ONE awk pass, because its
  # heaviest consumer is ac-turnend-guard.sh, which sweeps the WHOLE room set on
  # every fleet turn end. Rooms are records and are never deleted (AGENTS.md
  # section 8), so the set only grows: a per-room fork would put an unbounded,
  # daily-growing cost on the one hook that always runs. ac-statusline.sh's
  # no-fork budget is the same concern, stated for a far less frequent path.
  #
  # The family is the room file's parent directory - data/<family>/room.md,
  # ac-room.sh's layout. Portable multi-file bookkeeping: gawk's ENDFILE is not
  # everywhere, so a file is flushed when FILENAME changes and the last at END.
  # An empty room yields no records and so is never in handback - correct.
  [ "$#" -gt 0 ] || return 0
  awk '
    function fam(p,   n, a) { n = split(p, a, "/"); return (n >= 2 ? a[n - 1] : p) }
    FILENAME != cur { if (cur != "" && hb) print fam(cur); cur = FILENAME; hb = 0 }
    /^- \[[^]]*\] [^>]*> HANDBACK:/ { hb = 1 }
    /^- \[[^]]*\] [^>]*> HANDBACK-REFUSED:/ { hb = 0 }
    /^- \[[^]]*\] [^>]*> (DEMOTED|CLOSED):/ { hb = 0 }
    END { if (cur != "" && hb) print fam(cur) }
  ' "$@"
}

ac_room_list_rows() {
  # ac_room_list_rows <room-file>... - the PER-ROOM projection `ac-room.sh
  # list` needs: one line "<pending>\037<hb>\037<family>\037<last>" per
  # file, in argument order, from ONE awk pass over every file given. Fields
  # are separated by ASCII Unit Separator 0x1f (awk octal \037 - this awk has
  # no \x hex escape, verified empirically), never a tab: bash's `read`
  # trims a TRAILING run of IFS whitespace (space/tab/newline) from the last
  # assigned variable even when IFS is set to only one of them, so a `last`
  # that genuinely ends in a literal tab would lose it with a tab delimiter
  # (verified empirically) - 0x1f carries none of that special treatment.
  # <pending> and <hb> are per-file (never a cross-file sum - a DECIDED: in
  # one room still settles nothing in another); <last> is the FULL last line
  # matching `^- \[` (untruncated - the caller truncates it with a
  # character-aware bash substring, never awk's substr(), which is
  # byte-aware in this awk and measurably diverges from the original `cut
  # -c1-120` on this fleet's everyday multi-byte UTF-8 room text).
  #
  # ADDITIVE, not a re-derivation: the GATE/ASK/DECIDED and HANDBACK/DEMOTED/
  # CLOSED/HANDBACK-REFUSED patterns are copied verbatim from ac_room_pending
  # and ac_room_handback_families above - "ONE copy of the room grammar"
  # (that function's own docstring) - so all three stay byte-identical in
  # what they match. Neither helper's signature or behavior changes for its
  # existing callers (ac-turnend-guard.sh, ac_chief_gate_parked,
  # ac-statusline.sh); this is a third, independent reader of the same files.
  #
  # EVERY argument file emits exactly one row, in argument order, INCLUDING a
  # completely empty room.md - awk never runs a single pattern-action rule
  # for a zero-line file (no BEGINFILE/ENDFILE in this awk), so a design that
  # only prints on a FILENAME-change trigger never sees that file at all and
  # silently drops it from the inbox (a live-verified failure mode: an empty
  # room.md with a blocked-chief stamp must still surface
  # PENDING-CAPTAIN(1)+BLOCKED). Keying open/hb/last by FILENAME directly and
  # emitting from an ARGV walk in END sidesteps that: an untouched array
  # element reads as 0/"" - exactly an empty room's correct row - with no
  # dependency on ever having read a line from it.
  [ "$#" -gt 0 ] || return 0
  awk '
    function fam(p,   n, a) { n = split(p, a, "/"); return (n >= 2 ? a[n - 1] : p) }
    /^- \[[^]]*\] [^>]*> (GATE|ASK)( [A-Za-z0-9_-]+)?( \([^)]*\))?:/ { open[FILENAME]++ }
    /^- \[[^]]*\] [^>]*> DECIDED( [A-Za-z0-9_-]+)?( \([^)]*\))?:/ { if (open[FILENAME] > 0) open[FILENAME]-- }
    /^- \[[^]]*\] [^>]*> HANDBACK:/ { hb[FILENAME] = 1 }
    /^- \[[^]]*\] [^>]*> HANDBACK-REFUSED:/ { hb[FILENAME] = 0 }
    /^- \[[^]]*\] [^>]*> (DEMOTED|CLOSED):/ { hb[FILENAME] = 0 }
    /^- \[/ { last[FILENAME] = $0 }
    END {
      for (i = 1; i < ARGC; i++) {
        f = ARGV[i]
        p = (open[f] > 0 ? open[f] : 0)
        print p "\037" (hb[f] + 0) "\037" fam(f) "\037" last[f]
      }
    }
  ' "$@"
}

# --- the two CHIEF-QUIET predicates -------------------------------------------
#
# AUTHORITATIVE for "a <fam>-chief is EXPECTED to be quiet". Two TWINS at one
# rung: ac_chief_gate_parked is a chief parked at the CAPTAIN (unanswered
# GATE:/ASK:), ac_chief_child_live one parked at its CREWMATE (a live family
# task). Both answer a LIVE question re-asked on every call, never a remembered
# marker - so a suppressed pass stamps nothing and there is nothing for a later
# pane change to re-trip.
#
# TWO consumers, ONE definition - which is why they live here and not in the
# watcher that grew them:
#   - ac-watch.sh's stale/ended arm, the wake it DECLINES to emit (its
#     SUPERVISING-CHIEF QUIET header owns the reasoning for both).
#   - ac-wake-drain.sh's IDLE-MAY-BE-WAITING-ON-YOU notice, which re-reads the
#     watcher's OWN .change-<id> stamp: without the same two suppressions it
#     resurrects exactly the wake the watcher declined, once per drain forever,
#     and acking it settles nothing (the chief's own ack output is the pane
#     change that re-arms it). An ack treadmill trains a chief to ack
#     REFLEXIVELY, which is how a genuinely idle chief later gets acked away
#     unread - the notice degrades the signal it delivers.
# A non-chief id is NEITHER (the *-chief case gate returns first), so the
# crewmate net both consumers exist for is untouched by either.

ac_chief_gate_parked() {
  # ac_chief_gate_parked <id> - 0 when <id> is a roomchief whose room still
  # holds unanswered GATE:/ASK: items. The accounting is ac_room_pending's, the
  # one authoritative matcher, never re-implemented here; the room layout is
  # ac-room.sh's (data/<family>/room.md). No room means nothing pending.
  case "$1" in *-chief) : ;; *) return 1 ;; esac
  local f
  f="$(ac_data_dir)/${1%-chief}/room.md"
  [ -f "$f" ] || return 1
  [ "$(ac_room_pending "$f")" -gt 0 ]
}

ac_chief_child_live() {
  # ac_chief_child_live <state_dir> <id> - 0 when <id> is a roomchief with at
  # least one LIVE family task: it is supervising, not stalled. MEMBERSHIP is
  # AUTHORITATIVE, never an id PREFIX - the same pair and the same rule as
  # ac-teardown.sh's roomchief demote, whose header owns the incident:
  # ac_family_of_id over the CLOSED stage/revision suffix set, OR the pane's own
  # fleet_scope recorded at spawn. Never the chief's own pane, which is
  # fleet-scoped by charter. Liveness is the pair ac_roomchief_live reads for
  # the chief itself (meta present AND backend window alive), asked per member;
  # the first live one settles it.
  #
  # An open `<fam>-*` glob read an UNRELATED family whose id merely STARTS WITH
  # this one as this chief's own crew, so the predicate returned TRUE for a
  # genuinely IDLE chief and SWALLOWED the wake/notice both consumers exist to
  # deliver - the same collision that made a roomchief undemotable, failing in
  # the OPPOSITE and worse direction: a blocked action announces itself, silence
  # does not. Narrowing membership can only make this predicate false MORE
  # often, which runs WITH the fail-safe direction stated below.
  #
  # The window probe needs ac-backend.sh sourced by the CALLER; absent it, or on
  # any probe error, a member reads NOT live - fail-safe in the direction that
  # keeps the chief's wake/notice rather than swallowing it.
  case "$2" in *-chief) : ;; *) return 1 ;; esac
  local sd="$1" fam="${2%-chief}" m cid b
  for m in "$sd"/*.meta; do
    [ -e "$m" ] || continue
    # A VERIFICATION agent (ac_meta_is_verify owns the class) is not a family
    # CHILD: nobody is working the family's task while only a verifier flies,
    # so the chief is genuinely idle and must still be woken/reported.
    ac_meta_is_verify "$m" && continue
    cid="$(basename "$m" .meta)"
    # The chief's OWN pane is named explicitly and skipped FIRST. The grammar
    # DOES now resolve it (ac_family_of_id "<fam>-chief" is "<fam>" once its
    # nested data/<fam>/chief dir exists, board-detail-shows-every-artifact) -
    # but that dir is created lazily by the first status-timeline mirror, so
    # this case arm is DEFENSE IN DEPTH, kept because the two errors are not
    # symmetric: a chief that probed itself before its dir ever existed would
    # read as permanently supervising and never wake again - unrecoverable -
    # while one redundant case arm costs nothing.
    case "$cid" in "$fam"-chief) continue ;; esac
    [ "$(ac_family_of_id "$cid")" = "$fam" ] \
      || [ "$(ac_meta_get "$m" fleet_scope)" = "$fam" ] || continue
    b="$(ac_meta_get "$m" backend 2>/dev/null || true)"
    ( AC_BACKEND="${b:-herdr}"; export AC_BACKEND
      backend_window_alive "$cid" ) 2>/dev/null && return 0
  done
  return 1
}

