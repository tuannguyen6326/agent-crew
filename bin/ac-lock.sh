#!/usr/bin/env bash
# ac-lock.sh - per-home chief session lock: one fleet-driving session at a time.
#
# Usage: ac-lock.sh acquire | status | release
#
# The lock file state/.session-lock records which HARNESS process owns this
# home, one key=value per line: `pid=<n>`, `since=<ISO timestamp>`, and
# `cmd=<the pid's command at acquire time>` (absent when unreadable) - the
# IDENTITY fingerprint that lets a later check tell a still-live holder apart
# from an unrelated process pid reuse handed the same number (holder_alive
# owns the contract: PID REUSE below). The harness pid is found by walking
# this process's ancestry for the long-lived
# harness process (claude|codex|opencode; AC_LOCK_HARNESS_RE overrides the
# pattern) - never the transient tool-call subshell that ran this script, and
# never a rotating daemon worker (argv with a `bg-*` token directly after
# the harness token, e.g. `claude bg-spare ...`, `claude bg-pty-host ...` -
# skipped like a shell ancestor, matched or recorded as neither the harness
# nor the stable fallback, so a later tool call under a DIFFERENT worker
# still resolves the same identity). The match is ANCHORED to that exact
# position - a real harness whose argv merely CONTAINS "bg-spare" elsewhere
# (a path segment, say) is still matched as the harness, never skipped.
# The answer is the OUTERMOST harness ancestor, not the nearest: a Claude
# Stop hook fires levels below the lock-owning process
# with same-session claude workers in between, and first-match handed
# ownership checks the wrong pid; a single-match chain is unchanged. When no
# harness ancestor exists (custom launch template), acquire warns and uses
# the nearest stable (non-shell, non-worker) ancestor pid instead.
# AC_LOCK_PID overrides detection entirely (tests, unusual launchers).
#
# acquire:
#   - AC_SCOPE set (scoped roomchief session): prints a skip notice and exits
#     0 WITHOUT locking - scoped sessions never own the home.
#   - unlocked, or already held by this session: takes/keeps the lock, exit 0.
#     RE-ENTRANT: the holder counts as THIS session when its pid is the pid
#     detected above OR appears anywhere in this process's own ancestor chain
#     (the answer ac-turnend-guard.sh already gives to the same question). A
#     tool-call subshell whose argv carries a harness token (`ac-spawn.sh ...
#     --harness claude ...`) matches the harness regex itself, so the walk
#     answers with that transient shell and the session's OWN lock would
#     otherwise read as foreign - the spurious `another chief session owns
#     this home` seen on a fleet-watcher arm made in a spawning turn.
#     AC_LOCK_PID pins identity exactly and never consults the ancestry.
#   - held by a LIVE foreign pid whose command still matches its recorded
#     fingerprint: exit 2 with `another chief session owns this home
#     (pid <n> since <t>)`.
#   - held by a dead pid, OR a pid that is alive but running a DIFFERENT
#     command now (PID REUSE - see holder_alive): prints a stale-recovery
#     notice and takes the lock.
# status: prints one line - `unlocked`, `held pid=<n> since=<t>` (holder
#   alive and identity-verified), or `stale pid=<n> since=<t>` (holder dead
#   or identity-mismatched). Always exit 0.
# release:
#   - held by this session (same re-entrancy rule as acquire): removes the
#     lock, exit 0.
#   - held by a LIVE, identity-verified foreign pid: refused, exit 2 - only
#     the holder releases.
#   - held by a dead pid, or a reused one: cleared with a notice, exit 0.
#   - unlocked: no-op, exit 0.
#
# ATOMIC CLAIM CONTRACT (do_acquire): the winner is decided by ONE atomic
# filesystem op that FAILS for the loser, so two simultaneous chiefs can never
# both report acquired.
#   - The claim is `ln` (hard link) of a FULLY-POPULATED temp onto the lock
#     path. link(2) fails with EEXIST when the target exists: exactly one
#     racer's link succeeds and the winner's file is NEVER overwritten. (The
#     old `mv` REPLACED an existing target, so two racers that both passed the
#     check clobbered each other and both printed acquired.) Populating the
#     temp before the link means the lock is never observed pid-less - there is
#     no create-then-write window for a reader to mistake for a corpse. After a
#     winning link a read-back confirms the on-disk pid is ours (the contract's
#     final gate; the loser refuses).
#   - Stale recovery serializes through a reap DIR (state/.session-lock.reap):
#     removing a corpse and re-claiming cannot be one atomic step, and an
#     unguarded rm+claim lets a second recoverer delete the first winner's LIVE
#     lock. `mkdir` of the reap dir is the fail-for-loser gate - only the sole
#     reaper removes the corpse, and only while its pid still reads DEAD, so a
#     live holder is never removed. Every recoverer then re-races the same `ln`.
#     RESIDUAL (fail-CLOSED, never two holders): a reaper SIGKILLed between its
#     mkdir and rmdir leaks the reap dir, which makes stale recovery REFUSE
#     until state/.session-lock.reap is removed by hand.
#
# Files: state/.session-lock (+ transient .session-lock.tmp.<pid> /
# .session-lock.reap). Exit codes: 0 ok/skipped, 1 usage, 2 refused.

