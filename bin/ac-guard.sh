#!/usr/bin/env bash
# ac-guard.sh - warn-only situational advisory that rides along at the start
# of fleet commands (ac-send, ac-peek, ac-spawn, ac-review-diff,
# ac-merge-local). NEVER blocks: always exits 0, warnings go to stderr so
# the host command's stdout stays clean for pipelines.
#
# Usage: ac-guard.sh
#
# Every warning is scoped to the session it rides in (ac-lib.sh owns the
# keying): this script runs inside roomchief sessions too, so it nudges each
# one about the wakes and the watcher that are ITS OWN.
#
# Warnings (each at most one line, printed together as one block):
# - WATCHER-DOWN: crew tasks exist (state/*.meta) but the beacon of the
#   watcher serving this session (state/.last-watcher-beat[.<fam>]) is
#   missing or older than AC_GUARD_GRACE seconds (default 300; the whole
#   predicate is ac_watcher_down in ac-wake-lib.sh, shared with the
#   statusline's WATCH! so the two surfaces agree).
# - QUEUED WAKES: the wake store this session drains is non-empty - for a
#   roomchief state/.wake-spool.<fam>/, for the fleet state/.wake-spool/
#   plus any ORPHAN family spool (a live family's spool is its chief's).
# - TANGLE: the PRIMARY distro checkout (git-common-dir's parent, resolved
#   from ac_root; AC_GUARD_ROOT overrides for tests) is on a non-default
#   branch - fleet tooling may be mid-edit.
# - WIP-TOOLING: the checkout owning the invoked bin/ (ac_root; AC_GUARD_ROOT
#   overrides for tests) is not itself the PRIMARY checkout - usually a chief
#   that cd'd into a leased pool worktree and kept calling bin/ relatively,
#   running that worktree's own WIP copy. No crewmate-side tooling reaches
#   ac-guard.sh today (the five call sites above are its only ones; ac-ship.sh,
#   ac-done.sh, ac-qa.sh and the crew skills invoke none of them) except a
#   crewmate running ac-merge-local.sh directly from its own worktree
#   (that script's own :182 anticipates AC_CREW_ID/AC_SCOPE) - there this
#   fires as a benign false positive on a fail-open advisory.
#
# Rate-limited via a state stamp so back-to-back commands do not spam: the
# active warning set is recorded in state/.guard-stamp[.<fam>] (sig= + at=),
# and while the SAME set holds, repeats are suppressed for AC_GUARD_QUIET
# seconds (default 60). A CHANGED set prints immediately; an all-clear run
# clears the stamp so the next incident prints at once. The stamp is
# per-scope: a session's quiet window is its own bookkeeping, so a fleet
# nudge can neither suppress nor clear a roomchief's, or vice versa.
#
# Exit codes: always 0 (advisory; internal failures fail open).
# Files: reads state/*.meta, state/.last-watcher-beat[.<fam>],
# state/.wake-spool[.<fam>]/; writes state/.guard-stamp[.<fam>].

set -uo pipefail
. "$(dirname "$0")/ac-lib.sh" 2>/dev/null || exit 0
. "$(dirname "$0")/ac-backend.sh" 2>/dev/null || exit 0
. "$(dirname "$0")/ac-wake-lib.sh" 2>/dev/null || exit 0

state_dir="$(ac_state_dir 2>/dev/null)" || exit 0
quiet="${AC_GUARD_QUIET:-60}"
scope="${AC_SCOPE:-}"

warnings=""
sig=""

# WATCHER-DOWN: only meaningful while crew is in flight. The in-flight set,
# the beacon read, and the grace are ac_watcher_down's ONE definition
# (ac-wake-lib.sh), shared with ac-statusline.sh's WATCH! so the two can
# never disagree about the same fleet (audit-f4).
if ac_watcher_down "$state_dir" "$scope"; then
  warnings="${warnings}WATCHER-DOWN: crew in flight with no live watcher - arm bin/ac-watch.sh
"
  sig="$sig watcher-down"
fi

# Nudge each session about the wakes IT drains, mirroring ac-wake-drain.sh
# and the turn-end gate: a roomchief about its own store, the fleet about
# its own plus any orphan (a live family's store is its chief's business).
# ac_wake_pending answers per scope: does that spool hold a record.
queued=0
if [ -n "$scope" ]; then
  ac_wake_pending "$state_dir" "$scope" 2>/dev/null && queued=1
else
  { ac_wake_pending "$state_dir" '' || ac_wake_orphan_pending "$state_dir"; } 2>/dev/null && queued=1
fi
if [ "$queued" = 1 ]; then
  warnings="${warnings}QUEUED WAKES: run bin/ac-wake-drain.sh
"
  sig="$sig wake-queue"
fi

# TANGLE: the PRIMARY checkout (git-common-dir's parent, D1 geometry - see
# ac-primary-guard.sh) sitting on a non-default branch means the fleet tooling
# itself may be mid-edit. Resolve the primary FROM the anchor (the checkout
# that owns the invoked bin/, or AC_GUARD_ROOT for tests) rather than
# inspecting the anchor itself: a leased worktree's own branch is never the
# default (detached HEAD, or crew/<id>), so checking the anchor directly fires
# TANGLE unconditionally for exactly the actors who run this most.
anchor="${AC_GUARD_ROOT:-$(ac_root 2>/dev/null || true)}"
root="$anchor"
if [ -n "$root" ] && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  root="$(ac_repo_root "$root" 2>/dev/null || true)"
fi
if [ -n "$root" ] && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  cur="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || printf 'detached HEAD')"
  def="$(ac_default_branch "$root" 2>/dev/null || true)"
  if [ -n "$def" ] && [ "$cur" != "$def" ]; then
    warnings="${warnings}TANGLE: distro checkout on '$cur', not '$def' - fleet tooling may be mid-edit
"
    sig="$sig tangle"
  fi
fi

# WIP-TOOLING: the anchor (checkout owning the invoked bin/) differing from
# the resolved primary means the fleet command JUST RUN is executing a leased
# worktree's own copy of bin/, not the primary's - almost always a chief that
# cd'd into a leased pool worktree; the one anticipated exception is a
# crewmate running ac-merge-local.sh directly (:182), a benign false positive.
if [ -n "$anchor" ] && [ -n "$root" ] && [ "$anchor" != "$root" ]; then
  warnings="${warnings}WIP-TOOLING: running bin/ from '$anchor', not the primary '$root' - this may be a crewmate's leased worktree copy
"
  sig="$sig wip-tooling"
fi

# Per-scope stamp: the quiet window is this session's own bookkeeping. With
# one shared stamp a fleet nudge suppressed a roomchief's genuine nudge (same
# sig, same window), and either session's all-clear cleared the other's.
if ac_wake_scope_ok "$scope"; then
  stamp="$state_dir/.guard-stamp.$scope"
else
  stamp="$state_dir/.guard-stamp"
fi
if [ -z "$warnings" ]; then
  rm -f "$stamp"
  exit 0
fi

last_sig="$(ac_meta_get "$stamp" sig 2>/dev/null || true)"
last_at="$(ac_meta_get "$stamp" at 2>/dev/null || true)"
case "$last_at" in '' | *[!0-9]*) last_at=0 ;; esac
now="$(ac_now)"
if [ "$sig" = "$last_sig" ] && [ $(( now - last_at )) -lt "$quiet" ]; then
  exit 0
fi
printf '%s' "$warnings" >&2
ac_meta_set "$stamp" sig "$sig" 2>/dev/null || true
ac_meta_set "$stamp" at "$now" 2>/dev/null || true
exit 0
