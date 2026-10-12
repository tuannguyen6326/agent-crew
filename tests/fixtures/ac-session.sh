#!/usr/bin/env bash
# ac-session.sh - open (or print) a claude resume of a crewmate's session.
# Provides a safe forked view and an explicit live-session talk path.
#
#   ac-session.sh <id>          # SAFE view: resume with --fork-session -
#                               # reading/replying never mutates the
#                               # crewmate's real session
#   ac-session.sh <id> --talk   # UN-FORKED resume: what you say lands in the
#                               # session a later --resume-from continues -
#                               # REFUSED while the crewmate is busy (two
#                               # writers corrupt one session)
#
# Prints the command by default (run it in any pane). Works on live and
# archived tasks (teardown keeps session_id in state/archive/<id>/meta).

set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd -P)"
. "$here/ac-lib.sh"

id="${1:-}"; talk=0
[ -n "$id" ] || ac_die "usage: ac-session.sh <id> [--talk]"
[ "${2:-}" = "--talk" ] && talk=1

meta="$(ac_task_meta "$id")"
live=1
if [ ! -f "$meta" ]; then
  meta="$(ac_state_dir)/archive/$id/meta"
  live=0
fi
[ -f "$meta" ] || ac_die "no crewmate meta for $id"
[ "$(ac_meta_get "$meta" harness)" = "claude" ] || ac_die "$id is not a claude crewmate"
sid="$(ac_meta_get "$meta" session_id)"
[ -n "$sid" ] || ac_die "$id has no recorded session_id (pre-plumbing task)"
worktree="$(ac_meta_get "$meta" worktree)"

if [ "$talk" = 1 ] && [ "$live" = 1 ]; then
  state="$("$here/ac-crew-state.sh" "$id" 2>/dev/null || printf 'unknown')"
  case "$state" in
    busy*|*working:*|validate:*)
      ac_die "REFUSED: $id is mid-turn ($state) - two writers corrupt one session. Talk when it parks, or ac-follow.sh to watch now." ;;
    unobservable*)
      # An unknown backend must not proceed here, the same direction as the
      # collision-refusal guard (records/repo-knowledge/agent-crew.md:90):
      # writing an un-forked --talk into a pane that turns out to still be
      # mid-turn corrupts the session, the same class of harm the collision
      # guard refuses to risk on an unknown backend (a REAP guard on the
      # other hand must not ACT on unknown - there is no write here to
      # withhold, so refusing IS this guard's "do nothing").
      ac_die "REFUSED: the backend for $id could not be read ($state) - liveness is UNKNOWN, and two writers corrupt one session if it is still mid-turn. Check the backend (herdr status server), then talk again once it is readable." ;;
  esac
fi

[ -d "$worktree" ] || ac_warn "worktree $worktree is gone; mkdir -p it to let --resume load the transcript"
if [ "$talk" = 1 ]; then
  printf '# TALK: un-forked - your words become part of what --resume-from continues\n'
  printf "cd '%s' && claude --resume %s\n" "$worktree" "$sid"
else
  printf '# VIEW: forked - safe to read and poke, never mutates the real session\n'
  printf "cd '%s' && claude --resume %s --fork-session\n" "$worktree" "$sid"
fi