set -euo pipefail
. "$(dirname "$0")/ac-lib.sh"

state_dir="$(ac_state_dir)"
lock_file="$state_dir/.session-lock"
# The default alternation is the harness registry's known set (audit-f5): a
# 4th harness joins bin/ac-harness.sh and this matcher follows by itself.
harness_re="${AC_LOCK_HARNESS_RE:-$AC_HARNESS_RE}"

self_pid() {
  # The long-lived harness process this script runs under, by ancestry walk.
  if [ -n "${AC_LOCK_PID:-}" ]; then
    printf '%s\n' "$AC_LOCK_PID"
    return 0
  fi
  local pid=$$ cmd base stable="" match=""
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    if [ -n "$cmd" ]; then
      # A daemon worker's argv literally starts with a harness token
      # (`claude bg-spare --bg-spare <path>`, session-lock-claims-daemon-
      # spare-worker brief, 2026-07-22 evidence; `claude bg-pty-host` sits in
      # the same Stop-hook chain) but ROTATES - it is
      # never the long-lived harness the header names, and never a stable
      # fallback candidate either, so every `bg-*` worker token is skipped
      # like a shell rather than matched or recorded. ANCHORED to the worker
      # token appearing directly after the harness token - a bare substring
      # match would also skip a real harness whose argv merely CONTAINS
      # "bg-spare" elsewhere (e.g. a path segment), silently falling through
      # to a shared ancestor instead (chief-verify finding, repro'd live:
      # fell through to a shared `herdr server` pid, which every pane's
      # ancestry contains - a silent double-driver, the exact failure this
      # fix must never trade for).
      if printf '%s\n' "$cmd" | grep -qE "(^|[ /])($harness_re) bg-[a-z0-9-]+( |$)"; then
        :
      elif printf '%s\n' "$cmd" | grep -qE "(^|[ /])($harness_re)( |$)"; then
        # OUTERMOST match, not first: a
        # Claude Stop hook fires several levels below the session's actual
        # lock-owning process (hook shell -> claude bg-spare -> claude
        # bg-pty-host -> claude -> claude(lock)), so the nearest harness
        # ancestor can be an inner worker of the SAME session and ownership
        # checks then compare the wrong pid. Keep walking and answer with
        # the outermost harness ancestor; a chain with one match is
        # byte-identical to the old first-match answer, and a pane's chain
        # never reaches another session's harness (the daemon breaks it).
        match="$pid"
      else
        base="$(basename "${cmd%% *}")"
        case "$base" in
          bash|sh|zsh|dash|fish|-bash|-sh|-zsh|login|script) : ;;
          *) if [ -z "$stable" ] && [ "$pid" != "$$" ]; then stable="$pid"; fi ;;
        esac
      fi
    fi
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  done
  if [ -n "$match" ]; then
    printf '%s\n' "$match"
    return 0
  fi
  ac_warn "no harness ancestor matched ($harness_re) - locking with nearest stable ancestor pid ${stable:-$PPID}"
  printf '%s\n' "${stable:-$PPID}"
}

holder_alive() {
  # holder_alive <pid> - 0 when <pid> is not just ALIVE but is STILL the same
  # process that acquired the lock: mirrors ac-wake-lib.sh's ac_watcher_pid
  # PID-REUSE guard ("a recorded pid must still BE a watcher") for the
  # session lock, adapted to what this file can actually promise. Bare
  # ac_pid_alive alone means: after an unclean session end, the moment ANY
  # process is allocated the recorded pid, every acquire refuses ("another
  # chief session owns this home") until a human deletes the lock - and
  # silently inerts both Stop hooks, which then classify the true chief
  # session as read-only and exit 0 SILENTLY (ac-turnend-guard.sh,
  # ac-watch-autoarm.sh).
  # A fixed pattern (the harness regex) does not transfer: AC_LOCK_PID's
  # "unusual launcher" escape hatch means a recorded holder is not ALWAYS
  # literally claude/codex/opencode, so re-verifying against harness_re would
  # misjudge a legitimately non-harness holder as stale the instant anyone
  # asks - confirmed live (a custom-launcher-shaped AC_LOCK_PID session read
  # its OWN lock as stale from a second, unprivileged observer). What CAN be
  # verified without assuming the shape of a legitimate holder is IDENTITY:
  # do_acquire stamps `cmd=<observed command at acquire time>` alongside the
  # pid, and this compares it against the CURRENT command at that pid now - a
  # reused pid is running something else, byte-for-byte.
  # A missing fingerprint (a pre-fix lock, or the command was unreadable at
  # acquire time) or an unreadable CURRENT command fails toward HELD - the
  # safe direction: a false "still held" only wedges acquire, recoverable by
  # a human; a false "stale" risks two chiefs driving the SAME home at once.
  local pid="${1:-}" recorded current
  ac_pid_alive "$pid" || return 1
  recorded="$(ac_meta_get "$lock_file" cmd)"
  [ -n "$recorded" ] || return 0
  current="$(ps -o command= -p "$pid" 2>/dev/null || true)"
  [ -n "$current" ] || return 0
  [ "$current" = "$recorded" ]
}

self_owns() {
  # self_owns <holder-pid> <detected-pid> - 0 when the recorded holder IS this
  # session: the exact detected pid, or (RE-ENTRANCY) a pid anywhere in this
  # process's own ancestor chain. Same ancestry answer ac-turnend-guard.sh
  # already gives to the same question. AC_LOCK_PID pins identity EXACTLY and
  # never consults the ancestry - it overrides detection outright.
  local holder="${1:-}" me="${2:-}" pid
  [ -n "$holder" ] || return 1
  [ "$holder" = "$me" ] && return 0
  [ -z "${AC_LOCK_PID:-}" ] || return 1
  pid=$$
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null; do
    [ "$pid" = "$holder" ] && return 0
    pid="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)"
  done
  return 1
}

do_acquire() {
  if [ -n "${AC_SCOPE:-}" ]; then
    printf 'lock: skipped - scoped session (AC_SCOPE=%s) never owns the home\n' "$AC_SCOPE"
    return 0
  fi
  local me mycmd tmp reapdir holder since h2 s2 attempts=0 max_attempts=1000
  me="$(self_pid)"
  # The IDENTITY fingerprint holder_alive later re-verifies (see its header):
  # whatever this pid's command reads as right now, at acquire time. Absent
  # when unreadable - a later check against a missing fingerprint fails
  # toward HELD, never toward a false stale.
  mycmd="$(ps -o command= -p "$me" 2>/dev/null || true)"
  tmp="$lock_file.tmp.$$"
  reapdir="$lock_file.reap"
  # Fully populate the temp BEFORE the link so the lock is never seen pid-less.
  { printf 'pid=%s\nsince=%s\n' "$me" "$(ac_iso)"
    [ -z "$mycmd" ] || printf 'cmd=%s\n' "$mycmd"
  } >"$tmp"
  trap 'rm -f "$tmp"' RETURN
  # The atomic claim: link(2) fails if the lock path exists, so exactly one
  # racer wins and the winner is never overwritten.
  while ! ln "$tmp" "$lock_file" 2>/dev/null; do
    holder="$(ac_meta_get "$lock_file" pid)"
    since="$(ac_meta_get "$lock_file" since)"
    if self_owns "$holder" "$me"; then
      printf 'lock: already held by this session (pid %s since %s)\n' "$holder" "$since"
      return 0
    fi
    if [ -n "$holder" ] && holder_alive "$holder"; then
      printf 'ERROR: another chief session owns this home (pid %s since %s)\n' "$holder" "${since:-?}" >&2
      return 2
    fi
    # Stale (holder dead, empty, or alive-but-a-DIFFERENT-process now - pid
    # reuse). Reap under the mkdir gate: only the sole reaper removes the
    # corpse, and only while its pid still reads not-the-recorded-session - a
    # live lock is never removed - then everyone re-races the atomic claim.
    attempts=$((attempts + 1))
    if [ "$attempts" -gt "$max_attempts" ]; then
      printf 'ERROR: session lock did not settle after %s attempts (last holder pid %s) - leaked reap dir? remove %s\n' "$max_attempts" "${holder:-?}" "$reapdir" >&2
      return 2
    fi
    if mkdir "$reapdir" 2>/dev/null; then
      h2="$(ac_meta_get "$lock_file" pid)"
      s2="$(ac_meta_get "$lock_file" since)"
      if [ -n "$h2" ] && ! holder_alive "$h2"; then
        if ac_pid_alive "$h2"; then
          printf 'lock: recovering stale lock (pid %s alive but a DIFFERENT process now - pid reuse, held since %s)\n' "$h2" "${s2:-?}"
        else
          printf 'lock: recovering stale lock (pid %s dead, held since %s)\n' "$h2" "${s2:-?}"
        fi
        rm -f "$lock_file"
      fi
      rmdir "$reapdir" 2>/dev/null || true
    fi
  done
  # Read-back verify: the on-disk pid must be ours, else we lost and refuse.
  holder="$(ac_meta_get "$lock_file" pid)"
  if [ "$holder" != "$me" ]; then
    printf 'ERROR: lost the session-lock race after claim (on disk pid %s, this session pid %s)\n' "${holder:-?}" "$me" >&2
    return 2
  fi
  printf 'lock: acquired (pid %s)\n' "$me"
}

do_status() {
  local holder since
  [ -f "$lock_file" ] || { printf 'unlocked\n'; return 0; }
  holder="$(ac_meta_get "$lock_file" pid)"
  since="$(ac_meta_get "$lock_file" since)"
  if [ -n "$holder" ] && holder_alive "$holder"; then
    printf 'held pid=%s since=%s\n' "$holder" "${since:-?}"
  else
    printf 'stale pid=%s since=%s\n' "${holder:-?}" "${since:-?}"
  fi
}

do_release() {
  local me holder
  [ -f "$lock_file" ] || { printf 'lock: not held\n'; return 0; }
  holder="$(ac_meta_get "$lock_file" pid)"
  if [ -n "$holder" ] && holder_alive "$holder"; then
    me="$(self_pid)"
    if ! self_owns "$holder" "$me"; then
      printf 'ERROR: only the holder releases - held by live pid %s, this session is pid %s\n' "$holder" "$me" >&2
      return 2
    fi
  else
    printf 'lock: clearing stale lock (pid %s dead)\n' "${holder:-?}"
  fi
  rm -f "$lock_file"
  printf 'lock: released\n'
}

case "${1:-}" in
  acquire) do_acquire ;;
  status) do_status ;;
  release) do_release ;;
  *) ac_die 'usage: ac-lock.sh acquire | status | release' ;;
esac
